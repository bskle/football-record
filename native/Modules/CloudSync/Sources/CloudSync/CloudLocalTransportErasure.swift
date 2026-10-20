import Foundation

/// Optional single-file boundary; it does not change CloudLedger or erase any business store/staging files.
public protocol CloudLocalTransportErasing: Sendable {
    func eraseLocalTransport(_ request: CloudLocalTransportEraseRequest) async throws -> CloudLocalTransportEraseReceipt
}
public struct UnavailableCloudLocalTransportEraser: CloudLocalTransportErasing {
    public init() {}
    public func eraseLocalTransport(_ request: CloudLocalTransportEraseRequest) async throws -> CloudLocalTransportEraseReceipt { throw CloudError(.storageUnavailable) }
}
public struct CloudLocalTransportEraseRequest: Sendable, Equatable, Encodable {
    public let requestID: String
    public let scope: CloudScope
    public init(requestID: String, scope: CloudScope) throws {
        try CloudCodec.id(requestID); self.requestID = requestID; self.scope = scope
    }
    var digest: String { get throws { try CloudCodec.hash(self, domain: "local-transport-erase") } }
}
/// Minimal local control receipt only, never a cloud save proof or whole-device erase assertion.
public struct CloudLocalTransportEraseReceipt: Sendable, Equatable, Codable {
    public let requestID, requestDigest, stableZoneKey: String
    init(requestID: String, requestDigest: String, stableZoneKey: String) throws {
        try CloudCodec.id(requestID)
        guard CloudAssetReference.validDigest(requestDigest), CloudAssetReference.validDigest(stableZoneKey) else { throw CloudError(.invalidPayload) }
        self.requestID = requestID; self.requestDigest = requestDigest; self.stableZoneKey = stableZoneKey
    }
}
/// Deterministic development-only initialization faults; ordinary transaction faults remain separate.
public enum CloudLedgerMigrationFault: Sendable {
    case afterLegacyValidation, afterFenceTable, afterReceiptTable, afterVersion, afterValidation, afterCommitResponseLost
}

extension SQLiteCloudLedger: CloudLocalTransportErasing {
    func locallyErased(_ scope: CloudScope) throws -> Bool {
        try validatedLocalEraseFences(sql).contains(scope.stableZoneKey)
    }
    func requireNotLocallyErased(_ scope: CloudScope) throws {
        guard try !locallyErased(scope) else { throw CloudError(.accountChanged) }
    }
    /// An external first receipt authorizes only replay of the original internal proof.
    /// Missing controls or restored canonical copies never fall through to fresh erasure.
    public func replayLocalTransportErasure(_ request: CloudLocalTransportEraseRequest, expectedReceipt: CloudLocalTransportEraseReceipt) throws -> CloudLocalTransportEraseReceipt {
        let digest = try request.digest, stable = request.scope.stableZoneKey
        guard expectedReceipt.requestID.utf8.elementsEqual(request.requestID.utf8),
              expectedReceipt.requestDigest == digest, expectedReceipt.stableZoneKey == stable else { throw CloudError(.identityConflict) }
        return try transaction(forLocalErasure: true) {
            try validateLocalErasureLayout(sql)
            guard let row = try sql.rows("SELECT request_digest,stable_zone FROM cloud_local_erase_receipts WHERE request_id=?", [.text(request.requestID)]).first,
                  let oldDigest = row[0].string, let oldStable = row[1].string else { throw CloudError(.invalidPayload) }
            let receipt = try CloudLocalTransportEraseReceipt(requestID: request.requestID, requestDigest: oldDigest, stableZoneKey: oldStable)
            guard receipt == expectedReceipt else { throw CloudError(.identityConflict) }
            guard try locallyErased(request.scope) else { throw CloudError(.invalidPayload) }
            let current = try validateErasureCanonicalRows(sql, version: 4)
            guard !current.contains(where: { $0.stableZoneKey == stable }) else { throw CloudError(.invalidPayload) }
            return receipt
        }
    }
    public func eraseLocalTransport(_ request: CloudLocalTransportEraseRequest) throws -> CloudLocalTransportEraseReceipt {
        let digest = try request.digest, stable = request.scope.stableZoneKey
        return try transaction(forLocalErasure: true) {
            try validateLocalErasureLayout(sql)
            // Replay first: a lost COMMIT response never turns into a new operation.
            if let row = try sql.rows("SELECT request_digest,stable_zone FROM cloud_local_erase_receipts WHERE request_id=?", [.text(request.requestID)]).first {
                guard let oldDigest = row[0].string, let oldStable = row[1].string else { throw CloudError(.invalidPayload) }
                let receipt = try CloudLocalTransportEraseReceipt(requestID: request.requestID, requestDigest: oldDigest, stableZoneKey: oldStable)
                guard oldDigest == digest, oldStable == stable else { throw CloudError(.identityConflict) }
                guard try locallyErased(request.scope) else { throw CloudError(.invalidPayload) }
                let current = try validateErasureCanonicalRows(sql, version: 4)
                guard !current.contains(where: { $0.stableZoneKey == stable }) else {
                    throw CloudError(.invalidPayload)
                }
                return receipt
            }
            let scopes = try validateErasureCanonicalRows(sql, version: 4)
            try sql.execute("INSERT OR IGNORE INTO cloud_local_erase_fences(stable_zone) VALUES(?)", [.text(stable)])
            for scope in scopes where scope.stableZoneKey == stable {
                let key: [CloudSQLValue] = [.text(try scope.key)]
                for table in ["cloud_uploads", "cloud_batches", "cloud_conflicts", "cloud_save_evidence"] {
                    try sql.execute("DELETE FROM " + table + " WHERE scope=?", key)
                }
            }
            guard try !validateErasureCanonicalRows(sql, version: 4).contains(where: { $0.stableZoneKey == stable }) else { throw CloudError(.invalidPayload) }
            try sql.execute("INSERT INTO cloud_local_erase_receipts(request_id,request_digest,stable_zone) VALUES(?,?,?)", [.text(request.requestID),.text(digest),.text(stable)])
            return try CloudLocalTransportEraseReceipt(requestID: request.requestID, requestDigest: digest, stableZoneKey: stable)
        }
    }
}

