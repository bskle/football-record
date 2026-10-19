import Foundation
import Darwin
import CryptoKit

enum M4CatalogFault: Sendable { case beforeCommit, afterCommitResponseLost }
private struct M4CatalogOwner: Codable {
  let version: Int
  let owner: M4CatalogPath
  let ancestors: [M4CatalogPath]
}
/// The owner inode and directory ancestry are retained permanently. Only the
/// bounded canonical journal is atomically replaced; no await occurs under lock.
final class M4CatalogJournal: @unchecked Sendable {
  private let lock = NSLock()
  private let directory, ownerURL, journalURL: URL
  private let owner: M4CatalogOwner
  private let ownerBytes: Data
  private var fd: Int32
  private var closed = false
  private var fault: M4CatalogFault?
  init(directory: URL) throws {
    guard directory.isFileURL else { throw M4CatalogError.storageBlocked }
    self.directory = M4CatalogIO.canonical(directory)
    ownerURL = self.directory.appendingPathComponent("catalog.owner")
    journalURL = self.directory.appendingPathComponent("catalog.json")
    try M4CatalogIO.ensureDirectory(self.directory)
    let names = try FileManager.default.contentsOfDirectory(atPath: self.directory.path)
    let exists = M4CatalogIO.exists(ownerURL)
    guard Set(names).isSubset(of: ["catalog.owner", "catalog.json"]), exists || names.isEmpty else { throw M4CatalogError.unknownControl }
    let flags = exists ? O_RDWR | O_CLOEXEC | O_NOFOLLOW : O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL
    let descriptor = Darwin.open(ownerURL.path, flags, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw M4CatalogError.storageBlocked }
    fd = descriptor
    do {
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw M4CatalogError.busy }
      defer { flock(descriptor, LOCK_UN) }
      let anchor = try M4CatalogIO.anchor(ownerURL), ancestors = try M4CatalogIO.ancestors([anchor])
      if exists {
        let bytes = try M4CatalogIO.read(ownerURL, limit: 65536)
        let value: M4CatalogOwner = try M4CatalogIO.decode(bytes)
        guard value.version == 1, try M4CatalogIO.encode(value.owner) == M4CatalogIO.encode(anchor),
              try M4CatalogIO.encode(value.ancestors) == M4CatalogIO.encode(ancestors) else { throw M4CatalogError.identityChanged }
        owner = value; ownerBytes = bytes
        _ = try readState()
      } else {
        owner = M4CatalogOwner(version: 1, owner: anchor, ancestors: ancestors)
        ownerBytes = try M4CatalogIO.encode(owner)
        try M4CatalogIO.writeDescriptor(descriptor, bytes: ownerBytes)
        try M4CatalogIO.syncDirectory(self.directory)
        try writeState(.empty)
      }
    } catch { Darwin.close(descriptor); fd = -1; throw error }
  }
  private func validateOwner() throws {
    guard !closed, fd >= 0 else { throw M4CatalogError.closed }
    guard try M4CatalogIO.read(ownerURL, limit: 65536) == ownerBytes,
          try M4CatalogIO.encode(M4CatalogIO.anchor(ownerURL)) == M4CatalogIO.encode(owner.owner),
          try M4CatalogIO.encode(M4CatalogIO.ancestors([owner.owner])) == M4CatalogIO.encode(owner.ancestors) else { throw M4CatalogError.identityChanged }
    var held = stat(); guard fstat(fd, &held) == 0, UInt64(UInt32(bitPattern: held.st_dev)) == owner.owner.device, held.st_ino == owner.owner.inode else { throw M4CatalogError.identityChanged }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard Set(names) == ["catalog.owner", "catalog.json"] else { throw M4CatalogError.unknownControl }
  }
  private func readState() throws -> M4CatalogState {
    try validateOwner()
    let state: M4CatalogState = try M4CatalogIO.decode(M4CatalogIO.read(journalURL, limit: 1_048_576))
    try state.validate()
    for entry in state.entries { try entry.capsule.verifyCurrent(); try requireOutside(entry.capsule) }
    return state
  }
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      guard !closed, fd >= 0 else { throw M4CatalogError.closed }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw M4CatalogError.busy }
      defer { flock(fd, LOCK_UN) }
      return try body()
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
      guard bytes.count <= 1_048_576 else { throw M4CatalogError.budgetExceeded }
      let injected = fault; fault = nil
      if injected == .beforeCommit { throw M4CatalogError.injectedFailure }
      try writeState(after)
      if injected == .afterCommitResponseLost { throw M4CatalogError.injectedFailure }
      guard try M4CatalogIO.encode(readState()) == bytes else { throw M4CatalogError.storageBlocked }
    }
  }
  private func writeState(_ state: M4CatalogState) throws {
    let bytes = try M4CatalogIO.encode(state)
    guard bytes.count <= 1_048_576 else { throw M4CatalogError.budgetExceeded }
    let temporary = directory.appendingPathComponent("catalog-" + UUID().uuidString + ".pending")
    let temporaryFD = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard temporaryFD >= 0 else { throw M4CatalogError.storageBlocked }
    defer { Darwin.close(temporaryFD) }
    do {
      try M4CatalogIO.writeDescriptor(temporaryFD, bytes: bytes)
      guard Darwin.rename(temporary.path, journalURL.path) == 0 else { throw M4CatalogError.storageBlocked }
      try M4CatalogIO.syncDirectory(directory)
    } catch {
      // Only this operation's exclusively-created temporary name is eligible.
      if M4CatalogIO.exists(temporary) { _ = Darwin.unlink(temporary.path) }
      throw error
    }
  }
  func requireOutside(_ capsule: M4OwnershipCapsule) throws {
    let current = try M4CatalogIO.anchor(directory)
    guard !M4CatalogIO.sameInode(capsule.root, owner.owner), !M4CatalogIO.sameInode(capsule.root, current) else { throw M4CatalogError.identityChanged }
    if capsule.root.directory {
      guard !owner.ancestors.contains(where: { M4CatalogIO.sameInode($0, capsule.root) }) else { throw M4CatalogError.identityChanged }
    }
  }
  func injectNextFailure(_ value: M4CatalogFault) { lock.withLock { fault = value } }
  func close() throws { lock.withLock { if !closed { closed = true; Darwin.close(fd); fd = -1 } } }
  deinit { if fd >= 0 { Darwin.close(fd) } }
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
