import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore

final class CurrentWatchRegistrationEvidenceTests: XCTestCase, @unchecked Sendable {
    let h = LifecycleStateTests()
    struct Fixture {
        let context: LifecycleStateTests.Context
        let deviceKey: Curve25519.Signing.PrivateKey
        let attempt: WatchRegistrationAttemptV4
        let binding: AccountBindingV4
        let receipt: VerifiedAuthorityReceiptV1
        let store: MatchStore
    }
    func attempt(_ c: LifecycleStateTests.Context, key: Curve25519.Signing.PrivateKey, requestID: String = "watch-original", context supplied: WatchRegistrationContextV4? = nil) throws -> WatchRegistrationAttemptV4 {
        let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation), hash = String(repeating: "a", count: 64)
        let context = try supplied ?? WatchRegistrationContextV4(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, phoneID: c.binding.deviceID, activationEpoch: 1, environment: .development)
        let signing: [String: Any] = ["version": 1, "requestID": requestID, "watchID": "watch", "watchPublicKey": publicKey, "challengeID": "challenge", "challengeSHA256": hash]
        let bytes = try JSONSerialization.data(withJSONObject: signing, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: bytes))
        return try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: requestID, watchID: "watch", watchPublicKey: publicKey, challengeID: "challenge", deviceProof: AuthorityWire.base64URL(signature)), challengeRequestID: "watch-challenge", challengeSHA256: hash)
    }
    func signed(_ c: LifecycleStateTests.Context, attempt: WatchRegistrationAttemptV4, result: AuthorityResult = .registered, extra: [String: Any] = [:]) throws -> VerifiedAuthorityReceiptV1 {
        var fields: [String: Any] = ["registration": ["watchID": attempt.payload.watchID, "watchPublicKey": attempt.payload.watchPublicKey]]
        fields.merge(extra, uniquingKeysWith: { $1 })
        return try h.receipt(c, requestID: attempt.requestID, digest: attempt.requestDigest, operation: .registerWatch, result: result, extra: fields)
    }
    func fixture(accept: Bool = true) async throws -> Fixture {
        let c = try h.context(), key = Curve25519.Signing.PrivateKey(), a = try attempt(c, key: key)
        let b = try AccountBindingV4(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, deviceID: "watch", activationEpoch: 1, role: .watch, environment: .development)
        let receipt = try signed(c, attempt: a), s = try h.store(c)
        _ = try await s.admitWatchRegistrationContextV4(a.context, deviceID: "watch", publicKey: a.payload.watchPublicKey)
        try await s.saveWatchRegistrationAttemptV4(a, expectedIdentityGeneration: 0)
        if accept { try await s.acceptWatchRegistrationV4(a, receipt: receipt, watchBinding: b, expectedIdentityGeneration: 0) }
        return Fixture(context: c, deviceKey: key, attempt: a, binding: b, receipt: receipt, store: s)
    }
    func marker(_ url: URL) throws -> Data? {
        let db = try SQLite(url: url, fault: nil)
        defer { try? db.close() }
        return try db.rows("SELECT payload FROM lifecycle_steps_v4 WHERE id='watch-current-v1'").first?[0].data
    }
    func testFirstWatchBindingAcceptancePersistsMarkerAtomically() async throws {
        let f = try await fixture()
        try await f.store.close()
        XCTAssertNotNil(try marker(f.context.url), "the original binding acceptance transaction must persist its provenance")
        let reopened = try h.store(f.context)
        let binding = try await reopened.accountBindingV4(), raw = try await reopened.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
        XCTAssertEqual(binding, f.binding); XCTAssertEqual(raw, f.receipt.raw)
        try await reopened.close()
    }
    func testMarkerCommitFaultsReopenAtomicallyAndReplayDoesNotRewrite() async throws {
        for fault in [StoreFault.beforeCommit, .afterReceipt, .afterCommit] {
            let f = try await fixture(accept: false); try await f.store.close()
            let failing = try h.store(f.context, fault: fault)
            do { try await failing.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0); XCTFail("expected original transaction fault") } catch {}
            try await failing.close()
            let reopened = try h.store(f.context)
            let binding = try await reopened.accountBindingV4(), raw = try await reopened.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
            let before = try marker(f.context.url)
            XCTAssertEqual(before != nil, fault == .afterCommit); XCTAssertEqual(binding != nil, fault == .afterCommit); XCTAssertEqual(raw != nil, fault == .afterCommit)
            try await reopened.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
            let accepted = try marker(f.context.url); XCTAssertNotNil(accepted)
            try await reopened.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
            XCTAssertEqual(try marker(f.context.url), accepted)
            if let before { XCTAssertEqual(before, accepted) }
            try await reopened.close()
        }
    }
}
