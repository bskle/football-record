import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore

final class AuthorityTransactionTests: XCTestCase, @unchecked Sendable {
    func vector() throws -> (Data, AuthorityTrustConfiguration, AuthorityExpectedIntent, Data) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try Data(contentsOf: source.appendingPathComponent("backend/test/fixtures/receipt-v1.json"))
        let f = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let receipt = try JSONSerialization.data(withJSONObject: f["receipt"]!, options: [.sortedKeys,.withoutEscapingSlashes])
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: [f["keyID"] as! String:f["publicKey"] as! String])
        let intent = StartIntent(id:"fixture-acquire-v1",matchID:"fixture-match-v1",recordingDeviceID:"fixture-watch-v1",requestedAt:Date(timeIntervalSince1970:1800000000))
        let request = try ControlIntentV1.acquire(intent, epoch:42)
        XCTAssertEqual(String(decoding: request.canonicalRequest, as: UTF8.self), f["canonicalIntent"] as? String)
        return (receipt,trust,AuthorityExpectedIntent(request,accountID:"fixture-account-v1",epoch:42),Data(base64Encoded:f["signingBytesUTF8Base64"] as! String)!)
    }
    func testNodePublicVectorVerifiesExactIntentAndBytes() throws {
        let (raw,trust,expected,signing) = try vector()
        let verified = try VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust)
        XCTAssertEqual(AuthorityWire.signedInput("football-record.authority.receipt.v1",body:try AuthorityWire.encode(verified.body)),signing)
        XCTAssertEqual(verified.body.lockID,"fixture-lock-v1")
    }

    func testControlAndFirstSignedResultPersistThroughReopenAndRejectNewTrust() async throws {
        let (raw,trust,expected,_) = try vector(), url=TransactionTests().path()
        let binding=try AccountBindingV4(accountID:expected.accountID,cloudSpaceID:"fixture-cloud",deviceID:"fixture-watch-v1",activationEpoch:42,role:.watch,environment:.development)
        let start=StartIntent(id:expected.requestID,matchID:"fixture-match-v1",recordingDeviceID:binding.deviceID,requestedAt:Date(timeIntervalSince1970:1800000000))
        let intent=try ControlIntentV1.acquire(start,epoch:42)
        let store=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"authority-test"),authorityTrust:trust)
        try await store.bindAccountV4(binding)
        let prepared=try await store.prepareControlV4(intent); XCTAssertEqual(prepared.digest,intent.digest)
        let pending=try await store.pendingControlsV4(); XCTAssertEqual(pending,[intent])
        let verified=try VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust)
        let first=try await store.recordAuthorityResultV4(verified)
        let duplicate=try await store.recordAuthorityResultV4(verified); XCTAssertEqual(duplicate,first)
        try await store.close()
        let reopened=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"authority-test"),authorityTrust:trust)
        let after=try await reopened.pendingControlsV4(); XCTAssertTrue(after.isEmpty)
        let state=try await reopened.authorityStateV4(matchID:start.matchID,now:start.requestedAt)
        XCTAssertEqual(state.acquire?.raw,raw); XCTAssertEqual(state.status,.held)
        do { try await reopened.validateAuthorityStartV4(start,now:start.requestedAt); XCTFail("receipt alone must not start") } catch {}
        try await reopened.suspendAccountV4()
        do { _ = try await reopened.prepareControlV4(try ControlIntentV1.acquire(StartIntent(id:"other",matchID:"other",recordingDeviceID:binding.deviceID,requestedAt:start.requestedAt),epoch:42)); XCTFail() } catch {}
        try await reopened.close()
    }
    func testSignedResultSQLFaultsRollbackOrReplayFirstResultAfterCOMMIT() async throws {
        for fault in [StoreFault.beforeCommit,.afterReceipt,.afterCommit] {
            let (raw,trust,expected,_)=try vector(),url=TransactionTests().path()
            let binding=try AccountBindingV4(accountID:expected.accountID,cloudSpaceID:"fixture-cloud",deviceID:"fixture-watch-v1",activationEpoch:42,role:.watch,environment:.development)
            let intent=try ControlIntentV1.acquire(StartIntent(id:expected.requestID,matchID:"fixture-match-v1",recordingDeviceID:binding.deviceID,requestedAt:Date(timeIntervalSince1970:1800000000)),epoch:42)
            let seed=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"authority-test"),authorityTrust:trust)
            try await seed.bindAccountV4(binding);_=try await seed.prepareControlV4(intent);try await seed.close()
            let failing=try MatchStore(url:url,fault:fault,syncEnvironment:.development(databaseNamespace:"authority-test"),authorityTrust:trust)
            let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust)
            do { _=try await failing.recordAuthorityResultV4(receipt);XCTFail() } catch {}
            try await failing.close()
            let reopened=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"authority-test"),authorityTrust:trust)
            let pending=try await reopened.pendingControlsV4();XCTAssertEqual(pending.count,fault == .afterCommit ? 0 : 1)
            let result=try await reopened.recordAuthorityResultV4(receipt);XCTAssertEqual(result.rawDigest,AuthorityWire.hash(raw));try await reopened.close()
        }
    }
    func testUntrustedExtremeLiveTimeRejectsWithoutArithmeticTrap() throws {
        let (_,trust,_,_)=try vector()
        let q=try LiveLockQueryV1(requestID:"q",acquireRequestID:"a",matchID:"m",lockID:"l",recordingDeviceID:"watch",activationEpoch:42,nonce:"nonce")
        let body:[String:Any]=["version":1,"requestID":q.requestID,"acquireRequestID":q.acquireRequestID,"matchID":q.matchID,"lockID":q.lockID,"recordingDeviceID":q.recordingDeviceID,"activationEpoch":q.activationEpoch,"nonce":q.nonce,"accountID":"fixture-account-v1","receiptID":"receipt","environment":"development","keyID":"fixture-ed25519-v1","requestDigest":AuthorityWire.hash(try AuthorityWire.encode(q)),"status":"held","observedAt":Int64(-1),"expiresAt":Int64.max]
        let raw=try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(Data(repeating:0,count:64))],options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertThrowsError(try VerifiedLiveLockV1.verify(raw,query:q,accountID:"fixture-account-v1",trust:trust,now:Date(timeIntervalSince1970:-1)))
    }
    func testTamperWrongKeyEnvironmentIntentAndDERFailClosed() throws {
        let (raw,trust,expected,_) = try vector()
        var changed=raw; changed[changed.count-4] ^= 1
        XCTAssertThrowsError(try VerifiedAuthorityReceiptV1.verify(changed,expected:expected,trust:trust))
        let wrong=try AuthorityTrustConfiguration(environment:.production,publicKeys:trust.publicKeys)
        XCTAssertThrowsError(try VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:wrong))
        let intent=AuthorityExpectedIntent(requestID:expected.requestID,digest:String(repeating:"0",count:64),operation:.acquire,accountID:expected.accountID,epoch:42)
        XCTAssertThrowsError(try VerifiedAuthorityReceiptV1.verify(raw,expected:intent,trust:trust))
        XCTAssertThrowsError(try AuthorityTrustConfiguration(environment:.development,publicKeys:["der":AuthorityWire.base64URL(Data(repeating:0,count:44))]))
    }
}
