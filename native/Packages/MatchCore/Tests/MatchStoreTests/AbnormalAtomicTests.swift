import Foundation
import XCTest
import MatchCore
@testable import MatchStore
final class AbnormalAtomicTests:XCTestCase,@unchecked Sendable {
    func testAllLocalTerminationFaultsPreserveControlAndBusinessAtomicityAcrossReopen() async throws {
        let h=TransactionTests(),(raw,trust,expected,_)=try AuthorityTransactionTests().vector()
        for fault in [StoreFault.afterEvents,.afterCaptureOperations,.afterOutbox,.afterReceipt,.beforeCommit,.afterCommit] {
            let url=h.path(),start=StartIntent(id:expected.requestID,matchID:"fixture-match-v1",recordingDeviceID:"fixture-watch-v1",requestedAt:h.t)
            let plain=MatchDescriptor(startIntent:start,starter:true),descriptor=MatchDescriptor(startIntent:start,starter:true,startPermit:DevelopmentStartFixture.permit(for:start),backendLockState:.held)
            let acquire=try ControlIntentV1.acquire(start,epoch:42),seed=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"atomic"),authorityTrust:trust)
            try await seed.bindAccountV4(AccountBindingV4(accountID:expected.accountID,cloudSpaceID:"fixture-cloud",deviceID:"phone",activationEpoch:42,role:.phone,environment:.development))
            _=try await seed.commit(StoreCommit(commandID:"seed",expectedGeneration:0,descriptor:plain,events:[],packets:[]))
            _=try await seed.prepareControlV4(acquire);_=try await seed.recordAuthorityResultV4(VerifiedAuthorityReceiptV1.verify(raw,expected:expected,trust:trust))
            var recorder=LiveMatchRecorder(descriptor:descriptor);try recorder.start(eventID:"start",sourceDeviceID:start.recordingDeviceID,now:h.t)
            let startDelta=try BusinessDeltaV2(descriptor:descriptor,events:recorder.events,captureRevisions:[]),startOutbox=try BusinessOutboxItem(id:"start-outbox",matchID:start.matchID,sourceDeviceID:start.recordingDeviceID,payload:startDelta)
            _=try await seed.commitV2(StoreCommitV2(commandID:"start-business",expectedGeneration:1,descriptor:descriptor,events:recorder.events,captureRevisions:[],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[startOutbox]));try await seed.close()
            let event=try PostMatchEditor.terminateAbnormally(terminationID:"abnormal",descriptor:descriptor,events:recorder.events,sourceDeviceID:"phone",now:h.t.addingTimeInterval(1))
            let payload=try BusinessDeltaV2(descriptor:descriptor,events:[event],captureRevisions:[]),outbox=try BusinessOutboxItem(id:"abnormal-outbox",matchID:start.matchID,sourceDeviceID:"phone",payload:payload)
            let request=try StoreCommitV2(commandID:"abnormal",expectedGeneration:2,descriptor:descriptor,events:[event],captureRevisions:[],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[outbox])
            var fields=AuthorityFields();fields.matchID=start.matchID;fields.lockID="fixture-lock-v1";fields.recordingDeviceID=start.recordingDeviceID;fields.activationEpoch=42;fields.mode="abnormal"
            let intent=try ControlIntentV1(requestID:"abnormal",operation:.terminate,fields:fields),failing=try MatchStore(url:url,fault:fault,syncEnvironment:.development(databaseNamespace:"atomic"),authorityTrust:trust)
            do {_=try await failing.prepareAbnormalTerminationV4(intent:intent,request:request);XCTFail()}catch{}
            try await failing.close()
            let restored=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"atomic"),authorityTrust:trust)
            let snapshot=try await restored.snapshotV2(matchID:start.matchID),pending=try await restored.pendingControlsV4(),command=try await restored.committedCommandV2(commandID:"abnormal"),outboxes=try await restored.pendingBusinessOutbox(matchID:start.matchID)
            XCTAssertEqual(snapshot.business.events.contains(where:{$0.type == .matchTerminated}),fault == .afterCommit)
            XCTAssertEqual(pending.count,fault == .afterCommit ? 1:0);XCTAssertEqual(command != nil,fault == .afterCommit);XCTAssertEqual(outboxes.filter {$0.id=="abnormal-outbox"}.count,fault == .afterCommit ? 1:0)
            _=try await restored.prepareAbnormalTerminationV4(intent:intent,request:request)
            _=try await restored.prepareAbnormalTerminationV4(intent:intent,request:request)
            let final=try await restored.snapshotV2(matchID:start.matchID);XCTAssertEqual(final.business.events.filter {$0.type == .matchTerminated}.count,1);try await restored.close()
        }
    }
}
