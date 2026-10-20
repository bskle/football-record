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
@MainActor final class M4PreparedIdentity {
  let seed: M4IdentitySeed
  let material: M4IdentityMaterial
  private let lease: M4NamespaceLease
  private var repository: SQLiteSessionRepository?
  private var closed = false
  fileprivate init(seed: M4IdentitySeed, material: M4IdentityMaterial, lease: M4NamespaceLease) {
    self.seed = seed; self.material = material; self.lease = lease
  }
  func openRepository(authorityTrust: AuthorityTrustConfiguration? = nil, cloudSavePolicy: CloudSaveProofPolicy = .unavailable) throws -> SQLiteSessionRepository {
    guard !closed else { throw M4BootstrapError.closed }
    guard repository == nil else { throw M4BootstrapError.alreadyOpened }
    try lease.verifyIdentity()
    let value = try SQLiteSessionRepository(rootDirectory: seed.root, databaseNamespace: seed.namespace, authorityTrust: authorityTrust, cloudSavePolicy: cloudSavePolicy)
    repository = value; return value
  }
  func close() async throws {
    guard !closed else { return }
    try lease.verifyIdentity()
    try await repository?.close(); repository = nil
    closed = true; lease.close()
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
