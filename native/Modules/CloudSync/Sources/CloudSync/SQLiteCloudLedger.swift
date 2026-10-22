import Foundation
import SQLite3
import Darwin
import CryptoKit

// One actor owns one transport-only connection. No SQL transaction contains a network await.
enum CloudSQLValue {
    case text(String), blob(Data), integer(Int64), null
    var string: String? { if case .text(let x) = self { x } else { nil } }
    var data: Data? { if case .blob(let x) = self { x } else { nil } }
    var number: Int64? { if case .integer(let x) = self { x } else { nil } }
    // Only SQL NULL denotes no issue. Unknown non-NULL persisted values must not resume progress.
    func optionalIssue() throws -> CloudIssue? {
        switch self {
        case .null: return nil
        case .text(let raw):
            guard let issue = CloudIssue(rawValue: raw) else { throw CloudError(.invalidPayload) }
            return issue
        default: throw CloudError(.invalidPayload)
        }
    }
}
enum CloudSQLAccess { case createOrOpen, readOnlyExisting, readWriteExisting, immutableReadOnlyExisting }
struct CloudSQLiteFailure { let code: Int32; let system: Int32 }
final class CloudSQL: @unchecked Sendable {
    private var handle: OpaquePointer?
    private(set) var lastSQLiteFailure: CloudSQLiteFailure?
    init(url: URL, access: CloudSQLAccess = .createOrOpen) throws {
        guard url.isFileURL else { throw CloudError(.invalidPayload) }
        let flags: Int32
        switch access {
        case .createOrOpen: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnlyExisting: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        case .readWriteExisting: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .immutableReadOnlyExisting: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        }
        let filename = access == .immutableReadOnlyExisting ? URL(fileURLWithPath: url.path).absoluteString + "?mode=ro&immutable=1" : url.path
        guard sqlite3_open_v2(filename, &handle, flags, nil) == SQLITE_OK else { if let handle { sqlite3_close_v2(handle) }; handle = nil; throw CloudError(.storageUnavailable) }
        do { guard sqlite3_busy_timeout(handle, 5000) == SQLITE_OK else { throw CloudError(.storageUnavailable) } }
        catch { try? close(); throw error }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func close() throws { if let handle { guard sqlite3_close(handle) == SQLITE_OK else { throw CloudError(.storageUnavailable) }; self.handle = nil } }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { if sqlite3_get_autocommit(handle) == 0 { try execute("ROLLBACK") }; throw error }
    }
    func execute(_ sql: String, _ args: [CloudSQLValue] = []) throws { _ = try rows(sql, args) }
    func rows(_ sql: String, _ args: [CloudSQLValue] = []) throws -> [[CloudSQLValue]] {
        guard let handle else { throw CloudError(.closed) }
        lastSQLiteFailure = nil
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            // Capture before finalize/close can replace SQLite's error state.
            lastSQLiteFailure = CloudSQLiteFailure(code: sqlite3_extended_errcode(handle), system: sqlite3_system_errno(handle))
            if let statement { sqlite3_finalize(statement) }
            throw CloudError(.storageUnavailable)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(args.count) else { throw CloudError(.invalidPayload) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case .text(let x): code = x.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let x): code = sqlite3_bind_int64(statement, index, x)
            case .null: code = sqlite3_bind_null(statement, index)
            case .blob(let x): code = x.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : x.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(x.count), transient) }
            }
            guard code == SQLITE_OK else { throw CloudError(.storageUnavailable) }
        }
        var output: [[CloudSQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else {
                lastSQLiteFailure = CloudSQLiteFailure(code: sqlite3_extended_errcode(handle), system: sqlite3_system_errno(handle))
                throw CloudError(.storageUnavailable)
            }
            output.append(try (0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let pointer = sqlite3_column_text(statement, index),
                          let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8), !value.contains("\0") else { throw CloudError(.invalidPayload) }
                    return .text(value)
                case SQLITE_BLOB: return .blob(Data(bytes: sqlite3_column_blob(statement, index) ?? UnsafeRawPointer(bitPattern: 1)!, count: Int(sqlite3_column_bytes(statement, index))))
                default: return .null
                }
            })
        }
    }
}

