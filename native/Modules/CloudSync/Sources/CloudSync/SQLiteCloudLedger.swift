import Foundation
import SQLite3

// One actor owns one transport-only connection. No SQL transaction contains a network await.
enum CloudSQLValue {
    case text(String), blob(Data), integer(Int64), null
    var string: String? { if case .text(let x) = self { x } else { nil } }
    var data: Data? { if case .blob(let x) = self { x } else { nil } }
    var number: Int64? { if case .integer(let x) = self { x } else { nil } }
}
final class CloudSQL: @unchecked Sendable {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard url.isFileURL else { throw CloudError(.invalidPayload) }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if let handle { sqlite3_close_v2(handle) }; handle = nil; throw CloudError(.storageUnavailable) }
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
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CloudError(.storageUnavailable) }
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
            guard code == SQLITE_ROW else { throw CloudError(.storageUnavailable) }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB: return .blob(Data(bytes: sqlite3_column_blob(statement, index) ?? UnsafeRawPointer(bitPattern: 1)!, count: Int(sqlite3_column_bytes(statement, index))))
                default: return .null
                }
            })
        }
    }
}

public actor SQLiteCloudLedger: CloudLedger {
    let sql: CloudSQL
    private let fault: CloudLedgerFault?
    public init(url: URL, fault: CloudLedgerFault? = nil) throws {
        let sql = try CloudSQL(url: url)
        do {
            let version = try sql.rows("PRAGMA user_version").first?.first?.number ?? -1
            guard version == 0 || version == 1 else { throw CloudError(.unsupportedSchema) }
            guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw CloudError(.storageUnavailable) }
            if version == 0 {
                guard try sql.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw CloudError(.unsupportedSchema) }
                try sql.transaction {
                    try sql.execute("CREATE TABLE cloud_uploads(id TEXT PRIMARY KEY, scope TEXT NOT NULL, digest TEXT NOT NULL, original BLOB NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL, issue TEXT, retry_ms INTEGER, attempted_ms INTEGER) STRICT")
                    try sql.execute("PRAGMA user_version=1")
                }
            }
            _ = try sql.rows("SELECT id,scope,digest,original,state,attempts,issue,retry_ms,attempted_ms FROM cloud_uploads LIMIT 0")
            guard try sql.rows("PRAGMA journal_mode=WAL").first?.first?.string?.lowercased() == "wal" else { throw CloudError(.storageUnavailable) }
            try sql.execute("PRAGMA synchronous=FULL")
        } catch { try? sql.close(); throw error }
        self.sql = sql; self.fault = fault
    }
    public func close() throws { try sql.close() }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let result = try sql.transaction {
            let result = try body(); if fault == .beforeCommit { throw CloudError(.storageUnavailable) }; return result
        }
        if fault == .afterCommitResponseLost { throw CloudError(.storageUnavailable) }
        return result
    }
    public func enqueue(_ upload: CloudUpload) throws {
        let raw = try upload.canonicalBytes(), digest = CloudCodec.hash(raw)
        try transaction {
            if let row = try sql.rows("SELECT digest,original FROM cloud_uploads WHERE id=?", [.text(upload.id)]).first {
                guard row[0].string == digest, row[1].data == raw else { throw CloudError(.identityConflict) }; return
            }
            try sql.execute("INSERT INTO cloud_uploads(id,scope,digest,original,state,attempts) VALUES(?,?,?,?,?,0)", [.text(upload.id), .text(try upload.scope.key), .text(digest), .blob(raw), .text(CloudDeliveryState.pending.rawValue)])
        }
    }
    public func uploads(scope: CloudScope) throws -> [CloudUploadEntry] {
        try sql.rows("SELECT original,state,attempts,issue,retry_ms,digest FROM cloud_uploads WHERE scope=? ORDER BY id", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, let state = row[1].string.flatMap(CloudDeliveryState.init(rawValue:)), let count = row[2].number, count >= 0, row[5].string == CloudCodec.hash(raw) else { throw CloudError(.invalidPayload) }
            let upload = try CloudCodec.decode(CloudUpload.self, raw)
            guard upload.scope == scope else { throw CloudError(.accountChanged) }
            return CloudUploadEntry(upload: upload, originalBytes: raw, state: state, attemptCount: Int(count), issue: row[3].string.flatMap(CloudIssue.init(rawValue:)), nextAttemptAt: row[4].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    public func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        try CloudCodec.date(at); if let nextAttemptAt { try CloudCodec.date(nextAttemptAt) }
        try transaction {
            guard try !sql.rows("SELECT id FROM cloud_uploads WHERE id=?", [.text(id)]).isEmpty else { throw CloudError(.invalidPayload) }
            try sql.execute("UPDATE cloud_uploads SET attempts=attempts+1,issue=?,retry_ms=?,attempted_ms=? WHERE id=?", [.text(issue.rawValue), try nextAttemptAt.map { .integer(try CloudCodec.milliseconds($0)) } ?? .null, .integer(try CloudCodec.milliseconds(at)), .text(id)])
        }
    }
}