// Exact schema emitted by the ledger's v1-v4 migrations. Erasure never interprets,
// repairs or migrates an unknown layout, including on an already-open connection.
func validateLocalErasureLayout(_ sql: CloudSQL) throws {
    guard try sql.rows("PRAGMA user_version").first?.first?.number == 4 else { throw CloudError(.unsupportedSchema) }
    let layout = [
        ("cloud_uploads", "CREATE TABLE cloud_uploads(id TEXT PRIMARY KEY, scope TEXT NOT NULL, digest TEXT NOT NULL, original BLOB NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL, issue TEXT, retry_ms INTEGER, attempted_ms INTEGER) STRICT"),
        ("cloud_batches", "CREATE TABLE cloud_batches(scope TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL,issue TEXT,retry_ms INTEGER,attempted_ms INTEGER,ack BLOB,PRIMARY KEY(scope,id)) STRICT"),
        ("cloud_scope_state", "CREATE TABLE cloud_scope_state(scope TEXT PRIMARY KEY,issue TEXT,attempts INTEGER NOT NULL,retry_ms INTEGER,attempted_ms INTEGER) STRICT"),
        ("cloud_conflicts", "CREATE TABLE cloud_conflicts(scope TEXT NOT NULL,upload_id TEXT NOT NULL,remote_digest TEXT NOT NULL,change_tag TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id,remote_digest,change_tag)) STRICT"),
        ("cloud_save_evidence", "CREATE TABLE cloud_save_evidence(scope TEXT NOT NULL,upload_id TEXT NOT NULL,digest TEXT NOT NULL,original BLOB NOT NULL,PRIMARY KEY(scope,upload_id)) STRICT"),
        ("cloud_local_erase_fences", "CREATE TABLE cloud_local_erase_fences(stable_zone TEXT PRIMARY KEY) STRICT"),
        ("cloud_local_erase_receipts", "CREATE TABLE cloud_local_erase_receipts(request_id TEXT PRIMARY KEY,request_digest TEXT NOT NULL,stable_zone TEXT NOT NULL) STRICT")
    ]
    let objects = try sql.rows("SELECT type,name,tbl_name,sql FROM sqlite_schema")
    guard objects.count == layout.count * 2 else { throw CloudError(.invalidPayload) }
    for (name, definition) in layout {
        guard let table = objects.first(where: { $0[1].string == name }),
              table[0].string == "table", table[2].string == name, table[3].string == definition,
              let index = objects.first(where: { $0[1].string == "sqlite_autoindex_" + name + "_1" }),
              index[0].string == "index", index[2].string == name, case .null = index[3] else { throw CloudError(.invalidPayload) }
    }
}