private struct CloudErasureFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}
private func existingCloudErasureIdentity(_ url: URL) throws -> CloudErasureFileIdentity {
    guard url.isFileURL else { throw CloudError(.invalidPayload) }
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CloudError(.storageUnavailable) }
    guard Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG) else { throw CloudError(.invalidPayload) }
    return CloudErasureFileIdentity(device: info.st_dev, inode: info.st_ino)
}
private func validateExistingCloudErasure(_ sql: CloudSQL, requireWAL: Bool = true) throws {
    guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw CloudError(.storageUnavailable) }
    try validateLocalErasureLayout(sql)
    _ = try validateErasureCanonicalRows(sql, version: 4)
    if requireWAL { guard try sql.rows("PRAGMA journal_mode").first?.first?.string?.lowercased() == "wal" else { throw CloudError(.unsupportedSchema) } }
}

// Only a missing-WAL read failure may use this provisional, sidecar-free main-file parse.
// This is a point-in-time check after the caller joins its writers, not a cross-process lease.
private struct CloudErasureMainVersion: Equatable {
    let device: dev_t, inode: ino_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    let header: Data
}
private func cloudErasureSidecarsPresent(_ url: URL) throws -> Bool {
    var present = false
    for suffix in ["-wal", "-shm", "-journal"] {
        var info = stat()
        if lstat(url.path + suffix, &info) == 0 {
            guard Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG) else { throw CloudError(.invalidPayload) }
            present = true
        } else if errno != ENOENT { throw CloudError(.storageUnavailable) }
    }
    return present
}
private func cloudErasureMainVersion(_ fd: Int32, _ url: URL) throws -> CloudErasureMainVersion {
    var info = stat(), path = stat()
    guard fstat(fd, &info) == 0, lstat(url.path, &path) == 0,
          Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG), Int(path.st_mode) & Int(S_IFMT) == Int(S_IFREG),
          info.st_dev == path.st_dev, info.st_ino == path.st_ino, info.st_size >= 100 else { throw CloudError(.identityConflict) }
    var header = Data(count: 100)
    let count = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 100, 0) }
    guard count == 100 else { throw CloudError(.storageUnavailable) }
    return CloudErasureMainVersion(device: info.st_dev, inode: info.st_ino, size: info.st_size,
        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
        changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec, header: header)
}
private func cloudErasureFingerprint(_ fd: Int32, size: off_t) throws -> Data {
    var hasher = SHA256(), offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while offset < size {
        let requested = Int(min(off_t(buffer.count), size - offset))
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, requested, offset) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CloudError(.storageUnavailable) }
        hasher.update(data: Data(buffer.prefix(count))); offset += off_t(count)
    }
    return Data(hasher.finalize())
}
private final class CloudErasureStaticMain {
    let fd: Int32, url: URL, version: CloudErasureMainVersion, fingerprint: Data
    init?(url: URL) throws {
        guard try !cloudErasureSidecarsPresent(url) else { return nil }
        // Empty/short originals retain the accepted unsupported-schema handling without a static read.
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CloudError(.storageUnavailable) }
        guard info.st_size >= 100 else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CloudError(.storageUnavailable) }
        var retained = false; defer { if !retained { Darwin.close(fd) } }
        let version = try cloudErasureMainVersion(fd, url)
        guard version.header.prefix(16) == Data("SQLite format 3\0".utf8),
              version.header[18] == 2, version.header[19] == 2 else { return nil }
        let fingerprint = try cloudErasureFingerprint(fd, size: version.size)
        guard try cloudErasureMainVersion(fd, url) == version, try !cloudErasureSidecarsPresent(url) else { throw CloudError(.identityConflict) }
        self.fd = fd; self.url = url; self.version = version; self.fingerprint = fingerprint; retained = true
    }
    deinit { Darwin.close(fd) }
    func verify(requireNoSidecars: Bool = true) throws {
        guard try cloudErasureMainVersion(fd, url) == version,
              try cloudErasureFingerprint(fd, size: version.size) == fingerprint,
              try cloudErasureMainVersion(fd, url) == version else { throw CloudError(.identityConflict) }
        if requireNoSidecars { guard try !cloudErasureSidecarsPresent(url) else { throw CloudError(.identityConflict) } }
    }
}

