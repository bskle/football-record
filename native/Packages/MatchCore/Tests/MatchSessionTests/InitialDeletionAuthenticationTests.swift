import Foundation
import CryptoKit
import XCTest
import MatchCore
@testable import MatchStore
@testable import MatchSession

final class InitialDeletionAuthenticationTests: XCTestCase, @unchecked Sendable {
    private func eventually(_ condition: @escaping @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("original gate did not enter", file: file, line: line)
    }
    private func rejected(_ body: () async throws -> Void, retired: Bool = false, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("must reject original operation", file: file, line: line) }
        catch { if retired { XCTAssertEqual(error as? SessionError, .retired, file: file, line: line) } }
    }
    func testOriginalFacadeAndRetirementMutationGates() async throws {
        // J01: source from another real facade is never installed into this one.
        let first = try await InitialSessionFixture(), other = try await InitialSessionFixture()
        let actual = await first.session.syncRepositoryIdentity(), expected = await first.base.syncRepositoryIdentity()
        XCTAssertEqual(actual, expected)
        let before = try await first.state()
        await rejected { _ = try await first.session.prepareInitialDeletionAuthentication(request: first.request,
            expectedSource: other.source, authRequestID: "fresh-auth", challengeRequestID: "fresh-challenge") }
        let unchanged = try await first.state(); XCTAssertEqual(unchanged, before)
        try await first.base.close(); try await other.base.close()

        // J02: all business operations reject retired entry and both original await boundaries.
        for operation in ["prepare", "save", "reserve"] {
            let f = try await InitialSessionFixture(); try await f.stage(operation)
            let original = try await f.state()
            try await f.session.retireBusiness()
            await rejected({ try await f.run(operation) }, retired: true)
            let after = try await f.state(); XCTAssertEqual(after, original); try await f.base.close()
            for gate in ["environment", "mutex"] {
                let x = try await InitialSessionFixture(); try await x.stage(operation)
                let original = try await x.state()
                if gate == "mutex" { await x.session.acquire("_authority-account") }
                else { await x.proxy.configure("environment") }
                let writer = Task { try await x.run(operation) }
                if gate == "mutex" { await eventually { await x.session.initialDeletionWaiterCount() == 1 } }
                else { await eventually { await x.proxy.entered } }
                let completion = InitialSessionCompletion()
                let retiring = Task { try await x.session.retireBusiness(); await completion.finish() }
                await eventually { await x.session.businessRetired }
                let premature = await completion.finished; XCTAssertFalse(premature)
                if gate == "mutex" { await x.session.release("_authority-account") }
                else { await x.proxy.release() }
                await rejected({ try await writer.value }, retired: true); try await retiring.value
                let after = try await x.state(); XCTAssertEqual(after, original)
                try await x.base.close()
            }
        }
    }
    func testLateFactsAndOriginalCommitLoss() async throws {
        // J03: retirement permits only results of the same already-persisted sent attempt.
        for kind in ["accept", "resolve"] {
            let f = try await InitialSessionFixture(); try await f.stage("reserve")
            let normal = try await f.state(normalOnly: true)
            try await f.session.retireBusiness()
            if kind == "accept" {
                try await f.session.acceptInitialDeletionAuthentication(creationID: "delete", authRequestID: "fresh-auth", receipt: f.receipt(f.fresh),
                    opaqueReauthenticationID: "fresh-reauth", expectedIdentityGeneration: 0)
            } else {
                try await f.session.resolveInitialDeletionAttempt(creationID: "delete", authRequestID: "fresh-auth", resolution: .knownExpired, expectedIdentityGeneration: 0)
            }
            let context = try await f.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            if kind == "accept" { XCTAssertEqual(context?.association?.receipt.raw, try f.receipt(f.fresh).raw) }
            else { XCTAssertEqual(context?.attempts.first?.resolution, .knownExpired) }
            let after = try await f.state(normalOnly: true); XCTAssertEqual(after, normal)
            await rejected({ _ = try await f.session.reserveInitialDeletion(creationID: "delete", expectedIdentityGeneration: 0) }, retired: true)
            try await f.base.close()
        }
        // J04: the proxy gates the real commit reply, then loses only that reply.
        let f = try await InitialSessionFixture(); try await f.stage("reserve")
        let normal = try await f.state(normalOnly: true), raw = try f.receipt(f.fresh).raw
        await f.proxy.configure("accept", loseResponse: true)
        let writer = Task { try await f.session.acceptInitialDeletionAuthentication(creationID: "delete", authRequestID: "fresh-auth",
            receipt: f.receipt(f.fresh), opaqueReauthenticationID: "fresh-reauth", expectedIdentityGeneration: 0) }
        await eventually { await f.proxy.entered }
        let committed = try await f.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(committed?.association?.receipt.raw, raw)
        await f.proxy.release()
        do { try await writer.value; XCTFail("actual response loss must surface") }
        catch { XCTAssertEqual(error as? StoreError, .responseLost) }
        let after = try await f.state(normalOnly: true); XCTAssertEqual(after, normal)
        try await f.base.close()
        let reopened = try f.reopen()
        let saved = try await reopened.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(saved?.association?.receipt.raw, raw); try await reopened.close()
    }
    func testNoReentryAndRetirementDrain() async throws {
        // J05: a consumed parent remains the original control workflow.
        let f = try await InitialSessionFixture(); try await f.stage("reserve"); try await f.accept()
        _ = try await f.session.reserveInitialDeletion(creationID: "delete", expectedIdentityGeneration: 0)
        let original = try f.saga(); try await f.base.createDeletionSagaV4(original)
        await rejected { _ = try await f.session.prepareInitialDeletionAuthentication(request: f.request, expectedSource: f.source,
            authRequestID: "another-auth", challengeRequestID: "another-challenge") }
        await rejected { _ = try await f.session.reserveInitialDeletion(creationID: "delete", expectedIdentityGeneration: 0) }
        let saved = try await f.base.deletionSagaV4(requestID: "delete"); XCTAssertEqual(saved, original)
        try await f.base.close()
        // J06: each admitted business call owns its actual SQL reply tail until it returns.
        for operation in ["prepare", "save", "reserve"] {
            let x = try await InitialSessionFixture(); try await x.stage(operation)
            if operation == "reserve" { try await x.accept() }
            await x.proxy.configure(operation)
            let writer = Task { try await x.run(operation) }
            await eventually { await x.proxy.entered }
            let committed = try await x.state(), completion = InitialSessionCompletion()
            let retiring = Task { try await x.session.retireBusiness(); await completion.finish() }
            await eventually { await x.session.businessRetired }
            let premature = await completion.finished; XCTAssertFalse(premature)
            await x.proxy.release(); try await writer.value; try await retiring.value
            let after = try await x.state(); XCTAssertEqual(after, committed)
            let entries = await x.session.initialDeletionBusinessCount(); XCTAssertEqual(entries, 0)
            try await x.base.close()
        }
    }
}

