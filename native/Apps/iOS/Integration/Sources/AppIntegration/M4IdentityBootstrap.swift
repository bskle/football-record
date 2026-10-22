import Foundation
import Darwin
import AccountKit
import MatchStore
import MatchSession
#if DEBUG
import MatchPresentation
#endif

enum M4BootstrapError: Error, Equatable {
  case invalidNamespace, identityUnavailable, foreignNamespace, storageUnavailable
  case leaseInUse, alreadyOpened, closed
}
struct M4IdentitySeed: Sendable {
  let root, namespaceDirectory, controlDirectory, businessDatabaseURL: URL
  let namespace, installationID: String
  let businessExisted: Bool
}
/// Protocol fixtures or a later approved original vault supply this material.
/// This bootstrap never constructs a real SDK store or generates a signing key.
struct M4IdentityMaterial: Sendable {
  let signer: any DeviceProofSigner
  let vault: any DeviceCredentialVault
}
enum M4ResourceCrashPoint: Sendable { case afterReservation, afterResourceRename, afterBusinessRename }

@MainActor final class M4PreparedIdentity {
  let seed: M4IdentitySeed
  let material: M4IdentityMaterial
  private let lease: M4NamespaceLease
  private var repository: SQLiteSessionRepository?
  private var resources: M4PhysicalResourceOwner?
  private var managedResourcesRequired = false
  private var closed = false
  fileprivate init(seed: M4IdentitySeed, material: M4IdentityMaterial, lease: M4NamespaceLease) {
    self.seed = seed; self.material = material; self.lease = lease
  }
  func prepareManagedResources(crashHook: ((M4ResourceCrashPoint) throws -> Void)? = nil) throws {
    guard !closed, repository == nil, resources == nil else { throw M4BootstrapError.alreadyOpened }
    try lease.verifyIdentity()
    managedResourcesRequired = true
    resources = try M4PhysicalResourceOwner(seed: seed, keyID: AuthorityWire.deviceKeyID(publicKey: material.signer.publicKey), crashHook: crashHook)
  }
  func openRepository(authorityTrust: AuthorityTrustConfiguration? = nil, cloudSavePolicy: CloudSaveProofPolicy = .unavailable) throws -> SQLiteSessionRepository {
    guard !closed else { throw M4BootstrapError.closed }
    guard repository == nil else { throw M4BootstrapError.alreadyOpened }
    guard !managedResourcesRequired || resources != nil else { throw M4BootstrapError.identityUnavailable }
    try lease.verifyIdentity()
    try resources?.verify()
    let value = try SQLiteSessionRepository(rootDirectory: seed.root, databaseNamespace: seed.namespace, authorityTrust: authorityTrust, cloudSavePolicy: cloudSavePolicy)
    repository = value
    try resources?.verify()
    return value
  }
  func close() async throws {
    guard !closed else { return }
    try lease.verifyIdentity()
    try resources?.close()
    try await repository?.close(); repository = nil
    closed = true; lease.close()
  }
}
/// Owns only original physical publication in this slice. Ledger slot stays empty
/// until a later verified scope attachment; no account or deletion authority.
@MainActor private final class M4PhysicalResourceOwner {
  let catalog: M4OwnedDataCatalog
  let reservation: M4PhysicalResourceReservation
  private var closed = false
  init(seed: M4IdentitySeed, keyID: String, crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    let parent = seed.controlDirectory.deletingLastPathComponent()
    let directory = parent.appendingPathComponent("resources", isDirectory: true)
    let catalogDirectory = parent.appendingPathComponent("catalog", isDirectory: true)
    // A pre-existing positive database never creates a replacement catalog.
    guard !seed.businessExisted || M4CatalogIO.exists(catalogDirectory) else { throw M4BootstrapError.identityUnavailable }
    catalog = try M4OwnedDataCatalog(directory: catalogDirectory)
    do {
      if let prior = try catalog.physicalBootstrap() {
        reservation = prior.reservation
      } else {
        guard !seed.businessExisted, !M4CatalogIO.exists(seed.businessDatabaseURL), !M4CatalogIO.exists(directory) else { throw M4BootstrapError.identityUnavailable }
        let candidate = try Self.makeCandidate(seed: seed, directory: directory, keyID: keyID, catalogDirectory: catalogDirectory)
        try catalog.reservePhysicalBootstrap(candidate)
        guard let readback = try catalog.physicalBootstrap(), try M4CatalogIO.encode(readback.reservation) == M4CatalogIO.encode(candidate) else { throw M4CatalogError.storageBlocked }
        reservation = candidate
      }
      guard M4CatalogIO.raw(reservation.namespace, seed.namespace), M4CatalogIO.raw(reservation.installationID, seed.installationID),
            reservation.keyID == keyID, M4CatalogIO.raw(reservation.directory.path, directory.path),
            M4CatalogIO.raw(reservation.businessDatabase.path, seed.businessDatabaseURL.path),
            try M4CatalogIO.encode(reservation.identityControls) == M4CatalogIO.encode([
              M4CatalogIO.anchor(seed.controlDirectory.appendingPathComponent("identity.owner")), M4CatalogIO.anchor(seed.namespaceDirectory.appendingPathComponent("device.identity"))]) else { throw M4BootstrapError.identityUnavailable }
      try crashHook?(.afterReservation)
      try publishResourceDirectory(crashHook: crashHook)
      try publishBusinessFile(crashHook: crashHook)
      try verify()
    } catch { try? catalog.close(); throw error }
  }
  private static func makeCandidate(seed: M4IdentitySeed, directory: URL, keyID: String, catalogDirectory: URL) throws -> M4PhysicalResourceReservation {
    let id = UUID().uuidString, parent = directory.deletingLastPathComponent()
    let candidate = parent.appendingPathComponent(".resources.init-" + id, isDirectory: true)
    guard mkdir(candidate.path, S_IRWXU) == 0 else { throw M4BootstrapError.storageUnavailable }
    try M4CatalogIO.syncDirectory(parent)
    func create(_ name: String) throws {
      let url = candidate.appendingPathComponent(name)
      let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
      try M4CatalogIO.writeDescriptor(fd, bytes: Data())
    }
    try create("resource.owner"); try create("business.slot"); try create("ledger.slot")
    func atFinal(_ value: M4CatalogPath) -> M4CatalogPath {
      M4CatalogPath(path: value.path == candidate.path ? directory.path : directory.path + String(value.path.dropFirst(candidate.path.count)), device: value.device, inode: value.inode, directory: value.directory)
    }
    let sourceBusiness = try M4CatalogIO.anchor(candidate.appendingPathComponent("business.slot"))
    let business = M4CatalogPath(path: seed.businessDatabaseURL.path, device: sourceBusiness.device, inode: sourceBusiness.inode, directory: false)
    let controls = try [M4CatalogIO.anchor(seed.controlDirectory.appendingPathComponent("identity.owner")), M4CatalogIO.anchor(seed.namespaceDirectory.appendingPathComponent("device.identity"))]
    let catalogControls = try ["catalog.owner", "catalog.slot0", "catalog.slot1"].map { try M4CatalogIO.anchor(catalogDirectory.appendingPathComponent($0)) }
    let catalogOwnerDigest = try M4CatalogIO.hash(M4CatalogIO.read(catalogDirectory.appendingPathComponent("catalog.owner"), limit: 65536))
    let actualOwner = try M4CatalogIO.anchor(candidate.appendingPathComponent("resource.owner"))
    let ancestors = try M4CatalogIO.ancestors([actualOwner, business] + controls + catalogControls).map { M4CatalogIO.raw($0.path, candidate.path) ? atFinal($0) : $0 }.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
    let value = try M4PhysicalResourceReservation(version: 1, reservationID: id, namespace: seed.namespace, installationID: seed.installationID, keyID: keyID,
      candidate: M4CatalogIO.anchor(candidate), directory: atFinal(M4CatalogIO.anchor(candidate)), owner: atFinal(actualOwner),
      businessSlot: atFinal(sourceBusiness), businessDatabase: business, ledgerSlot: atFinal(M4CatalogIO.anchor(candidate.appendingPathComponent("ledger.slot"))), identityControls: controls, catalogControls: catalogControls, ancestors: ancestors, catalogOwnerDigest: catalogOwnerDigest)
    try value.validate()
    let bytes = try M4CatalogIO.encode(value)
    guard bytes.count <= 65536 else { throw M4CatalogError.budgetExceeded }
    let fd = Darwin.open(candidate.appendingPathComponent("resource.owner").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
    try M4CatalogIO.writeDescriptor(fd, bytes: bytes); try M4CatalogIO.syncDirectory(candidate); try M4CatalogIO.syncDirectory(parent)
    return value
  }
  private func state() throws -> M4PhysicalBootstrapState {
    guard let value = try catalog.physicalBootstrap(), try M4CatalogIO.encode(value.reservation) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.identityChanged }; return value
  }
  private func original(_ expected: M4CatalogPath, at url: URL) throws {
    let actual = try M4CatalogIO.anchor(url)
    guard actual.directory == expected.directory, M4CatalogIO.sameInode(actual, expected) else { throw M4CatalogError.identityChanged }
  }
  private func resourceLocation() throws -> URL {
    let source = URL(fileURLWithPath: reservation.candidate.path), target = URL(fileURLWithPath: reservation.directory.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    let actual = hasSource ? source : target
    try original(reservation.directory, at: actual)
    try original(reservation.owner, at: actual.appendingPathComponent("resource.owner"))
    guard try M4CatalogIO.read(actual.appendingPathComponent("resource.owner"), limit: 65536) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.identityChanged }
    for expected in reservation.ancestors {
      let url = URL(fileURLWithPath: expected.path == reservation.directory.path ? actual.path : expected.path)
      try original(expected, at: url)
    }
    for expected in reservation.identityControls + reservation.catalogControls { try original(expected, at: URL(fileURLWithPath: expected.path)) }
    guard try M4CatalogIO.hash(M4CatalogIO.read(URL(fileURLWithPath: reservation.catalogControls[0].path), limit: 65536)) == reservation.catalogOwnerDigest else { throw M4CatalogError.identityChanged }
    let actualAncestors = try M4CatalogIO.ancestors([M4CatalogIO.anchor(actual.appendingPathComponent("resource.owner")), reservation.businessDatabase] + reservation.identityControls + reservation.catalogControls).map { value in
      M4CatalogIO.raw(value.path, actual.path) ? M4CatalogPath(path: reservation.directory.path, device: value.device, inode: value.inode, directory: value.directory) : value
    }.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
    guard try M4CatalogIO.encode(actualAncestors) == M4CatalogIO.encode(reservation.ancestors) else { throw M4CatalogError.identityChanged }
    var mode = stat()
    guard lstat(actual.path, &mode) == 0, mode.st_uid == geteuid(), mode.st_mode & 0o7777 == 0o700 else { throw M4CatalogError.identityChanged }
    try privateFile(actual.appendingPathComponent("resource.owner"))
    return actual
  }
  private func privateFile(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o7777 == 0o600 else { throw M4CatalogError.identityChanged }
  }
  private func requireEmpty(_ url: URL, original expected: M4CatalogPath) throws {
    try original(expected, at: url); try privateFile(url)
    var st = stat(); guard lstat(url.path, &st) == 0, st.st_size == 0, st.st_nlink == 1 else { throw M4CatalogError.identityChanged }
  }
  private func rejectSidecarsForUninitializedBusiness(_ url: URL) throws {
    var main = stat()
    guard lstat(url.path, &main) == 0 else { throw M4CatalogError.identityChanged }
    // Our reserved zero-byte main has never owned SQLite recovery files. Leave
    // unknown evidence intact; initialized databases retain normal WAL recovery.
    guard main.st_size == 0 else { return }
    for suffix in ["-wal", "-shm", "-journal"] {
      var sidecar = stat()
      guard lstat(url.path + suffix, &sidecar) == -1, errno == ENOENT else { throw M4CatalogError.unknownControl }
    }
  }
  private func publishResourceDirectory(crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    let current = try state(), actual = try resourceLocation(), target = URL(fileURLWithPath: reservation.directory.path)
    if M4CatalogIO.raw(actual.path, reservation.candidate.path) {
      guard !current.resourcesPublished, !current.businessPublished, !M4CatalogIO.exists(URL(fileURLWithPath: reservation.businessDatabase.path)) else { throw M4CatalogError.identityChanged }
      try requireEmpty(actual.appendingPathComponent("business.slot"), original: reservation.businessSlot)
      try requireEmpty(actual.appendingPathComponent("ledger.slot"), original: reservation.ledgerSlot)
      guard Set(try FileManager.default.contentsOfDirectory(atPath: actual.path)) == ["resource.owner", "business.slot", "ledger.slot"] else { throw M4CatalogError.unknownControl }
      guard renameatx_np(AT_FDCWD, actual.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterResourceRename)
      try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    }
    _ = try resourceLocation()
    // A retry after the rename must stabilize its parent too, before marking
    // the original publication durable in the catalog.
    try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.recordPhysicalPublication(reservation, business: false)
  }
  private func publishBusinessFile(crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    let current = try state(), directory = try resourceLocation()
    guard current.resourcesPublished, M4CatalogIO.raw(directory.path, reservation.directory.path) else { throw M4CatalogError.identityChanged }
    let source = directory.appendingPathComponent("business.slot"), target = URL(fileURLWithPath: reservation.businessDatabase.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    if hasSource {
      guard !current.businessPublished else { throw M4CatalogError.identityChanged }
      try requireEmpty(source, original: reservation.businessSlot)
      guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterBusinessRename)
    }
    try original(reservation.businessDatabase, at: target)
    if !current.businessPublished { try requireEmpty(target, original: reservation.businessDatabase) }
    try rejectSidecarsForUninitializedBusiness(target)
    try M4CatalogIO.syncDirectory(directory); try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.recordPhysicalPublication(reservation, business: true)
  }
  func verify() throws {
    guard !closed else { throw M4CatalogError.closed }
    let current = try state(), directory = try resourceLocation()
    guard current.resourcesPublished, current.businessPublished, M4CatalogIO.raw(directory.path, reservation.directory.path),
          Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["resource.owner", "ledger.slot"] else { throw M4CatalogError.unknownControl }
    try requireEmpty(directory.appendingPathComponent("ledger.slot"), original: reservation.ledgerSlot)
    let business = URL(fileURLWithPath: reservation.businessDatabase.path)
    try original(reservation.businessDatabase, at: business); try privateFile(business)
    try rejectSidecarsForUninitializedBusiness(business)
  }
  func close() throws {
    guard !closed else { return }
    try verify(); try catalog.close(); closed = true
  }
}

