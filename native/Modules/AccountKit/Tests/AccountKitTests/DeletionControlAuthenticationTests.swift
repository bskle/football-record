import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import AccountKit

actor DeletionControlRelay: AuthorityHTTPRelay {
    let upstream: any AuthorityHTTPRelay
    var dropAuth = false
    var dropBeforeAuth = false
    var dropChallenge = false
    var challengeFailure: String?
    var alterAuth: String?
    var recoverStatus: Int?
    var paths: [String] = []
    init(_ upstream: any AuthorityHTTPRelay) { self.upstream = upstream }
    func dropNextAuthentication() { dropAuth = true }
    func dropAuthenticationBeforeDispatch() { dropBeforeAuth = true }
    func dropNextChallengeResponse() { dropChallenge = true }
    func failChallenge(_ value: String?) { challengeFailure = value }
    func alterAuthentication(_ value: String?) { alterAuth = value }
    func failRecovery(_ status: Int?) { recoverStatus = status }
    func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
        paths.append(request.path)
        if request.path == "/v1/accounts/delete/reauth/challenges", let challengeFailure {
            if challengeFailure == "timeout" { throw URLError(.timedOut) }
            return AuthorityHTTPResponse(status: Int(challengeFailure)!, body: Data("{\"code\":\"unauthorized\",\"requestID\":\"challenge-original\",\"retryable\":false}".utf8))
        }
        if request.path == "/v1/accounts/delete/reauth/recover", let status = recoverStatus {
            return AuthorityHTTPResponse(status: status, body: Data("{\"code\":\"notFound\",\"requestID\":\"original\",\"retryable\":false}".utf8))
        }
        if request.path == "/v1/accounts/delete/reauth/apple", dropBeforeAuth {
            dropBeforeAuth = false; throw URLError(.networkConnectionLost)
        }
        let response = try await upstream.send(request)
        if request.path == "/v1/accounts/delete/reauth/challenges", dropChallenge {
            dropChallenge = false; throw URLError(.networkConnectionLost)
        }
        if request.path == "/v1/accounts/delete/reauth/apple", let alterAuth {
            var value = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            if alterAuth == "extra" { value["futureField"] = true }
            else if alterAuth == "credential" { var credential = value["credential"] as! [String: Any]; credential["accountID"] = "foreign-account"; value["credential"] = credential }
            else { var proof = value["authorization"] as! [String: Any]; var body = proof["body"] as! [String: Any]; body["purpose"] = "ordinary"; proof["body"] = body; value["authorization"] = proof }
            return AuthorityHTTPResponse(status: response.status, body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        if request.path == "/v1/accounts/delete/reauth/apple", dropAuth {
            dropAuth = false
            throw URLError(.networkConnectionLost)
        }
        return response
    }
}
private actor DeletionControlHeldApple: AppleSignInDriver {
    let inner: any AppleSignInDriver
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ inner: any AppleSignInDriver) { self.inner = inner }
    func authorize(nonceSHA256: String) async throws -> AppleAuthorization {
        entered = true
        await withCheckedContinuation { gate = $0 }
        return try await inner.authorize(nonceSHA256: nonceSHA256)
    }
    func release() { gate?.resume(); gate = nil }
}
private actor DeletionControlCompletion {
    var complete = false
    func finish() { complete = true }
}
actor DeletionControlHeldSigner: DeviceProofSigner {
    nonisolated let publicKey: String
    let inner: any DeviceProofSigner
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ inner: any DeviceProofSigner) { self.inner = inner; publicKey = inner.publicKey }
    func sign(_ bytes: Data) async throws -> Data { entered = true; await withCheckedContinuation { gate = $0 }; return try await inner.sign(bytes) }
    func release() { gate?.resume(); gate = nil }
}
actor DeletionControlScopeSource {
    var value: CloudScopeV1
    var hold = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ value: CloudScopeV1, hold: Bool = false) { self.value = value; self.hold = hold }
    func current() async -> CloudScopeV1 { if hold { entered = true; await withCheckedContinuation { gate = $0 } }; return value }
    func change(_ value: CloudScopeV1) { self.value = value }
    func release() { hold = false; gate?.resume(); gate = nil }
}
actor DeletionControlHeldSQL: DeletionControlAuthenticationCoordinator {
    let base: MatchSession
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ base: MatchSession) { self.base = base }
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await base.syncRepositoryIdentity() }
    func saveDeletionControlAttempt(_ attempt: DeletionControlAttemptV1) async throws { try await base.saveDeletionControlAttempt(attempt) }
    func acceptDeletionControlAuthorization(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, originalAcquire: Data?, expectedIdentityGeneration: Int64) async throws {
        try await base.acceptDeletionControlAuthorization(parentID: parentID, authorization: authorization, originalAcquire: originalAcquire, expectedIdentityGeneration: expectedIdentityGeneration)
        entered = true; await withCheckedContinuation { gate = $0 }
    }
    func resolveDeletionControlAttempt(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64) async throws { try await base.resolveDeletionControlAttempt(parentID: parentID, authorization: authorization, expectedIdentityGeneration: expectedIdentityGeneration) }
    func saveDeletionControlLockConfirmation(parentID: String, confirmation: DeletionControlLockConfirmationV1, expectedIdentityGeneration: Int64) async throws { try await base.saveDeletionControlLockConfirmation(parentID: parentID, confirmation: confirmation, expectedIdentityGeneration: expectedIdentityGeneration) }
    func acceptDeletionControlLiveLock(parentID: String, proof: VerifiedLiveLockV1, expectedIdentityGeneration: Int64) async throws { try await base.acceptDeletionControlLiveLock(parentID: parentID, proof: proof, expectedIdentityGeneration: expectedIdentityGeneration) }
    func acceptDeletionControlAbnormalResult(parentID: String, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws { try await base.acceptDeletionControlAbnormalResult(parentID: parentID, receipt: receipt, expectedIdentityGeneration: expectedIdentityGeneration) }
    func release() { gate?.resume(); gate = nil }
}
actor DeletionControlHeldVault: DeviceCredentialVault {
    let inner: any DeviceCredentialVault
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ inner: any DeviceCredentialVault) { self.inner = inner }
    func credential() async throws -> DeviceCredential { try await inner.credential() }
    func advanceIdentityFence(to generation: Int64) async throws { try await inner.advanceIdentityFence(to: generation) }
    func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) async throws {
        entered = true; await withCheckedContinuation { gate = $0 }
        try await inner.replace(credential, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    func release() { gate?.resume(); gate = nil }
}
final class DeletionControlAuthenticationTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let h: AuthenticationRecoveryTests.Harness
        let binding: AccountBindingV4
        let saga: DeletionSagaV4
        let scope: CloudScopeV1
        let relay: DeletionControlRelay
    }
    func fixture(_ f: NodeAuthorityFixture, pinned: Bool = false) async throws -> Fixture {
        let relay = DeletionControlRelay(try URLSessionAuthorityRelay(baseURL: URL(string: f.metadata.baseURL)!, environment: .development))
        let h = try await AuthenticationRecoveryTests().harness(f, relay: relay)
        let authentication = try await h.service.signIn(requestID: "control-original-login", challengeRequestID: "control-original-login-challenge")
        if pinned {
            var fields = AuthorityFields(); fields.matchID = "remote-held-match"; fields.recordingDeviceID = authentication.binding.deviceID; fields.activationEpoch = authentication.binding.activationEpoch
            _ = try await h.client.send(ControlIntentV1(requestID: "remote-original-acquire", operation: .acquire, fields: fields))
        }
        let scope = try CloudScopeV1(accountID: authentication.binding.accountID, cloudSpaceID: authentication.binding.cloudSpaceID, zoneID: "matches", activationEpoch: authentication.binding.activationEpoch)
        let capability = AuthorityWire.base64URL(Data(repeating: 29, count: 32))
        var fields = AuthorityFields(); fields.reauthenticationID = "original-expired-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
        let saga = try DeletionSagaV4(intent: ControlIntentV1(requestID: "control-original-delete", operation: .deleteAccount, fields: fields), accountID: scope.accountID, activationEpoch: scope.activationEpoch, recoveryCapability: capability, cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: scope)
        try await h.repo.createDeletionSagaV4(saga)
        try await h.session.retireBusiness()
        let stored = try await h.repo.accountBindingV4()
        return Fixture(h: h, binding: try XCTUnwrap(stored), saga: saga, scope: scope, relay: relay)
    }
    func service(_ x: Fixture, apple: (any AppleSignInDriver)? = nil) -> DeletionControlAuthenticationService {
        let scope = x.scope
        return DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: x.h.session, scope: scope, apple: apple ?? x.h.apple, currentScope: { scope })
    }
    func assertReady(_ outcome: DeletionControlOutcomeV1, lock: DeletionControlLockStateV1 = .none, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ready(let reauth, let state) = outcome else { return XCTFail("expected original-parent control ready", file: file, line: line) }
        XCTAssertNotNil(reauth, file: file, line: line); XCTAssertEqual(state, lock, file: file, line: line)
    }
    func testRetiredOriginalSessionFreshControlKeepsBindingGenerationAndBusinessFacts() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = service(x)
        let before = try await x.h.repo.identityGenerationV4()
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "control-auth", challengeRequestID: "control-challenge", expectedIdentityGeneration: before))
        let binding = try await x.h.repo.accountBindingV4(), generation = try await x.h.repo.identityGenerationV4(), matches = try await x.h.repo.matchIDs(), credential = try await x.h.vault.credential()
        XCTAssertEqual(binding, x.binding); XCTAssertEqual(generation, before); XCTAssertTrue(matches.isEmpty); XCTAssertTrue(credential.sessionID.hasPrefix("dc.")); XCTAssertEqual(credential.accountID, x.binding.accountID)
        do { _ = try await x.h.session.prepareStart(starter: true); XCTFail("control must never reopen business") } catch { XCTAssertEqual(error as? SessionError, .retired) }
        let saved = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "control-auth")
        XCTAssertEqual(saved?.authorization.body.parentDigest, x.saga.intent.digest)
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testCommittedAuthResponseLossRecoversOriginalAttemptWithoutSecondAppleOrIdentity() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = service(x)
        await x.relay.dropNextAuthentication()
        guard case .unresolved = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "control-lost-auth", challengeRequestID: "control-lost-challenge", expectedIdentityGeneration: 0) else { return XCTFail("lost response remains unknown") }
        await x.relay.failRecovery(404)
        guard case .unresolved = try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "control-lost-auth", expectedIdentityGeneration: 0) else { return XCTFail("404 cannot close original attempt") }
        do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "must-not-switch", challengeRequestID: "must-not-consume", expectedIdentityGeneration: 0); XCTFail("unknown attempt blocks another auth") } catch {}
        await x.relay.failRecovery(nil)
        assertReady(try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "control-lost-auth", expectedIdentityGeneration: 0))
        let paths = await x.relay.paths
        XCTAssertEqual(paths.filter { $0 == "/v1/accounts/delete/reauth/apple" }.count, 1)
        let attempts = try await x.h.repo.deletionControlAttemptsV4(parentID: x.saga.intent.requestID)
        XCTAssertEqual(attempts.map(\.authentication.requestID), ["control-lost-auth"])
        let rows = try XCTUnwrap(f.command(["op": "inspect", "sql": "SELECT auth_request_id FROM auth_records WHERE auth_request_id='control-lost-auth'"])["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testRemoteOriginalPinNeedsExplicitConfirmationAndNeverCreatesLocalMatch() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f, pinned: true), s = service(x)
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "control-pin-auth", challengeRequestID: "control-pin-challenge", expectedIdentityGeneration: 0), lock: .pinned)
        let live = try await s.lockStatus(parentID: x.saga.intent.requestID, expectedIdentityGeneration: 0)
        XCTAssertEqual(live.body.status, .held)
        let before = try XCTUnwrap(f.command(["op": "inspect", "sql": "SELECT * FROM active_locks"])["rows"] as? [[String: Any]])
        XCTAssertEqual(before.count, 1)
        let released = try await s.confirmAbnormal(parentID: x.saga.intent.requestID, confirmationID: "explicit-user-confirmation", requestID: "explicit-original-abnormal", confirmedAt: x.h.client.now(), expectedIdentityGeneration: 0)
        XCTAssertEqual(released.body.result, .releasedAbnormal); XCTAssertEqual(released.body.matchID, "remote-held-match")
        let replay = try await s.confirmAbnormal(parentID: x.saga.intent.requestID, confirmationID: "explicit-user-confirmation", requestID: "explicit-original-abnormal", confirmedAt: x.h.client.now(), expectedIdentityGeneration: 0)
        XCTAssertEqual(replay.raw, released.raw)
        do { _ = try await s.confirmAbnormal(parentID: x.saga.intent.requestID, confirmationID: "different-confirm", requestID: "different-abnormal", confirmedAt: x.h.client.now(), expectedIdentityGeneration: 0); XCTFail("first explicit parent intent is immutable") } catch {}
        let matches = try await x.h.repo.matchIDs(); XCTAssertTrue(matches.isEmpty)
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testFinalStopJoinsCancellationInsensitiveAppleAndNeverSendsLateAuth() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), apple = DeletionControlHeldApple(x.h.apple), s = service(x, apple: apple), done = DeletionControlCompletion()
        let operation = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "stopped-auth", challengeRequestID: "stopped-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await apple.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await apple.entered; XCTAssertTrue(entered)
        let stop = Task { await s.stopAndJoin(); await done.finish() }
        try await Task.sleep(for: .milliseconds(20))
        let early = await done.complete; XCTAssertFalse(early)
        await apple.release(); await stop.value
        do { _ = try await operation.value; XCTFail("late Apple result is fenced") } catch {}
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains("/v1/accounts/delete/reauth/apple"))
        do { _ = try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "stopped-auth", expectedIdentityGeneration: 0); XCTFail("stop is permanent") } catch {}
        let binding = try await x.h.repo.accountBindingV4(); XCTAssertEqual(binding, x.binding)
        try await x.h.repo.close()
    }
    func testLostReadyAcrossServerRestartAndTTLClosesOriginalThenFreshExplicitAttemptWorks() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), original = service(x)
        await x.relay.dropNextAuthentication()
        guard case .unresolved = try await original.renew(parentID: x.saga.intent.requestID, authRequestID: "ttl-lost-auth", challengeRequestID: "ttl-lost-challenge", expectedIdentityGeneration: 0) else { return XCTFail() }
        await original.stopAndJoin(); try await x.h.repo.close()
        let future = f.metadata.now + 301; _ = try f.command(["op": "clock", "now": future])
        let restarted = try f.command(["op": "restart"]), baseURL = try XCTUnwrap(restarted["baseURL"] as? String), date = Date(timeIntervalSince1970: Double(future))
        let repository = try SQLiteSessionRepository(rootDirectory: x.h.root, databaseNamespace: "auth-session", authorityTrust: x.h.client.trust, cloudSavePolicy: .development(databaseNamespace: "auth-session"))
        let session = MatchSession(store: repository, deviceIdentity: FixedIdentity(value: x.binding.deviceID), clock: FixedClock(date: date), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "auth-session"))
        try await session.retireBusiness()
        let client = AuthorityClient(relay: try URLSessionAuthorityRelay(baseURL: URL(string: baseURL)!, environment: .development), vault: x.h.vault, signer: x.h.signer, trust: x.h.client.trust, now: { date }), scope = x.scope
        let s = DeletionControlAuthenticationService(client: client, repository: repository, coordinator: session, scope: scope, apple: x.h.apple, currentScope: { scope })
        guard case .knownExpired = try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "ttl-lost-auth", expectedIdentityGeneration: 0) else { return XCTFail("trusted expiry closes lost ready without synthesizing ready") }
        let first = try await repository.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "ttl-lost-auth")
        XCTAssertEqual(first?.authorization.body.result, .knownExpired); XCTAssertNil(first?.resolution)
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "ttl-explicit-fresh", challengeRequestID: "ttl-explicit-challenge", expectedIdentityGeneration: 0))
        let binding = try await repository.accountBindingV4(), generation = try await repository.identityGenerationV4()
        XCTAssertEqual(binding, x.binding); XCTAssertEqual(generation, 0)
        await s.stopAndJoin(); try await repository.close()
    }
    func testUnsignedNotFoundIsUnknownButSignedAbandonmentAllowsOnlyExplicitFreshAttempt() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = service(x), before = try await x.h.vault.credential()
        await x.relay.dropAuthenticationBeforeDispatch()
        guard case .unresolved = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "uncommitted-control", challengeRequestID: "uncommitted-challenge", expectedIdentityGeneration: 0) else { return XCTFail() }
        guard case .knownAbandoned = try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "uncommitted-control", expectedIdentityGeneration: 0) else { return XCTFail("fixed-trust parent-bound proof required") }
        let credential = try await x.h.vault.credential(); XCTAssertEqual(credential.sessionID, before.sessionID)
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "explicit-after-abandoned", challengeRequestID: "explicit-challenge-after-abandoned", expectedIdentityGeneration: 0))
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testForeignIndependentScopeAndOtherFacadeRejectBeforeControlHTTP() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), wrong = try CloudScopeV1(accountID: x.scope.accountID, cloudSpaceID: "foreign-space", zoneID: x.scope.zoneID, activationEpoch: x.scope.activationEpoch)
        let s = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: x.h.session, scope: x.scope, apple: x.h.apple, currentScope: { wrong })
        do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "foreign-auth", challengeRequestID: "foreign-challenge", expectedIdentityGeneration: 0); XCTFail() } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
        let other = try await AuthenticationRecoveryTests().harness(f), scope = x.scope
        let mismatch = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: other.session, scope: scope, apple: x.h.apple, currentScope: { scope })
        do { _ = try await mismatch.renew(parentID: x.saga.intent.requestID, authRequestID: "other-facade-auth", challengeRequestID: "other-facade-challenge", expectedIdentityGeneration: 0); XCTFail() } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains { $0.contains("delete/reauth") })
        await s.stopAndJoin(); await mismatch.stopAndJoin(); try await other.repo.close(); try await x.h.repo.close()
    }
    func testFinalStopJoinsIndependentIdentitySourceBeforeAnyControlMutation() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), source = DeletionControlScopeSource(x.scope, hold: true), scope = x.scope, done = DeletionControlCompletion()
        let s = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: x.h.session, scope: scope, apple: x.h.apple, currentScope: { await source.current() })
        let call = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "source-held", challengeRequestID: "source-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await source.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await source.entered; XCTAssertTrue(entered)
        let stop = Task { await s.stopAndJoin(); await done.finish() }; try await Task.sleep(for: .milliseconds(20))
        let early = await done.complete; XCTAssertFalse(early)
        await source.release(); await stop.value
        do { _ = try await call.value; XCTFail() } catch {}
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains { $0.contains("delete/reauth") })
        try await x.h.repo.close()
    }
    func testCallerCancellationJoinsHeldOriginalSignerWithoutClosingBorrowedResources() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), signer = DeletionControlHeldSigner(x.h.signer), scope = x.scope, done = DeletionControlCompletion()
        let client = AuthorityClient(relay: x.relay, vault: x.h.vault, signer: signer, trust: x.h.client.trust, now: x.h.client.now)
        let s = DeletionControlAuthenticationService(client: client, repository: x.h.repo, coordinator: x.h.session, scope: scope, apple: x.h.apple, currentScope: { scope })
        let call = Task { do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "signer-held", challengeRequestID: "signer-challenge", expectedIdentityGeneration: 0); XCTFail() } catch {}; await done.finish() }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await signer.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await signer.entered; XCTAssertTrue(entered); call.cancel()
        try await Task.sleep(for: .milliseconds(20)); let early = await done.complete; XCTAssertFalse(early)
        await signer.release(); await call.value
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains { $0.contains("delete/reauth") })
        let generation = try await x.h.repo.identityGenerationV4(); XCTAssertEqual(generation, 0)
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testStopJoinsCommittedHTTPReplyAndOriginalAttemptCanRecoverOnSameFacade() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), held = GatedAuthResponseRelay(x.relay, path: "/v1/accounts/delete/reauth/apple"), scope = x.scope, done = DeletionControlCompletion()
        let client = AuthorityClient(relay: held, vault: x.h.vault, signer: x.h.signer, trust: x.h.client.trust, now: x.h.client.now)
        let s = DeletionControlAuthenticationService(client: client, repository: x.h.repo, coordinator: x.h.session, scope: scope, apple: x.h.apple, currentScope: { scope })
        let call = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "http-held-auth", challengeRequestID: "http-held-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await held.entered; XCTAssertTrue(entered)
        let stop = Task { await s.stopAndJoin(); await done.finish() }; try await Task.sleep(for: .milliseconds(20))
        let early = await done.complete; XCTAssertFalse(early)
        await held.release(); await stop.value; do { _ = try await call.value; XCTFail() } catch {}
        let saved = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "http-held-auth"); XCTAssertNil(saved)
        let next = service(x); assertReady(try await next.recover(parentID: x.saga.intent.requestID, authRequestID: "http-held-auth", expectedIdentityGeneration: 0))
        await next.stopAndJoin(); try await x.h.repo.close()
    }
    func testStopJoinsPositiveOriginalSQLBeforeClosingAndPreservesProofForRecovery() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), held = DeletionControlHeldSQL(x.h.session), scope = x.scope, done = DeletionControlCompletion(), oldCredential = try await x.h.vault.credential()
        let s = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: held, scope: scope, apple: x.h.apple, currentScope: { scope })
        let call = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "sql-held-auth", challengeRequestID: "sql-held-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await held.entered; XCTAssertTrue(entered)
        let proof = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "sql-held-auth"); XCTAssertNotNil(proof)
        let stop = Task { await s.stopAndJoin(); await done.finish() }; try await Task.sleep(for: .milliseconds(20)); let early = await done.complete; XCTAssertFalse(early)
        await held.release(); await stop.value; do { _ = try await call.value; XCTFail() } catch {}
        let credential = try await x.h.vault.credential(); XCTAssertEqual(credential.sessionID, oldCredential.sessionID)
        let next = service(x); assertReady(try await next.recover(parentID: x.saga.intent.requestID, authRequestID: "sql-held-auth", expectedIdentityGeneration: 0))
        let same = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "sql-held-auth"); XCTAssertEqual(same?.authorization.raw, proof?.authorization.raw)
        await next.stopAndJoin(); try await x.h.repo.close()
    }
    func testLateVaultWriteIsJoinedAndOriginalGenerationCASRejectsAfterIdentityFence() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), held = DeletionControlHeldVault(x.h.vault), scope = x.scope, done = DeletionControlCompletion()
        let client = AuthorityClient(relay: x.relay, vault: held, signer: x.h.signer, trust: x.h.client.trust, now: x.h.client.now)
        let s = DeletionControlAuthenticationService(client: client, repository: x.h.repo, coordinator: x.h.session, scope: scope, apple: x.h.apple, currentScope: { scope })
        let call = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "vault-held-auth", challengeRequestID: "vault-held-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await held.entered; XCTAssertTrue(entered)
        try await x.h.session.suspendAccount(); let generation = try await x.h.repo.identityGenerationV4(); try await x.h.vault.advanceIdentityFence(to: generation)
        let stop = Task { await s.stopAndJoin(); await done.finish() }; try await Task.sleep(for: .milliseconds(20)); let early = await done.complete; XCTAssertFalse(early)
        await held.release(); await stop.value; do { _ = try await call.value; XCTFail() } catch {}
        do { _ = try await x.h.vault.credential(); XCTFail("old-generation late credential cannot be installed") } catch {}
        let proof = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "vault-held-auth"); XCTAssertNotNil(proof)
        try await x.h.repo.close()
    }
    func testMutatedCredentialProofOrFutureReplyFieldCannotInstallVaultOrOverwriteOriginalAttempt() async throws {
        for mutation in ["credential", "purpose", "extra"] {
            let f = try NodeAuthorityFixture(); defer { f.close() }
            let x = try await fixture(f), s = service(x), before = try await x.h.vault.credential()
            await x.relay.alterAuthentication(mutation)
            do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "mutated-auth", challengeRequestID: "mutated-challenge", expectedIdentityGeneration: 0); XCTFail("untrusted reply rejected") } catch {}
            let credential = try await x.h.vault.credential(), saved = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "mutated-auth")
            XCTAssertEqual(credential.sessionID, before.sessionID); XCTAssertNil(saved)
            await x.relay.alterAuthentication(nil)
            assertReady(try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "mutated-auth", expectedIdentityGeneration: 0))
            await s.stopAndJoin(); try await x.h.repo.close()
        }
    }
    func testBackendDeletedRecoveryReturnsOriginalReceiptWithoutCredentialRefresh() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }; _ = try f.command(["op": "revoker"])
        let x = try await fixture(f), s = service(x)
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "completed-auth", challengeRequestID: "completed-challenge", expectedIdentityGeneration: 0))
        let credential = try await x.h.vault.credential(), raw = try await x.h.client.send(x.saga.intent)
        guard case .parentCompleted(let receipt) = try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "completed-auth", expectedIdentityGeneration: 0) else { return XCTFail("only original capability receipt is accepted") }
        XCTAssertEqual(receipt.raw, raw); XCTAssertEqual(receipt.body.requestDigest, x.saga.intent.digest)
        let after = try await x.h.vault.credential(); XCTAssertEqual(after.sessionID, credential.sessionID)
        _ = try await x.h.session.acceptDeletion(requestID: x.saga.intent.requestID, receipt: receipt, expectedRevision: 0)
        do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "after-completion", challengeRequestID: "after-completion-challenge", expectedIdentityGeneration: 0); XCTFail("completed parent cannot authenticate again") } catch {}
        await s.stopAndJoin(); try await x.h.repo.close()
    }

    func testTrustedClosingAfterPositiveSQLBlocksOriginalLateReadyBeforeVaultRefresh() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), held = DeletionControlHeldSQL(x.h.session), scope = x.scope, old = try await x.h.vault.credential()
        let first = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: held, scope: scope, apple: x.h.apple, currentScope: { scope })
        let call = Task { try await first.renew(parentID: x.saga.intent.requestID, authRequestID: "closing-race-auth", challengeRequestID: "closing-race-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await held.entered; XCTAssertTrue(entered)
        _ = try f.command(["op": "inspect", "sql": "UPDATE sessions SET revoked=1 WHERE session_id IN (SELECT session_id FROM auth_records WHERE auth_request_id='closing-race-auth') RETURNING revoked"])
        let closing = service(x)
        guard case .knownRevoked = try await closing.recover(parentID: x.saga.intent.requestID, authRequestID: "closing-race-auth", expectedIdentityGeneration: 0) else { return XCTFail("independently trusted closing must persist before delayed SQL callback") }
        await held.release()
        do { _ = try await call.value; XCTFail("previous positive SQL cannot authorize vault after current closing") } catch {}
        let credential = try await x.h.vault.credential(), history = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "closing-race-auth")
        XCTAssertEqual(credential.sessionID, old.sessionID); XCTAssertEqual(history?.authorization.body.result, .ready); XCTAssertEqual(history?.resolution?.body.result, .knownRevoked)
        await first.stopAndJoin(); await closing.stopAndJoin(); try await x.h.repo.close()
    }
    func testIndependentScopeChangedWhileCommittedHTTPIsHeldRejectsBeforeSQLAndVault() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), held = GatedAuthResponseRelay(x.relay, path: "/v1/accounts/delete/reauth/apple"), source = DeletionControlScopeSource(x.scope), old = try await x.h.vault.credential()
        let client = AuthorityClient(relay: held, vault: x.h.vault, signer: x.h.signer, trust: x.h.client.trust, now: x.h.client.now)
        let s = DeletionControlAuthenticationService(client: client, repository: x.h.repo, coordinator: x.h.session, scope: x.scope, apple: x.h.apple, currentScope: { await source.current() })
        let call = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "changed-scope-auth", challengeRequestID: "changed-scope-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await held.entered; XCTAssertTrue(entered)
        let foreign = try CloudScopeV1(accountID: x.scope.accountID, cloudSpaceID: x.scope.cloudSpaceID, zoneID: "foreign-zone", activationEpoch: x.scope.activationEpoch)
        await source.change(foreign); await held.release()
        do { _ = try await call.value; XCTFail("fresh independent identity required after HTTP") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
        let credential = try await x.h.vault.credential(), saved = try await x.h.repo.deletionControlAuthorizationV4(parentID: x.saga.intent.requestID, authRequestID: "changed-scope-auth")
        XCTAssertEqual(credential.sessionID, old.sessionID); XCTAssertNil(saved)
        await source.change(x.scope)
        assertReady(try await s.recover(parentID: x.saga.intent.requestID, authRequestID: "changed-scope-auth", expectedIdentityGeneration: 0))
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testPublicConcurrentRenewalsSerializeWholeSourceAppleSQLAndVaultOperation() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), apple = DeletionControlHeldApple(x.h.apple), s = service(x, apple: apple)
        let first = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "serial-first", challengeRequestID: "serial-first-challenge", expectedIdentityGeneration: 0) }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await apple.entered), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await apple.entered; XCTAssertTrue(entered)
        let second = Task { try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "serial-second", challengeRequestID: "serial-second-challenge", expectedIdentityGeneration: 0) }
        try await Task.sleep(for: .milliseconds(20))
        let before = await x.relay.paths; XCTAssertEqual(before.filter { $0 == "/v1/accounts/delete/reauth/challenges" }.count, 1)
        // Only the first authorization is held; release each original callback.
        await apple.release(); assertReady(try await first.value)
        let next = ContinuousClock.now.advanced(by: .seconds(3))
        while await apple.gate == nil, ContinuousClock.now < next { try await Task.sleep(for: .milliseconds(2)) }
        await apple.release(); assertReady(try await second.value)
        let attempts = try await x.h.repo.deletionControlAttemptsV4(parentID: x.saga.intent.requestID)
        XCTAssertEqual(attempts.map(\.authentication.requestID), ["serial-first", "serial-second"])
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testDefaultIndependentIdentitySourceNeverUsesConfigurationAsAuthentication() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = DeletionControlAuthenticationService(client: x.h.client, repository: x.h.repo, coordinator: x.h.session, scope: x.scope, apple: x.h.apple)
        do { _ = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "default-unavailable", challengeRequestID: "default-unavailable-challenge", expectedIdentityGeneration: 0); XCTFail() } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains { $0.contains("delete/reauth") })
        await s.stopAndJoin(); try await x.h.repo.close()
    }
    func testOriginalSQLiteNeverStoresAppleCodeIdentityTokenOrControlBearer() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = service(x)
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "private-control-auth", challengeRequestID: "private-control-challenge", expectedIdentityGeneration: 0))
        let token = await x.h.apple.lastToken, credential = try await x.h.vault.credential()
        await s.stopAndJoin(); try await x.h.repo.close()
        let secrets = [try XCTUnwrap(token), "client-transient-code-never-durable", credential.token]
        for file in FileManager.default.enumerator(at: x.h.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [] where !file.hasDirectoryPath {
            let bytes = try Data(contentsOf: file)
            for secret in secrets { XCTAssertNil(bytes.range(of: Data(secret.utf8)), "credential material must not enter business/control SQLite") }
        }
    }

    func testLostChallengeBeforeAnyAuthAttemptNeedsExplicitFreshIDsAndNeverClaimsAuthAbandonment() async throws {
        let f = try NodeAuthorityFixture(); defer { f.close() }
        let x = try await fixture(f), s = service(x)
        await x.relay.dropNextChallengeResponse()
        guard case .needsFreshAuthorization = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "challenge-lost-auth", challengeRequestID: "challenge-lost-id", expectedIdentityGeneration: 0) else { return XCTFail("a lost challenge does not create or close an authentication attempt") }
        let attempts = try await x.h.repo.deletionControlAttemptsV4(parentID: x.saga.intent.requestID)
        XCTAssertTrue(attempts.isEmpty)
        let paths = await x.relay.paths; XCTAssertFalse(paths.contains("/v1/accounts/delete/reauth/apple"))
        assertReady(try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "explicit-new-auth", challengeRequestID: "explicit-new-challenge", expectedIdentityGeneration: 0))
        let saved = try await x.h.repo.deletionControlAttemptsV4(parentID: x.saga.intent.requestID)
        XCTAssertEqual(saved.map(\.authentication.requestID), ["explicit-new-auth"])
        await s.stopAndJoin(); try await x.h.repo.close()
    }

    func testChallenge401404AndTimeoutNeverClaimFreshAuthorizationOrCloseAuthAttempt() async throws {
        for failure in ["401", "404", "timeout"] {
            let f = try NodeAuthorityFixture(); defer { f.close() }
            let x = try await fixture(f), s = service(x)
            await x.relay.failChallenge(failure)
            guard case .unresolved = try await s.renew(parentID: x.saga.intent.requestID, authRequestID: "unknown-challenge-auth", challengeRequestID: "unknown-challenge", expectedIdentityGeneration: 0) else { return XCTFail("401/404/timeout cannot reclassify authentication state") }
            let attempts = try await x.h.repo.deletionControlAttemptsV4(parentID: x.saga.intent.requestID), paths = await x.relay.paths
            XCTAssertTrue(attempts.isEmpty); XCTAssertFalse(paths.contains("/v1/accounts/delete/reauth/apple"))
            await s.stopAndJoin(); try await x.h.repo.close()
        }
    }

}
