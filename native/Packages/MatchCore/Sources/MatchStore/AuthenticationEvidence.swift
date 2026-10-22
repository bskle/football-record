import Foundation

public protocol CurrentAuthenticationEvidenceReadingV4: Sendable {
    func currentAuthenticationEvidenceV4(expectedIdentityGeneration: Int64) async throws -> VerifiedLocalAuthenticationEvidenceV4?
}

/// Local committed-grant provenance only; never recording or credential admission.
public struct VerifiedLocalAuthenticationEvidenceV4: Sendable {
    public let binding: AccountBindingV4
    public let identityGeneration: Int64
    public let currentAuthRequestID: String
    public let attempt: AuthAttemptV4
    public let admissionGeneration: Int64
    public let receipt: VerifiedAuthorityReceiptV1
    fileprivate init(binding: AccountBindingV4, identityGeneration: Int64, currentAuthRequestID: String, attempt: AuthAttemptV4, admissionGeneration: Int64, receipt: VerifiedAuthorityReceiptV1) {
        self.binding = binding; self.identityGeneration = identityGeneration
        self.currentAuthRequestID = currentAuthRequestID; self.attempt = attempt
        self.admissionGeneration = admissionGeneration; self.receipt = receipt
    }
}

extension MatchStore: CurrentAuthenticationEvidenceReadingV4 {
    public func currentAuthenticationEvidenceV4(expectedIdentityGeneration: Int64) throws -> VerifiedLocalAuthenticationEvidenceV4? {
        try checkedCurrentAuthenticationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration)
    }

    // No await spans this read snapshot. The optional internal observation hook
    // permits a second real connection to commit while tests hold this snapshot.
    func checkedCurrentAuthenticationEvidenceV4(expectedIdentityGeneration: Int64, afterSnapshot: (@Sendable () throws -> Void)? = nil) throws -> VerifiedLocalAuthenticationEvidenceV4? {
        guard expectedIdentityGeneration >= 0, expectedIdentityGeneration <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        try db.execute("BEGIN DEFERRED")
        do {
            try authenticationEvidenceBudgetV4(table: "lifecycle_steps_v4", id: "identity-generation")
            let generation = try identityGenerationV4()
            try afterSnapshot?()
            guard generation == expectedIdentityGeneration else { throw AuthorityError.identityChanged }
            let value = try currentAuthenticationEvidenceLockedV4(generation: generation)
            try db.execute("COMMIT")
            return value
        } catch {
            let original = error
            try db.execute("ROLLBACK")
            throw original
        }
    }

    private func authenticationEvidenceBudgetV4(table: String, id: String) throws {
        let rows = try db.rows("SELECT length(payload),length(checksum) FROM " + table + " WHERE id=?", [.text(id)])
        guard let row = rows.first else { return }
        guard rows.count == 1, let size = row[0].number, (0...32_768).contains(size), row[1].number == 64 else { throw AuthorityError.invalidWire }
    }

    private func authenticationEvidenceValueV4<T: Codable>(_ type: T.Type, id: String) throws -> T? {
        try authenticationEvidenceBudgetV4(table: "lifecycle_steps_v4", id: id)
        return try readLifecycleV4(type, id)
    }

    private func currentAuthenticationEvidenceLockedV4(generation: Int64) throws -> VerifiedLocalAuthenticationEvidenceV4? {
        try authenticationEvidenceBudgetV4(table: "account_binding_v4", id: "current")
        let binding = try currentBindingV4()
        let currentID = try authenticationEvidenceValueV4(String.self, id: "auth-current")
        guard let currentID else {
            let receiptExists = try db.rows("SELECT 1 FROM lifecycle_steps_v4 WHERE id GLOB 'auth-receipt:*' LIMIT 1").first != nil
            if receiptExists { throw AuthorityError.intentMismatch }
            if let binding {
                if binding.suspended { throw AuthorityError.identityChanged }
                throw binding.role == .watch ? AuthorityError.unavailable : AuthorityError.intentMismatch
            }
            let historyExists = try db.rows("SELECT 1 FROM lifecycle_steps_v4 WHERE id GLOB 'auth-attempt:*' OR id GLOB 'auth-admission:*' OR id GLOB 'auth-resolved:*' LIMIT 1").first != nil
            guard !historyExists else { throw AuthorityError.unavailable }
            return nil
        }
        try AuthorityWire.identifier(currentID)
        guard let binding else { throw AuthorityError.intentMismatch }
        _ = try AccountBindingV4(accountID: binding.accountID, cloudSpaceID: binding.cloudSpaceID, deviceID: binding.deviceID, activationEpoch: binding.activationEpoch, role: binding.role, environment: binding.environment, suspended: binding.suspended)
        guard !binding.suspended else { throw AuthorityError.identityChanged }
        guard let attempt = try authenticationEvidenceValueV4(AuthAttemptV4.self, id: "auth-attempt:" + currentID),
              let admission = try authenticationEvidenceValueV4(Int64.self, id: "auth-admission:" + currentID),
              let raw = try authenticationEvidenceValueV4(Data.self, id: "auth-receipt:" + currentID) else { throw AuthorityError.intentMismatch }
        guard try authenticationEvidenceValueV4(AuthResolutionV4.self, id: "auth-resolved:" + currentID) == nil else { throw AuthorityError.intentMismatch }
        guard admission == generation else { throw AuthorityError.identityChanged }
        guard let trust = authorityTrust, trust.environment == binding.environment, attempt.environment == binding.environment else { throw AuthorityError.unavailable }
        func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
        guard same(attempt.requestID, currentID), same(attempt.deviceID, binding.deviceID), same(attempt.cloudSpaceID, binding.cloudSpaceID),
              same(attempt.keyID, try AuthorityWire.deviceKeyID(publicKey: attempt.publicKey)) else { throw AuthorityError.intentMismatch }
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: currentID, digest: attempt.requestDigest, operation: .authApple, accountID: binding.accountID, epoch: binding.activationEpoch), trust: trust)
        let body = receipt.body
        guard (body.result == .registered && binding.role == .phone) || (body.result == .waitingMigration && binding.role == .waiting),
              body.matchID.isEmpty, body.lockID.isEmpty, body.recordingDeviceID.isEmpty,
              body.migration == nil, body.peerGrant == nil, body.registration == nil, body.lostRecovery == nil, body.deletion == nil else { throw AuthorityError.intentMismatch }
        return VerifiedLocalAuthenticationEvidenceV4(binding: binding, identityGeneration: generation, currentAuthRequestID: currentID, attempt: attempt, admissionGeneration: admission, receipt: receipt)
    }
}