@MainActor enum M4IdentityBootstrap {
  #if DEBUG
  static func readDevelopmentConfiguration(_ url: URL) throws -> DevelopmentAuthorityConfiguration {
    let url = M4BootstrapFile.canonical(url)
    let parents = try M4BootstrapFile.anchors([url.deletingLastPathComponent()]), original = try M4BootstrapFile.anchor(url, directory: false)
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o7777 == 0o600 else { throw M4BootstrapError.identityUnavailable }
    let bytes = try M4BootstrapFile.read(url, maximum: 16384)
    guard try M4BootstrapFile.encode(original) == M4BootstrapFile.encode(M4BootstrapFile.anchor(url, directory: false)),
          try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([url.deletingLastPathComponent()])) else { throw M4BootstrapError.identityUnavailable }
    return try JSONDecoder().decode(DevelopmentAuthorityConfiguration.self, from: bytes)
  }
  #endif
  static func prepare(root: URL, namespace: String, controlDirectory: URL, vaultFactory: @MainActor (M4IdentitySeed) async throws -> M4IdentityMaterial) async throws -> M4PreparedIdentity {
    try Task.checkCancellation()
    guard !namespace.isEmpty, namespace.utf8.count <= 128,
          namespace.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
          root.isFileURL, controlDirectory.isFileURL else { throw M4BootstrapError.invalidNamespace }
    let root = M4BootstrapFile.canonical(root), control = M4BootstrapFile.canonical(controlDirectory)
    let directory = root.appendingPathComponent(namespace, isDirectory: true)
    guard !M4BootstrapFile.overlap(directory, control) else { throw M4BootstrapError.foreignNamespace }
    let lease = try M4NamespaceLease(root: root, namespace: namespace, directory: directory, control: control)
    let seed = M4IdentitySeed(root: root, namespaceDirectory: directory, controlDirectory: control,
      businessDatabaseURL: directory.appendingPathComponent("matches.sqlite"), namespace: namespace,
      installationID: lease.installationID, businessExisted: try lease.businessExists())
    // The retained nonblocking ownership lease spans the context lifetime. No
    // mutable-file/SQL critical section or blocking lock wait spans this await.
    let material = try await vaultFactory(seed)
    try Task.checkCancellation()
    _ = try AuthorityWire.deviceKeyID(publicKey: material.signer.publicKey)
    try lease.verifyIdentity()
    guard try lease.businessExists() == seed.businessExisted else { throw M4BootstrapError.identityUnavailable }
    return M4PreparedIdentity(seed: seed, material: material, lease: lease)
  }
}