enum CloudErasureReadOnlyStage: Sendable, Equatable { case afterStaticValidation, beforeReadWriteOpen }
private func openExistingCloudErasure(_ existingLocalErasureURL: URL,
    checkpoint: (@Sendable (CloudErasureReadOnlyStage) throws -> Void)? = nil) throws -> CloudSQL {
    let original = try existingCloudErasureIdentity(existingLocalErasureURL)
    let provisional = try CloudErasureStaticMain(url: existingLocalErasureURL)
    let readonly = try CloudSQL(url: existingLocalErasureURL, access: .readOnlyExisting)
    var usedStaticRead = false
    do {
        try validateExistingCloudErasure(readonly)
        try readonly.close()
        guard try existingCloudErasureIdentity(existingLocalErasureURL) == original else { throw CloudError(.identityConflict) }
    } catch {
        let failure = readonly.lastSQLiteFailure
        try? readonly.close()
        guard failure?.code == SQLITE_CANTOPEN, failure?.system == ENOENT, let provisional else { throw error }
        try provisional.verify()
        let immutable = try CloudSQL(url: existingLocalErasureURL, access: .immutableReadOnlyExisting)
        do {
            // This handle is only a provisional parser; its journal_mode is not source evidence.
            try validateExistingCloudErasure(immutable, requireWAL: false)
            try immutable.close()
        } catch { try? immutable.close(); throw error }
        try checkpoint?(.afterStaticValidation)
        try provisional.verify()
        usedStaticRead = true
    }
    if usedStaticRead { try checkpoint?(.beforeReadWriteOpen); try provisional?.verify() }
    let existing = try CloudSQL(url: existingLocalErasureURL, access: .readWriteExisting)
    do {
        guard try existingCloudErasureIdentity(existingLocalErasureURL) == original else { throw CloudError(.identityConflict) }
        if usedStaticRead { try provisional?.verify() }
        // A normal SQLite lock/current read, never the immutable parse, admits the actor.
        try existing.transaction { try validateExistingCloudErasure(existing) }
        guard try existingCloudErasureIdentity(existingLocalErasureURL) == original else { throw CloudError(.identityConflict) }
        if usedStaticRead { try provisional?.verify(requireNoSidecars: false) }
        try existing.execute("PRAGMA synchronous=FULL")
    } catch { try? existing.close(); throw error }
    return existing
}

// This context correlates one original transport file and leaf request. It does
// not prove the caller's parent Saga, catalog ownership or namespace lease.
private struct RetainedControlContext: Sendable {
    let url: URL
    let identity: CloudErasureFileIdentity
    let request: CloudLocalTransportEraseRequest
}
private enum CloudLedgerAccess: Sendable {
    case active, localErasureOnly
    case retainedControl(RetainedControlContext)
}
private enum RetainedFenceState: Sendable {
    case scopeFence(attempts: Int)
    case erased
}
// Every allowed call takes a fresh deferred read snapshot. This never uses the
// write transaction entrance, creates a missing fence, or repairs lost proof.
private func readRetainedFenceState(_ sql: CloudSQL, context: RetainedControlContext) throws -> RetainedFenceState {
    guard try existingCloudErasureIdentity(context.url) == context.identity else { throw CloudError(.identityConflict) }
    try sql.execute("BEGIN")
    let state: RetainedFenceState
    do {
        guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw CloudError(.storageUnavailable) }
        try validateLocalErasureLayout(sql)
        let scopes = try validateErasureCanonicalRows(sql, version: 4)
        let fences = try validatedLocalEraseFences(sql)
        guard try sql.rows("PRAGMA journal_mode").first?.first?.string?.lowercased() == "wal" else { throw CloudError(.unsupportedSchema) }
        let request = context.request, stable = request.scope.stableZoneKey
        if fences.contains(stable) {
            guard let row = try sql.rows("SELECT request_id,request_digest,stable_zone FROM cloud_local_erase_receipts WHERE request_id=?", [.text(request.requestID)]).first else { throw CloudError(.storageUnavailable) }
            guard let id = row[0].string, let digest = row[1].string, let zone = row[2].string else { throw CloudError(.invalidPayload) }
            _ = try CloudLocalTransportEraseReceipt(requestID: id, requestDigest: digest, stableZoneKey: zone)
            guard id.utf8.elementsEqual(request.requestID.utf8), digest == (try request.digest), zone == stable else { throw CloudError(.identityConflict) }
            guard !scopes.contains(where: { $0.stableZoneKey == stable }) else { throw CloudError(.invalidPayload) }
            state = .erased
        } else {
            guard let row = try sql.rows("SELECT issue,attempts,retry_ms,attempted_ms FROM cloud_scope_state WHERE scope=?", [.text(try request.scope.key)]).first else { throw CloudError(.storageUnavailable) }
            guard let attempts = row[1].number, attempts >= 1, row[3].number != nil else { throw CloudError(.invalidPayload) }
            guard try row[0].optionalIssue() == .accountChanged, case .null = row[2] else { throw CloudError(.storageUnavailable) }
            state = .scopeFence(attempts: Int(attempts))
        }
        try sql.execute("COMMIT")
    } catch { try? sql.execute("ROLLBACK"); throw error }
    guard try existingCloudErasureIdentity(context.url) == context.identity else { throw CloudError(.identityConflict) }
    return state
}

