import Foundation
import MatchStore
import MatchSession

/// Borrows the original facade and reads its existing credential. The extra normal
/// session minted by the server is validated transiently and never installed here.
public actor InitialDeletionAuthenticationService {
    private enum Ownership { @TaskLocal static var owner: UUID? }
    private let owner = UUID()
    private let client: AuthorityClient
    private let repository: any InitialDeletionAuthenticationRepositoryV1 & CurrentAuthenticationEvidenceReadingV4
    private let coordinator: any InitialDeletionAuthenticationCoordinatorV1
    private let apple: any AppleSignInDriver
    private let currentScope: @Sendable () async throws -> CloudScopeV1
    private var stopped = false, lifetime: UInt64 = 0
    private var callers = Set<UUID>(), activeKey: Data?
    private var drains: [CheckedContinuation<Void, Never>] = []
    private enum Output: Sendable { case outcome(InitialDeletionAuthenticationOutcomeV1), reservation(InitialDeletionReservationV1) }
    private struct Flight { let fingerprint: Data; let task: Task<Output, Error> }
    private var flight: Flight?
    private struct Observation: Sendable {
        let source: VerifiedLocalAuthenticationEvidenceV4, credential: DeviceCredential
        let context: InitialDeletionContextV1?
    }
    private struct SourceBytes: Encodable {
        let binding: AccountBindingV4, identityGeneration: Int64, currentAuthRequestID: String
        let attempt: AuthAttemptV4, admissionGeneration: Int64, receipt: Data
        init(_ s: VerifiedLocalAuthenticationEvidenceV4) {
            binding = s.binding; identityGeneration = s.identityGeneration; currentAuthRequestID = s.currentAuthRequestID
            attempt = s.attempt; admissionGeneration = s.admissionGeneration; receipt = s.receipt.raw
        }
    }
    public init(client: AuthorityClient,
        repository: any InitialDeletionAuthenticationRepositoryV1 & CurrentAuthenticationEvidenceReadingV4,
        coordinator: any InitialDeletionAuthenticationCoordinatorV1, apple: any AppleSignInDriver,
        currentScope: @escaping @Sendable () async throws -> CloudScopeV1) {
        self.client = client; self.repository = repository; self.coordinator = coordinator
        self.apple = apple; self.currentScope = currentScope
    }
    private func running(_ token: UInt64) throws {
        guard !stopped, token == lifetime, !Task.isCancelled else { throw InitialDeletionIssueV1.stopped }
    }
    private func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private func sourceBytes(_ value: VerifiedLocalAuthenticationEvidenceV4) throws -> Data { try AuthorityWire.encode(SourceBytes(value)) }
    private func credentialBytes(_ c: DeviceCredential) throws -> Data {
        try AuthorityWire.encode([c.token, c.sessionID, c.accountID, c.deviceID, c.keyID, String(c.activationEpoch), String(c.expiresAt)])
    }
    private func descriptorBytes(_ d: InitialDeletionReservationV1) throws -> Data {
        try AuthorityWire.encode([AuthorityWire.encode(d.request).base64EncodedString(), String(d.identityGeneration), d.originalAuthRequestID,
            d.originalAuthReceiptDigest, d.initialAuthRequestID, d.initialAuthRequestDigest, d.initialAuthReceiptDigest, d.opaqueReauthenticationID])
    }
    private func seconds() throws -> Int64 {
        let value = client.now().timeIntervalSince1970
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }; return Int64(value)
    }
    /// External observations precede the last original SQL snapshot. No vault await follows that snapshot.
    private func checked(_ creation: String, _ generation: Int64, _ token: UInt64,
        expected: Observation? = nil, source expectedSource: VerifiedLocalAuthenticationEvidenceV4? = nil,
        request: InitialDeletionRequestV1? = nil) async throws -> Observation {
        try running(token)
        let cid = await coordinator.syncRepositoryIdentity(); try running(token)
        let rid = await repository.syncRepositoryIdentity(); try running(token)
        guard cid == rid else { throw AuthorityError.identityChanged }
        let scope = try await currentScope(); try running(token)
        let credential = try await client.vault.credential(); try running(token)
        if let expected { guard try credentialBytes(credential) == credentialBytes(expected.credential) else { throw AuthorityError.identityChanged } }
        let context = try await repository.initialDeletionContextV4(creationID: creation, expectedIdentityGeneration: generation); try running(token)
        let source: VerifiedLocalAuthenticationEvidenceV4
        if let context { source = context.originalAuthentication }
        else {
            guard let current = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation) else { throw AuthorityError.identityChanged }
            try running(token); source = current
        }
        let b = source.binding, a = source.attempt
        guard source.identityGeneration == generation, source.admissionGeneration == generation,
            b.role == .phone, !b.suspended, source.receipt.body.result == .registered,
            b.environment == client.trust.environment, a.environment == b.environment,
            same(b.accountID, scope.accountID), same(b.cloudSpaceID, scope.cloudSpaceID), b.activationEpoch == scope.activationEpoch,
            same(a.publicKey, client.signer.publicKey), same(a.keyID, try AuthorityWire.deviceKeyID(publicKey: client.signer.publicKey)),
            same(a.deviceID, b.deviceID), same(a.cloudSpaceID, b.cloudSpaceID),
            same(credential.accountID, b.accountID), same(credential.deviceID, b.deviceID), same(credential.keyID, a.keyID),
            credential.activationEpoch == b.activationEpoch, credential.expiresAt > (try seconds()), !credential.token.isEmpty else { throw AuthorityError.identityChanged }
        if let expected { guard try sourceBytes(source) == sourceBytes(expected.source) else { throw AuthorityError.identityChanged } }
        if let expectedSource { guard try sourceBytes(source) == sourceBytes(expectedSource) else { throw AuthorityError.identityChanged } }
        let originalRequest = request ?? context?.request
        if let originalRequest {
            guard try AuthorityWire.encode(originalRequest.originalScope) == AuthorityWire.encode(scope) else { throw AuthorityError.identityChanged }
            if let context { guard try AuthorityWire.encode(context.request) == AuthorityWire.encode(originalRequest) else { throw AuthorityError.conflict } }
        }
        try running(token)
        return Observation(source: source, credential: credential, context: context)
    }
    private func leave(_ id: UUID) {
        callers.remove(id)
        if callers.isEmpty {
            activeKey = nil; flight = nil
            let all = drains; drains = []; all.forEach { $0.resume() }
        }
    }
    private func cancel(_ id: UUID) { if callers.contains(id) { flight?.task.cancel() } }
    private func perform(key: Data, creation: String, generation: Int64, source: VerifiedLocalAuthenticationEvidenceV4? = nil,
        request: InitialDeletionRequestV1? = nil, operation: @escaping @Sendable (Observation, UInt64) async throws -> Output) async throws -> Output {
        guard !stopped else { throw InitialDeletionIssueV1.stopped }
        guard activeKey == nil || activeKey == key else { throw AuthorityError.conflict }
        let id = UUID(), token = lifetime; callers.insert(id); activeKey = key
        defer { leave(id) }
        return try await Ownership.$owner.withValue(owner) {
            try await withTaskCancellationHandler(operation: {
                let first = try await checked(creation, generation, token, source: source, request: request)
                let fingerprint = try AuthorityWire.encode([key.base64EncodedString(), sourceBytes(first.source).base64EncodedString(), credentialBytes(first.credential).base64EncodedString()])
                let task: Task<Output, Error>
                if let prior = flight {
                    guard prior.fingerprint == fingerprint else { throw AuthorityError.conflict }; task = prior.task
                } else {
                    try running(token)
                    task = Task { try await operation(first, token) }
                    flight = Flight(fingerprint: fingerprint, task: task)
                }
                // A canceled caller still joins the real worker, including cancellation-insensitive HTTP.
                let output = try await task.value
                let final = try await checked(creation, generation, token, expected: first, request: request)
                switch output {
                case .reservation(let descriptor):
                    guard let saved = final.context?.reservation, try descriptorBytes(saved) == descriptorBytes(descriptor) else { throw AuthorityError.identityChanged }
                case .outcome(.associated(let association)):
                    guard let saved = final.context?.association, same(saved.authRequestID, association.authRequestID),
                        saved.receipt.raw == association.receipt.raw, saved.opaqueReauthenticationID.map({ Data($0.utf8) }) == association.opaqueReauthenticationID.map({ Data($0.utf8) }) else { throw AuthorityError.identityChanged }
                default: break
                }
                try running(token); return output
            }, onCancel: { Task { await self.cancel(id) } })
        }
    }
    public func stopAndJoin() async throws {
        guard Ownership.owner != owner else { throw InitialDeletionIssueV1.recursiveStop }
        if !stopped { stopped = true; lifetime &+= 1 }
        let task = flight?.task; task?.cancel()
        if let task { _ = await task.result }
        if !callers.isEmpty { await withCheckedContinuation { drains.append($0) } }
    }
    public func authenticate(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4,
        authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionAuthenticationOutcomeV1 {
        let key = try AuthorityWire.encode(["authenticate", AuthorityWire.encode(request).base64EncodedString(), sourceBytes(expectedSource).base64EncodedString(), authRequestID, challengeRequestID])
        let output = try await perform(key: key, creation: request.creationID, generation: expectedSource.identityGeneration, source: expectedSource, request: request) { first, token in
            .outcome(try await self.authenticateOwned(request, authRequestID, challengeRequestID, first, token))
        }
        guard case .outcome(let value) = output else { throw AuthorityError.conflict }; return value
    }
    public func recover(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionAuthenticationOutcomeV1 {
        let key = try AuthorityWire.encode(["recover", creationID, authRequestID, String(expectedIdentityGeneration)])
        let output = try await perform(key: key, creation: creationID, generation: expectedIdentityGeneration) { first, token in
            .outcome(try await self.recoverOwned(creationID, authRequestID, first, token))
        }
        guard case .outcome(let value) = output else { throw AuthorityError.conflict }; return value
    }
    public func reserve(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 {
        let key = try AuthorityWire.encode(["reserve", creationID, String(expectedIdentityGeneration)])
        let output = try await perform(key: key, creation: creationID, generation: expectedIdentityGeneration) { first, token in
            .reservation(try await self.reserveOwned(creationID, expectedIdentityGeneration, first, token))
        }
        guard case .reservation(let value) = output else { throw AuthorityError.conflict }; return value
    }
    private func reserveOwned(_ creationID: String, _ expectedIdentityGeneration: Int64, _ first: Observation, _ token: UInt64) async throws -> InitialDeletionReservationV1 {
            guard let context = first.context else { throw InitialDeletionIssueV1.unresolved }
            if context.phase == .reserved {
                guard let descriptor = context.reservation else { throw AuthorityError.intentMismatch }
                // Only Store's pure-read mint can resume the dispatch fence after retirement.
                let again = try await checked(creationID, expectedIdentityGeneration, token, expected: first)
                guard let saved = again.context?.reservation, try descriptorBytes(saved) == descriptorBytes(descriptor) else { throw AuthorityError.identityChanged }
                try running(token); return saved
            }
            guard context.phase == .associated, context.reservation == nil else { throw InitialDeletionIssueV1.unresolved }
            let descriptor = try await coordinator.reserveInitialDeletion(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration)
            _ = try await checked(creationID, expectedIdentityGeneration, token, expected: first)
            return descriptor
    }
    private func initial(_ context: InitialDeletionContextV1?) throws {
        if context?.phase == .reserved { throw InitialDeletionIssueV1.alreadyReserved }
        if context?.phase == .consumed { throw InitialDeletionIssueV1.parentExists }
    }
    private func object(_ raw: Data) throws -> [String: Any] {
        guard raw.count <= 65_536, let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any], try bytes(value) == raw else { throw AuthorityError.invalidWire }; return value
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] { try object(AuthorityWire.encode(value)) }
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func transient(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let failure = error as? AuthorityHTTPFailure { return failure.retryable || ["notFound", "unauthorized", "unavailable"].contains(failure.code) }; return false
    }
    private func authenticateOwned(_ request: InitialDeletionRequestV1, _ authID: String, _ challengeID: String, _ first: Observation, _ token: UInt64) async throws -> InitialDeletionAuthenticationOutcomeV1 {
        try initial(first.context)
        if let context = first.context {
            if let association = context.association {
                guard same(association.authRequestID, authID) else { throw AuthorityError.conflict }; return .associated(association)
            }
            if let attempt = context.attempts.first(where: { same($0.authRequestID, authID) }) {
                guard same(attempt.challengeRequestID, challengeID) else { throw AuthorityError.conflict }
                if let resolution = attempt.resolution { return .closed(resolution) }
                if attempt.authentication != nil { return try await recoverOwned(request.creationID, authID, first, token) }
            }
        }
        let generation = first.source.identityGeneration, a = first.source.attempt
        _ = try await coordinator.prepareInitialDeletionAuthentication(request: request, expectedSource: first.source, authRequestID: authID, challengeRequestID: challengeID)
        _ = try await checked(request.creationID, generation, token, expected: first, request: request)
        let challengeRequest = AccountService.ChallengeRequest(requestID: challengeID, deviceID: a.deviceID, devicePublicKey: a.publicKey)
        let raw: Data
        do { raw = try await client.unsigned(path: "/v1/auth/challenges", body: AuthorityWire.encode(challengeRequest)) }
        catch { _ = try await checked(request.creationID, generation, token, expected: first); if transient(error) { return .unresolved }; throw error }
        _ = try await checked(request.creationID, generation, token, expected: first)
        let value = try object(raw), challenge = try AuthorityWire.decode(AccountService.Challenge.self, raw)
        guard challenge.version == 1, same(challenge.requestID, challengeID) else { throw AuthorityError.invalidWire }
        try AuthorityWire.identifier(challenge.challengeID)
        if let status = challenge.status {
            guard Set(value.keys) == ["version", "requestID", "challengeID", "expiresAt", "status"], ["expired", "consumed"].contains(status), challenge.challenge == nil else { throw AuthorityError.invalidWire }
            try await coordinator.closePreparedInitialDeletionAttempt(creationID: request.creationID, authRequestID: authID, expectedIdentityGeneration: generation)
            _ = try await checked(request.creationID, generation, token, expected: first); return .closed(.notDispatched)
        }
        let now = try seconds()
        guard Set(value.keys) == ["version", "requestID", "challengeID", "expiresAt", "challenge"], challenge.expiresAt >= now, challenge.expiresAt - now <= 300, let secret = challenge.challenge else { throw AuthorityError.staleAttestation }
        let hash = AuthorityWire.hash(Data(secret.utf8)), authorization = try await apple.authorize(nonceSHA256: hash)
        _ = try await checked(request.creationID, generation, token, expected: first)
        let auth = AccountService.AuthRequest(requestID: authID, challengeID: challenge.challengeID, identityToken: authorization.identityToken, authorizationCode: authorization.authorizationCode,
            deviceID: a.deviceID, devicePublicKey: a.publicKey, cloudSpaceID: a.cloudSpaceID)
        var signing = try object(auth); signing["challengeSHA256"] = hash
        let signature = try await client.signer.sign(AuthorityWire.signedInput("football-record.device.challenge.v1", body: bytes(signing)))
        _ = try await checked(request.creationID, generation, token, expected: first)
        var full = try object(auth); full["deviceProof"] = AuthorityWire.base64URL(signature)
        let body = try bytes(full), attempt = try AuthAttemptV4(requestID: authID, deviceID: a.deviceID, publicKey: a.publicKey, cloudSpaceID: a.cloudSpaceID,
            challengeID: challenge.challengeID, requestDigest: AuthorityWire.hash(body), environment: a.environment)
        try await coordinator.saveInitialDeletionAttempt(creationID: request.creationID, authentication: attempt, expectedIdentityGeneration: generation)
        _ = try await checked(request.creationID, generation, token, expected: first)
        let response: Data
        do { response = try await client.unsigned(path: "/v1/auth/apple", body: body) }
        catch { _ = try await checked(request.creationID, generation, token, expected: first); if transient(error) { return .unresolved }; throw error }
        _ = try await checked(request.creationID, generation, token, expected: first)
        return try await accept(response, creation: request.creationID, attempt: attempt, first: first, token: token)
    }
    private func recoverOwned(_ creation: String, _ authID: String, _ first: Observation, _ token: UInt64) async throws -> InitialDeletionAuthenticationOutcomeV1 {
        try initial(first.context)
        guard let context = first.context, let saved = context.attempts.first(where: { same($0.authRequestID, authID) }), let attempt = saved.authentication else { throw InitialDeletionIssueV1.unresolved }
        if let resolution = saved.resolution { return .closed(resolution) }
        if let association = context.association { guard same(association.authRequestID, authID) else { throw AuthorityError.conflict }; return .associated(association) }
        let request = AccountService.RecoverRequest(requestID: client.nonce(), authRequestID: authID, deviceID: attempt.deviceID,
            keyID: attempt.keyID, nonce: client.nonce(), devicePublicKey: attempt.publicKey, issuedAt: try seconds())
        var full = try object(request)
        let signature = try await client.signer.sign(AuthorityWire.signedInput("football-record.device.auth-recover.v1", body: bytes(full)))
        _ = try await checked(creation, first.source.identityGeneration, token, expected: first)
        full["deviceProof"] = AuthorityWire.base64URL(signature)
        let response: Data
        do { response = try await client.unsigned(path: "/v1/auth/recover", body: bytes(full)) }
        catch { _ = try await checked(creation, first.source.identityGeneration, token, expected: first); if transient(error) { return .unresolved }; throw error }
        _ = try await checked(creation, first.source.identityGeneration, token, expected: first)
        let value = try object(response)
        if value["status"] != nil {
            guard Set(value.keys) == ["status"], let status = value["status"] as? String else { throw AuthorityError.invalidWire }
            if status == "knownNotFound" { return .unresolved }
            guard let resolution = InitialDeletionResolutionV1(rawValue: status), resolution != .notDispatched else { throw AuthorityError.invalidWire }
            try await coordinator.resolveInitialDeletionAttempt(creationID: creation, authRequestID: authID, resolution: resolution, expectedIdentityGeneration: first.source.identityGeneration)
            _ = try await checked(creation, first.source.identityGeneration, token, expected: first); return .closed(resolution)
        }
        return try await accept(response, creation: creation, attempt: attempt, first: first, token: token)
    }
    private func accept(_ raw: Data, creation: String, attempt: AuthAttemptV4, first: Observation, token: UInt64) async throws -> InitialDeletionAuthenticationOutcomeV1 {
        let value = try object(raw), b = first.source.binding
        guard Set(value.keys) == Set(["receipt", "sessionClaims", "credential", "context"] + (value["reauthenticationID"] == nil ? [] : ["reauthenticationID"])),
            let credentialObject = value["credential"] as? [String: Any], Set(credentialObject.keys) == ["token", "sessionID", "accountID", "deviceID", "keyID", "activationEpoch", "expiresAt"],
            let claimsObject = value["sessionClaims"] as? [String: Any], Set(claimsObject.keys) == ["sessionID", "expiresAt"],
            let contextObject = value["context"] as? [String: Any], Set(contextObject.keys) == ["accountID", "deviceID", "keyID", "activationEpoch"], let receiptObject = value["receipt"] as? [String: Any] else { throw AuthorityError.invalidWire }
        let credential = try JSONDecoder().decode(DeviceCredential.self, from: bytes(credentialObject))
        let claims = try JSONDecoder().decode(AccountService.SessionClaims.self, from: bytes(claimsObject))
        let context = try JSONDecoder().decode(AccountService.Context.self, from: bytes(contextObject))
        guard same(context.accountID, b.accountID), same(context.deviceID, b.deviceID), same(context.keyID, attempt.keyID), context.activationEpoch == b.activationEpoch,
            same(credential.accountID, b.accountID), same(credential.deviceID, b.deviceID), same(credential.keyID, attempt.keyID), credential.activationEpoch == b.activationEpoch,
            same(claims.sessionID, credential.sessionID), claims.expiresAt == credential.expiresAt, credential.expiresAt > (try seconds()), !credential.token.isEmpty else { throw AuthorityError.identityChanged }
        try AuthorityWire.identifier(credential.sessionID)
        let receipt = try VerifiedAuthorityReceiptV1.verify(bytes(receiptObject), expected: AuthorityExpectedIntent(requestID: attempt.requestID, digest: attempt.requestDigest,
            operation: .authApple, accountID: b.accountID, epoch: b.activationEpoch), trust: client.trust)
        let r = receipt.body
        guard r.result == .registered, r.matchID.isEmpty, r.lockID.isEmpty, r.recordingDeviceID.isEmpty,
            r.migration == nil, r.peerGrant == nil, r.registration == nil, r.lostRecovery == nil, r.deletion == nil else { throw AuthorityError.intentMismatch }
        let opaque: String?
        if let supplied = value["reauthenticationID"] { guard let text = supplied as? String else { throw AuthorityError.invalidWire }; try AuthorityWire.identifier(text); opaque = text } else { opaque = nil }
        _ = try await checked(creation, first.source.identityGeneration, token, expected: first)
        do { try await coordinator.acceptInitialDeletionAuthentication(creationID: creation, authRequestID: attempt.requestID, receipt: receipt, opaqueReauthenticationID: opaque, expectedIdentityGeneration: first.source.identityGeneration) }
        catch {
            let original = error, readback = try await checked(creation, first.source.identityGeneration, token, expected: first)
            guard let saved = readback.context?.association, saved.receipt.raw == receipt.raw,
                saved.opaqueReauthenticationID.map({ Data($0.utf8) }) == opaque.map({ Data($0.utf8) }) else { throw original }
        }
        let after = try await checked(creation, first.source.identityGeneration, token, expected: first)
        guard let association = after.context?.association, same(association.authRequestID, attempt.requestID), association.receipt.raw == receipt.raw else { throw AuthorityError.intentMismatch }
        return .associated(association)
    }
}