private struct M4BootstrapAnchor: Codable {
  let path: String
  let device, inode: UInt64
}
private struct M4BootstrapOwner: Codable {
  let version: Int
  let namespace, installationID: String
  let owner: M4BootstrapAnchor
  let anchors: [M4BootstrapAnchor]
}
/// Exclusive namespace ownership, distinct from a short file-mutation lock.
/// Closing releases the descriptor, never the retained inode or its parent.
fileprivate final class M4NamespaceLease {
  private var fd: Int32 = -1
  private let root, directory, control, ownerURL: URL
  private let namespace: String
  private var record: M4BootstrapOwner?
  private var originalBytes = Data()
  var installationID: String { record!.installationID }
  init(root: URL, namespace: String, directory: URL, control: URL) throws {
    self.root = root; self.namespace = namespace; self.directory = directory; self.control = control
    ownerURL = control.appendingPathComponent("identity.owner")
    try M4BootstrapFile.ensureDirectory(directory)
    try M4BootstrapFile.ensureDirectory(control)
    try M4BootstrapFile.requireDisjoint(directory, control)
    let hasOwner = M4BootstrapFile.exists(ownerURL)
    if !hasOwner {
      if try Self.businessExists(directory) { throw M4BootstrapError.identityUnavailable }
      guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty else { throw M4BootstrapError.foreignNamespace }
      if M4BootstrapFile.exists(control) {
        guard try FileManager.default.contentsOfDirectory(at: control, includingPropertiesForKeys: nil).isEmpty else { throw M4BootstrapError.identityUnavailable }
      }
    }
    var created = false
    fd = Darwin.open(ownerURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    if fd >= 0 { created = true }
    else {
      guard errno == EEXIST else { throw M4BootstrapError.storageUnavailable }
      fd = Darwin.open(ownerURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    }
    guard fd >= 0 else { throw M4BootstrapError.identityUnavailable }
    do {
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw M4BootstrapError.leaseInUse }
      let actualOwner = try M4BootstrapFile.anchor(ownerURL, directory: false)
      if created {
        let value = M4BootstrapOwner(version: 1, namespace: namespace, installationID: UUID().uuidString,
          owner: actualOwner, anchors: try M4BootstrapFile.anchors([directory, control]))
        let bytes = try M4BootstrapFile.encode(value)
        guard bytes.count <= 65536, bytes.withUnsafeBytes({ Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }) == bytes.count, fsync(fd) == 0 else { throw M4BootstrapError.storageUnavailable }
        record = value; originalBytes = bytes
        try M4BootstrapFile.syncDirectory(control)
      } else {
        let bytes = try M4BootstrapFile.read(ownerURL, maximum: 65536)
        let value = try JSONDecoder().decode(M4BootstrapOwner.self, from: bytes)
        guard value.version == 1, Data(value.namespace.utf8) == Data(namespace.utf8),
              UUID(uuidString: value.installationID)?.uuidString == value.installationID,
              try M4BootstrapFile.encode(value) == bytes,
              try M4BootstrapFile.encode(value.owner) == M4BootstrapFile.encode(actualOwner),
              try M4BootstrapFile.encode(value.anchors) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory, control])) else { throw M4BootstrapError.identityUnavailable }
        record = value; originalBytes = bytes
      }
      let identity = directory.appendingPathComponent("device.identity")
      if !M4BootstrapFile.exists(identity) {
        guard try !Self.businessExists(directory) else { throw M4BootstrapError.identityUnavailable }
        try Data(("football-record.identity.v1:" + installationID).utf8).write(to: identity, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        let file = Darwin.open(identity.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw M4BootstrapError.storageUnavailable }
        defer { Darwin.close(file) }
        guard fsync(file) == 0 else { throw M4BootstrapError.storageUnavailable }
        try M4BootstrapFile.syncDirectory(directory)
      }
      try verifyIdentity()
    } catch {
      close()
      if error is M4BootstrapError { throw error }
      throw M4BootstrapError.identityUnavailable
    }
  }
  func verifyIdentity() throws {
    guard fd >= 0, let record else { throw M4BootstrapError.closed }
    try M4BootstrapFile.requireDisjoint(directory, control)
    guard try M4BootstrapFile.encode(record.owner) == M4BootstrapFile.encode(M4BootstrapFile.anchor(ownerURL, directory: false)),
          try M4BootstrapFile.encode(record.anchors) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory, control])),
          try M4BootstrapFile.read(ownerURL, maximum: 65536) == originalBytes,
          try M4BootstrapFile.read(directory.appendingPathComponent("device.identity"), maximum: 256) == Data(("football-record.identity.v1:" + installationID).utf8) else { throw M4BootstrapError.identityUnavailable }
  }
  func businessExists() throws -> Bool { try Self.businessExists(directory) }
  private static func businessExists(_ directory: URL) throws -> Bool {
    let main = directory.appendingPathComponent("matches.sqlite")
    var found = false
    for name in ["matches.sqlite", "matches.sqlite-wal", "matches.sqlite-shm", "matches.sqlite-journal"] {
      let path = directory.appendingPathComponent(name)
      if M4BootstrapFile.exists(path) { _ = try M4BootstrapFile.anchor(path, directory: false); found = true }
    }
    guard !found || M4BootstrapFile.exists(main) else { throw M4BootstrapError.identityUnavailable }
    return found
  }
  func close() {
    if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
  }
  deinit { close() }
}

