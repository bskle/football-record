import Foundation
import Darwin
import CryptoKit

enum M4CatalogFault: Sendable { case beforeCommit, afterCommitResponseLost }
enum M4CatalogSyncBoundary: String, Sendable { case catalogDirectory, publicationParent }
enum M4CatalogCrashPoint: String, Sendable {
  case afterStageCreate, afterSlotSync, afterOwnerCreateBeforeWrite, afterOwnerSync, beforeInitializationPublish
  case afterInitializationRename, afterInitializationPublish, afterPendingSync, afterPublicationRename, afterPublicationSync
  case afterCatalogDirectorySync, afterPublicationParentSync, beforeInactiveSlotWrite
}
private struct M4CatalogOwner: Codable {
  let version: Int
  let publicationID, initialDigest: String
  let owner: M4CatalogPath
  let slots, ancestors: [M4CatalogPath]
}
/// The basename is the durable publication descriptor, not a filename prefix
/// authorizing cleanup. Recovery also requires the exact original slot inode,
/// both revisions, and both complete payload hashes before changing any name.
private struct M4CatalogPublication {
  let beforeRevision, afterRevision: UInt64
  let beforeDigest, afterDigest: String
  var name: String { "catalog.pending.\(beforeRevision).\(afterRevision).\(beforeDigest).\(afterDigest)" }
  init(before: M4CatalogState, beforeBytes: Data, after: M4CatalogState, afterBytes: Data) throws {
    guard before.revision < UInt64.max, after.revision == before.revision + 1 else { throw M4CatalogError.intentMismatch }
    beforeRevision = before.revision; afterRevision = after.revision
    beforeDigest = M4CatalogIO.hash(beforeBytes); afterDigest = M4CatalogIO.hash(afterBytes)
  }
  init(name: String) throws {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 6, parts[0] == "catalog", parts[1] == "pending",
          let before = UInt64(parts[2]), let after = UInt64(parts[3]),
          String(before) == parts[2], String(after) == parts[3], before < UInt64.max,
          after == before + 1, M4CatalogIO.isDigest(parts[4]), M4CatalogIO.isDigest(parts[5]) else { throw M4CatalogError.unknownControl }
    beforeRevision = before; afterRevision = after; beforeDigest = parts[4]; afterDigest = parts[5]
  }
}
/// Owner and slot inodes are permanent. catalog.json is an atomic hard-link
/// publication of one slot; only the other proven slot may be overwritten.
/// Every transaction is bounded and synchronous, with no await under either lock.
final class M4CatalogJournal: @unchecked Sendable {
  static let maximumJournalBytes = 1_048_576
  private static let ownerLimit = 65_536, journalLimit = maximumJournalBytes
  private static let fixedNames: Set<String> = ["catalog.owner", "catalog.slot0", "catalog.slot1", "catalog.json"]
  private let lock = NSLock()
  private let directory, ownerURL, journalURL: URL
  private let owner: M4CatalogOwner
  private let ownerBytes: Data
  private let crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)?
  private var fd: Int32 = -1, directoryFD: Int32 = -1
  private var closed = false
  private var fault: M4CatalogFault?
  private var synchronizationFault: M4CatalogSyncBoundary?
  private enum OpeningPolicy { case initializeIfAbsent, existingOnly }
  convenience init(directory: URL, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)? = nil, synchronizationFault: M4CatalogSyncBoundary? = nil) throws {
    try self.init(directory: directory, opening: .initializeIfAbsent, crashHook: crashHook, synchronizationFault: synchronizationFault)
  }
  convenience init(existingDirectory: URL, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)? = nil, synchronizationFault: M4CatalogSyncBoundary? = nil) throws {
    try self.init(directory: existingDirectory, opening: .existingOnly, crashHook: crashHook, synchronizationFault: synchronizationFault)
  }
  private init(directory: URL, opening: OpeningPolicy, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)?, synchronizationFault: M4CatalogSyncBoundary?) throws {
    self.synchronizationFault = synchronizationFault
    guard directory.isFileURL else { throw M4CatalogError.storageBlocked }
    self.directory = M4CatalogIO.canonical(directory); self.crashHook = crashHook
    ownerURL = self.directory.appendingPathComponent("catalog.owner")
    journalURL = self.directory.appendingPathComponent("catalog.json")
    switch opening {
    case .initializeIfAbsent: try Self.initializeIfAbsent(self.directory, crashHook: crashHook)
    case .existingOnly: break
    }
    let bytes = try M4CatalogIO.read(ownerURL, limit: Self.ownerLimit)
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["version"] as? Int == 2 else { throw M4CatalogError.unsupportedSchema }
    owner = try M4CatalogIO.decode(bytes); ownerBytes = bytes
    directoryFD = Darwin.open(self.directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw M4CatalogError.storageBlocked }
    fd = Darwin.openat(directoryFD, "catalog.owner", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { Darwin.close(directoryFD); directoryFD = -1; throw M4CatalogError.storageBlocked }
    do {
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw M4CatalogError.busy }
      defer { flock(fd, LOCK_UN) }
      _ = try readState()
    } catch { Darwin.close(fd); Darwin.close(directoryFD); fd = -1; directoryFD = -1; throw error }
  }
  /// No partial initialization is ever published at the requested path. A
  /// killed unpublished candidate is preserved outside that path and is never
  /// scanned, adopted or deleted on retry. It contains no business payload.
  private static func initializeIfAbsent(_ directory: URL, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)?) throws {
    if M4CatalogIO.exists(directory) {
      guard try M4CatalogIO.anchor(directory).directory else { throw M4CatalogError.identityChanged }
      return // Empty, legacy or incomplete existing roots are not newly adopted.
    }
    let parent = directory.deletingLastPathComponent()
    try M4CatalogIO.ensureDirectory(parent)
    let parentAnchor = try M4CatalogIO.anchor(parent)
    let parentChain = [parentAnchor] + (try M4CatalogIO.ancestors([parentAnchor]))
    let publicationID = UUID().uuidString
    let empty = try M4CatalogIO.encode(M4CatalogState.empty), initialDigest = M4CatalogIO.hash(empty)
    func placeholder(_ name: String, directory isDirectory: Bool = false) -> M4CatalogPath {
      M4CatalogPath(path: name.isEmpty ? directory.path : directory.appendingPathComponent(name).path,
        device: parentAnchor.device, inode: UInt64.max, directory: isDirectory)
    }
    // Upper-bound every as-yet-unknown inode before creating any candidate file.
    // Real inode decimal encodings can only be shorter than these placeholders.
    let prospective = M4CatalogOwner(version: 2, publicationID: publicationID, initialDigest: initialDigest,
      owner: placeholder("catalog.owner"), slots: [placeholder("catalog.slot0"), placeholder("catalog.slot1")],
      ancestors: ([placeholder("", directory: true)] + parentChain).sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) })
    guard try M4CatalogIO.encode(prospective).count <= ownerLimit else { throw M4CatalogError.budgetExceeded }
    let parentFD = Darwin.open(parent.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(parentFD) }
    let stageName = "." + directory.lastPathComponent + ".init-" + publicationID
    guard stageName.utf8.count <= 255, mkdirat(parentFD, stageName, S_IRWXU) == 0 else { throw M4CatalogError.storageBlocked }
    let stage = parent.appendingPathComponent(stageName, isDirectory: true)
    let stageFD = Darwin.openat(parentFD, stageName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard stageFD >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(stageFD) }
    guard fsync(parentFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterStageCreate)
    func create(_ name: String, _ bytes: Data) throws {
      let file = Darwin.openat(stageFD, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      guard file >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(file) }
      try M4CatalogIO.writeDescriptor(file, bytes: bytes)
    }
    try create("catalog.slot0", empty); try create("catalog.slot1", Data())
    guard fsync(stageFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterSlotSync)
    // The owner inode must exist to bind its actual identity, but remains in the
    // private, unpublished candidate until every control is durable and valid.
    try create("catalog.owner", Data())
    crashHook?(.afterOwnerCreateBeforeWrite)
    func rebound(_ actual: M4CatalogPath, name: String) -> M4CatalogPath {
      M4CatalogPath(path: directory.appendingPathComponent(name).path, device: actual.device, inode: actual.inode, directory: actual.directory)
    }
    let actualOwner = try M4CatalogIO.anchor(stage.appendingPathComponent("catalog.owner"))
    let actualSlots = try ["catalog.slot0", "catalog.slot1"].map { try rebound(M4CatalogIO.anchor(stage.appendingPathComponent($0)), name: $0) }
    let actualAncestors = try M4CatalogIO.ancestors([actualOwner]).map { value in
      M4CatalogIO.raw(value.path, stage.path) ? M4CatalogPath(path: directory.path, device: value.device, inode: value.inode, directory: true) : value
    }.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
    let owner = M4CatalogOwner(version: 2, publicationID: publicationID, initialDigest: initialDigest,
      owner: rebound(actualOwner, name: "catalog.owner"), slots: actualSlots, ancestors: actualAncestors)
    let bytes = try M4CatalogIO.encode(owner)
    guard bytes.count <= ownerLimit else { throw M4CatalogError.budgetExceeded }
    let ownerFD = Darwin.openat(stageFD, "catalog.owner", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard ownerFD >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(ownerFD) }
    try M4CatalogIO.writeDescriptor(ownerFD, bytes: bytes)
    guard fsync(stageFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterOwnerSync)
    guard linkat(stageFD, "catalog.slot0", stageFD, "catalog.json", 0) == 0, fsync(stageFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.beforeInitializationPublish)
    guard try M4CatalogIO.encode(parentChain) == M4CatalogIO.encode([M4CatalogIO.anchor(parent)] + M4CatalogIO.ancestors([parentAnchor])) else { throw M4CatalogError.identityChanged }
    var held = stat(); guard fstat(parentFD, &held) == 0, UInt64(UInt32(bitPattern: held.st_dev)) == parentAnchor.device, held.st_ino == parentAnchor.inode else { throw M4CatalogError.identityChanged }
    // RENAME_EXCL cannot replace an unknown or concurrently published directory.
    guard renameatx_np(parentFD, stageName, parentFD, directory.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.busy }
    crashHook?(.afterInitializationRename)
    guard fsync(parentFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterInitializationPublish)
  }
  private func validateOwner() throws {
    guard !closed, fd >= 0, directoryFD >= 0 else { throw M4CatalogError.closed }
    guard owner.version == 2, UUID(uuidString: owner.publicationID)?.uuidString == owner.publicationID,
          owner.initialDigest == M4CatalogIO.hash(try M4CatalogIO.encode(M4CatalogState.empty)), owner.slots.count == 2,
          M4CatalogIO.raw(owner.owner.path, ownerURL.path), try M4CatalogIO.read(ownerURL, limit: Self.ownerLimit) == ownerBytes,
          try M4CatalogIO.encode(M4CatalogIO.anchor(ownerURL)) == M4CatalogIO.encode(owner.owner),
          try M4CatalogIO.encode(M4CatalogIO.ancestors([owner.owner])) == M4CatalogIO.encode(owner.ancestors) else { throw M4CatalogError.identityChanged }
    for index in 0..<2 {
      guard M4CatalogIO.raw(owner.slots[index].path, directory.appendingPathComponent("catalog.slot\(index)").path),
            try M4CatalogIO.encode(M4CatalogIO.anchor(URL(fileURLWithPath: owner.slots[index].path))) == M4CatalogIO.encode(owner.slots[index]) else { throw M4CatalogError.identityChanged }
    }
    var held = stat(), heldDirectory = stat()
    guard let directoryAnchor = owner.ancestors.first(where: { M4CatalogIO.raw($0.path, directory.path) }),
      fstat(fd, &held) == 0, UInt64(UInt32(bitPattern: held.st_dev)) == owner.owner.device, held.st_ino == owner.owner.inode,
      fstat(directoryFD, &heldDirectory) == 0, UInt64(UInt32(bitPattern: heldDirectory.st_dev)) == directoryAnchor.device, heldDirectory.st_ino == directoryAnchor.inode else { throw M4CatalogError.identityChanged }
  }
  /// A prior process may have renamed either the whole catalog or catalog.json
  /// without reaching directory fsync. Stabilize both namespace levels before
  /// exposing that read or reusing the old slot. No payload or name is changed.
  private func stabilizePublication() throws {
    try validateOwner()
    let parent = directory.deletingLastPathComponent()
    guard let expected = owner.ancestors.first(where: { M4CatalogIO.raw($0.path, parent.path) }), expected.directory else { throw M4CatalogError.identityChanged }
    let parentFD = Darwin.open(parent.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(parentFD) }
    var held = stat()
    guard fstat(parentFD, &held) == 0, (held.st_mode & S_IFMT) == S_IFDIR,
          UInt64(UInt32(bitPattern: held.st_dev)) == expected.device, held.st_ino == expected.inode else { throw M4CatalogError.identityChanged }
    if synchronizationFault == .catalogDirectory { synchronizationFault = nil; throw M4CatalogError.storageBlocked }
    guard fsync(directoryFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterCatalogDirectorySync)
    if synchronizationFault == .publicationParent { synchronizationFault = nil; throw M4CatalogError.storageBlocked }
    guard fsync(parentFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterPublicationParentSync)
    try validateOwner()
    guard fstat(parentFD, &held) == 0, UInt64(UInt32(bitPattern: held.st_dev)) == expected.device, held.st_ino == expected.inode else { throw M4CatalogError.identityChanged }
  }
  private func checkedState(_ bytes: Data) throws -> M4CatalogState {
    let state: M4CatalogState = try M4CatalogIO.decode(bytes); try state.validate()
    for entry in state.entries { try entry.capsule.verifyCurrent(); try requireOutside(entry.capsule) }
    return state
  }
  private func committed() throws -> (state: M4CatalogState, bytes: Data, slot: Int) {
    let anchor = try M4CatalogIO.anchor(journalURL)
    guard let slot = owner.slots.firstIndex(where: { M4CatalogIO.sameInode($0, anchor) }) else { throw M4CatalogError.identityChanged }
    let bytes = try M4CatalogIO.read(journalURL, limit: Self.journalLimit)
    return (try checkedState(bytes), bytes, slot)
  }
  private func readState() throws -> M4CatalogState {
    try validateOwner()
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    guard Self.fixedNames.isSubset(of: names) else { throw M4CatalogError.unknownControl }
    let extra = names.subtracting(Self.fixedNames)
    guard extra.count <= 1 else { throw M4CatalogError.unknownControl }
    try stabilizePublication()
    let current = try committed()
    if let name = extra.first {
      let publication = try M4CatalogPublication(name: name)
      let path = directory.appendingPathComponent(name), candidateAnchor = try M4CatalogIO.anchor(path)
      guard let slot = owner.slots.firstIndex(where: { M4CatalogIO.sameInode($0, candidateAnchor) }) else { throw M4CatalogError.identityChanged }
      let bytes = try M4CatalogIO.read(path, limit: Self.journalLimit), candidate = try checkedState(bytes)
      guard candidate.revision == publication.afterRevision, M4CatalogIO.hash(bytes) == publication.afterDigest else { throw M4CatalogError.intentMismatch }
      if current.state.revision == publication.beforeRevision, M4CatalogIO.hash(current.bytes) == publication.beforeDigest, slot != current.slot {
        try validateOwner()
        guard renameat(directoryFD, name, directoryFD, "catalog.json") == 0 else { throw M4CatalogError.storageBlocked }
      } else {
        // This publisher always renames a different inactive slot. Atomic rename
        // consumes the descriptor name; an extra link to the current slot has no
        // supported publisher history, so preserve it and refuse to guess.
        throw M4CatalogError.intentMismatch
      }
      try stabilizePublication(); return try committed().state
    }
    return current.state
  }
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      guard !closed, fd >= 0 else { throw M4CatalogError.closed }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw M4CatalogError.busy }
      defer { flock(fd, LOCK_UN) }; return try body()
    }
  }
  func read() throws -> M4CatalogState { try locked { try readState() } }
  func transaction(_ mutate: (inout M4CatalogState) throws -> Void) throws {
    try locked {
      let before = try readState(); var after = before
      try mutate(&after)
      guard try M4CatalogIO.encode(before) != M4CatalogIO.encode(after) else { return }
      guard after.revision < UInt64.max else { throw M4CatalogError.budgetExceeded }
      after.revision += 1; try after.validate()
      let bytes = try M4CatalogIO.encode(after)
      guard bytes.count <= Self.journalLimit else { throw M4CatalogError.budgetExceeded }
      let injected = fault; fault = nil
      if injected == .beforeCommit { throw M4CatalogError.injectedFailure }
      try writeState(after)
      if injected == .afterCommitResponseLost { throw M4CatalogError.injectedFailure }
      guard try M4CatalogIO.encode(readState()) == bytes else { throw M4CatalogError.storageBlocked }
    }
  }
  private func writeState(_ state: M4CatalogState) throws {
    try stabilizePublication()
    let current = try committed(), bytes = try M4CatalogIO.encode(state)
    guard bytes.count <= Self.journalLimit else { throw M4CatalogError.budgetExceeded }
    let publication = try M4CatalogPublication(before: current.state, beforeBytes: current.bytes, after: state, afterBytes: bytes)
    guard publication.name.utf8.count <= 255 else { throw M4CatalogError.budgetExceeded }
    let slot = 1 - current.slot, name = "catalog.slot\(slot)"
    let candidateFD = Darwin.openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard candidateFD >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(candidateFD) }
    var held = stat()
    guard fstat(candidateFD, &held) == 0, UInt64(UInt32(bitPattern: held.st_dev)) == owner.slots[slot].device, held.st_ino == owner.slots[slot].inode else { throw M4CatalogError.identityChanged }
    crashHook?(.beforeInactiveSlotWrite)
    try M4CatalogIO.writeDescriptor(candidateFD, bytes: bytes)
    try validateOwner()
    guard linkat(directoryFD, name, directoryFD, publication.name, 0) == 0, fsync(directoryFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterPendingSync)
    try validateOwner()
    guard renameat(directoryFD, publication.name, directoryFD, "catalog.json") == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterPublicationRename)
    guard fsync(directoryFD) == 0 else { throw M4CatalogError.storageBlocked }
    crashHook?(.afterPublicationSync)
  }
  func requireOutside(_ capsule: M4OwnershipCapsule) throws {
    let current = try M4CatalogIO.anchor(directory)
    guard !([owner.owner] + owner.slots + [current]).contains(where: { M4CatalogIO.sameInode(capsule.root, $0) }) else { throw M4CatalogError.identityChanged }
    if capsule.root.directory { guard !owner.ancestors.contains(where: { M4CatalogIO.sameInode($0, capsule.root) }) else { throw M4CatalogError.identityChanged } }
  }
  func injectNextFailure(_ value: M4CatalogFault) { lock.withLock { fault = value } }
  func injectNextSynchronizationFailure(_ value: M4CatalogSyncBoundary) { lock.withLock { synchronizationFault = value } }
  func close() throws { lock.withLock { if !closed { closed = true; Darwin.close(fd); Darwin.close(directoryFD); fd = -1; directoryFD = -1 } } }
  deinit { if fd >= 0 { Darwin.close(fd) }; if directoryFD >= 0 { Darwin.close(directoryFD) } }
}