public actor SQLiteCloudLedger: CloudLedger {
    let sql: CloudSQL
    private let fault: CloudLedgerFault?
    private let access: CloudLedgerAccess
    private var closed = false
    public init(url: URL, fault: CloudLedgerFault? = nil, migrationFault: CloudLedgerMigrationFault? = nil) throws {
        let sql = try CloudSQL(url: url)
        do {
            let version = try sql.rows("PRAGMA user_version").first?.first?.number ?? -1
            guard (0...4).contains(version) else { throw CloudError(.unsupportedSchema) }
            guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw CloudError(.storageUnavailable) }
            let uploadCheck = "SELECT id,scope,digest,original,state,attempts,issue,retry_ms,attempted_ms FROM cloud_uploads LIMIT 0"
            let batchCheck = "SELECT scope,id,digest,original,state,attempts,issue,retry_ms,attempted_ms,ack FROM cloud_batches LIMIT 0"
            let currentChecks = ["SELECT scope,issue,attempts,retry_ms,attempted_ms FROM cloud_scope_state LIMIT 0", "SELECT scope,upload_id,remote_digest,change_tag,original FROM cloud_conflicts LIMIT 0", "SELECT scope,upload_id,digest,original FROM cloud_save_evidence LIMIT 0"]
            let eraseChecks = ["SELECT stable_zone FROM cloud_local_erase_fences LIMIT 0", "SELECT request_id,request_digest,stable_zone FROM cloud_local_erase_receipts LIMIT 0"]
            // Validate every existing version before changing either schema or journal settings.
            if version >= 1 { _ = try sql.rows(uploadCheck) }
            if version >= 2 { _ = try sql.rows(batchCheck) }
            if version >= 3 { for check in currentChecks { _ = try sql.rows(check) } }
            if version == 4 { for check in eraseChecks { _ = try sql.rows(check) } }
            if version == 0 { guard try sql.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw CloudError(.unsupportedSchema) } }
            if version < 4 {
                // All DDL, final structure checks and version updates commit together.
                try sql.transaction {
                    _ = try validateErasureCanonicalRows(sql, version: Int(version))
                    if version == 0 {
                    try sql.execute("CREATE TABLE cloud_uploads(id TEXT PRIMARY KEY, scope TEXT NOT NULL, digest TEXT NOT NULL, original BLOB NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL, issue TEXT, retry_ms INTEGER, attempted_ms INTEGER) STRICT")
                    }
                    if version < 2 {
                    try sql.execute("CREATE TABLE cloud_batches(scope TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL,issue TEXT,retry_ms INTEGER,attempted_ms INTEGER,ack BLOB,PRIMARY KEY(scope,id)) STRICT")
                    }
                    if version < 3 {
                    try sql.execute("CREATE TABLE cloud_scope_state(scope TEXT PRIMARY KEY,issue TEXT,attempts INTEGER NOT NULL,retry_ms INTEGER,attempted_ms INTEGER) STRICT")
                    try sql.execute("CREATE TABLE cloud_conflicts(scope TEXT NOT NULL,upload_id TEXT NOT NULL,remote_digest TEXT NOT NULL,change_tag TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id,remote_digest,change_tag)) STRICT")
                    try sql.execute("CREATE TABLE cloud_save_evidence(scope TEXT NOT NULL,upload_id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id)) STRICT")
                    }
                    if migrationFault == .afterLegacyValidation { throw CloudError(.storageUnavailable) }
                    try sql.execute("CREATE TABLE cloud_local_erase_fences(stable_zone TEXT PRIMARY KEY) STRICT")
                    if migrationFault == .afterFenceTable { throw CloudError(.storageUnavailable) }
                    try sql.execute("CREATE TABLE cloud_local_erase_receipts(request_id TEXT PRIMARY KEY,request_digest TEXT NOT NULL,stable_zone TEXT NOT NULL) STRICT")
                    if migrationFault == .afterReceiptTable { throw CloudError(.storageUnavailable) }
                    try sql.execute("PRAGMA user_version=4")
                    if migrationFault == .afterVersion { throw CloudError(.storageUnavailable) }
                    for check in [uploadCheck,batchCheck] + currentChecks + eraseChecks { _ = try sql.rows(check) }
                    if migrationFault == .afterValidation { throw CloudError(.storageUnavailable) }
                }
                if migrationFault == .afterCommitResponseLost { throw CloudError(.storageUnavailable) }
            }
            guard try sql.rows("PRAGMA journal_mode=WAL").first?.first?.string?.lowercased() == "wal" else { throw CloudError(.storageUnavailable) }
            try sql.execute("PRAGMA synchronous=FULL")
        } catch { try? sql.close(); throw error }
        self.sql = sql; self.fault = fault; access = .active
    }
    /// Existing-file local erasure only: never CREATE, migrate or reconstruct lost proof.
    /// The caller still proves catalog ownership; known SQLite WAL coordination is allowed.
    public init(existingLocalErasureURL: URL, fault: CloudLedgerFault? = nil) throws {
        sql = try openExistingCloudErasure(existingLocalErasureURL); self.fault = fault; access = .localErasureOnly
    }
    // Internal, synchronous fault seam: no production caller or global fault/VFS state.
    init(existingLocalErasureURL: URL, readOnlyCheckpoint: @escaping @Sendable (CloudErasureReadOnlyStage) throws -> Void) throws {
        sql = try openExistingCloudErasure(existingLocalErasureURL, checkpoint: readOnlyCheckpoint); fault = nil; access = .localErasureOnly
    }
    /// Strict existing-file control only. Original caller ownership and parent
    /// authorization remain mandatory; this cannot perform an erase or replay.
    public init(existingRetainedControlURL: URL, originalEraseRequest: CloudLocalTransportEraseRequest) throws {
        let identity = try existingCloudErasureIdentity(existingRetainedControlURL)
        let opened = try openExistingCloudErasure(existingRetainedControlURL)
        let context = RetainedControlContext(url: existingRetainedControlURL, identity: identity, request: originalEraseRequest)
        do { _ = try readRetainedFenceState(opened, context: context) }
        catch { try? opened.close(); throw error }
        sql = opened; fault = nil; access = .retainedControl(context)
    }
    // Same synchronous strict-opening fault seam as the accepted erasure mode;
    // this changes neither the public API nor either mode's opening policy.
    init(existingRetainedControlURL: URL, originalEraseRequest: CloudLocalTransportEraseRequest,
         readOnlyCheckpoint: @escaping @Sendable (CloudErasureReadOnlyStage) throws -> Void) throws {
        let identity = try existingCloudErasureIdentity(existingRetainedControlURL)
        let opened = try openExistingCloudErasure(existingRetainedControlURL, checkpoint: readOnlyCheckpoint)
        let context = RetainedControlContext(url: existingRetainedControlURL, identity: identity, request: originalEraseRequest)
        do { _ = try readRetainedFenceState(opened, context: context) }
        catch { try? opened.close(); throw error }
        sql = opened; fault = nil; access = .retainedControl(context)
    }
    public func close() throws { try sql.close(); closed = true }
    private func requireOrdinaryRead() throws {
        if case .retainedControl = access { throw CloudError(closed ? .closed : .storageUnavailable) }
    }
    func transaction<T>(forLocalErasure: Bool = false, _ body: () throws -> T) throws -> T {
        switch access {
        case .active: break
        case .localErasureOnly: guard forLocalErasure else { throw CloudError(.storageUnavailable) }
        case .retainedControl: throw CloudError(closed ? .closed : .storageUnavailable)
        }
        let result = try sql.transaction {
            let result = try body(); if fault == .beforeCommit { throw CloudError(.storageUnavailable) }; return result
        }
        if fault == .afterCommitResponseLost { throw CloudError(.storageUnavailable) }
        return result
    }
    public func enqueue(_ upload: CloudUpload) throws {
        let raw = try upload.canonicalBytes(), digest = CloudCodec.hash(raw)
        try transaction {
            try requireNotLocallyErased(upload.scope)
            if let row = try sql.rows("SELECT digest,original FROM cloud_uploads WHERE id=?", [.text(upload.id)]).first {
                guard row[0].string == digest, row[1].data == raw else { throw CloudError(.identityConflict) }; return
            }
            try sql.execute("INSERT INTO cloud_uploads(id,scope,digest,original,state,attempts) VALUES(?,?,?,?,?,0)", [.text(upload.id), .text(try upload.scope.key), .text(digest), .blob(raw), .text(CloudDeliveryState.pending.rawValue)])
        }
    }
    public func uploads(scope: CloudScope) throws -> [CloudUploadEntry] {
        try requireOrdinaryRead()
        return try sql.rows("SELECT original,state,attempts,issue,retry_ms,digest FROM cloud_uploads WHERE scope=? ORDER BY id", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, let state = row[1].string.flatMap(CloudDeliveryState.init(rawValue:)), let count = row[2].number, count >= 0, row[5].string == CloudCodec.hash(raw) else { throw CloudError(.invalidPayload) }
            let upload = try CloudCodec.decode(CloudUpload.self, raw)
            guard upload.scope == scope else { throw CloudError(.accountChanged) }
            return CloudUploadEntry(upload: upload, originalBytes: raw, state: state, attemptCount: Int(count), issue: try row[3].optionalIssue(), nextAttemptAt: row[4].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    public func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        try CloudCodec.date(at); if let nextAttemptAt { try CloudCodec.date(nextAttemptAt) }
        try transaction {
            guard let row = try sql.rows("SELECT original FROM cloud_uploads WHERE id=?", [.text(id)]).first, let raw = row[0].data else { throw CloudError(.invalidPayload) }
            try requireNotLocallyErased(CloudCodec.decode(CloudUpload.self, raw).scope)
            let state: CloudDeliveryState = [.conflict,.invalidPayload,.identityConflict].contains(issue) ? .blocked : .pending
            try sql.execute("UPDATE cloud_uploads SET state=?,attempts=attempts+1,issue=?,retry_ms=?,attempted_ms=? WHERE id=?", [.text(state.rawValue),.text(issue.rawValue), try nextAttemptAt.map { .integer(try CloudCodec.milliseconds($0)) } ?? .null, .integer(try CloudCodec.milliseconds(at)), .text(id)])
        }
    }
    public func stage(_ batch: CloudFetchBatch) throws {
        let raw = try batch.canonicalBytes(), digest = try batch.digest, scopeKey = try batch.scope.key
        try transaction {
            try requireNotLocallyErased(batch.scope)
            if let row = try sql.rows("SELECT digest,original FROM cloud_batches WHERE scope=? AND id=?", [.text(scopeKey), .text(batch.batchID)]).first {
                guard row[0].string == digest, row[1].data == raw else { throw CloudError(.identityConflict) }; return
            }
            guard try scopeState(scope: batch.scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
            try sql.execute("INSERT INTO cloud_batches(scope,id,digest,original,state,attempts) VALUES(?,?,?,?,?,0)", [.text(scopeKey),.text(batch.batchID),.text(digest),.blob(raw),.text(CloudDeliveryState.pending.rawValue)])
        }
    }
    public func batches(scope: CloudScope) throws -> [CloudBatchEntry] {
        try requireOrdinaryRead()
        return try sql.rows("SELECT original,state,attempts,issue,retry_ms,digest FROM cloud_batches WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, let state = row[1].string.flatMap(CloudDeliveryState.init(rawValue:)), let count = row[2].number, count >= 0 else { throw CloudError(.invalidPayload) }
            let batch = try CloudCodec.decode(CloudFetchBatch.self, raw)
            guard batch.scope == scope, try batch.digest == row[5].string else { throw CloudError(.invalidPayload) }
            return CloudBatchEntry(batch: batch, originalBytes: raw, state: state, attemptCount: Int(count), issue: try row[3].optionalIssue(), nextAttemptAt: row[4].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    public func acknowledge(_ acknowledgement: CloudImportAcknowledgement) throws {
        try transaction {
            try requireNotLocallyErased(acknowledgement.scope)
            guard let row = try sql.rows("SELECT original,ack FROM cloud_batches WHERE scope=? AND id=?", [.text(try acknowledgement.scope.key),.text(acknowledgement.batchID)]).first, let raw = row[0].data else { throw CloudError(.invalidPayload) }
            let batch = try CloudCodec.decode(CloudFetchBatch.self, raw)
            guard try acknowledgement.matches(batch) else { throw CloudError(.invalidPayload) }
            let ackBytes = try CloudCodec.encode(acknowledgement)
            if let existing = row[1].data { guard existing == ackBytes else { throw CloudError(.identityConflict) }; return }
            guard try scopeState(scope: acknowledgement.scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
            try sql.execute("UPDATE cloud_batches SET state=?,issue=NULL,retry_ms=NULL,ack=? WHERE scope=? AND id=?", [.text(CloudDeliveryState.confirmed.rawValue),.blob(ackBytes),.text(try acknowledgement.scope.key),.text(acknowledgement.batchID)])
        }
    }
    public func failBatch(scope: CloudScope, id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        try CloudCodec.date(at); if let nextAttemptAt { try CloudCodec.date(nextAttemptAt) }
        let state: CloudDeliveryState = [.cursorMismatch,.staleGeneration,.invalidPayload,.conflict].contains(issue) ? .blocked : .pending
        try transaction {
            try requireNotLocallyErased(scope)
            guard try !sql.rows("SELECT id FROM cloud_batches WHERE scope=? AND id=? AND state!=?", [.text(try scope.key),.text(id),.text(CloudDeliveryState.confirmed.rawValue)]).isEmpty else { throw CloudError(.invalidPayload) }
            try sql.execute("UPDATE cloud_batches SET state=?,attempts=attempts+1,issue=?,retry_ms=?,attempted_ms=? WHERE scope=? AND id=?", [.text(state.rawValue),.text(issue.rawValue),try nextAttemptAt.map { .integer(try CloudCodec.milliseconds($0)) } ?? .null,.integer(try CloudCodec.milliseconds(at)),.text(try scope.key),.text(id)])
        }
    }

    public func scopeState(scope: CloudScope) throws -> CloudScopeState {
        if case .retainedControl(let context) = access {
            guard !closed else { throw CloudError(.closed) }
            guard scope == context.request.scope else { throw CloudError(.identityConflict) }
            switch try readRetainedFenceState(sql, context: context) {
            case .scopeFence(let attempts): return CloudScopeState(issue: .accountChanged, attemptCount: attempts, nextAttemptAt: nil)
            case .erased: return CloudScopeState(issue: .accountChanged, attemptCount: 0, nextAttemptAt: nil)
            }
        }
        if try locallyErased(scope) { return CloudScopeState(issue: .accountChanged, attemptCount: 0, nextAttemptAt: nil) }
        guard let row = try sql.rows("SELECT issue,attempts,retry_ms FROM cloud_scope_state WHERE scope=?", [.text(try scope.key)]).first else { return CloudScopeState(issue: nil, attemptCount: 0, nextAttemptAt: nil) }
        guard let count = row[1].number, count >= 0 else { throw CloudError(.invalidPayload) }
        return CloudScopeState(issue: try row[0].optionalIssue(), attemptCount: Int(count), nextAttemptAt: row[2].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
    public func recordScopeIssue(scope: CloudScope, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        if case .retainedControl(let context) = access {
            guard !closed else { throw CloudError(.closed) }
            guard scope == context.request.scope else { throw CloudError(.identityConflict) }
            guard issue == .accountChanged, nextAttemptAt == nil else { throw CloudError(.storageUnavailable) }
            _ = try CloudCodec.milliseconds(at)
            switch try readRetainedFenceState(sql, context: context) {
            case .scopeFence: return
            case .erased: throw CloudError(.accountChanged)
            }
        }
        let now = try CloudCodec.milliseconds(at), retry = try nextAttemptAt.map(CloudCodec.milliseconds)
        try transaction {
            try requireNotLocallyErased(scope)
            let current = try scopeState(scope: scope)
            guard current.issue != .accountChanged || issue == .accountChanged else { throw CloudError(.accountChanged) }
            try sql.execute("INSERT INTO cloud_scope_state(scope,issue,attempts,retry_ms,attempted_ms) VALUES(?,?,1,?,?) ON CONFLICT(scope) DO UPDATE SET issue=excluded.issue,attempts=cloud_scope_state.attempts+1,retry_ms=excluded.retry_ms,attempted_ms=excluded.attempted_ms", [.text(try scope.key),.text(issue.rawValue),retry.map(CloudSQLValue.integer) ?? .null,.integer(now)])
        }
    }
    public func clearScopeIssue(scope: CloudScope) throws {
        try transaction {
            guard try scopeState(scope: scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
            try sql.execute("UPDATE cloud_scope_state SET issue=NULL,retry_ms=NULL WHERE scope=?", [.text(try scope.key)])
        }
    }
    public func retainConflict(_ conflict: CloudConflict) throws {
        let raw = try CloudCodec.encode(conflict)
        try transaction {
            try requireNotLocallyErased(conflict.scope)
            let key: [CloudSQLValue] = [.text(try conflict.scope.key),.text(conflict.uploadID),.text(conflict.remoteDigest),.text(conflict.remoteChangeTag)]
            if let row = try sql.rows("SELECT original FROM cloud_conflicts WHERE scope=? AND upload_id=? AND remote_digest=? AND change_tag=?", key).first {
                guard row[0].data == raw else { throw CloudError(.identityConflict) }; return
            }
            try sql.execute("INSERT INTO cloud_conflicts(scope,upload_id,remote_digest,change_tag,original) VALUES(?,?,?,?,?)", key + [.blob(raw)])
        }
    }
    public func conflicts(scope: CloudScope) throws -> [CloudConflict] {
        try requireOrdinaryRead()
        return try sql.rows("SELECT original FROM cloud_conflicts WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data else { throw CloudError(.invalidPayload) }
            let conflict = try CloudCodec.decode(CloudConflict.self, raw)
            guard conflict.scope == scope, CloudCodec.hash(conflict.localBytes) == conflict.localDigest, CloudCodec.hash(conflict.remoteBytes) == conflict.remoteDigest else { throw CloudError(.invalidPayload) }
            _ = try CloudRecord(scope: scope, canonicalBytes: conflict.localBytes); _ = try CloudRecord(scope: scope, canonicalBytes: conflict.remoteBytes)
            return conflict
        }
    }
    public func confirmUpload(_ evidence: DevelopmentCloudSaveEvidence) throws {
        let raw = try CloudCodec.encode(evidence), digest = CloudCodec.hash(raw)
        try transaction {
            try requireNotLocallyErased(evidence.scope)
            let key: [CloudSQLValue] = [.text(try evidence.scope.key),.text(evidence.uploadID)]
            if let existing = try sql.rows("SELECT digest,original FROM cloud_save_evidence WHERE scope=? AND upload_id=?", key).first {
                guard existing[0].string == digest, existing[1].data == raw else { throw CloudError(.identityConflict) }; return
            }
            guard try scopeState(scope: evidence.scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
            guard let row = try sql.rows("SELECT original FROM cloud_uploads WHERE scope=? AND id=?", key).first, let original = row[0].data else { throw CloudError(.invalidPayload) }
            let upload = try CloudCodec.decode(CloudUpload.self, original)
            guard evidence.matches(upload) else { throw CloudError(.invalidPayload) }
            try sql.execute("INSERT INTO cloud_save_evidence(scope,upload_id,digest,original) VALUES(?,?,?,?)", key + [.text(digest),.blob(raw)])
            try sql.execute("UPDATE cloud_uploads SET state=?,attempts=attempts+1,issue=NULL,retry_ms=NULL WHERE scope=? AND id=?", [.text(CloudDeliveryState.confirmed.rawValue)] + key)
        }
    }
    public func saveEvidence(scope: CloudScope) throws -> [DevelopmentCloudSaveEvidence] {
        try requireOrdinaryRead()
        return try sql.rows("SELECT original,digest FROM cloud_save_evidence WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, row[1].string == CloudCodec.hash(raw) else { throw CloudError(.invalidPayload) }
            let evidence = try CloudCodec.decode(DevelopmentCloudSaveEvidence.self, raw)
            guard evidence.scope == scope, evidence.boundary == "controlledDevelopmentTransport" else { throw CloudError(.invalidPayload) }
            return evidence
        }
    }
}
