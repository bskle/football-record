import Foundation
import MatchStore
import MatchSession

/// A parent-bound control owner borrowing the original facade, client and vault.
/// It cannot admit an account identity or restart a retired business Session.
public actor DeletionControlAuthenticationService {
    private let client: AuthorityClient
    private let repository: any DeletionControlAuthenticationRepository
    private let coordinator: any DeletionControlAuthenticationCoordinator
    private let scope: CloudScopeV1
    private let apple: any AppleSignInDriver
    private let currentScope: @Sendable () async throws -> CloudScopeV1
    private var stopped = false
    private var lifetime: UInt64 = 0
    private struct Owned: Sendable { let cancel: @Sendable () -> Void; let joined: Task<Void, Never> }
    private var owned: [UUID: Owned] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(client: AuthorityClient, repository: any DeletionControlAuthenticationRepository, coordinator: any DeletionControlAuthenticationCoordinator, scope: CloudScopeV1, apple: any AppleSignInDriver, currentScope: @escaping @Sendable () async throws -> CloudScopeV1 = { throw AuthorityError.unavailable }) {
        self.client = client; self.repository = repository; self.coordinator = coordinator
        self.scope = scope; self.apple = apple; self.currentScope = currentScope
    }
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private func running(_ token: UInt64) throws {
        guard !stopped, token == lifetime, !Task.isCancelled else { throw DeletionControlIssueV1.stopped }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (UInt64) async throws -> T) async throws -> T {
        guard !stopped else { throw DeletionControlIssueV1.stopped }
        let id = UUID(), token = lifetime
        let task = Task {
            await self.acquire(); defer { self.release() }
            try self.running(token)
            return try await operation(token)
        }
        let joined = Task { _ = await task.result }
        owned[id] = Owned(cancel: { task.cancel() }, joined: joined)
        defer { owned.removeValue(forKey: id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func stopAndJoin() async {
        if !stopped { stopped = true; lifetime &+= 1 }
        let pending = Array(owned.values)
        pending.forEach { $0.cancel() }
        for item in pending { await item.joined.value }
    }
    private func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private func same(_ a: CloudScopeV1, _ b: CloudScopeV1) -> Bool {
        same(a.accountID, b.accountID) && same(a.cloudSpaceID, b.cloudSpaceID) && same(a.zoneID, b.zoneID) && a.activationEpoch == b.activationEpoch
    }
    private func seconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        return Int64(value)
    }
    /// The independent source is observed anew; fixture configuration never substitutes for it.
    private func checked(_ parentID: String, _ generation: Int64, _ token: UInt64) async throws -> DeletionControlContextV1 {
        try running(token)
        let coordinatorID = await coordinator.syncRepositoryIdentity(); try running(token)
        let repositoryID = await repository.syncRepositoryIdentity(); try running(token)
        guard coordinatorID == repositoryID else { throw AuthorityError.identityChanged }
        let observed = try await currentScope(); try running(token)
        guard same(observed, scope) else { throw AuthorityError.identityChanged }
        let context = try await repository.deletionControlContextV4(parentID: parentID, expectedIdentityGeneration: generation); try running(token)
        guard same(context.originalScope, scope), same(context.binding.accountID, scope.accountID), same(context.binding.cloudSpaceID, scope.cloudSpaceID), context.binding.activationEpoch == scope.activationEpoch,
              context.binding.environment == client.trust.environment, context.publicKey == client.signer.publicKey,
              context.keyID == (try AuthorityWire.deviceKeyID(publicKey: client.signer.publicKey)) else { throw AuthorityError.identityChanged }
        return context
    }
    private func requireAttempt(_ attempt: DeletionControlAttemptV1, context: DeletionControlContextV1, generation: Int64) throws {
        guard attempt.identityGeneration == generation, context.identityGeneration == generation,
              attempt.parentRequestID == context.saga.intent.requestID, attempt.parentDigest == context.saga.intent.digest,
              same(attempt.originalScope, context.originalScope),
              try AuthorityWire.encode(attempt.binding) == AuthorityWire.encode(context.binding),
              attempt.publicKey == context.publicKey, attempt.keyID == context.keyID,
              attempt.authentication.publicKey == context.publicKey, attempt.authentication.keyID == context.keyID,
              same(attempt.authentication.deviceID, context.binding.deviceID), same(attempt.authentication.cloudSpaceID, context.originalScope.cloudSpaceID), attempt.authentication.environment == context.binding.environment else { throw AuthorityError.identityChanged }
    }
    private func requireFresh(_ credential: DeviceCredential, proof: VerifiedDeletionControlAuthorizationV1) throws {
        let now = try seconds(client.now())
        guard proof.body.result == .ready, proof.body.issuedAt <= now + 60,
              proof.body.expiresAt > now, credential.expiresAt == proof.body.expiresAt else { throw AuthorityError.staleAttestation }
    }
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func object(_ raw: Data) throws -> [String: Any] {
        guard raw.count <= 65536, let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any], try bytes(value) == raw else { throw AuthorityError.invalidWire }
        return value
    }
    private func common(_ context: DeletionControlContextV1, requestID: String) throws -> [String: Any] {
        try AuthorityWire.identifier(requestID)
        return ["version": 1, "purpose": "deleteControl.v1", "requestID": requestID,
                "deleteRequest": try object(context.saga.intent.canonicalRequest), "deleteDigest": context.saga.intent.digest,
                "accountID": context.binding.accountID, "deviceID": context.binding.deviceID, "devicePublicKey": context.publicKey, "keyID": context.keyID,
                "activationEpoch": context.binding.activationEpoch, "cloudSpaceID": context.originalScope.cloudSpaceID, "recoveryCapability": context.saga.recoveryCapability]
    }
    private func unsigned(_ path: String, body: Data) async throws -> Data {
        guard ["/v1/accounts/delete/reauth/challenges", "/v1/accounts/delete/reauth/apple", "/v1/accounts/delete/reauth/recover"].contains(path), body.count <= 16384 else { throw AuthorityError.invalidWire }
        return try await client.response(AuthorityHTTPRequest(method: "POST", path: path, body: body))
    }
    private func transient(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let failure = error as? AuthorityHTTPFailure { return failure.retryable || ["notFound", "unauthorized", "unavailable", "receiptExpired"].contains(failure.code) }
        return false
    }
    public func renew(parentID: String, authRequestID: String, challengeRequestID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlOutcomeV1 {
        try await perform { token in try await self.renewOwned(parentID, authRequestID, challengeRequestID, expectedIdentityGeneration, token) }
    }
    private func renewOwned(_ parentID: String, _ authID: String, _ challengeID: String, _ generation: Int64, _ token: UInt64) async throws -> DeletionControlOutcomeV1 {
        var context = try await checked(parentID, generation, token)
        let previous = try await repository.deletionControlAttemptV4(parentID: parentID, authRequestID: authID)
        context = try await checked(parentID, generation, token)
        if let previous {
            try requireAttempt(previous, context: context, generation: generation)
            return try await recoverOwned(parentID, authID, generation, token)
        }
        let attempts = try await repository.deletionControlAttemptsV4(parentID: parentID)
        context = try await checked(parentID, generation, token)
        for attempt in attempts {
            let result = try await repository.deletionControlAuthorizationV4(parentID: parentID, authRequestID: attempt.authentication.requestID)
            context = try await checked(parentID, generation, token)
            guard result != nil else { throw DeletionControlIssueV1.unresolved }
        }
        var challengeRequest = try common(context, requestID: challengeID)
        challengeRequest["issuedAt"] = try seconds(client.now()); challengeRequest["nonce"] = client.nonce()
        let challengeBytes = try bytes(challengeRequest)
        let challengeSignature = try await client.signer.sign(AuthorityWire.signedInput("football-record.deletion-control.challenge.v1", body: challengeBytes))
        context = try await checked(parentID, generation, token)
        challengeRequest["deviceProof"] = AuthorityWire.base64URL(challengeSignature)
        let rawChallenge: Data
        do { rawChallenge = try await unsigned("/v1/accounts/delete/reauth/challenges", body: bytes(challengeRequest)) }
        catch {
            _ = try await checked(parentID, generation, token)
            if let loss = error as? URLError, loss.code == .networkConnectionLost {
                // This lexical phase precedes Apple authorization, durable auth
                // preparation and every auth POST. It closes no auth attempt.
                let prepared = try await repository.deletionControlAttemptV4(parentID: parentID, authRequestID: authID)
                _ = try await checked(parentID, generation, token)
                guard prepared == nil else { return .unresolved }
                return .needsFreshAuthorization
            }
            if transient(error) { return .unresolved }; throw error
        }
        context = try await checked(parentID, generation, token)
        if let completed = try parentResult(rawChallenge, context: context) { return completed }
        let challenge = try object(rawChallenge), now = try seconds(client.now())
        guard Set(challenge.keys) == ["version", "purpose", "requestID", "challengeID", "expiresAt", "challenge"], challenge["version"] as? Int == 1, challenge["purpose"] as? String == "deleteControl.v1", challenge["requestID"] as? String == challengeID,
              let challengeValue = challenge["challengeID"] as? String, let secret = challenge["challenge"] as? String, let expires = challenge["expiresAt"] as? Int64, expires >= now, expires - now <= 300 else { throw AuthorityError.staleAttestation }
        try AuthorityWire.identifier(challengeValue)
        let hash = AuthorityWire.hash(Data(secret.utf8)), authorization = try await apple.authorize(nonceSHA256: hash)
        context = try await checked(parentID, generation, token)
        var authRequest = try common(context, requestID: authID)
        authRequest["challengeID"] = challengeValue; authRequest["identityToken"] = authorization.identityToken; authRequest["authorizationCode"] = authorization.authorizationCode
        var signing = authRequest; signing["challengeSHA256"] = hash
        let signature = try await client.signer.sign(AuthorityWire.signedInput("football-record.deletion-control.authenticate.v1", body: bytes(signing)))
        context = try await checked(parentID, generation, token)
        authRequest["deviceProof"] = AuthorityWire.base64URL(signature)
        let raw = try bytes(authRequest)
        let auth = try AuthAttemptV4(requestID: authID, deviceID: context.binding.deviceID, publicKey: context.publicKey, cloudSpaceID: context.originalScope.cloudSpaceID, challengeID: challengeValue, requestDigest: AuthorityWire.hash(raw), environment: context.binding.environment)
        let attempt = try DeletionControlAttemptV1(context: context, challengeRequestID: challengeID, authentication: auth)
        try await coordinator.saveDeletionControlAttempt(attempt)
        _ = try await checked(parentID, generation, token)
        let response: Data
        do { response = try await unsigned("/v1/accounts/delete/reauth/apple", body: raw) }
        catch { _ = try await checked(parentID, generation, token); if transient(error) { return .unresolved }; throw error }
        context = try await checked(parentID, generation, token)
        return try await accept(response, context: context, attempt: attempt, generation: generation, token: token)
    }
    public func recover(parentID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlOutcomeV1 {
        try await perform { token in try await self.recoverOwned(parentID, authRequestID, expectedIdentityGeneration, token) }
    }
    private func recoverOwned(_ parentID: String, _ authID: String, _ generation: Int64, _ token: UInt64) async throws -> DeletionControlOutcomeV1 {
        var context = try await checked(parentID, generation, token)
        guard let attempt = try await repository.deletionControlAttemptV4(parentID: parentID, authRequestID: authID) else { throw DeletionControlIssueV1.unresolved }
        context = try await checked(parentID, generation, token)
        try requireAttempt(attempt, context: context, generation: generation)
        var request = try common(context, requestID: client.nonce())
        request["authRequestID"] = authID; request["authRequestDigest"] = attempt.authentication.requestDigest
        request["issuedAt"] = try seconds(client.now()); request["nonce"] = client.nonce()
        let signature = try await client.signer.sign(AuthorityWire.signedInput("football-record.deletion-control.recover.v1", body: bytes(request)))
        context = try await checked(parentID, generation, token)
        try requireAttempt(attempt, context: context, generation: generation)
        request["deviceProof"] = AuthorityWire.base64URL(signature)
        let response: Data
        do { response = try await unsigned("/v1/accounts/delete/reauth/recover", body: bytes(request)) }
        catch { _ = try await checked(parentID, generation, token); if transient(error) { return .unresolved }; throw error }
        context = try await checked(parentID, generation, token)
        return try await accept(response, context: context, attempt: attempt, generation: generation, token: token)
    }
    private func parentResult(_ raw: Data, context: DeletionControlContextV1) throws -> DeletionControlOutcomeV1? {
        let value = try object(raw)
        guard value["status"] != nil else { return nil }
        if Set(value.keys) == ["status"], value["status"] as? String == "receiptExpired" { return .unresolved }
        guard Set(value.keys) == ["status", "receipt"], value["status"] as? String == "backendDeleted", let receipt = value["receipt"] else { throw AuthorityError.invalidWire }
        let proof = try VerifiedAuthorityReceiptV1.verify(bytes(receipt as? [String: Any] ?? [:]), expected: AuthorityExpectedIntent(context.saga.intent, accountID: context.saga.accountID, epoch: context.saga.activationEpoch), trust: client.trust)
        guard proof.body.result == .deleted else { throw AuthorityError.intentMismatch }
        return .parentCompleted(proof)
    }
    private func accept(_ raw: Data, context: DeletionControlContextV1, attempt: DeletionControlAttemptV1, generation: Int64, token: UInt64) async throws -> DeletionControlOutcomeV1 {
        try requireAttempt(attempt, context: context, generation: generation)
        if let completed = try parentResult(raw, context: context) { return completed }
        let value = try object(raw)
        guard Set(value.keys) == ["authorization", "originalAcquire", "credential"], let signed = value["authorization"] as? [String: Any] else { throw AuthorityError.invalidWire }
        let proof = try VerifiedDeletionControlAuthorizationV1.verify(bytes(signed), expectedParent: context.saga, expectedAttempt: attempt, trust: client.trust)
        let parentID = context.saga.intent.requestID
        guard attempt.identityGeneration == generation, same(attempt.originalScope, scope) else { throw AuthorityError.identityChanged }
        if proof.body.result != .ready {
            guard value["credential"] is NSNull, value["originalAcquire"] is NSNull else { throw AuthorityError.invalidWire }
            _ = try await checked(parentID, generation, token)
            switch proof.body.result {
            case .knownAbandoned, .knownExpired, .knownRevoked:
                try await coordinator.resolveDeletionControlAttempt(parentID: parentID, authorization: proof, expectedIdentityGeneration: generation)
                _ = try await checked(parentID, generation, token)
                switch proof.body.result { case .knownAbandoned: return .knownAbandoned; case .knownExpired: return .knownExpired; default: return .knownRevoked }
            case .parentUnavailable: return .parentUnavailable
            case .lockMappingUnavailable: return .lockMappingUnavailable
            case .ready: throw AuthorityError.invalidWire
            }
        }
        guard let credentialObject = value["credential"] as? [String: Any], Set(credentialObject.keys) == ["token", "sessionID", "accountID", "deviceID", "keyID", "activationEpoch", "expiresAt"] else { throw AuthorityError.invalidWire }
        let credential = try JSONDecoder().decode(DeviceCredential.self, from: bytes(credentialObject)), b = proof.body
        guard same(credential.accountID, b.accountID), same(credential.deviceID, b.deviceID), credential.keyID == b.deviceKeyID, credential.activationEpoch == b.activationEpoch, credential.sessionID == b.sessionID, credential.expiresAt == b.expiresAt, credential.expiresAt > (try seconds(client.now())) else { throw AuthorityError.identityChanged }
        _ = try AuthorityWire.decodeBase64URL(credential.token, count: 32)
        try requireFresh(credential, proof: proof)
        let acquire: Data?
        if value["originalAcquire"] is NSNull { acquire = nil }
        else if let original = value["originalAcquire"] as? [String: Any] { acquire = try bytes(original) }
        else { throw AuthorityError.invalidWire }
        _ = try await checked(parentID, generation, token)
        do { try await coordinator.acceptDeletionControlAuthorization(parentID: parentID, authorization: proof, originalAcquire: acquire, expectedIdentityGeneration: generation) }
        catch {
            let original = error
            let readback = try await repository.deletionControlAuthorizationV4(parentID: parentID, authRequestID: attempt.authentication.requestID)
            _ = try await checked(parentID, generation, token)
            try requireFresh(credential, proof: proof)
            guard readback?.authorization.raw == proof.raw, readback?.resolution == nil else { throw original }
        }
        _ = try await checked(parentID, generation, token)
        let beforeVault = try await repository.deletionControlReadyContextV4(parentID: parentID, authorization: proof, expectedIdentityGeneration: generation, at: client.now())
        try running(token)
        try requireAttempt(attempt, context: beforeVault, generation: generation)
        try requireFresh(credential, proof: proof)
        try await client.vault.replace(credential, expectedIdentityGeneration: generation)
        _ = try await checked(parentID, generation, token)
        // The last asynchronous read proves current parent/gen AND this exact
        // attempt's unclosed first proof in one original SQL transaction.
        let afterVault = try await repository.deletionControlReadyContextV4(parentID: parentID, authorization: proof, expectedIdentityGeneration: generation, at: client.now())
        try running(token)
        try requireAttempt(attempt, context: afterVault, generation: generation)
        try requireFresh(credential, proof: proof)
        return .ready(reauthenticationID: b.reauthenticationID, lockState: b.lockState)
    }
    private func currentAuthorization(_ parentID: String, _ generation: Int64, _ token: UInt64) async throws -> (DeletionControlContextV1, DeletionControlAuthorizationRecordV1) {
        var context = try await checked(parentID, generation, token)
        let attempts = try await repository.deletionControlAttemptsV4(parentID: parentID)
        context = try await checked(parentID, generation, token)
        for attempt in attempts.reversed() where attempt.identityGeneration == generation {
            let record = try await repository.deletionControlAuthorizationV4(parentID: parentID, authRequestID: attempt.authentication.requestID)
            context = try await checked(parentID, generation, token)
            if let record, record.authorization.body.result == .ready, record.resolution == nil, record.authorization.body.expiresAt > (try seconds(client.now())) { return (context, record) }
        }
        throw DeletionControlIssueV1.needsFreshAuthorization
    }
    public func lockStatus(parentID: String, expectedIdentityGeneration: Int64) async throws -> VerifiedLiveLockV1 {
        try await perform { token in try await self.statusOwned(parentID, expectedIdentityGeneration, token) }
    }
    private func statusOwned(_ parentID: String, _ generation: Int64, _ token: UInt64) async throws -> VerifiedLiveLockV1 {
        let (context, record) = try await currentAuthorization(parentID, generation, token)
        guard let pin = record.authorization.body.lock, record.originalAcquire != nil else { throw DeletionControlIssueV1.lockMappingUnavailable }
        let query = try LiveLockQueryV1(requestID: client.nonce(), acquireRequestID: pin.acquireRequestID, matchID: pin.matchID, lockID: pin.lockID, recordingDeviceID: pin.recordingDeviceID, activationEpoch: pin.activationEpoch, nonce: client.nonce())
        let request = try await client.signedRequest(path: "/v1/locks/status", body: AuthorityWire.encode(query), requestID: query.requestID)
        _ = try await checked(parentID, generation, token)
        let raw = try await client.response(request)
        _ = try await checked(parentID, generation, token)
        let proof = try VerifiedLiveLockV1.verify(raw, query: query, accountID: context.saga.accountID, trust: client.trust, now: client.now())
        try await coordinator.acceptDeletionControlLiveLock(parentID: parentID, proof: proof, expectedIdentityGeneration: generation)
        _ = try await checked(parentID, generation, token)
        return proof
    }
    public func confirmAbnormal(parentID: String, confirmationID: String, requestID: String, confirmedAt: Date, expectedIdentityGeneration: Int64) async throws -> VerifiedAuthorityReceiptV1 {
        try await perform { token in try await self.abnormalOwned(parentID, confirmationID, requestID, confirmedAt, expectedIdentityGeneration, token) }
    }
    private func abnormalOwned(_ parentID: String, _ confirmationID: String, _ requestID: String, _ confirmedAt: Date, _ generation: Int64, _ token: UInt64) async throws -> VerifiedAuthorityReceiptV1 {
        let (context, record) = try await currentAuthorization(parentID, generation, token)
        guard let pin = record.authorization.body.lock, let acquire = record.originalAcquire else { throw DeletionControlIssueV1.lockMappingUnavailable }
        var fields = AuthorityFields(); fields.matchID = pin.matchID; fields.lockID = pin.lockID; fields.recordingDeviceID = pin.recordingDeviceID; fields.activationEpoch = pin.activationEpoch; fields.mode = "abnormal"
        let intent = try ControlIntentV1(requestID: requestID, operation: .terminate, fields: fields)
        let confirmation = try DeletionControlLockConfirmationV1(parentRequestID: parentID, parentDigest: context.saga.intent.digest, confirmationID: confirmationID, confirmedAt: seconds(confirmedAt), intent: intent, acquireRaw: acquire)
        try await coordinator.saveDeletionControlLockConfirmation(parentID: parentID, confirmation: confirmation, expectedIdentityGeneration: generation)
        _ = try await checked(parentID, generation, token)
        let request = try await client.signedRequest(path: "/v1/locks/terminate", body: intent.canonicalRequest, requestID: requestID)
        _ = try await checked(parentID, generation, token)
        let raw = try await client.response(request)
        _ = try await checked(parentID, generation, token)
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(intent, accountID: context.saga.accountID, epoch: context.saga.activationEpoch), trust: client.trust)
        try await coordinator.acceptDeletionControlAbnormalResult(parentID: parentID, receipt: receipt, expectedIdentityGeneration: generation)
        _ = try await checked(parentID, generation, token)
        return receipt
    }
}