enum M4CatalogIO {
  static func canonical(_ url: URL) -> URL {
    let path = url.standardizedFileURL.path
    if path == "/var" || path == "/tmp" || path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return URL(fileURLWithPath: "/private" + path) }
    return url.standardizedFileURL
  }
  static func raw(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
  static func opaque(_ value: String, limit: Int) -> Bool { !value.utf8.isEmpty && value.utf8.count <= limit && !value.utf8.contains(0) }
  static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
  static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  static func framedHash(domain: String, fields: [String]) -> String {
    var bytes = Data((domain + "\0").utf8)
    for field in fields {
      let value = Data(field.utf8); var count = UInt64(value.count).bigEndian
      withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(value)
    }
    return hash(bytes)
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
  }
  static func decode<T: Codable>(_ bytes: Data) throws -> T {
    do {
      let value = try JSONDecoder().decode(T.self, from: bytes)
      guard try encode(value) == bytes else { throw M4CatalogError.storageBlocked }; return value
    } catch let error as M4CatalogError { throw error } catch { throw M4CatalogError.storageBlocked }
  }
  static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
  static func validate(_ value: M4CatalogPath) throws {
    guard value.path.hasPrefix("/"), opaque(value.path, limit: 4096), value.inode > 0,
          raw(canonical(URL(fileURLWithPath: value.path)).path, value.path) else { throw M4CatalogError.identityChanged }
  }
  static func anchor(_ url: URL) throws -> M4CatalogPath {
    guard url.isFileURL else { throw M4CatalogError.identityChanged }
    let url = canonical(url); var st = stat()
    guard lstat(url.path, &st) == 0, [S_IFDIR, S_IFREG].contains(st.st_mode & S_IFMT) else { throw M4CatalogError.identityChanged }
    let value = M4CatalogPath(path: url.path, device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino, directory: (st.st_mode & S_IFMT) == S_IFDIR)
    try validate(value)
    var parent = url.deletingLastPathComponent()
    while parent.path != "/" {
      var st = stat(); guard lstat(parent.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw M4CatalogError.identityChanged }
      parent.deleteLastPathComponent()
    }
    return value
  }
  static func sameInode(_ a: M4CatalogPath, _ b: M4CatalogPath) -> Bool { a.device == b.device && a.inode == b.inode }
  static func ancestors(_ values: [M4CatalogPath]) throws -> [M4CatalogPath] {
    var seen = Set<Data>(), result: [M4CatalogPath] = []
    for value in values {
      var parent = URL(fileURLWithPath: value.path).deletingLastPathComponent()
      while true {
        if seen.insert(Data(parent.path.utf8)).inserted { result.append(try anchor(parent)) }
        if parent.path == "/" { break }; parent.deleteLastPathComponent()
      }
    }
    return result.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
  }
  static func ensureDirectory(_ url: URL) throws {
    if exists(url) { guard try anchor(url).directory else { throw M4CatalogError.identityChanged }; return }
    let parent = url.deletingLastPathComponent(); try ensureDirectory(parent)
    guard mkdir(url.path, S_IRWXU) == 0 || errno == EEXIST else { throw M4CatalogError.storageBlocked }
    guard try anchor(url).directory else { throw M4CatalogError.identityChanged }
    try syncDirectory(url); try syncDirectory(parent)
  }
  static func read(_ url: URL, limit: Int) throws -> Data {
    let expected = try anchor(url); guard !expected.directory else { throw M4CatalogError.identityChanged }
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, UInt64(UInt32(bitPattern: st.st_dev)) == expected.device, st.st_ino == expected.inode,
          st.st_size > 0, st.st_size <= limit else { throw M4CatalogError.storageBlocked }
    var bytes = Data(count: Int(st.st_size)); let size = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
    guard size == bytes.count else { throw M4CatalogError.storageBlocked }; return bytes
  }
  static func writeDescriptor(_ fd: Int32, bytes: Data) throws {
    guard bytes.withUnsafeBytes({ Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }) == bytes.count,
          ftruncate(fd, off_t(bytes.count)) == 0, fsync(fd) == 0 else { throw M4CatalogError.storageBlocked }
  }
  static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4CatalogError.storageBlocked }; defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw M4CatalogError.storageBlocked }
  }
}
