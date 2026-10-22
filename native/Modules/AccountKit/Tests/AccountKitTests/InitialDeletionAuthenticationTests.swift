import Foundation
import CryptoKit
import XCTest
import MatchCore
@testable import MatchStore
@testable import MatchSession
@testable import AccountKit

final class InitialDeletionAuthenticationTests: XCTestCase, @unchecked Sendable {
    private func rejected(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("must reject stale or conflicting initial authority", file: file, line: line) } catch { }
    }
    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline { if await predicate() { return }; await Task.yield() }
        XCTFail("gate was not reached", file: file, line: line)
    }
    private func associated(_ outcome: InitialDeletionAuthenticationOutcomeV1, file: StaticString = #filePath, line: UInt = #line) -> InitialDeletionAssociationV1? {
        guard case .associated(let value) = outcome else { XCTFail("expected association", file: file, line: line); return nil }; return value
    }
    func testDedicatedWireAndOrdinaryIsolation() async throws {
        // A01: this fixture actually starts empty, signs in with nil reauth, and recovers through AccountService.
        let f = try await InitialLeafFixture(), normal = try await f.normal(), vault = try await f.vault.credential()
        let writes = await f.vault.writes(), result = try await f.authenticate()
        XCTAssertEqual(associated(result)?.authRequestID, "fresh-auth")
        XCTAssertEqual(associated(result)?.opaqueReauthenticationID, "opaque-fresh-auth")
        let after = try await f.normal(), afterVault = try await f.vault.credential(), afterWrites = await f.vault.writes()
        XCTAssertEqual(after, normal); XCTAssertEqual(afterVault, vault); XCTAssertEqual(afterWrites, writes)
        let counts = await f.counts()
        await rejected { _ = try await f.ordinary.signIn(requestID: "ordinary-new", challengeRequestID: "ordinary-challenge") }
        await rejected { _ = try await f.ordinary.recover(authRequestID: "original-auth") }
        let blocked = await f.counts(); XCTAssertEqual(blocked, counts)
        try await f.close()
        // A02: ordinary operations already past their preflight cannot mutate after the purpose commits.
        for status in ["knownExpired", "knownRevoked", "success"] {
            let x = try await InitialLeafFixture(); await x.relay.setRecoverStatus(status == "success" ? nil : status)
            await x.relay.recoverGate.arm()
            let late = Task { try await x.ordinary.recover(authRequestID: "original-auth") }
            await eventually { await x.relay.recoverGate.entered > 0 }
            _ = try await x.session.prepareInitialDeletionAuthentication(request: x.request, expectedSource: x.source,
                authRequestID: "fresh-auth", challengeRequestID: "fresh-challenge")
            let baseline = try await x.normal(), v = try await x.vault.credential(), w = await x.vault.writes()
            await x.relay.recoverGate.release(); await rejected { _ = try await late.value }
            let n = try await x.normal(), v2 = try await x.vault.credential(), w2 = await x.vault.writes()
            XCTAssertEqual(n, baseline); XCTAssertEqual(v2, v); XCTAssertEqual(w2, w); try await x.close()
        }
        // A06: nil is a real, valid signed-auth result, but cannot authorize reservation.
        let nilID = try await InitialLeafFixture(); await nilID.relay.setMutation("nil")
        let nilOutcome = try await nilID.authenticate(); XCTAssertNil(associated(nilOutcome)?.opaqueReauthenticationID)
        await rejected { _ = try await nilID.service.reserve(creationID: "delete", expectedIdentityGeneration: 0) }
        try await nilID.close()
        // A07: each response is independently constructed and signed before the selected corruption.
        for kind in ["extra", "receipt", "context-extra", "claims-extra", "account", "key", "epoch", "credential", "waiting", "oversize"] {
            let x = try await InitialLeafFixture(); let n = try await x.normal(), v = try await x.vault.credential(), w = await x.vault.writes()
            await x.relay.setMutation(kind); await rejected { _ = try await x.authenticate() }
            let c = try await x.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            XCTAssertNil(c?.association)
            let n2 = try await x.normal(), v2 = try await x.vault.credential(), w2 = await x.vault.writes()
            XCTAssertEqual(n2, n); XCTAssertEqual(v2, v); XCTAssertEqual(w2, w); try await x.close()
        }
    }
    func testUnknownRecoveryAndPreparedFailure() async throws {
        // A03/A04: lost committed reply, same persisted ID recovery; no second fresh authentication.
        let f = try await InitialLeafFixture(); await f.relay.setLoss(true)
        guard case .unresolved = try await f.authenticate() else { return XCTFail("lost reply must stay unresolved") }
        let normal = try await f.normal(), v = try await f.vault.credential(), writes = await f.vault.writes()
        await rejected { _ = try await f.authenticate(id: "second", challenge: "second-challenge") }
        for mode in ["401", "404", "timeout", "knownNotFound"] {
            await f.relay.setRecoverStatus(mode)
            guard case .unresolved = try await f.service.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0) else { return XCTFail("unknown cannot close") }
            let c = try await f.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            XCTAssertNil(c?.attempts.first?.resolution)
        }
        await f.relay.setRecoverStatus(nil)
        let recovered = try await f.service.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0); XCTAssertNotNil(associated(recovered))
        let paths = await f.relay.counts(); XCTAssertEqual(paths[1], 2) // one ordinary + exactly one fresh POST
        let n2 = try await f.normal(), v2 = try await f.vault.credential(), w2 = await f.vault.writes()
        XCTAssertEqual(n2, normal); XCTAssertEqual(v2, v); XCTAssertEqual(w2, writes); try await f.close()
        // A05: only exact single closing statuses write dedicated resolution facts.
        for status in ["knownAbandoned", "knownExpired", "knownRevoked", "bad-status"] {
            let x = try await InitialLeafFixture(); await x.relay.setLoss(true); _ = try await x.authenticate()
            let n = try await x.normal(), v = try await x.vault.credential(), w = await x.vault.writes()
            await x.relay.setRecoverStatus(status)
            if status == "bad-status" { await rejected { _ = try await x.service.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0) } }
            else {
                let outcome = try await x.service.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0)
                guard case .closed(let resolution) = outcome else { return XCTFail("must persist dedicated closure") }
                XCTAssertEqual(resolution.rawValue, status)
            }
            let n2 = try await x.normal(), v2 = try await x.vault.credential(), w2 = await x.vault.writes()
            XCTAssertEqual(n2, n); XCTAssertEqual(v2, v); XCTAssertEqual(w2, w); try await x.close()
        }
        // A08: challenge timeout has no sent attempt. Explicit expiry consumes only the prepared CAS.
        for mode in ["timeout", "expired", "consumed"] {
            let x = try await InitialLeafFixture(); await x.relay.setChallengeStatus(mode)
            let outcome = try await x.authenticate(), c = try await x.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            XCTAssertNil(c?.attempts.first?.authentication)
            if mode == "timeout" { guard case .unresolved = outcome else { return XCTFail("timeout remains prepared") }; XCTAssertNil(c?.attempts.first?.resolution) }
            else {
                guard case .closed(.notDispatched) = outcome else { return XCTFail("known challenge closure") }
                let old = try AuthAttemptV4(requestID: "fresh-auth", deviceID: "phone", publicKey: x.signer.publicKey,
                    cloudSpaceID: "cloud", challengeID: "server-fresh-challenge", requestDigest: String(repeating: "f", count: 64), environment: .development)
                await rejected { try await x.session.saveInitialDeletionAttempt(creationID: "delete", authentication: old, expectedIdentityGeneration: 0) }
            }
            try await x.close()
        }
    }
    func testOperationDedupCancellationAndJoin() async throws {
        // A09: both callers have the full same input, one actual Apple worker and POST.
        let f = try await InitialLeafFixture(); await f.apple.gate.arm()
        let a = Task { try await f.authenticate() }; await eventually { await f.apple.gate.entered > 0 }
        let b = Task { try await f.authenticate() }
        await rejected { _ = try await f.authenticate(id: "different", challenge: "different-challenge") }
        await f.apple.gate.release(); let av = try await a.value, bv = try await b.value; XCTAssertNotNil(associated(av)); XCTAssertNotNil(associated(bv))
        let counts = await f.counts(); XCTAssertEqual(counts[1], 2); XCTAssertEqual(counts[3], 2) // ordinary + fresh
        try await f.close()
        // A10/A11: a cancellation-insensitive relay owns its real completion and all joined return tails.
        let x = try await InitialLeafFixture(); await x.relay.authGate.arm()
        let completion = InitialLeafCompletion(), worker = Task { defer { Task { await completion.mark("worker") } }; return try await x.authenticate() }
        await eventually { await x.relay.authGate.entered > 0 }
        worker.cancel(); await Task.yield(); let premature = await completion.contains("worker"); XCTAssertFalse(premature)
        let stop = Task { try await x.service.stopAndJoin(); await completion.mark("stop") }
        await Task.yield(); let earlyStop = await completion.contains("stop"); XCTAssertFalse(earlyStop)
        await x.relay.authGate.release(); await rejected { _ = try await worker.value }; try await stop.value
        let c = try await x.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertNotNil(c?.attempts.first?.authentication); XCTAssertNil(c?.attempts.first?.resolution)
        let count = await x.counts(); await rejected { _ = try await x.authenticate() }; let count2 = await x.counts(); XCTAssertEqual(count2, count)
        // Another service on the same original owner recovers only that sent ID; it never re-posts.
        let resumed = x.newService(); let resumedOutcome = try await resumed.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0); XCTAssertNotNil(associated(resumedOutcome))
        try await resumed.stopAndJoin(); try await x.base.close()
        // A11 independently holds both caller return tails after the single worker has committed and ended.
        let tails = try await InitialLeafFixture(); await tails.apple.gate.arm(); await tails.reads.holdAssociated(after: 1)
        let done = InitialLeafCompletion()
        let one = Task { do { let r = try await tails.authenticate(); await done.mark("one"); return r } catch { await done.mark("one"); throw error } }
        await eventually { await tails.apple.gate.entered > 0 }
        let baselineReads = await tails.reads.total
        let two = Task { do { let r = try await tails.authenticate(); await done.mark("two"); return r } catch { await done.mark("two"); throw error } }
        await eventually { await tails.reads.total > baselineReads }
        await tails.apple.gate.release()
        await eventually { await tails.reads.tailGate.entered == 2 }
        let stopTails = Task { try await tails.service.stopAndJoin(); await done.mark("stop") }
        // A conflicting call observes stopped synchronously only after stop has entered the service actor.
        await eventually {
            do { _ = try await tails.authenticate(id: "stop-probe", challenge: "stop-probe-challenge"); return false }
            catch { return error as? InitialDeletionIssueV1 == .stopped }
        }
        let earlyOne = await done.contains("one"), earlyTwo = await done.contains("two"), earlyDrain = await done.contains("stop")
        XCTAssertFalse(earlyOne); XCTAssertFalse(earlyTwo); XCTAssertFalse(earlyDrain)
        await tails.reads.tailGate.release()
        await rejected { _ = try await one.value }; await rejected { _ = try await two.value }; try await stopTails.value
        try await tails.close()
        // A12: TaskLocal protection includes source observation and relay callbacks, then external stop joins.
        for location in ["source", "relay"] {
            let y = try await InitialLeafFixture(), result = InitialLeafCompletion()
            let callback: @Sendable () async throws -> Void = {
                do { try await y.service.stopAndJoin(); XCTFail("recursive stop must throw") }
                catch { XCTAssertEqual(error as? InitialDeletionIssueV1, .recursiveStop); await result.mark("recursive") }
            }
            if location == "source" { await y.scope.setCallback(callback) } else { await y.relay.setCallback(callback) }
            _ = try await y.authenticate(); let did = await result.contains("recursive"); XCTAssertTrue(did)
            await y.scope.setCallback(nil); await y.relay.setCallback(nil); try await y.close()
        }
    }
    func testReentryAndReservedVeto() async throws {
        // A13: independent observations change while actual Apple work is suspended.
        for kind in ["scope", "vault", "generation", "stop"] {
            let f = try await InitialLeafFixture(); await f.apple.gate.arm()
            let worker = Task { try await f.authenticate() }; await eventually { await f.apple.gate.entered > 0 }
            var stopper: Task<Void, Error>?
            switch kind {
            case "scope": await f.scope.change(try CloudScopeV1(accountID: "other", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 1))
            case "vault": await f.vault.force(DeviceCredential(token: "changed", sessionID: "changed", accountID: "account", deviceID: "phone", keyID: f.source.attempt.keyID, activationEpoch: 1, expiresAt: 9999))
            case "generation": try await f.changeGeneration()
            default: stopper = Task { try await f.service.stopAndJoin() }
            }
            await f.apple.gate.release(); await rejected { _ = try await worker.value }; if let stopper { try await stopper.value }
            try await f.close()
        }
        // A14: read reserved D through the original retired facade; never call mutation reserve again.
        let f = try await InitialLeafFixture(); _ = try await f.authenticate()
        let d = try await f.service.reserve(creationID: "delete", expectedIdentityGeneration: 0)
        try await f.session.retireBusiness(); let calls = await f.coordinator.reserves, counts = await f.counts(), normal = try await f.normal()
        let again = try await f.service.reserve(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(try InitialLeafFixture.descriptor(d), try InitialLeafFixture.descriptor(again))
        let calls2 = await f.coordinator.reserves, counts2 = await f.counts(), n2 = try await f.normal()
        XCTAssertEqual(calls2, calls); XCTAssertEqual(counts2, counts); XCTAssertEqual(n2, normal)
        await rejected { _ = try await f.authenticate() }
        await rejected { _ = try await f.service.recover(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0) }
        let counts3 = await f.counts(); XCTAssertEqual(counts3, counts)
        try await f.base.createDeletionSagaV4(f.saga(d))
        await rejected { _ = try await f.service.reserve(creationID: "delete", expectedIdentityGeneration: 0) }; try await f.close()
        // The reserved service's last SQL read remains a live source check, after external observations.
        for kind in ["generation", "stop", "close"] {
            let x = try await InitialLeafFixture(); _ = try await x.authenticate(); _ = try await x.service.reserve(creationID: "delete", expectedIdentityGeneration: 0)
            await x.reads.holdBeforeRead(3)
            let read = Task { try await x.service.reserve(creationID: "delete", expectedIdentityGeneration: 0) }
            await eventually { await x.reads.beforeGate.entered > 0 }
            var stop: Task<Void, Error>?
            if kind == "generation" { try await x.changeGeneration() }
            if kind == "stop" { stop = Task { try await x.service.stopAndJoin() } }
            if kind == "close" { try await x.base.close() }
            await x.reads.beforeGate.release(); await rejected { _ = try await read.value }
            if let stop { try await stop.value }
            if kind != "close" { try await x.close() } else { try await x.service.stopAndJoin() }
        }
        let associatedOnly = try await InitialLeafFixture(); _ = try await associatedOnly.authenticate(); try await associatedOnly.session.retireBusiness()
        await rejected { _ = try await associatedOnly.service.reserve(creationID: "delete", expectedIdentityGeneration: 0) }; try await associatedOnly.close()
        for kind in ["source", "stop", "close"] {
            let x = try await InitialLeafFixture(); _ = try await x.authenticate(); _ = try await x.service.reserve(creationID: "delete", expectedIdentityGeneration: 0)
            if kind == "source" { try await x.changeGeneration() }
            if kind == "stop" { try await x.service.stopAndJoin() }
            if kind == "close" { try await x.base.close() }
            await rejected { _ = try await x.service.reserve(creationID: "delete", expectedIdentityGeneration: 0) }
            if kind != "close" { try await x.close() } else { try await x.service.stopAndJoin() }
        }
    }
    func testSecretDisposalAndSourceFreshSeparation() async throws {
        // A15/A16: inspect the actual DB and WAL, not just Codable declarations.
        let f = try await InitialLeafFixture(); _ = try await f.authenticate()
        let d = try await f.service.reserve(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(d.request, f.request); XCTAssertEqual(d.originalAuthRequestID, "original-auth")
        XCTAssertEqual(d.originalAuthReceiptDigest, AuthorityWire.hash(f.source.receipt.raw)); XCTAssertEqual(d.identityGeneration, 0)
        XCTAssertEqual(d.initialAuthRequestID, "fresh-auth"); XCTAssertNotEqual(d.initialAuthRequestID, d.originalAuthRequestID)
        let c = try await f.base.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(d.initialAuthRequestDigest, c?.association?.requestDigest)
        XCTAssertEqual(d.initialAuthReceiptDigest, c.map { AuthorityWire.hash($0.association!.receipt.raw) })
        let raw = try await f.relay.cachedAuthRequest("fresh-auth")
        let secrets = [Data("leaf-apple-identity-token".utf8), Data("leaf-apple-authorization-code".utf8), Data("new-session-secret-fresh-auth".utf8), raw]
        try assertNoSecrets(root: f.root, secrets: secrets)
        let sessions = await f.relay.minted; XCTAssertEqual(sessions, 2) // server did mint the extra session; no revocation claim.
        try await f.close()
    }
    private func assertNoSecrets(root: URL, secrets: [Data]) throws {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where ["sqlite", "db"].contains(url.pathExtension) || url.lastPathComponent.hasSuffix("-wal") {
            let bytes = try Data(contentsOf: url)
            for secret in secrets { XCTAssertNil(bytes.range(of: secret), "transient secret persisted in \(url.lastPathComponent)") }
        }
    }

}

private actor InitialLeafGate {
    private var held = false
    private(set) var entered = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func arm() { held = true; entered = 0 }
    func hit() async { entered += 1; if held { await withCheckedContinuation { waiting.append($0) } } }
    func release() { held = false; let all = waiting; waiting = []; all.forEach { $0.resume() } }
}
private actor InitialLeafCompletion {
    private var labels = Set<String>()
    func mark(_ value: String) { labels.insert(value) }
    func contains(_ value: String) -> Bool { labels.contains(value) }
}
private actor InitialLeafSigner: DeviceProofSigner {
    nonisolated let publicKey: String
    private let key: Curve25519.Signing.PrivateKey
    private(set) var calls = 0
    init() throws { key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)); publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation) }
    func sign(_ bytes: Data) throws -> Data { calls += 1; return try key.signature(for: bytes) }
}
private actor InitialLeafApple: AppleSignInDriver {
    let gate = InitialLeafGate(); private(set) var calls = 0
    func authorize(nonceSHA256: String) async throws -> AppleAuthorization {
        calls += 1; await gate.hit(); return AppleAuthorization(identityToken: "leaf-apple-identity-token", authorizationCode: "leaf-apple-authorization-code")
    }
}
private actor InitialLeafVault: DeviceCredentialVault {
    private var current: DeviceCredential?, generation: Int64 = 0, replaces = 0, fences = 0
    func credential() throws -> DeviceCredential { guard let current else { throw AuthorityError.unavailable }; return current }
    func advanceIdentityFence(to value: Int64) throws { guard value >= generation else { throw AuthorityError.identityChanged }; fences += 1; if value > generation { current = nil }; generation = value }
    func replace(_ value: DeviceCredential?, expectedIdentityGeneration: Int64) throws { guard generation == expectedIdentityGeneration else { throw AuthorityError.identityChanged }; replaces += 1; current = value }
    func writes() -> [Int] { [replaces, fences] }
    func force(_ value: DeviceCredential) { current = value }
}
private actor InitialLeafScope {
    private var value: CloudScopeV1
    private var callback: (@Sendable () async throws -> Void)?
    init(_ value: CloudScopeV1) { self.value = value }
    func observe() async throws -> CloudScopeV1 { try await callback?(); return value }
    func change(_ value: CloudScopeV1) { self.value = value }
    func setCallback(_ value: (@Sendable () async throws -> Void)?) { callback = value }
}
private actor InitialLeafRelay: AuthorityHTTPRelay {
    let authGate = InitialLeafGate(), recoverGate = InitialLeafGate()
    let key: Curve25519.Signing.PrivateKey
    private let devicePublicKey: String
    private var mutation = "", loss = false, recoverStatus: String?, challengeStatus: String?
    private var replies: [String: Data] = [:], authRequests: [String: Data] = [:]
    private var challenges: [String: String] = [:], pathCounts = [0, 0, 0]
    private var callback: (@Sendable () async throws -> Void)?
    private(set) var minted = 0
    init(key: Curve25519.Signing.PrivateKey, publicKey: String) { self.key = key; devicePublicKey = publicKey }
    func setMutation(_ value: String) { mutation = value }
    func setLoss(_ value: Bool) { loss = value }
    func setRecoverStatus(_ value: String?) { recoverStatus = value }
    func setChallengeStatus(_ value: String?) { challengeStatus = value }
    func setCallback(_ value: (@Sendable () async throws -> Void)?) { callback = value }
    func counts() -> [Int] { pathCounts }
    func cachedAuthRequest(_ id: String) throws -> Data { try XCTUnwrap(authRequests[id]) }
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
        try await callback?()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let canonical = try bytes(value); XCTAssertEqual(canonical, request.body); XCTAssertNil(request.authorization)
        let id = try XCTUnwrap(value["requestID"] as? String)
        switch request.path {
        case "/v1/auth/challenges":
            pathCounts[0] += 1
            if challengeStatus == "timeout" { throw URLError(.timedOut) }
            let challenge = "server-" + id; challenges[challenge] = "challenge-secret-" + id
            var reply: [String: Any] = ["version": 1, "requestID": id, "challengeID": challenge, "expiresAt": 1100]
            if let challengeStatus { reply["status"] = challengeStatus } else { reply["challenge"] = challenges[challenge] }
            return AuthorityHTTPResponse(status: 200, body: try bytes(reply))
        case "/v1/auth/apple":
            pathCounts[1] += 1; authRequests[id] = request.body
            let challenge = try XCTUnwrap(value["challengeID"] as? String), secret = try XCTUnwrap(challenges[challenge])
            let signature = try AuthorityWire.decodeBase64URL(XCTUnwrap(value.removeValue(forKey: "deviceProof") as? String), count: 64)
            value["challengeSHA256"] = AuthorityWire.hash(Data(secret.utf8))
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(devicePublicKey, count: 32))
            let signatureValid = publicKey.isValidSignature(signature, for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: try bytes(value))); XCTAssertTrue(signatureValid)
            let reply: Data
            if let prior = replies[id] { reply = prior } else { reply = try makeReply(id, digest: AuthorityWire.hash(request.body)); replies[id] = reply; minted += 1 }
            await authGate.hit()
            if loss { loss = false; throw URLError(.networkConnectionLost) }
            return AuthorityHTTPResponse(status: 200, body: reply)
        case "/v1/auth/recover":
            pathCounts[2] += 1
            let proof = try AuthorityWire.decodeBase64URL(XCTUnwrap(value.removeValue(forKey: "deviceProof") as? String), count: 64)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(devicePublicKey, count: 32))
            let signatureValid = publicKey.isValidSignature(proof, for: AuthorityWire.signedInput("football-record.device.auth-recover.v1", body: try bytes(value))); XCTAssertTrue(signatureValid)
            await recoverGate.hit()
            if let status = recoverStatus {
                if status == "timeout" { throw URLError(.timedOut) }
                if ["401", "404"].contains(status) { return AuthorityHTTPResponse(status: Int(status)!, body: try bytes(["code": status == "401" ? "unauthorized" : "notFound", "requestID": id, "retryable": false])) }
                return AuthorityHTTPResponse(status: 200, body: try bytes(status == "bad-status" ? ["status": "knownExpired", "extra": true] : ["status": status]))
            }
            return AuthorityHTTPResponse(status: 200, body: try XCTUnwrap(replies[value["authRequestID"] as? String ?? ""]))
        default: throw AuthorityError.invalidWire
        }
    }
    private func makeReply(_ id: String, digest: String) throws -> Data {
        let keyID = try AuthorityWire.deviceKeyID(publicKey: devicePublicKey)
        var body: [String: Any] = ["version": 1, "environment": "development", "keyID": "test", "receiptID": "receipt-" + id,
            "requestID": id, "requestDigest": digest, "operation": "authApple", "accountID": "account", "activationEpoch": 1,
            "matchID": "", "lockID": "", "recordingDeviceID": "", "result": mutation == "waiting" ? "waitingMigration" : "registered", "issuedAt": 1000]
        var credential: [String: Any] = ["token": id == "original-auth" ? "original-session-secret" : "new-session-secret-" + id, "sessionID": "session-" + id,
            "accountID": "account", "deviceID": "phone", "keyID": keyID, "activationEpoch": 1, "expiresAt": 9999]
        var context: [String: Any] = ["accountID": "account", "deviceID": "phone", "keyID": keyID, "activationEpoch": 1]
        var claims: [String: Any] = ["sessionID": "session-" + id, "expiresAt": 9999]
        if mutation == "receipt" { body["requestDigest"] = String(repeating: "0", count: 64) }
        if mutation == "account" { credential["accountID"] = "other"; context["accountID"] = "other" }
        if mutation == "epoch" { credential["activationEpoch"] = 2; context["activationEpoch"] = 2 }
        if mutation == "key" { credential["keyID"] = "other"; context["keyID"] = "other" }
        if mutation == "credential" { credential["expiresAt"] = 1 }
        if mutation == "context-extra" { context["extra"] = true }
        if mutation == "claims-extra" { claims["extra"] = true }
        let signed: [String: Any] = ["body": body, "signature": AuthorityWire.base64URL(try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes(body))))]
        var reply: [String: Any] = ["receipt": signed, "sessionClaims": claims, "credential": credential, "context": context]
        if id != "original-auth", mutation != "nil" { reply["reauthenticationID"] = "opaque-" + id }
        if mutation == "extra" { reply["extra"] = true }
        if mutation == "oversize" { reply["reauthenticationID"] = String(repeating: "a", count: 70_000) }
        return try bytes(reply)
    }
}
private actor InitialLeafCoordinator: InitialDeletionAuthenticationCoordinatorV1 {
    let session: MatchSession
    private(set) var reserves = 0
    init(_ session: MatchSession) { self.session = session }
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await session.syncRepositoryIdentity() }
    func prepareInitialDeletionAuthentication(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1 { try await session.prepareInitialDeletionAuthentication(request: request, expectedSource: expectedSource, authRequestID: authRequestID, challengeRequestID: challengeRequestID) }
    func saveInitialDeletionAttempt(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws { try await session.saveInitialDeletionAttempt(creationID: creationID, authentication: authentication, expectedIdentityGeneration: expectedIdentityGeneration) }
    func acceptInitialDeletionAuthentication(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws { try await session.acceptInitialDeletionAuthentication(creationID: creationID, authRequestID: authRequestID, receipt: receipt, opaqueReauthenticationID: opaqueReauthenticationID, expectedIdentityGeneration: expectedIdentityGeneration) }
    func closePreparedInitialDeletionAttempt(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws { try await session.closePreparedInitialDeletionAttempt(creationID: creationID, authRequestID: authRequestID, expectedIdentityGeneration: expectedIdentityGeneration) }
    func resolveInitialDeletionAttempt(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws { try await session.resolveInitialDeletionAttempt(creationID: creationID, authRequestID: authRequestID, resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration) }
    func reserveInitialDeletion(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 { reserves += 1; return try await session.reserveInitialDeletion(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration) }
}
/// Gates the original SQL reply or entry; never fabricates evidence or a repository identity.
private actor InitialLeafReadRepository: InitialDeletionAuthenticationRepositoryV1, CurrentAuthenticationEvidenceReadingV4 {
    let base: SQLiteSessionRepository
    let tailGate = InitialLeafGate(), beforeGate = InitialLeafGate()
    private(set) var total = 0
    private var associated = 0, allowedAssociated: Int?, beforeOrdinal: Int?, ordinal = 0
    init(_ base: SQLiteSessionRepository) { self.base = base }
    func holdAssociated(after count: Int) async { associated = 0; allowedAssociated = count; await tailGate.arm() }
    func holdBeforeRead(_ count: Int) async { ordinal = 0; beforeOrdinal = count; await beforeGate.arm() }
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await base.syncRepositoryIdentity() }
    func currentAuthenticationEvidenceV4(expectedIdentityGeneration: Int64) async throws -> VerifiedLocalAuthenticationEvidenceV4? { try await base.currentAuthenticationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration) }
    func initialDeletionContextV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionContextV1? {
        total += 1; ordinal += 1
        if beforeOrdinal == ordinal { await beforeGate.hit() }
        let result = try await base.initialDeletionContextV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration)
        if result?.phase == .associated { associated += 1; if let allowedAssociated, associated > allowedAssociated { await tailGate.hit() } }
        return result
    }
    func prepareInitialDeletionAuthenticationV4(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1 { try await base.prepareInitialDeletionAuthenticationV4(request: request, expectedSource: expectedSource, authRequestID: authRequestID, challengeRequestID: challengeRequestID) }
    func saveInitialDeletionAttemptV4(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws { try await base.saveInitialDeletionAttemptV4(creationID: creationID, authentication: authentication, expectedIdentityGeneration: expectedIdentityGeneration) }
    func acceptInitialDeletionAuthenticationV4(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws { try await base.acceptInitialDeletionAuthenticationV4(creationID: creationID, authRequestID: authRequestID, receipt: receipt, opaqueReauthenticationID: opaqueReauthenticationID, expectedIdentityGeneration: expectedIdentityGeneration) }
    func closePreparedInitialDeletionAttemptV4(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws { try await base.closePreparedInitialDeletionAttemptV4(creationID: creationID, authRequestID: String(authRequestID), expectedIdentityGeneration: expectedIdentityGeneration) }
    func resolveInitialDeletionAttemptV4(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws { try await base.resolveInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration) }
    func reserveInitialDeletionV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 { try await base.reserveInitialDeletionV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration) }
}
private struct InitialLeafFixture: Sendable {
    let root: URL, base: SQLiteSessionRepository, reads: InitialLeafReadRepository, session: MatchSession, coordinator: InitialLeafCoordinator
    let signer: InitialLeafSigner, apple: InitialLeafApple, vault: InitialLeafVault, relay: InitialLeafRelay, scope: InitialLeafScope
    let source: VerifiedLocalAuthenticationEvidenceV4, request: InitialDeletionRequestV1, ordinary: AccountService
    let client: AuthorityClient, service: InitialDeletionAuthenticationService
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("initial-leaf-" + UUID().uuidString)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 11, count: 32))
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["test": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        signer = try InitialLeafSigner(); apple = InitialLeafApple(); vault = InitialLeafVault(); relay = InitialLeafRelay(key: key, publicKey: signer.publicKey)
        base = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "initial-leaf", authorityTrust: trust)
        session = MatchSession(store: base, deviceIdentity: FixedIdentity(value: "phone"), clock: FixedClock(date: Date(timeIntervalSince1970: 1000)), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "initial-leaf"))
        coordinator = InitialLeafCoordinator(session); reads = InitialLeafReadRepository(base)
        client = AuthorityClient(relay: relay, vault: vault, signer: signer, trust: trust, now: { Date(timeIntervalSince1970: 1000) }, nonce: { UUID().uuidString })
        ordinary = AccountService(client: client, repository: base, coordinator: session, deviceID: "phone", cloudSpaceID: "cloud", apple: apple)
        let empty = try await base.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0); XCTAssertNil(empty)
        try await ordinary.admitCurrentIdentity()
        let first = try await ordinary.signIn(requestID: "original-auth", challengeRequestID: "original-challenge"); XCTAssertNil(first.reauthenticationID)
        guard case .authenticated(let recovered) = try await ordinary.recover(authRequestID: "original-auth") else { throw AuthorityError.unavailable }
        XCTAssertNil(recovered.reauthenticationID)
        let current = try await base.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0); source = try XCTUnwrap(current)
        let fixedScope = try CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 1)
        request = try InitialDeletionRequestV1(creationID: "delete", originalScope: fixedScope, cloud: .keep, local: .delete, health: .keep, healthConfirmed: false, confirmedAt: 1000)
        scope = InitialLeafScope(fixedScope); let observed = scope
        service = InitialDeletionAuthenticationService(client: client, repository: reads, coordinator: coordinator, apple: apple, currentScope: { try await observed.observe() })
    }
    func newService() -> InitialDeletionAuthenticationService { let observed = scope; return InitialDeletionAuthenticationService(client: client, repository: reads, coordinator: coordinator, apple: apple, currentScope: { try await observed.observe() }) }
    func authenticate(id: String = "fresh-auth", challenge: String = "fresh-challenge") async throws -> InitialDeletionAuthenticationOutcomeV1 { try await service.authenticate(request: request, expectedSource: source, authRequestID: id, challengeRequestID: challenge) }
    func changeGeneration() async throws { let store = await base.store; try await store.initialLeafChangeGeneration() }
    func normal() async throws -> Data { let store = await base.store; return try await store.initialLeafNormalState() }
    func counts() async -> [Int] { let http = await relay.counts(), apple = await apple.calls, signatures = await signer.calls, writes = await vault.writes(); return http + [apple, signatures] + writes }
    func close() async throws { try await service.stopAndJoin(); try await base.close() }
    static func descriptor(_ d: InitialDeletionReservationV1) throws -> Data { try AuthorityWire.encode([AuthorityWire.encode(d.request).base64EncodedString(), String(d.identityGeneration), d.originalAuthRequestID, d.originalAuthReceiptDigest, d.initialAuthRequestID, d.initialAuthRequestDigest, d.initialAuthReceiptDigest, d.opaqueReauthenticationID]) }
    func saga(_ d: InitialDeletionReservationV1) throws -> DeletionSagaV4 {
        let cap = AuthorityWire.base64URL(Data(repeating: 1, count: 32)); var fields = AuthorityFields(); fields.reauthenticationID = d.opaqueReauthenticationID; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(cap.utf8))
        return try DeletionSagaV4(intent: ControlIntentV1(requestID: d.request.creationID, operation: .deleteAccount, fields: fields), accountID: "account", activationEpoch: 1, recoveryCapability: cap, cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: d.request.originalScope)
    }
}
private extension MatchStore {
    func initialLeafChangeGeneration() throws { _ = try db.transaction { try advanceIdentityGenerationLockedV4() } }
    func initialLeafNormalState() throws -> Data {
        var rows = try db.rows("SELECT quote(id),quote(payload),quote(checksum) FROM lifecycle_steps_v4 WHERE substr(CAST(id AS BLOB),1,19) != CAST('initial-delete-auth' AS BLOB) ORDER BY id").map { $0.map { $0.string! } }
        rows += try db.rows("SELECT quote(id),quote(payload),quote(checksum) FROM account_binding_v4 ORDER BY id").map { $0.map { $0.string! } }
        return try Canonical.data(rows)
    }
}
