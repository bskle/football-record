import Foundation
import Darwin

private final class DeviceSyncOwnerLock: @unchecked Sendable {
    let fd: Int32
    let identity: DeviceSyncRootIdentity
    private let lock = NSRecursiveLock()
    private var depth = 0
    init(fd: Int32, identity: DeviceSyncRootIdentity) { self.fd = fd; self.identity = identity }
    deinit { close(fd) }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if depth == 0 { guard flock(fd, LOCK_EX) == 0 else { throw DeviceSyncErasureError.fileIO } }
            depth += 1
            defer { depth -= 1; if depth == 0 { flock(fd, LOCK_UN) } }
            return try body()
        }
    }
}
private final class DeviceSyncLockRegistry: @unchecked Sendable {
    static let shared = DeviceSyncLockRegistry()
    private let lock = NSLock()
    // The retained open owner inode is shared by every handle in this process.
    private var values: [String: DeviceSyncOwnerLock] = [:]
    func get(_ url: URL, create: Bool) throws -> (DeviceSyncOwnerLock, Bool) {
        try lock.withLock {
            var created = false
            var fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if fd >= 0 { created = true }
            else { guard errno == EEXIST else { throw DeviceSyncErasureError.fileIO }; fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
            guard fd >= 0 else { throw DeviceSyncErasureError.ownerChanged }
            if created && !create { close(fd); throw DeviceSyncErasureError.ownerChanged }
            var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw DeviceSyncErasureError.ownerChanged }
            let identity = DeviceSyncRootIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino), key = "\(identity.device):\(identity.inode)"
            if let existing = values[key] { close(fd); return (existing, created) }
            let value = DeviceSyncOwnerLock(fd: fd, identity: identity); values[key] = value; return (value, created)
        }
    }
}