private enum M4BootstrapFile {
  static func canonical(_ url: URL) -> URL {
    let path = url.standardizedFileURL.path
    if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return URL(fileURLWithPath: "/private" + path, isDirectory: true) }
    return url.standardizedFileURL
  }
  static func overlap(_ a: URL, _ b: URL) -> Bool {
    let aa = Data(a.path.utf8), bb = Data(b.path.utf8)
    return aa == bb || aa.starts(with: Data((b.path + "/").utf8)) || bb.starts(with: Data((a.path + "/").utf8))
  }
  // Raw path checks alone cannot distinguish case aliases on APFS. Compare
  // real directory identities against the opposite ancestry before any owner,
  // identity or vault write; checkExistingChain still rejects all symlinks.
  static func requireDisjoint(_ a: URL, _ b: URL) throws {
    try checkExistingChain(a); try checkExistingChain(b)
    for (root, descendant) in [(a, b), (b, a)] {
      let original = try anchor(root, directory: true)
      var cursor = descendant
      while true {
        let current = try anchor(cursor, directory: true)
        guard original.device != current.device || original.inode != current.inode else { throw M4BootstrapError.foreignNamespace }
        if cursor.path == "/" { break }
        cursor.deleteLastPathComponent()
      }
    }
  }
  static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
  static func anchor(_ url: URL, directory: Bool) throws -> M4BootstrapAnchor {
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { throw M4BootstrapError.identityUnavailable }
    return M4BootstrapAnchor(path: url.path, device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino)
  }
  static func checkExistingChain(_ url: URL) throws {
    var cursor = url
    while cursor.path != "/" {
      if exists(cursor) { _ = try anchor(cursor, directory: true) }
      cursor.deleteLastPathComponent()
    }
  }
  static func ensureDirectory(_ url: URL) throws {
    try checkExistingChain(url)
    if exists(url) { return }
    let parent = url.deletingLastPathComponent()
    try ensureDirectory(parent)
    guard mkdir(url.path, S_IRWXU) == 0 || errno == EEXIST else { throw M4BootstrapError.storageUnavailable }
    _ = try anchor(url, directory: true)
    try syncDirectory(url); try syncDirectory(parent)
  }
  static func anchors(_ urls: [URL]) throws -> [M4BootstrapAnchor] {
    var seen = Set<Data>(), values: [M4BootstrapAnchor] = []
    for url in urls {
      var cursor = url
      while cursor.path != "/" {
        let key = Data(cursor.path.utf8)
        if seen.insert(key).inserted { values.append(try anchor(cursor, directory: true)) }
        cursor.deleteLastPathComponent()
      }
    }
    return values.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
  }
  static func read(_ url: URL, maximum: Int) throws -> Data {
    _ = try anchor(url, directory: false)
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.identityUnavailable }; defer { Darwin.close(fd) }
    var st = stat(); guard fstat(fd, &st) == 0, st.st_size > 0, st.st_size <= maximum else { throw M4BootstrapError.identityUnavailable }
    var bytes = Data(count: Int(st.st_size))
    let actual = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
    guard actual == bytes.count else { throw M4BootstrapError.identityUnavailable }
    return bytes
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw M4BootstrapError.storageUnavailable }
  }
}