/// Opaque full-scope SQL keys cannot identify an account/zone. Validate every original before classifying;
/// any unclassifiable row aborts the entire transaction, including rows apparently belonging elsewhere.
func validateErasureCanonicalRows(_ sql: CloudSQL, version: Int) throws -> Set<CloudScope> {
    var scopes = Set<CloudScope>()
    func bind(_ scope: CloudScope, _ key: CloudSQLValue) throws {
        guard key.string == (try scope.key) else { throw CloudError(.invalidPayload) }; scopes.insert(scope)
    }
    if version >= 1 {
        for row in try sql.rows("SELECT id,scope,digest,original,state,attempts,issue FROM cloud_uploads") {
            guard let raw = row[3].data, row[2].string == CloudCodec.hash(raw), let state = row[4].string, CloudDeliveryState(rawValue: state) != nil, let count = row[5].number, count >= 0 else { throw CloudError(.invalidPayload) }
            _ = try row[6].optionalIssue()
            let upload = try CloudCodec.decode(CloudUpload.self, raw)
            guard row[0].string == upload.id else { throw CloudError(.invalidPayload) }; try bind(upload.scope, row[1])
        }
    }
    if version >= 2 {
        for row in try sql.rows("SELECT scope,id,digest,original,state,attempts,issue,ack FROM cloud_batches") {
            guard let raw = row[3].data, let state = row[4].string, CloudDeliveryState(rawValue: state) != nil, let count = row[5].number, count >= 0 else { throw CloudError(.invalidPayload) }
            _ = try row[6].optionalIssue()
            let batch = try CloudCodec.decode(CloudFetchBatch.self, raw)
            guard row[1].string == batch.batchID, row[2].string == (try batch.digest) else { throw CloudError(.invalidPayload) }; try bind(batch.scope, row[0])
            switch row[7] {
            case .null: guard state != CloudDeliveryState.confirmed.rawValue else { throw CloudError(.invalidPayload) }
            case .blob(let rawAck):
                guard state == CloudDeliveryState.confirmed.rawValue, try CloudCodec.decode(CloudImportAcknowledgement.self, rawAck).matches(batch) else { throw CloudError(.invalidPayload) }
            default: throw CloudError(.invalidPayload)
            }
        }
    }
    if version >= 3 {
        for row in try sql.rows("SELECT issue,attempts FROM cloud_scope_state") {
            _ = try row[0].optionalIssue(); guard let count = row[1].number, count >= 0 else { throw CloudError(.invalidPayload) }
        }
        for row in try sql.rows("SELECT scope,upload_id,remote_digest,change_tag,original FROM cloud_conflicts") {
            guard let raw = row[4].data else { throw CloudError(.invalidPayload) }
            let conflict = try CloudCodec.decode(CloudConflict.self, raw)
            guard row[1].string == conflict.uploadID, row[2].string == conflict.remoteDigest, row[3].string == conflict.remoteChangeTag,
                  CloudCodec.hash(conflict.localBytes) == conflict.localDigest, CloudCodec.hash(conflict.remoteBytes) == conflict.remoteDigest else { throw CloudError(.invalidPayload) }
            _ = try CloudRecord(scope: conflict.scope, canonicalBytes: conflict.localBytes); _ = try CloudRecord(scope: conflict.scope, canonicalBytes: conflict.remoteBytes)
            try bind(conflict.scope, row[0])
        }
        for row in try sql.rows("SELECT scope,upload_id,digest,original FROM cloud_save_evidence") {
            guard let raw = row[3].data, row[2].string == CloudCodec.hash(raw) else { throw CloudError(.invalidPayload) }
            let evidence = try CloudCodec.decode(DevelopmentCloudSaveEvidence.self, raw)
            guard row[1].string == evidence.uploadID, evidence.boundary == "controlledDevelopmentTransport" else { throw CloudError(.invalidPayload) }; try bind(evidence.scope, row[0])
        }
    }
    if version >= 4 {
        _ = try validatedLocalEraseFences(sql)
    }
    return scopes
}

func validatedLocalEraseFences(_ sql: CloudSQL) throws -> Set<String> {
    var fences = Set<String>()
    for row in try sql.rows("SELECT stable_zone FROM cloud_local_erase_fences") {
        guard let stable = row[0].string, CloudAssetReference.validDigest(stable) else { throw CloudError(.invalidPayload) }; fences.insert(stable)
    }
    for row in try sql.rows("SELECT request_id,request_digest,stable_zone FROM cloud_local_erase_receipts") {
        guard let id = row[0].string, let digest = row[1].string, let stable = row[2].string, fences.contains(stable) else { throw CloudError(.invalidPayload) }
        _ = try CloudLocalTransportEraseReceipt(requestID: id, requestDigest: digest, stableZoneKey: stable)
    }
    return fences
}
