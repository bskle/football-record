import Foundation
import MatchCore
import SQLite3
import Darwin
import CryptoKit

enum SQLValue {
    case text(String), blob(Data), integer(Int64), null
    var string: String? { if case .text(let value) = self { value } else { nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
    var number: Int64? { if case .integer(let value) = self { value } else { nil } }
}

private enum ExistingStoreAccess { case readOnlyExisting, readWriteExisting, immutableReadOnlyExisting }
private struct ExistingStoreSQLiteFailure { let code: Int32; let system: Int32 }
enum ExistingStoreOpenStage: Equatable {
    case afterReadOnlyValidation, afterStaticValidation, beforeReadWriteOpen, afterReadWriteOpenBeforeValidation
}
private struct ExistingStoreIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}
private func existingStoreFileError() -> StoreError {
    .sqlite(code: SQLITE_CANTOPEN, message: "existing storage unavailable: " + String(cString: strerror(errno)))
}
private func existingStoreStat(_ path: String, directory: Bool, privateMode: Bool = true) throws -> stat {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw existingStoreFileError() }
    let expected = directory ? S_IFDIR : S_IFREG
    guard info.st_mode & S_IFMT == expected else { throw StoreError.invalidRequest }
    if privateMode {
        guard info.st_uid == geteuid(), info.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
              directory || info.st_nlink == 1 else { throw StoreError.invalidRequest }
    }
    return info
}
// Anchors protect this opening interval. Historical catalog ownership and namespace leasing
// remain the caller's responsibility; this is not an interprocess filesystem lease.
private final class ExistingStoreAdmission {
    let url: URL
    private(set) var fd: Int32
    let original: ExistingStoreIdentity
    let ancestors: [(String, ExistingStoreIdentity)]
    let sidecars: [String: ExistingStoreIdentity]
    init(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.path.hasPrefix("/"),
              !url.path.utf8.contains(0), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              url.query == nil, url.fragment == nil else { throw StoreError.invalidRequest }
        let parent = url.deletingLastPathComponent().path
        _ = try existingStoreStat(parent, directory: true)
        var anchors: [(String, ExistingStoreIdentity)] = [], path = parent
        while true {
            anchors.append((path, ExistingStoreIdentity(try existingStoreStat(path, directory: true, privateMode: false))))
            if path == "/" { break }
            path = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        let main = try existingStoreStat(url.path, directory: false)
        var known: [String: ExistingStoreIdentity] = [:]
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 {
                known[suffix] = ExistingStoreIdentity(try existingStoreStat(url.path + suffix, directory: false))
            } else if errno != ENOENT { throw existingStoreFileError() }
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw existingStoreFileError() }
        self.url = url; fd = descriptor; original = ExistingStoreIdentity(main); ancestors = anchors; sidecars = known
        do { try verify(); _ = try header() }
        catch { Darwin.close(descriptor); fd = -1; throw error }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func verify() throws {
        let main = try existingStoreStat(url.path, directory: false)
        var retained = stat()
        guard fstat(fd, &retained) == 0 else { throw existingStoreFileError() }
        guard retained.st_mode & S_IFMT == S_IFREG, retained.st_nlink == 1, retained.st_uid == geteuid(),
              retained.st_mode & 0o7777 == 0o600, ExistingStoreIdentity(main) == original,
              ExistingStoreIdentity(retained) == original else { throw StoreError.invalidRequest }
        _ = try existingStoreStat(url.deletingLastPathComponent().path, directory: true)
        for (path, expected) in ancestors {
            guard ExistingStoreIdentity(try existingStoreStat(path, directory: true, privateMode: false)) == expected else { throw StoreError.invalidRequest }
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 {
                let current = ExistingStoreIdentity(try existingStoreStat(url.path + suffix, directory: false))
                if let expected = sidecars[suffix], current != expected { throw StoreError.invalidRequest }
            } else {
                guard errno == ENOENT else { throw existingStoreFileError() }
                guard sidecars[suffix] == nil else { throw StoreError.invalidRequest }
            }
        }
    }
    func header() throws -> Data {
        try verify()
        var info = stat(); guard fstat(fd, &info) == 0 else { throw existingStoreFileError() }
        guard info.st_size >= 100 else { throw StoreError.unsupportedSchema(0) }
        var data = Data(count: 100)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 100, 0) }
        guard count == 100 else { throw StoreError.sqlite(code: SQLITE_IOERR | (1 << 8), message: "existing header unavailable") }
        guard data.prefix(16) == Data("SQLite format 3\0".utf8) else { throw StoreError.sqlite(code: SQLITE_NOTADB, message: "invalid existing SQLite header") }
        try verify(); return data
    }
    func noSidecars() throws -> Bool {
        try verify()
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 { return false }
            guard errno == ENOENT else { throw existingStoreFileError() }
        }
        return true
    }
}
private struct ExistingStoreMainVersion: Equatable {
    let device: dev_t, inode: ino_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    let header: Data
}
// Immutable parsing is only provisional when an ordinary readonly SQL read fails
// specifically because clean WAL sidecars are absent. A current SQLite lock follows it.
private final class ExistingStoreStaticMain {
    let admission: ExistingStoreAdmission
    let version: ExistingStoreMainVersion
    let fingerprint: Data
    init?(_ admission: ExistingStoreAdmission) throws {
        guard try admission.noSidecars() else { return nil }
        let version = try Self.version(admission)
        guard version.header[18] == 2, version.header[19] == 2 else { return nil }
        let digest = try Self.fingerprint(admission.fd, size: version.size)
        guard try Self.version(admission) == version, try admission.noSidecars() else { throw StoreError.invalidRequest }
        self.admission = admission; self.version = version; fingerprint = digest
    }
    private static func version(_ admission: ExistingStoreAdmission) throws -> ExistingStoreMainVersion {
        let header = try admission.header()
        var info = stat(); guard fstat(admission.fd, &info) == 0 else { throw existingStoreFileError() }
        return ExistingStoreMainVersion(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec, header: header)
    }
    private static func fingerprint(_ fd: Int32, size: off_t) throws -> Data {
        var hasher = SHA256(), offset: off_t = 0, buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < size {
            let requested = Int(min(off_t(buffer.count), size - offset))
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, requested, offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw StoreError.sqlite(code: SQLITE_IOERR | (1 << 8), message: "existing main unavailable") }
            hasher.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        return Data(hasher.finalize())
    }
    func verify(requireNoSidecars: Bool = true) throws {
        guard try Self.version(admission) == version,
              try Self.fingerprint(admission.fd, size: version.size) == fingerprint,
              try Self.version(admission) == version else { throw StoreError.invalidRequest }
        if requireNoSidecars { guard try admission.noSidecars() else { throw StoreError.invalidRequest } }
    }
}