#if DEBUG
/// Borrowed, explicitly controlled observations only. These files are never
/// synthesized from configuration, credentials, pending requests or local binding.
actor M4ControlledCurrentIdentity: M4CurrentIdentityObserving {
  private struct Apple: Codable { let version: Int; let environment, namespace, observationID, accountID: String }
  private struct Cloud: Codable { let version: Int; let environment, namespace, observationID, cloudSpaceID, zoneID: String }
  private let directory: URL
  private let namespace: String
  private let parents, files: [M4BootstrapAnchor]
  private let readReplyGate: (@Sendable () async -> Void)?
  private var generation: Int64 = 0
  private var lifetime = UUID()
  init(directory: URL, namespace: String, readReplyGate: (@Sendable () async -> Void)? = nil) throws {
    let directory = M4BootstrapFile.canonical(directory)
    guard namespace != SQLiteSessionRepository.productionNamespace else { throw AuthorityError.unavailable }
    let parents = try M4BootstrapFile.anchors([directory])
    let files = try ["apple-account.json", "cloud-space.json"].map { try M4BootstrapFile.anchor(directory.appendingPathComponent($0), directory: false) }
    let first = try Self.read(directory: directory, parents: parents, files: files)
    _ = try Self.decode(first, namespace: namespace)
    guard first == (try Self.read(directory: directory, parents: parents, files: files)) else { throw AuthorityError.identityChanged }
    self.directory = directory; self.namespace = namespace; self.parents = parents; self.files = files; self.readReplyGate = readReplyGate
  }
  func advanceIdentityFence(to generation: Int64) throws {
    guard generation >= self.generation, generation <= 9_007_199_254_740_991 else { throw AuthorityError.identityChanged }
    if generation > self.generation { self.generation = generation; lifetime = UUID() }
  }
  func currentIdentity() async throws -> M4CurrentAccountIdentity {
    try Task.checkCancellation()
    let token = lifetime, generation = generation
    let first = try Self.read(directory: directory, parents: parents, files: files)
    let observed = try Self.decode(first, namespace: namespace)
    await readReplyGate?()
    try Task.checkCancellation()
    guard token == lifetime, generation == self.generation,
          first == (try Self.read(directory: directory, parents: parents, files: files)) else { throw AuthorityError.identityChanged }
    return observed
  }
  private static func decode(_ pair: [Data], namespace: String) throws -> M4CurrentAccountIdentity {
    let apple = try JSONDecoder().decode(Apple.self, from: pair[0]), cloud = try JSONDecoder().decode(Cloud.self, from: pair[1])
    guard try M4BootstrapFile.encode(apple) == pair[0], try M4BootstrapFile.encode(cloud) == pair[1],
          apple.version == 1, cloud.version == 1, apple.environment == "development", cloud.environment == "development",
          Data(apple.namespace.utf8) == Data(namespace.utf8), Data(cloud.namespace.utf8) == Data(namespace.utf8),
          UUID(uuidString: apple.observationID)?.uuidString == apple.observationID,
          Data(apple.observationID.utf8) == Data(cloud.observationID.utf8) else { throw AuthorityError.identityChanged }
    for value in [apple.accountID, cloud.cloudSpaceID, cloud.zoneID] { try AuthorityWire.identifier(value) }
    return M4CurrentAccountIdentity(accountID: apple.accountID, cloudSpaceID: cloud.cloudSpaceID, zoneID: cloud.zoneID, environment: .development)
  }
  private static func read(directory: URL, parents: [M4BootstrapAnchor], files: [M4BootstrapAnchor]) throws -> [Data] {
    guard try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory])) else { throw AuthorityError.identityChanged }
    var dir = stat()
    guard lstat(directory.path, &dir) == 0, dir.st_uid == geteuid(), dir.st_mode & 0o7777 == 0o700 else { throw AuthorityError.unavailable }
    var result: [Data] = []
    for expected in files {
      let url = URL(fileURLWithPath: expected.path), actual = try M4BootstrapFile.anchor(url, directory: false)
      guard try M4BootstrapFile.encode(expected) == M4BootstrapFile.encode(actual) else { throw AuthorityError.identityChanged }
      let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw AuthorityError.unavailable }; defer { Darwin.close(fd) }
      var held = stat()
      guard fstat(fd, &held) == 0, held.st_uid == geteuid(), held.st_nlink == 1, held.st_mode & 0o7777 == 0o600,
            UInt64(UInt32(bitPattern: held.st_dev)) == expected.device, held.st_ino == expected.inode,
            held.st_size > 0, held.st_size <= 16384 else { throw AuthorityError.unavailable }
      var bytes = Data(count: Int(held.st_size))
      let count = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
      guard count == bytes.count, try M4BootstrapFile.encode(expected) == M4BootstrapFile.encode(M4BootstrapFile.anchor(url, directory: false)) else { throw AuthorityError.identityChanged }
      result.append(bytes)
    }
    guard try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory])) else { throw AuthorityError.identityChanged }
    return result
  }
}
#endif
