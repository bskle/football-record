import Foundation
import SQLite3

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
            guard version == 0 || version == 1 || version == 2 || version == 3 else { throw CloudError(.unsupportedSchema) }
            guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw CloudError(.storageUnavailable) }
            let uploadCheck = "SELECT id,scope,digest,original,state,attempts,issue,retry_ms,attempted_ms FROM cloud_uploads LIMIT 0"
            let batchCheck = "SELECT scope,id,digest,original,state,attempts,issue,retry_ms,attempted_ms,ack FROM cloud_batches LIMIT 0"
            let currentChecks = ["SELECT scope,issue,attempts,retry_ms,attempted_ms FROM cloud_scope_state LIMIT 0", "SELECT scope,upload_id,remote_digest,change_tag,original FROM cloud_conflicts LIMIT 0", "SELECT scope,upload_id,digest,original FROM cloud_save_evidence LIMIT 0"]
            // Validate every existing version before changing either schema or journal settings.
            if version >= 1 { _ = try sql.rows(uploadCheck) }
            if version >= 2 { _ = try sql.rows(batchCheck) }
            if version == 3 { for check in currentChecks { _ = try sql.rows(check) } }
            if version == 0 { guard try sql.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw CloudError(.unsupportedSchema) } }
            if version < 3 {
                // All DDL, final structure checks and version updates commit together.
                try sql.transaction {
                    if version == 0 {
                    try sql.execute("CREATE TABLE cloud_uploads(id TEXT PRIMARY KEY, scope TEXT NOT NULL, digest TEXT NOT NULL, original BLOB NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL, issue TEXT, retry_ms INTEGER, attempted_ms INTEGER) STRICT")
                    }
                    if version < 2 {
                    try sql.execute("CREATE TABLE cloud_batches(scope TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL,issue TEXT,retry_ms INTEGER,attempted_ms INTEGER,ack BLOB,PRIMARY KEY(scope,id)) STRICT")
                    }
                    try sql.execute("CREATE TABLE cloud_scope_state(scope TEXT PRIMARY KEY,issue TEXT,attempts INTEGER NOT NULL,retry_ms INTEGER,attempted_ms INTEGER) STRICT")
                    try sql.execute("CREATE TABLE cloud_conflicts(scope TEXT NOT NULL,upload_id TEXT NOT NULL,remote_digest TEXT NOT NULL,change_tag TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id,remote_digest,change_tag)) STRICT")
                    try sql.execute("CREATE TABLE cloud_save_evidence(scope TEXT NOT NULL,upload_id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id)) STRICT")
                    for check in [uploadCheck,batchCheck] + currentChecks { _ = try sql.rows(check) }
                    try sql.execute("PRAGMA user_version=3")
                }
            }
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
            return CloudUploadEntry(upload: upload, originalBytes: raw, state: state, attemptCount: Int(count), issue: try row[3].optionalIssue(), nextAttemptAt: row[4].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    public func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        try CloudCodec.date(at); if let nextAttemptAt { try CloudCodec.date(nextAttemptAt) }
        try transaction {
            guard try !sql.rows("SELECT id FROM cloud_uploads WHERE id=?", [.text(id)]).isEmpty else { throw CloudError(.invalidPayload) }
            let state: CloudDeliveryState = [.conflict,.invalidPayload,.identityConflict].contains(issue) ? .blocked : .pending
            try sql.execute("UPDATE cloud_uploads SET state=?,attempts=attempts+1,issue=?,retry_ms=?,attempted_ms=? WHERE id=?", [.text(state.rawValue),.text(issue.rawValue), try nextAttemptAt.map { .integer(try CloudCodec.milliseconds($0)) } ?? .null, .integer(try CloudCodec.milliseconds(at)), .text(id)])
        }
    }
    public func stage(_ batch: CloudFetchBatch) throws {
        let raw = try batch.canonicalBytes(), digest = try batch.digest, scopeKey = try batch.scope.key
        try transaction {
            if let row = try sql.rows("SELECT digest,original FROM cloud_batches WHERE scope=? AND id=?", [.text(scopeKey), .text(batch.batchID)]).first {
                guard row[0].string == digest, row[1].data == raw else { throw CloudError(.identityConflict) }; return
            }
            guard try scopeState(scope: batch.scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
            try sql.execute("INSERT INTO cloud_batches(scope,id,digest,original,state,attempts) VALUES(?,?,?,?,?,0)", [.text(scopeKey),.text(batch.batchID),.text(digest),.blob(raw),.text(CloudDeliveryState.pending.rawValue)])
        }
    }
    public func batches(scope: CloudScope) throws -> [CloudBatchEntry] {
        try sql.rows("SELECT original,state,attempts,issue,retry_ms,digest FROM cloud_batches WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, let state = row[1].string.flatMap(CloudDeliveryState.init(rawValue:)), let count = row[2].number, count >= 0 else { throw CloudError(.invalidPayload) }
            let batch = try CloudCodec.decode(CloudFetchBatch.self, raw)
            guard batch.scope == scope, try batch.digest == row[5].string else { throw CloudError(.invalidPayload) }
            return CloudBatchEntry(batch: batch, originalBytes: raw, state: state, attemptCount: Int(count), issue: try row[3].optionalIssue(), nextAttemptAt: row[4].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    public func acknowledge(_ acknowledgement: CloudImportAcknowledgement) throws {
        try transaction {
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
            guard try !sql.rows("SELECT id FROM cloud_batches WHERE scope=? AND id=? AND state!=?", [.text(try scope.key),.text(id),.text(CloudDeliveryState.confirmed.rawValue)]).isEmpty else { throw CloudError(.invalidPayload) }
            try sql.execute("UPDATE cloud_batches SET state=?,attempts=attempts+1,issue=?,retry_ms=?,attempted_ms=? WHERE scope=? AND id=?", [.text(state.rawValue),.text(issue.rawValue),try nextAttemptAt.map { .integer(try CloudCodec.milliseconds($0)) } ?? .null,.integer(try CloudCodec.milliseconds(at)),.text(try scope.key),.text(id)])
        }
    }

    public func scopeState(scope: CloudScope) throws -> CloudScopeState {
        guard let row = try sql.rows("SELECT issue,attempts,retry_ms FROM cloud_scope_state WHERE scope=?", [.text(try scope.key)]).first else { return CloudScopeState(issue: nil, attemptCount: 0, nextAttemptAt: nil) }
        guard let count = row[1].number, count >= 0 else { throw CloudError(.invalidPayload) }
        return CloudScopeState(issue: try row[0].optionalIssue(), attemptCount: Int(count), nextAttemptAt: row[2].number.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
    public func recordScopeIssue(scope: CloudScope, issue: CloudIssue, at: Date, nextAttemptAt: Date?) throws {
        let now = try CloudCodec.milliseconds(at), retry = try nextAttemptAt.map(CloudCodec.milliseconds)
        try transaction {
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
            let key: [CloudSQLValue] = [.text(try conflict.scope.key),.text(conflict.uploadID),.text(conflict.remoteDigest),.text(conflict.remoteChangeTag)]
            if let row = try sql.rows("SELECT original FROM cloud_conflicts WHERE scope=? AND upload_id=? AND remote_digest=? AND change_tag=?", key).first {
                guard row[0].data == raw else { throw CloudError(.identityConflict) }; return
            }
            try sql.execute("INSERT INTO cloud_conflicts(scope,upload_id,remote_digest,change_tag,original) VALUES(?,?,?,?,?)", key + [.blob(raw)])
        }
    }
    public func conflicts(scope: CloudScope) throws -> [CloudConflict] {
        try sql.rows("SELECT original FROM cloud_conflicts WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
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
        try sql.rows("SELECT original,digest FROM cloud_save_evidence WHERE scope=? ORDER BY rowid", [.text(try scope.key)]).map { row in
            guard let raw = row[0].data, row[1].string == CloudCodec.hash(raw) else { throw CloudError(.invalidPayload) }
            let evidence = try CloudCodec.decode(DevelopmentCloudSaveEvidence.self, raw)
            guard evidence.scope == scope, evidence.boundary == "controlledDevelopmentTransport" else { throw CloudError(.invalidPayload) }
            return evidence
        }
    }
}
