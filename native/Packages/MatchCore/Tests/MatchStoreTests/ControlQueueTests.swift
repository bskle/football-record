import Foundation
import XCTest
import MatchCore
@testable import MatchStore
final class ControlQueueTests:XCTestCase,@unchecked Sendable {
    func testControlAttemptsRetryMetadataReopenAndFirstResultAlwaysWins() async throws {
        let (raw,trust,expected,_)=try AuthorityTransactionTests().vector(),url=TransactionTests().path(),now=TransactionTests().t,start=StartIntent(id:expected.requestID,matchID:"fixture-match-v1",recordingDeviceID:"fixture-watch-v1",requestedAt:now),intent=try ControlIntentV1.acquire(start,epoch:42)
        let s=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"queue"),authorityTrust:trust)
        try await s.bindAccountV4(AccountBindingV4(accountID:expected.accountID,cloudSpaceID:"cloud",deviceID:start.recordingDeviceID,activationEpoch:42,role:.watch,environment:.development));_=try await s.prepareControlV4(intent)
        try await s.beginControlAttemptV4(intent:intent,at:now);try await s.failControlAttemptV4(intent:intent,issue:.unavailable,retryable:true,at:now);try await s.close()
        let r=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"queue"),authorityTrust:trust),saved=try await r.controlQueueV4(),first=try XCTUnwrap(saved.first)
        XCTAssertEqual(first.intent,intent);XCTAssertEqual(first.attemptCount,1);XCTAssertEqual(first.state,.retryScheduled);XCTAssertNotNil(first.nextAttemptAt)
        _=try await r.recordAuthorityResultV4(VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust))
        try await r.failControlAttemptV4(intent:intent,issue:.unknown,retryable:true,at:now)
        let completed=try await r.controlQueueV4(),pending=try await r.pendingControlsV4();XCTAssertEqual(completed.first?.state,.confirmed);XCTAssertTrue(pending.isEmpty)
        try await r.close()
    }
    func testAttemptTransactionFaultsReopenWithoutPartialMetadata() async throws {
        for fault in [StoreFault.beforeCommit,.afterCommit] {
            let (raw,trust,expected,_)=try AuthorityTransactionTests().vector(),url=TransactionTests().path(),now=TransactionTests().t,start=StartIntent(id:expected.requestID,matchID:"fixture-match-v1",recordingDeviceID:"fixture-watch-v1",requestedAt:now),intent=try ControlIntentV1.acquire(start,epoch:42)
            let seed=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"queue"),authorityTrust:trust)
            try await seed.bindAccountV4(AccountBindingV4(accountID:expected.accountID,cloudSpaceID:"cloud",deviceID:start.recordingDeviceID,activationEpoch:42,role:.watch,environment:.development));_=try await seed.prepareControlV4(intent);try await seed.close()
            let failing=try MatchStore(url:url,fault:fault,syncEnvironment:.development(databaseNamespace:"queue"),authorityTrust:trust)
            do {try await failing.beginControlAttemptV4(intent:intent,at:now);XCTFail()}catch{}
            try await failing.close();let reopened=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"queue"),authorityTrust:trust),entries=try await reopened.controlQueueV4();XCTAssertEqual(entries.first?.attemptCount,fault == .afterCommit ? 1:0)
            _=try await reopened.recordAuthorityResultV4(VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust));try await reopened.close()
        }
    }

}