private extension MatchSession {
    func initialDeletionWaiterCount() -> Int { waiters["_authority-account"]?.count ?? 0 }
    func initialDeletionBusinessCount() -> Int { businessEntries }
}
private extension MatchStore {
    func initialSessionTestState(normalOnly: Bool) throws -> Data {
        let whereClause = normalOnly ? " WHERE substr(CAST(id AS BLOB),1,19) != CAST('initial-delete-auth' AS BLOB)" : ""
        var rows = try db.rows("SELECT quote(id),quote(payload),quote(checksum) FROM lifecycle_steps_v4" + whereClause + " ORDER BY id").map { $0.map { $0.string! } }
        rows += try db.rows("SELECT quote(id),quote(payload),quote(checksum) FROM account_binding_v4 ORDER BY id").map { $0.map { $0.string! } }
        return try Canonical.data(rows)
    }
}
private actor InitialSessionCompletion { private(set) var finished = false; func finish() { finished = true } }
private struct InitialSessionFixture: Sendable {
    static let namespace = "initial-delete-session"
    let root: URL, key: Curve25519.Signing.PrivateKey, trust: AuthorityTrustConfiguration
    let base: SQLiteSessionRepository, proxy: InitialSessionRepository, session: MatchSession
    let source: VerifiedLocalAuthenticationEvidenceV4
    let request: InitialDeletionRequestV1, fresh: AuthAttemptV4
    let freshReceipt: VerifiedAuthorityReceiptV1
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        key = Curve25519.Signing.PrivateKey()
        trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["test": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        base = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: Self.namespace, authorityTrust: trust)
        proxy = InitialSessionRepository(base)
        session = MatchSession(store: proxy, deviceIdentity: Identity(value: "phone"), clock: TestClock(), ids: TestIDs(),
            permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: Self.namespace))
        let original = try AuthAttemptV4(requestID: "original-auth", deviceID: "phone", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation),
            cloudSpaceID: "cloud", challengeID: "original-server-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
        let binding = try AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: "phone", activationEpoch: 1, role: .phone, environment: .development)
        try await base.saveAuthAttemptV4(original, expectedIdentityGeneration: 0)
        let signed = try Self.signed(key: key, trust: trust, attempt: original)
        try await base.acceptAuthenticationV4(attempt: original, binding: binding, receipt: signed, expectedIdentityGeneration: 0)
        let observed = try await base.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        source = try XCTUnwrap(observed)
        request = try InitialDeletionRequestV1(creationID: "delete", originalScope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 1),
            cloud: .keep, local: .delete, health: .keep, healthConfirmed: false, confirmedAt: 1000)
        fresh = try AuthAttemptV4(requestID: "fresh-auth", deviceID: "phone", publicKey: original.publicKey, cloudSpaceID: "cloud",
            challengeID: "fresh-server-challenge", requestDigest: String(repeating: "b", count: 64), environment: .development)
        freshReceipt = try Self.signed(key: key, trust: trust, attempt: fresh)
    }
    static func signed(key: Curve25519.Signing.PrivateKey, trust: AuthorityTrustConfiguration, attempt: AuthAttemptV4) throws -> VerifiedAuthorityReceiptV1 {
        let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "test", "receiptID": attempt.requestID + "-receipt",
            "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "authApple", "accountID": "account", "activationEpoch": 1,
            "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "registered", "issuedAt": 1000]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let raw = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes)))], options: [.sortedKeys, .withoutEscapingSlashes])
        return try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: attempt.requestID, digest: attempt.requestDigest,
            operation: .authApple, accountID: "account", epoch: 1), trust: trust)
    }
    func receipt(_ attempt: AuthAttemptV4) throws -> VerifiedAuthorityReceiptV1 {
        guard attempt == fresh else { throw AuthorityError.intentMismatch }
        return freshReceipt
    }
    func stage(_ operation: String) async throws {
        if operation == "prepare" { return }
        _ = try await session.prepareInitialDeletionAuthentication(request: request, expectedSource: source, authRequestID: "fresh-auth", challengeRequestID: "fresh-challenge")
        if operation == "reserve" { try await session.saveInitialDeletionAttempt(creationID: "delete", authentication: fresh, expectedIdentityGeneration: 0) }
    }
    func accept() async throws { try await session.acceptInitialDeletionAuthentication(creationID: "delete", authRequestID: "fresh-auth",
        receipt: receipt(fresh), opaqueReauthenticationID: "fresh-reauth", expectedIdentityGeneration: 0) }
    func run(_ operation: String) async throws {
        switch operation {
        case "prepare": _ = try await session.prepareInitialDeletionAuthentication(request: request, expectedSource: source, authRequestID: "fresh-auth", challengeRequestID: "fresh-challenge")
        case "save": try await session.saveInitialDeletionAttempt(creationID: "delete", authentication: fresh, expectedIdentityGeneration: 0)
        default: _ = try await session.reserveInitialDeletion(creationID: "delete", expectedIdentityGeneration: 0)
        }
    }
    func state(normalOnly: Bool = false) async throws -> Data { let store = await base.store; return try await store.initialSessionTestState(normalOnly: normalOnly) }
    func reopen() throws -> SQLiteSessionRepository { try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: Self.namespace, authorityTrust: trust) }
    func saga() throws -> DeletionSagaV4 {
        let capability = AuthorityWire.base64URL(Data(repeating: 9, count: 32)); var fields = AuthorityFields()
        fields.reauthenticationID = "fresh-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
        return try DeletionSagaV4(intent: ControlIntentV1(requestID: "delete", operation: .deleteAccount, fields: fields), accountID: "account", activationEpoch: 1,
            recoveryCapability: capability, cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: request.originalScope)
    }
}

