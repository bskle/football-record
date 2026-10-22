import Foundation

public protocol WatchRegistrationSetupEvidenceReadingV4: Sendable {
    func watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: Int64, deviceID: String, publicKey: String) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4
}

/// A local setup snapshot, never current registration, credentials or recording admission.
public struct CheckedLocalWatchRegistrationSetupEvidenceV4: Sendable {
    public enum State: Sendable, Equatable { case empty, admissionOnly }
    public let state: State
    public let identityGeneration: Int64
    public let watchDeviceID: String
    public let watchPublicKey: String
    public let watchDeviceKeyID: String
    public let admittedContext: WatchRegistrationContextV4?
    fileprivate init(state: State, identityGeneration: Int64, watchDeviceID: String,
                     watchPublicKey: String, watchDeviceKeyID: String, admittedContext: WatchRegistrationContextV4?) {
        self.state = state; self.identityGeneration = identityGeneration
        self.watchDeviceID = watchDeviceID; self.watchPublicKey = watchPublicKey
        self.watchDeviceKeyID = watchDeviceKeyID; self.admittedContext = admittedContext
    }
}

private let watchSetupEmptyTablesV4 = [
    "account_binding_v4", "control_intents_v4", "authority_results_v4", "authority_projection_v4",
    "peer_grants_v4", "peer_contexts_v4", "peer_inbox_v4", "cloud_applied_batches_v4",
    "cloud_checkpoints_v4", "cloud_records_v4", "cloud_history_v4", "cloud_cursors_v4", "cloud_deletions_v4",
    "matches", "events", "commands", "outbox", "inbound", "diagnostics", "completion",
    "capture_identities", "capture_revisions", "capture_operations", "capture_operation_history",
    "business_outbox", "commands_v2", "completion_confirmations", "completion_v2",
    "sync_delivery_v3", "sync_fragments_v3", "sync_context_v3", "sync_registry_v3", "sync_routes_v3",
    "sync_sequences_v3", "sync_inbox_v3", "sync_acknowledgements_v3", "sync_ack_controls_v3", "sync_receive_progress_v3"
]

extension MatchStore: WatchRegistrationSetupEvidenceReadingV4 {
    public func watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: Int64, deviceID: String, publicKey: String) throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
        try checkedWatchRegistrationSetupEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration, deviceID: deviceID, publicKey: publicKey)
    }

    // No await crosses this snapshot. The hook permits a real second connection in tests.
    func checkedWatchRegistrationSetupEvidenceV4(expectedIdentityGeneration: Int64, deviceID: String, publicKey: String, afterSnapshot: (@Sendable () throws -> Void)? = nil) throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
        guard expectedIdentityGeneration >= 0, expectedIdentityGeneration <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        try AuthorityWire.identifier(deviceID)
        let keyID = try AuthorityWire.deviceKeyID(publicKey: publicKey)
        guard let trust = authorityTrust else { throw AuthorityError.unavailable }
        switch (syncEnvironment, trust.environment) {
        case (.production, .production), (.development, .development): break
        default: throw AuthorityError.identityChanged
        }
        try db.execute("BEGIN DEFERRED")
        do {
            try watchEvidenceBudgetV4(id: "identity-generation")
            let generation = try identityGenerationV4()
            try afterSnapshot?()
            guard generation == expectedIdentityGeneration else { throw AuthorityError.identityChanged }
            try db.validateLocalErasureLayoutV4()
            let admission = try watchSetupAdmissionLockedV4(deviceID: deviceID, publicKey: publicKey, environment: trust.environment)
            for table in watchSetupEmptyTablesV4 {
                guard try db.rows("SELECT 1 FROM " + table + " LIMIT 1").isEmpty else { throw AuthorityError.unavailable }
            }
            let result = CheckedLocalWatchRegistrationSetupEvidenceV4(
                state: admission == nil ? .empty : .admissionOnly, identityGeneration: generation,
                watchDeviceID: deviceID, watchPublicKey: publicKey, watchDeviceKeyID: keyID, admittedContext: admission?.context)
            try db.execute("COMMIT")
            return result
        } catch {
            let original = error
            try db.execute("ROLLBACK")
            if original is DecodingError { throw AuthorityError.invalidWire }
            throw original
        }
    }

    private func watchSetupAdmissionLockedV4(deviceID: String, publicKey: String, environment: AuthorityEnvironment) throws -> StoredWatchAdmission? {
        // Inspect bounded metadata before loading any payload or unbounded key bytes.
        let rows = try db.rows("""
            SELECT length(CAST(id AS BLOB)),length(payload),length(checksum),
                   typeof(id),typeof(payload),typeof(checksum),substr(CAST(id AS BLOB),1,161)
            FROM lifecycle_steps_v4 ORDER BY rowid LIMIT 3
            """)
        guard rows.count <= 2 else { throw AuthorityError.invalidWire }
        let admissionID = "watch-admission:" + deviceID
        var hasAdmission = false
        for row in rows {
            guard let keySize = row[0].number, (1...160).contains(keySize), row[3].string == "text",
                  let keyBytes = row[6].data, keyBytes.count == Int(keySize),
                  let key = String(data: keyBytes, encoding: .utf8), keyBytes == Data(key.utf8) else { throw AuthorityError.invalidWire }
            guard keyBytes == Data("identity-generation".utf8) || keyBytes == Data(admissionID.utf8) else { throw AuthorityError.unavailable }
            guard row[4].string == "blob", let size = row[1].number, (0...32_768).contains(size),
                  row[5].string == "text", row[2].number == 64 else { throw AuthorityError.invalidWire }
            if keyBytes == Data(admissionID.utf8) { hasAdmission = true }
        }
        guard hasAdmission else { return nil }
        guard let admission = try watchEvidenceValueV4(StoredWatchAdmission.self, id: admissionID) else { throw AuthorityError.invalidWire }
        let context = admission.context
        _ = try WatchRegistrationContextV4(accountID: context.accountID, cloudSpaceID: context.cloudSpaceID,
            phoneID: context.phoneID, activationEpoch: context.activationEpoch, environment: context.environment)
        _ = try AuthorityWire.deviceKeyID(publicKey: admission.publicKey)
        guard context.environment == environment, !deviceID.utf8.elementsEqual(context.phoneID.utf8),
              admission.publicKey.utf8.elementsEqual(publicKey.utf8) else { throw AuthorityError.identityChanged }
        return admission
    }
}
