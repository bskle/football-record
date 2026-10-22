import Foundation

/// Local provenance of a real binding acceptance, never a credential or business permit.
struct StoredCurrentWatchRegistrationV1: Codable, Equatable {
    let version: Int
    let requestID: String
    let requestDigest: String
    let acceptedGeneration: Int64
    let acceptedBinding: AccountBindingV4
    let admittedContext: WatchRegistrationContextV4
    let watchPublicKey: String
    let watchDeviceKeyID: String
    let receiptDigest: String
}

extension MatchStore {
    func watchEvidenceBudgetV4(table: String = "lifecycle_steps_v4", id: String) throws {
        guard let row = try db.rows("SELECT length(payload),length(checksum) FROM " + table + " WHERE id=?", [.text(id)]).first else { return }
        guard let size = row[0].number, (0...32_768).contains(size), row[1].number == 64 else { throw AuthorityError.invalidWire }
    }
    func watchEvidenceValueV4<T: Codable>(_ type: T.Type, id: String) throws -> T? {
        try watchEvidenceBudgetV4(id: id)
        return try readLifecycleV4(type, id)
    }
    func currentWatchRegistrationFactsLockedV4() throws -> (marker: StoredCurrentWatchRegistrationV1, attempt: WatchRegistrationAttemptV4, receipt: VerifiedAuthorityReceiptV1)? {
        let rows = try db.rows("SELECT id,length(payload),length(checksum),CAST(id AS BLOB) FROM lifecycle_steps_v4 WHERE id GLOB 'watch-current*' LIMIT 2")
        guard !rows.isEmpty else { return nil }
        guard rows.count == 1, rows[0][0].string == "watch-current-v1", rows[0][3].data == Data("watch-current-v1".utf8),
              let size = rows[0][1].number, (0...32_768).contains(size), rows[0][2].number == 64 else { throw AuthorityError.invalidWire }
        guard let marker = try watchEvidenceValueV4(StoredCurrentWatchRegistrationV1.self, id: "watch-current-v1") else { throw AuthorityError.intentMismatch }
        guard marker.version == 1, marker.acceptedGeneration >= 0, marker.acceptedGeneration <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        try AuthorityWire.identifier(marker.requestID)
        guard let attempt = try watchEvidenceValueV4(WatchRegistrationAttemptV4.self, id: "watch-attempt:" + marker.requestID),
              let raw = try watchEvidenceValueV4(Data.self, id: "watch-receipt:" + marker.requestID) else { throw AuthorityError.intentMismatch }
        try attempt.validate()
        let binding = marker.acceptedBinding
        _ = try AccountBindingV4(accountID: binding.accountID, cloudSpaceID: binding.cloudSpaceID, deviceID: binding.deviceID, activationEpoch: binding.activationEpoch, role: binding.role, environment: binding.environment, suspended: binding.suspended)
        _ = try WatchRegistrationContextV4(accountID: marker.admittedContext.accountID, cloudSpaceID: marker.admittedContext.cloudSpaceID, phoneID: marker.admittedContext.phoneID, activationEpoch: marker.admittedContext.activationEpoch, environment: marker.admittedContext.environment)
        guard marker.requestID.utf8.elementsEqual(attempt.requestID.utf8), marker.requestDigest == attempt.requestDigest,
              marker.receiptDigest == AuthorityWire.hash(raw), binding.role == .watch, !binding.suspended,
              binding.accountID.utf8.elementsEqual(attempt.context.accountID.utf8), binding.cloudSpaceID.utf8.elementsEqual(attempt.context.cloudSpaceID.utf8),
              binding.deviceID.utf8.elementsEqual(attempt.payload.watchID.utf8), binding.activationEpoch == attempt.context.activationEpoch, binding.environment == attempt.context.environment,
              try Canonical.data(marker.admittedContext) == Canonical.data(attempt.context),
              marker.watchPublicKey.utf8.elementsEqual(attempt.payload.watchPublicKey.utf8),
              marker.watchDeviceKeyID == (try AuthorityWire.deviceKeyID(publicKey: attempt.payload.watchPublicKey)) else { throw AuthorityError.intentMismatch }
        let receipt = try verifyWatchRegistrationV4(attempt, raw: raw)
        guard receipt.body.result == .registered else { throw AuthorityError.intentMismatch }
        return (marker, attempt, receipt)
    }
    /// Historical integrity only: later generation/admission/binding changes must not poison retained facts.
    func validateCurrentWatchRegistrationRowsLockedV4() throws {
        _ = try currentWatchRegistrationFactsLockedV4()
    }
    func persistCurrentWatchRegistrationV4(attempt: WatchRegistrationAttemptV4, receipt: VerifiedAuthorityReceiptV1, binding: AccountBindingV4, generation: Int64) throws {
        guard generation >= 0, generation <= 9_007_199_254_740_991,
              let admission = try watchEvidenceValueV4(StoredWatchAdmission.self, id: "watch-admission:" + attempt.payload.watchID),
              try Canonical.data(admission.context) == Canonical.data(attempt.context),
              admission.publicKey.utf8.elementsEqual(attempt.payload.watchPublicKey.utf8) else { throw AuthorityError.identityChanged }
        let marker = StoredCurrentWatchRegistrationV1(version: 1, requestID: attempt.requestID, requestDigest: attempt.requestDigest,
            acceptedGeneration: generation, acceptedBinding: binding, admittedContext: admission.context,
            watchPublicKey: admission.publicKey, watchDeviceKeyID: try AuthorityWire.deviceKeyID(publicKey: admission.publicKey), receiptDigest: AuthorityWire.hash(receipt.raw))
        try writeV4(marker, table: "lifecycle_steps_v4", id: "watch-current-v1")
    }
}