/// Gates only replies from the same real facade; never substitutes a SQL result.
private actor InitialSessionRepository: SessionRepository, InitialDeletionAuthenticationRepositoryV1 {
    let base: SQLiteSessionRepository
    private var point: String?, continuation: CheckedContinuation<Void, Never>?, loseResponse = false
    private(set) var entered = false
    init(_ base: SQLiteSessionRepository) { self.base = base }
    func configure(_ point: String, loseResponse: Bool = false) { self.point = point; self.loseResponse = loseResponse; entered = false }
    func hold(_ point: String) async throws {
        if self.point == point { entered = true; await withCheckedContinuation { continuation = $0 }; if loseResponse { throw StoreError.responseLost } }
    }
    func release() { point = nil; continuation?.resume(); continuation = nil }
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await base.syncRepositoryIdentity() }
    func databaseNamespace() async -> String { let value = await base.databaseNamespace(); try? await hold("environment"); return value }
    func initialDeletionContextV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionContextV1? { try await base.initialDeletionContextV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration) }
    func prepareInitialDeletionAuthenticationV4(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1 {
        let value = try await base.prepareInitialDeletionAuthenticationV4(request: request, expectedSource: expectedSource, authRequestID: authRequestID, challengeRequestID: challengeRequestID)
        try await hold("prepare"); return value
    }
    func saveInitialDeletionAttemptV4(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws {
        try await base.saveInitialDeletionAttemptV4(creationID: creationID, authentication: authentication, expectedIdentityGeneration: expectedIdentityGeneration); try await hold("save")
    }
    func acceptInitialDeletionAuthenticationV4(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws {
        try await base.acceptInitialDeletionAuthenticationV4(creationID: creationID, authRequestID: authRequestID, receipt: receipt, opaqueReauthenticationID: opaqueReauthenticationID, expectedIdentityGeneration: expectedIdentityGeneration); try await hold("accept")
    }
    func closePreparedInitialDeletionAttemptV4(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws { try await base.closePreparedInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, expectedIdentityGeneration: expectedIdentityGeneration) }
    func resolveInitialDeletionAttemptV4(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws { try await base.resolveInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration) }
    func reserveInitialDeletionV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 { let value = try await base.reserveInitialDeletionV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration); try await hold("reserve"); return value }
    func matchIDs() async throws -> [String] { try await base.matchIDs() }
    func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await base.snapshotV2(matchID: matchID) }
    func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await base.committedCommandV2(commandID: commandID) }
    func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 { try await base.commitV2(request) }
    func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await base.pendingCaptureOperations(matchID: matchID) }
    func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await base.unroutedBusinessOutboxV3(matchID: matchID) }
    func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await base.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
    func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await base.pendingPacketsV2(matchID: matchID) }
    func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await base.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
    func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await base.acknowledgeV2(bytes, peer: peer, now: now) }
    func syncStateV3(matchID: String) async throws -> SyncState { try await base.syncStateV3(matchID: matchID) }
    func ensureSyncDeliveriesV3(matchID: String) async throws { try await base.ensureSyncDeliveriesV3(matchID: matchID) }
    func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await base.dueSyncDeliveriesV3(now: now, limit: limit) }
    func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await base.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
    func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await base.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
    func reactivateSyncACKsV3() async throws { try await base.reactivateSyncACKsV3() }
    func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await base.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
    func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await base.pendingSyncAssembliesV3(peer: peer, now: now) }
    func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await base.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
    func expireSyncAssembliesV3(now: Date) async throws { try await base.expireSyncAssembliesV3(now: now) }
}