/// A retained gate is shared by constructors, synchronous SDK dispatch and erasure.
/// Account/catalog provenance is provided by026, never inferred here.
public final class DeviceSyncStorageContext: @unchecked Sendable {
    public let root: URL
    public let rootIdentity: DeviceSyncRootIdentity
    let managed: Bool
    let ledger: DeviceSyncErasureLedger
    private let ownerLock: DeviceSyncOwnerLock
    private let identities: [(URL, DeviceSyncRootIdentity)]
    private let databaseIdentity: DeviceSyncRootIdentity
    private let ownerMarker: Data
    public convenience init(root: URL) throws {
        guard root.lastPathComponent == "DeviceSync" else { throw DeviceSyncErasureError.unsupportedLayout }
        try self.init(directory: root, managed: true)
    }
    private init(directory: URL, managed: Bool) throws {
        root = Self.canonicalURL(directory); self.managed = managed
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.checkDirectoryChain(root)
        rootIdentity = try Self.identity(root, directory: true)
        let control = root.appendingPathComponent(".control", isDirectory: true), database = control.appendingPathComponent("control.sqlite"), owner = control.appendingPathComponent(".owner")
        guard mkdir(control.path, S_IRWXU) == 0 || errno == EEXIST else { throw DeviceSyncErasureError.fileIO }
        _ = try Self.identity(control, directory: true)
        let hadDatabase = FileManager.default.fileExists(atPath: database.path), hadOwner = FileManager.default.fileExists(atPath: owner.path)
        guard !hadDatabase || hadOwner else { throw DeviceSyncErasureError.ownerChanged }
        if hadDatabase { _ = try Self.identity(database, directory: false) }
        let (gate, created) = try DeviceSyncLockRegistry.shared.get(owner, create: !hadDatabase && !hadOwner)
        ownerLock = gate
        var tracked: [(URL, DeviceSyncRootIdentity)] = [(owner, gate.identity), (control, try Self.identity(control, directory: true))]
        var cursor = root
        while cursor.path != "/" { tracked.append((cursor, try Self.identity(cursor, directory: true))); cursor.deleteLastPathComponent() }
        let marker = Data(("football-record.device-sync-owner.v1\n" + tracked.map { url, identity in
            digest(Self.pathKey(url)) + ":\(identity.device):\(identity.inode)"
        }.joined(separator: "\n")).utf8)
        guard marker.count <= 8192 else { throw DeviceSyncErasureError.ownerChanged }
        ownerMarker = marker
        ledger = try gate.withLock {
            if created {
                guard marker.withUnsafeBytes({ Darwin.write(gate.fd, $0.baseAddress, $0.count) }) == marker.count, fsync(gate.fd) == 0 else { throw DeviceSyncErasureError.fileIO }
            } else {
                guard try Self.readRegular(owner, limit: 8192) == marker else { throw DeviceSyncErasureError.ownerChanged }
                guard FileManager.default.fileExists(atPath: database.path) else { throw DeviceSyncErasureError.ownerChanged }
            }
            return try DeviceSyncErasureLedger(url: database)
        }
        databaseIdentity = try Self.identity(database, directory: false)
        identities = tracked
        try withLocked { _ = try ledger.state() }
    }
    static func component(_ directory: URL, role: String) throws -> DeviceSyncStorageContext {
        let directory = canonicalURL(directory)
        var cursor = directory, managedRoot: URL?
        while cursor.path != "/" {
            if cursor.lastPathComponent == "DeviceSync" { managedRoot = cursor }
            cursor.deleteLastPathComponent()
        }
        if let managedRoot {
            guard pathKey(directory) == pathKey(managedRoot.appendingPathComponent(role)) else { throw DeviceSyncErasureError.unsupportedLayout }
            return try DeviceSyncStorageContext(root: managedRoot)
        }
        // A standalone leaf owns its own gate; never choose a generic parent/tmp root.
        return try DeviceSyncStorageContext(directory: directory, managed: false)
    }
    func withLocked<T>(_ body: () throws -> T) throws -> T {
        try ownerLock.withLock {
            for (url, identity) in identities {
                guard try Self.identity(url, directory: url.lastPathComponent != ".owner") == identity else { throw DeviceSyncErasureError.ownerChanged }
            }
            guard try Self.readRegular(root.appendingPathComponent(".control/.owner"), limit: 8192) == ownerMarker else { throw DeviceSyncErasureError.ownerChanged }
            guard try Self.identity(root.appendingPathComponent(".control/control.sqlite"), directory: false) == databaseIdentity else { throw DeviceSyncErasureError.ownerChanged }
            return try body()
        }
    }
    func withActive<T>(_ body: () throws -> T) throws -> T {
        try withLocked {
            let state = try ledger.state()
            guard state.request == nil else { throw DeviceSyncError.erased }
            guard !managed || state.owner != nil else { throw DeviceSyncErasureError.unbound }
            return try body()
        }
    }
    func withFenced<T>(_ request: DeviceSyncLocalEraseRequest, _ body: () throws -> T) throws -> T {
        try withLocked {
            let state = try ledger.state()
            guard state.owner == request.binding, state.request == request else { throw DeviceSyncErasureError.intentMismatch }
            return try body()
        }
    }
    public func bind(_ binding: DeviceSyncNamespaceBinding) throws {
        try binding.validate()
        try withLocked {
            guard managed, binding.rootIdentity == rootIdentity else { throw DeviceSyncErasureError.intentMismatch }
            let state = try ledger.state()
            guard state.request == nil else { throw DeviceSyncError.erased }
            if let owner = state.owner { guard owner == binding else { throw DeviceSyncErasureError.intentMismatch }; return }
            for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where entry.lastPathComponent != ".control" {
                guard ["inbox", "outbox", "state"].contains(entry.lastPathComponent), (try? Self.identity(entry, directory: true)) != nil, try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).isEmpty else { throw DeviceSyncErasureError.unbound }
            }
            try ledger.bind(binding)
        }
    }
    // Darwin temporary-directory URLs use the system /var and /tmp aliases.
    // Normalize those known aliases only; never resolve caller-controlled symlinks.
    private static func pathKey(_ url: URL) -> Data { Data(url.standardizedFileURL.path.split(separator: "/").joined(separator: "/").utf8) }
    private static func canonicalURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return URL(fileURLWithPath: "/private" + path, isDirectory: true) }
        return url.standardizedFileURL
    }
    static func identity(_ url: URL, directory: Bool) throws -> DeviceSyncRootIdentity {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { throw DeviceSyncErasureError.ownerChanged }
        return DeviceSyncRootIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
    }
    private static func checkDirectoryChain(_ url: URL) throws {
        var cursor = url
        while cursor.path != "/" { _ = try identity(cursor, directory: true); cursor.deleteLastPathComponent() }
    }
    static func readRegular(_ url: URL, limit: Int) throws -> Data {
        _ = try identity(url, directory: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let n = attrs[.size] as? NSNumber, n.int64Value > 0, n.int64Value <= Int64(limit) else { throw DeviceSyncErasureError.unknownInventory }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == n.intValue, (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw DeviceSyncErasureError.unknownInventory }
        return data
    }
    func synchronize(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DeviceSyncErasureError.fileIO }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw DeviceSyncErasureError.fileIO }
    }
}