/// Access is exclusively owned by MatchStore's actor after initialization. No statement escapes.
final class SQLite: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var lastSQLiteFailure: ExistingStoreSQLiteFailure?
    private init(rawExistingURL: URL, access: ExistingStoreAccess) throws {
        let flags: Int32
        switch access {
        case .readOnlyExisting: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        case .readWriteExisting: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .immutableReadOnlyExisting: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        }
        let filename = access == .immutableReadOnlyExisting
            ? URL(fileURLWithPath: rawExistingURL.path).absoluteString + "?mode=ro&immutable=1" : rawExistingURL.path
        let result = sqlite3_open_v2(filename, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = failure(result); if let handle { sqlite3_close_v2(handle) }; handle = nil; throw error
        }
        do { try check(sqlite3_busy_timeout(handle, 5_000)) }
        catch { if let handle { sqlite3_close_v2(handle) }; handle = nil; throw error }
    }
    convenience init(existingCurrentV4URL: URL) throws {
        try self.init(existingCurrentV4URL: existingCurrentV4URL, checkpoint: nil)
    }
    // The checkpoint can interrupt actual validation; it never supplies proof or bypasses it.
    convenience init(existingCurrentV4URL: URL, checkpoint: ((ExistingStoreOpenStage) throws -> Void)?) throws {
        let admission = try ExistingStoreAdmission(existingCurrentV4URL)
        let provisional = try ExistingStoreStaticMain(admission)
        let readonly = try SQLite(rawExistingURL: existingCurrentV4URL, access: .readOnlyExisting)
        var usedStatic = false
        do {
            try readonly.validateExistingCurrentV4()
            try readonly.close()
            try admission.verify()
            try checkpoint?(.afterReadOnlyValidation)
        } catch {
            let failure = readonly.lastSQLiteFailure
            try? readonly.close()
            guard failure?.code == SQLITE_CANTOPEN, failure?.system == ENOENT, let provisional else { throw error }
            try provisional.verify()
            let immutable = try SQLite(rawExistingURL: existingCurrentV4URL, access: .immutableReadOnlyExisting)
            do {
                try immutable.validateExistingCurrentV4(requireWAL: false)
                try immutable.close()
            } catch { try? immutable.close(); throw error }
            try checkpoint?(.afterStaticValidation)
            try provisional.verify()
            usedStatic = true
        }
        try checkpoint?(.beforeReadWriteOpen)
        try admission.verify()
        if usedStatic { try provisional?.verify() }
        try self.init(rawExistingURL: existingCurrentV4URL, access: .readWriteExisting)
        do {
            try admission.verify()
            if usedStatic { try provisional?.verify() }
            try checkpoint?(.afterReadWriteOpenBeforeValidation)
            try admission.verify()
            // After the no-sidecar RW handoff, lawful SQLite coordination may create WAL/SHM.
            // The original main fingerprint still holds; the current lock decides contention.
            if usedStatic { try provisional?.verify(requireNoSidecars: false) }
            // Current SQLite locking and WAL view, not the immutable parser, admit this facade.
            try transaction { try validateExistingCurrentV4() }
            try admission.verify()
            if usedStatic { try provisional?.verify(requireNoSidecars: false) }
            try execute("PRAGMA synchronous=FULL")
            guard try scalar("PRAGMA synchronous").number == 2 else {
                throw StoreError.sqlite(code: SQLITE_ERROR, message: "FULL durability unavailable")
            }
        } catch { try? close(); throw error }
    }
    private func validateExistingCurrentV4(requireWAL: Bool = true) throws {
        try validateLocalErasureLayoutV4()
        if requireWAL {
            guard try scalar("PRAGMA journal_mode").string?.lowercased() == "wal" else {
                throw StoreError.sqlite(code: SQLITE_ERROR, message: "existing WAL required")
            }
        }
    }
    init(url: URL, fault: StoreFault?) throws {
        guard url.isFileURL else { throw StoreError.invalidRequest }
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let error = failure(result); if let handle { sqlite3_close_v2(handle) }; handle = nil; throw error
        }
        do {
            try check(sqlite3_busy_timeout(handle, 5_000))
            let version = try scalar("PRAGMA user_version").number ?? -1
            guard version == 0 || version == 1 || version == 2 || version == 3 || version == 4 else { throw StoreError.unsupportedSchema(version) }
            // Check every existing schema before adding anything; all upgrades share one COMMIT.
            if version >= 1 { for sql in Self.schemaChecks { _ = try rows(sql) } }
            if version >= 2 { for sql in Self.schemaChecksV2 { _ = try rows(sql) } }
            if version >= 3 { for sql in Self.schemaChecksV3 { _ = try rows(sql) } }
            guard try scalar("PRAGMA quick_check(1)").string == "ok" else {
                throw StoreError.sqlite(code: SQLITE_CORRUPT, message: "integrity check failed")
            }
            if version == 4 { for sql in Self.schemaChecksV4 { _ = try rows(sql) } }
            if version < 4 {
                try transaction {
                    if version == 0 {
                        guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw StoreError.unsupportedSchema(0) }
                        for sql in Self.schema { try execute(sql) }
                        if fault == .migrationAfterSchema { throw StoreError.injectedFailure }
                        try execute("PRAGMA user_version=1")
                    }
                    for sql in Self.schemaChecks { _ = try rows(sql) }
                    if version < 2 {
                        for sql in Self.schemaV2 { try execute(sql) }
                        try migrateLegacyCompletionConfirmations()
                        if fault == .migrationAfterSchema || fault == .migrationBeforeV2Version { throw StoreError.injectedFailure }
                        try execute("PRAGMA user_version=2")
                        if fault == .migrationAfterV2Version { throw StoreError.injectedFailure }
                    }
                    for sql in Self.schemaChecksV2 { _ = try rows(sql) }
                    if version < 3 {
                    for sql in Self.schemaV3 { try execute(sql) }
                    if fault == .migrationAfterV3Schema || fault == .migrationBeforeV3Version { throw StoreError.injectedFailure }
                    try execute("PRAGMA user_version=3")
                    if fault == .migrationAfterV3Version { throw StoreError.injectedFailure }
                    }
                    for sql in Self.schemaChecksV3 { _ = try rows(sql) }
                    for sql in Self.schemaV4 { try execute(sql) }
                    if fault == .migrationAfterV4Schema || fault == .migrationBeforeV4Version { throw StoreError.injectedFailure }
                    for sql in Self.schemaChecksV4 { _ = try rows(sql) }
                    try execute("PRAGMA user_version=4")
                    if fault == .migrationAfterV4Version { throw StoreError.injectedFailure }
                }
            }
            for sql in Self.schemaChecksV3 { _ = try rows(sql) }
            for sql in Self.schemaChecksV4 { _ = try rows(sql) }
            guard try scalar("PRAGMA quick_check(1)").string == "ok" else {
                throw StoreError.sqlite(code: SQLITE_CORRUPT, message: "integrity check failed")
            }
            guard try scalar("PRAGMA journal_mode=WAL").string?.lowercased() == "wal" else {
                throw StoreError.sqlite(code: SQLITE_ERROR, message: "WAL unavailable")
            }
            try execute("PRAGMA synchronous=FULL")
            guard try scalar("PRAGMA synchronous").number == 2 else {
                throw StoreError.sqlite(code: SQLITE_ERROR, message: "FULL durability unavailable")
            }
        } catch { if let handle { sqlite3_close_v2(handle) }; handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func close() throws {
        if let handle { try check(sqlite3_close(handle)); self.handle = nil }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body(); try execute("COMMIT"); return result
        } catch {
            let original = error
            // A failed COMMIT may leave the transaction open. Surface rollback failure as well.
            if sqlite3_get_autocommit(handle) == 0 { try execute("ROLLBACK") }
            throw original
        }
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> SQLValue {
        guard let value = try rows(sql, values).first?.first else { throw StoreError.sqlite(code: SQLITE_ERROR, message: "missing SQL result") }
        return value
    }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        guard let handle else { throw StoreError.closed }
        lastSQLiteFailure = nil
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            let error = failure(prepared) // Capture extended code and errno before finalize changes them.
            if let statement { sqlite3_finalize(statement) }
            throw error
        }
        guard let statement else { throw StoreError.sqlite(code: SQLITE_ERROR, message: "missing SQL statement") }
        var finalized = false
        defer { if !finalized { sqlite3_finalize(statement) } }
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else { throw StoreError.invalidRequest }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number): try check(sqlite3_bind_int64(statement, index, number))
            case .null: try check(sqlite3_bind_null(statement, index))
            case .text(let string):
                guard string.utf8.count <= Int(Int32.max) else { throw StoreError.invalidRequest }
                try string.withCString { pointer in try check(sqlite3_bind_text(statement, index, pointer, Int32(string.utf8.count), transient)) }
            case .blob(let data):
                guard data.count <= Int(Int32.max) else { throw StoreError.invalidRequest }
                if data.isEmpty { try check(sqlite3_bind_zeroblob(statement, index, 0)) }
                else { try data.withUnsafeBytes { bytes in try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)) } }
            }
        }
        var result: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure(status) }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let pointer = sqlite3_column_text(statement, column) else { throw failure(SQLITE_CORRUPT) }
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, column) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { throw failure(SQLITE_CORRUPT) }
                case SQLITE_NULL: row.append(.null)
                default: throw failure(SQLITE_MISMATCH)
                }
            }
            result.append(row)
        }
        let status = sqlite3_finalize(statement); finalized = true; try check(status)
        return result
    }
    /// Narrow read-only admission for the Store erasure witness, not a migration or repair.
    func validateLocalErasureLayoutV4() throws {
        let version = try scalar("PRAGMA user_version").number ?? -1
        guard version == 4 else { throw StoreError.unsupportedSchema(version) }
        let definitions = Self.schema + Self.schemaV2 + Self.schemaV3 + Self.schemaV4
        var expected: [String: String] = [:]
        for sql in definitions {
            let words = sql.split(separator: " ")
            expected[String(words[2])] = sql
        }
        var seen: Set<String> = []
        for row in try rows("SELECT type,name,tbl_name,sql FROM sqlite_master") {
            guard let kind = row[0].string, let name = row[1].string, let table = row[2].string else {
                throw StoreError.corruptPayload(table: "sqlite_schema", key: "schema4")
            }
            if kind == "index", case .null = row[3], name.hasPrefix("sqlite_autoindex_"), expected[table] != nil { continue }
            guard kind == "table", name == table, let sql = row[3].string, let original = expected[name],
                  sql.utf8.elementsEqual(original.utf8), seen.insert(name).inserted else {
                throw StoreError.corruptPayload(table: "sqlite_schema", key: name)
            }
        }
        guard seen == Set(expected.keys) else { throw StoreError.corruptPayload(table: "sqlite_schema", key: "schema4") }
        for sql in Self.schemaChecks + Self.schemaChecksV2 + Self.schemaChecksV3 + Self.schemaChecksV4 { _ = try rows(sql) }
        guard try scalar("PRAGMA quick_check(1)").string == "ok" else {
            throw StoreError.sqlite(code: SQLITE_CORRUPT, message: "integrity check failed")
        }
    }
    private func migrateLegacyCompletionConfirmations() throws {
        let emptyDigest = try CaptureRevision.digest([])
        for row in try rows("SELECT match_id,evidence FROM completion") {
            let id = row[0].string ?? "invalid-id", bytes = row[1].data ?? Data()
            guard let evidence = try? JSONDecoder().decode(TrustedCompletionEvidence.self, from: bytes),
                  evidence.matchID == id, !evidence.confirmationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.corruptPayload(table: "completion", key: id)
            }
            let proof = try Canonical.data(CaptureCompletionConfirmation(evidence: evidence, captureDigest: emptyDigest))
            try execute("INSERT INTO completion_confirmations VALUES (?,?,?,?)", [.text(id), .text(evidence.confirmationID), .blob(proof), .text(Canonical.hash(proof))])
        }
    }
    private func failure(_ code: Int32) -> StoreError {
        if let handle {
            lastSQLiteFailure = ExistingStoreSQLiteFailure(code: sqlite3_extended_errcode(handle), system: sqlite3_system_errno(handle))
        }
        return .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")
    }
    private func check(_ code: Int32) throws { if code != SQLITE_OK { throw failure(code) } }
    private static let schema = [
        "CREATE TABLE matches (match_id TEXT PRIMARY KEY NOT NULL, descriptor BLOB NOT NULL, generation INTEGER NOT NULL, intent_id TEXT UNIQUE NOT NULL)",
        "CREATE TABLE events (match_id TEXT NOT NULL, event_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE commands (command_id TEXT PRIMARY KEY NOT NULL, request_hash TEXT NOT NULL, receipt BLOB NOT NULL)",
        "CREATE TABLE outbox (packet_id TEXT PRIMARY KEY NOT NULL, idempotency_key TEXT UNIQUE NOT NULL, match_id TEXT NOT NULL, packet BLOB NOT NULL, checksum TEXT NOT NULL, target TEXT NOT NULL, ack BLOB)",
        "CREATE TABLE inbound (packet_id TEXT PRIMARY KEY NOT NULL, idempotency_key TEXT UNIQUE NOT NULL, checksum TEXT NOT NULL, peer TEXT NOT NULL, ack BLOB NOT NULL)",
        "CREATE TABLE diagnostics (match_id TEXT NOT NULL, code TEXT NOT NULL, key TEXT NOT NULL, raw BLOB NOT NULL, severity TEXT NOT NULL, UNIQUE(match_id,code,key,raw))",
        "CREATE TABLE completion (match_id TEXT PRIMARY KEY NOT NULL, evidence BLOB NOT NULL)"
    ]
    private static let schemaChecks = [
        "SELECT match_id,descriptor,generation,intent_id FROM matches LIMIT 0",
        "SELECT match_id,event_id,payload,checksum FROM events LIMIT 0",
        "SELECT command_id,request_hash,receipt FROM commands LIMIT 0",
        "SELECT packet_id,idempotency_key,match_id,packet,checksum,target,ack FROM outbox LIMIT 0",
        "SELECT packet_id,idempotency_key,checksum,peer,ack FROM inbound LIMIT 0",
        "SELECT match_id,code,key,raw,severity FROM diagnostics LIMIT 0",
        "SELECT match_id,evidence FROM completion LIMIT 0"
    ]
    private static let schemaV2 = [
        "CREATE TABLE capture_identities (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE capture_revisions (id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, parent_id TEXT, revision INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE capture_operations (id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, operation BLOB NOT NULL, checksum TEXT NOT NULL, record BLOB NOT NULL, record_checksum TEXT NOT NULL, history_count INTEGER NOT NULL)",
        "CREATE TABLE capture_operation_history (operation_id TEXT NOT NULL, ordinal INTEGER NOT NULL, command_id TEXT NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(operation_id,ordinal))",
        "CREATE TABLE business_outbox (id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, routing_state TEXT NOT NULL)",
        "CREATE TABLE commands_v2 (command_id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, request BLOB NOT NULL, request_hash TEXT NOT NULL, receipt BLOB NOT NULL)",
        "CREATE TABLE completion_confirmations (match_id TEXT NOT NULL, confirmation_id TEXT NOT NULL, proof BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(match_id,confirmation_id))",
        "CREATE TABLE completion_v2 (match_id TEXT PRIMARY KEY NOT NULL, evidence BLOB NOT NULL, capture_digest TEXT NOT NULL)"
    ]
    private static let schemaChecksV2 = [
        "SELECT id,kind,match_id,payload,checksum FROM capture_identities LIMIT 0",
        "SELECT id,match_id,parent_id,revision,payload,checksum FROM capture_revisions LIMIT 0",
        "SELECT id,match_id,operation,checksum,record,record_checksum,history_count FROM capture_operations LIMIT 0",
        "SELECT operation_id,ordinal,command_id,record,checksum FROM capture_operation_history LIMIT 0",
        "SELECT id,match_id,payload,checksum,routing_state FROM business_outbox LIMIT 0",
        "SELECT command_id,match_id,request,request_hash,receipt FROM commands_v2 LIMIT 0",
        "SELECT match_id,evidence,capture_digest FROM completion_v2 LIMIT 0",
        "SELECT match_id,confirmation_id,proof,checksum FROM completion_confirmations LIMIT 0"
    ]

    private static let schemaV3 = [
        "CREATE TABLE sync_delivery_v3 (delivery_id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE sync_fragments_v3 (fragment_id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE sync_context_v3 (singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE sync_registry_v3 (kind TEXT NOT NULL, id TEXT NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(kind,id))",
        "CREATE TABLE sync_routes_v3 (outbox_id TEXT PRIMARY KEY NOT NULL, packet_id TEXT UNIQUE NOT NULL, idempotency_key TEXT UNIQUE NOT NULL, source TEXT NOT NULL, target TEXT NOT NULL, match_id TEXT NOT NULL, sequence INTEGER NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL, UNIQUE(source,target,match_id,sequence))",
        "CREATE TABLE sync_sequences_v3 (source TEXT NOT NULL, target TEXT NOT NULL, match_id TEXT NOT NULL, next_sequence INTEGER NOT NULL, PRIMARY KEY(source,target,match_id))",
        "CREATE TABLE sync_inbox_v3 (packet_id TEXT PRIMARY KEY NOT NULL, idempotency_key TEXT UNIQUE NOT NULL, source TEXT NOT NULL, target TEXT NOT NULL, match_id TEXT NOT NULL, sequence INTEGER NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL, UNIQUE(source,target,match_id,sequence))",
        "CREATE TABLE sync_acknowledgements_v3 (packet_id TEXT PRIMARY KEY NOT NULL, ack_id TEXT UNIQUE NOT NULL, match_id TEXT NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE sync_ack_controls_v3 (ack_id TEXT PRIMARY KEY NOT NULL, packet_id TEXT UNIQUE NOT NULL, match_id TEXT NOT NULL, raw BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE sync_receive_progress_v3 (source TEXT NOT NULL, target TEXT NOT NULL, match_id TEXT NOT NULL, record BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(source,target,match_id))"
    ]
    private static let schemaChecksV3 = [
        "SELECT delivery_id,match_id,record,checksum FROM sync_delivery_v3 LIMIT 0",
        "SELECT fragment_id,match_id,record,checksum FROM sync_fragments_v3 LIMIT 0",
        "SELECT singleton,payload,checksum FROM sync_context_v3 LIMIT 0",
        "SELECT kind,id,match_id,payload,checksum FROM sync_registry_v3 LIMIT 0",
        "SELECT outbox_id,packet_id,idempotency_key,source,target,match_id,sequence,record,checksum FROM sync_routes_v3 LIMIT 0",
        "SELECT source,target,match_id,next_sequence FROM sync_sequences_v3 LIMIT 0",
        "SELECT packet_id,idempotency_key,source,target,match_id,sequence,record,checksum FROM sync_inbox_v3 LIMIT 0",
        "SELECT packet_id,ack_id,match_id,record,checksum FROM sync_acknowledgements_v3 LIMIT 0",
        "SELECT ack_id,packet_id,match_id,raw,checksum FROM sync_ack_controls_v3 LIMIT 0",
        "SELECT source,target,match_id,record,checksum FROM sync_receive_progress_v3 LIMIT 0"
    ]
    private static let schemaV4 = [
        "CREATE TABLE account_binding_v4 (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE control_intents_v4 (id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE authority_results_v4 (id TEXT PRIMARY KEY NOT NULL, request_id TEXT UNIQUE NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE authority_projection_v4 (match_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE peer_grants_v4 (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE lifecycle_steps_v4 (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE cloud_applied_batches_v4 (scope TEXT NOT NULL, batch_id TEXT NOT NULL, digest TEXT NOT NULL, receipt BLOB NOT NULL, PRIMARY KEY(scope,batch_id))",
        "CREATE TABLE cloud_checkpoints_v4 (id TEXT PRIMARY KEY NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE cloud_records_v4 (id TEXT PRIMARY KEY NOT NULL, scope TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE cloud_history_v4 (scope TEXT NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(scope,match_id))",
        "CREATE TABLE cloud_cursors_v4 (scope TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE cloud_deletions_v4 (scope TEXT NOT NULL, match_id TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(scope,match_id))",
        "CREATE TABLE peer_contexts_v4 (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE peer_inbox_v4 (id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, receipt BLOB NOT NULL)"
    ]
    private static let schemaChecksV4 = [
        "SELECT id,payload,checksum FROM account_binding_v4 LIMIT 0",
        "SELECT id,match_id,payload,checksum FROM control_intents_v4 LIMIT 0",
        "SELECT id,request_id,match_id,payload,checksum FROM authority_results_v4 LIMIT 0",
        "SELECT match_id,payload,checksum FROM authority_projection_v4 LIMIT 0",
        "SELECT id,payload,checksum FROM peer_grants_v4 LIMIT 0",
        "SELECT id,payload,checksum FROM lifecycle_steps_v4 LIMIT 0",
        "SELECT scope,batch_id,digest,receipt FROM cloud_applied_batches_v4 LIMIT 0",
        "SELECT id,match_id,payload,checksum FROM cloud_checkpoints_v4 LIMIT 0",
        "SELECT id,scope,payload,checksum FROM cloud_records_v4 LIMIT 0",
        "SELECT scope,match_id,payload,checksum FROM cloud_history_v4 LIMIT 0",
        "SELECT scope,payload,checksum FROM cloud_cursors_v4 LIMIT 0",
        "SELECT scope,match_id,payload,checksum FROM cloud_deletions_v4 LIMIT 0",
        "SELECT id,payload,checksum FROM peer_contexts_v4 LIMIT 0",
        "SELECT id,digest,receipt FROM peer_inbox_v4 LIMIT 0"
    ]
}
