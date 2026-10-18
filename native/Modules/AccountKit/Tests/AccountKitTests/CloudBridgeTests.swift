import Foundation
import XCTest
import CryptoKit
import MatchCore
import MatchStore
import MatchSession
import CloudSync
@testable import AccountKit

actor ReadbackCloudDriver:CloudDriver {
    let records:[CloudRecord]
    init(records:[CloudRecord]=[]){self.records=records}
    func fetch(scope:CloudScope,cursor:CloudCursor) async throws->CloudFetchBatch {try CloudFetchBatch(scope:scope,batchID:"real-bridge-batch",records:records,expectedAppliedToken:cursor.appliedToken,nextToken:Data([0,255,4]),fetchGeneration:cursor.fetchGeneration,moreComing:false)}
    func save(_ upload:CloudUpload) async throws->CloudSaveResult {
        let bytes=upload.record.canonicalBytes
        let ref=try CloudAssetReference(partID:"part-"+upload.record.recordID,index:0,byteCount:bytes.count,digest:AuthorityWire.hash(bytes))
        let manifest=try CloudSaveManifest(upload:upload,parts:[ref])
        return .complete(CloudSaveReadback(scope:upload.scope,recordID:upload.record.recordID,manifestRecordID:upload.checkpointID,manifestBytes:try AuthorityWire.encode(manifest),manifestChangeTag:"manifest-tag",manifestCondition:.ifServerRecordUnchanged,parts:[CloudSavedPart(reference:ref,changeTag:"part-tag",condition:.ifServerRecordUnchanged,readBackBytes:bytes)],confirmationID:"confirm-"+upload.record.recordID,recordChangeTag:"record-tag",recordCondition:.ifServerRecordUnchanged))
    }
}
final class CloudBridgeTests:XCTestCase,@unchecked Sendable {
    func scope(_ f:NodeAuthorityFixture)throws->CloudScope {try CloudScope(accountID:f.metadata.credential.accountID,cloudSpaceID:"fixture-cloud",zoneID:"matches",activationEpoch:f.metadata.credential.activationEpoch)}
    func testRealSessionFactsCanonicalMatchesCloudLedgerAndSaveDoesNotCompleteAlone() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:true);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let end=try await h.session.prepare(.end,matchID:start.matchID);_=try await h.session.execute(end);try await waitForCapture(h.repo,matchID:start.matchID)
        let bridge=CloudSessionBridge(repository:h.repo,client:h.client,policy:.development(databaseNamespace:"http-session"));try await bridge.attach(h.session)
        let scope=try scope(f),upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope)
        guard case .matchFacts(let facts)=try upload.record.payload else {return XCTFail()}
        let core=try CloudFactSetV1(startIntent:facts.startIntent,starter:facts.starter,events:facts.events,captureRevisions:facts.captureRevisions)
        XCTAssertEqual(try core.factDigest,try facts.factDigest);XCTAssertEqual(try core.captureDigest,try facts.captureDigest)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("cloud-transport.sqlite"));try await ledger.enqueue(upload)
        let service=CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(),sink:bridge,clock:{h.date})
        let outcome=try await service.synchronize();XCTAssertNil(outcome.issue)
        let evidence=try await ledger.saveEvidence(scope:scope);XCTAssertEqual(evidence.count,1)
        _=try await bridge.acceptDevelopmentSave(upload:upload,evidence:evidence[0],ledger:ledger)
        let snapshot=try await h.repo.snapshotV2(matchID:start.matchID);XCTAssertEqual(try snapshot.business.replay(now:h.date).state,.endedPendingSync)
        let proof=try await h.repo.matchingCloudSaveV4(matchID:start.matchID);XCTAssertNotNil(proof)
        try await ledger.close()
    }
    func testTransportImportsThroughSameFacadeAndDifferentFacadeIsRejected() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:false);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let bridge=CloudSessionBridge(repository:h.repo,client:h.client);try await bridge.attach(h.session)
        let scope=try scope(f),upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("cloud-transport.sqlite")),service=CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(records:[upload.record]),sink:bridge,clock:{h.date})
        let outcome=try await service.synchronize();XCTAssertNil(outcome.issue);XCTAssertEqual(outcome.importedBatchIDs,["real-bridge-batch"])
        let cursor=try await bridge.appliedCursor(scope:scope);XCTAssertEqual(cursor.appliedToken,Data([0,255,4]))
        let reset=try await bridge.resetCursor(scope:scope,expectedGeneration:0);XCTAssertEqual(reset.fetchGeneration,1)
        let other=try await HTTPAuthorityIntegrationTests().harness(f)
        do {try await bridge.attach(other.session);XCTFail()}catch{}
        try await ledger.close()
    }
    func saveCurrent(_ h:HTTPAuthorityIntegrationTests.Harness,match:String) async throws {
        let bridge=CloudSessionBridge(repository:h.repo,client:h.client,policy:.development(databaseNamespace:"http-session"));try await bridge.attach(h.session)
        let scope=try scope(h.fixture),upload=try await bridge.prepareUpload(matchID:match,scope:scope)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent(UUID().uuidString+".sqlite"));try await ledger.enqueue(upload)
        let service=CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(),sink:bridge,clock:{h.date})
        let result=try await service.synchronize();XCTAssertNil(result.issue)
        let evidence=try await ledger.saveEvidence(scope:scope);_=try await bridge.acceptDevelopmentSave(upload:upload,evidence:evidence[0],ledger:ledger);try await ledger.close()
    }
    func testNormalDoubleProofCOMMITLostResponseThenNextStartAndOldTerminationReplay() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let first=try await h.session.prepareStart(starter:true);_=try await h.session.execute(first);try await waitForCapture(h.repo,matchID:first.matchID)
        let end=try await h.session.prepare(.end,matchID:first.matchID);_=try await h.session.execute(end);try await waitForCapture(h.repo,matchID:first.matchID)
        try await saveCurrent(h,match:first.matchID)
        let service=AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session)
        _=try f.command(["op":"fault","value":"terminate"])
        do {_=try await service.normal(matchID:first.matchID,requestID:"normal-release");XCTFail()}catch{}
        let before=try await h.repo.snapshotV2(matchID:first.matchID);XCTAssertEqual(try before.business.replay(now:h.date).state,.endedPendingSync)
        let pending=try await h.repo.pendingControlsV4();let intent=try XCTUnwrap(pending.first(where:{$0.requestID=="normal-release"}))
        _=try f.command(["op":"fault","value":NSNull()]);try await h.repo.close()
        let reopened=try await HTTPAuthorityIntegrationTests().harness(f,root:h.root,gateway:TrackingGateway()),retry=AuthorityControlService(client:reopened.client,repository:reopened.repo,coordinator:reopened.session)
        let original=try await retry.reconcile(intent)
        let completed=try await reopened.repo.snapshotV2(matchID:first.matchID);XCTAssertEqual(try completed.business.replay(now:h.date).state,.completed)
        let next=try await reopened.session.prepareStart(starter:false);_=try await reopened.session.execute(next)
        let replay=try await retry.reconcile(intent);XCTAssertEqual(replay.raw,original.raw)
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT match_id FROM active_locks"])["rows"] as? [[String:Any]])
        XCTAssertEqual(rows.first?["match_id"] as? String,next.matchID)
    }
    func testSignedTerminalWithoutReleaseReceiptPermitsNextAndReopenedOrdinaryCommandsCannotContinueOldMatch() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let first=try await h.session.prepareStart(starter:true);_=try await h.session.execute(first);try await waitForCapture(h.repo,matchID:first.matchID)
        let ordinary=try await h.session.prepare(.quick(.teamGoal),matchID:first.matchID)
        try await HTTPAuthorityIntegrationTests().terminateOnServer(h,request:first);try await waitForCapture(h.repo,matchID:first.matchID);try await h.repo.close()
        let reopened=try await HTTPAuthorityIntegrationTests().harness(f,root:h.root,gateway:TrackingGateway())
        do {_=try await reopened.session.execute(ordinary);XCTFail()}catch{}
        let state=try await reopened.repo.authorityStateV4(matchID:first.matchID,now:h.date);XCTAssertEqual(state.status,.terminal);XCTAssertNil(state.verifiedNormalRelease)
        let next=try await reopened.session.prepareStart(starter:false);_=try await reopened.session.execute(next)
        let old=try await reopened.repo.snapshotV2(matchID:first.matchID);XCTAssertNotEqual(try old.business.replay(now:h.date).state,.completed)
    }

    func testFirstImportReceiptReplaysAfterPersistentAccountSuspension() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:false);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let bridge=CloudSessionBridge(repository:h.repo,client:h.client);try await bridge.attach(h.session)
        let scope=try scope(f),upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope),batch=try CloudFetchBatch(scope:scope,batchID:"first-receipt",records:[upload.record],expectedAppliedToken:nil,nextToken:Data([1]),fetchGeneration:0,moreComing:false)
        let first=try await bridge.importBatch(batch);try await h.repo.suspendAccountV4()
        let replay=try await bridge.importBatch(batch);XCTAssertEqual(first,replay)
        let newBatch=try CloudFetchBatch(scope:scope,batchID:"must-stop",records:[],expectedAppliedToken:Data([1]),nextToken:Data([2]),fetchGeneration:0,moreComing:false)
        do {_=try await bridge.importBatch(newBatch);XCTFail()}catch{}
    }

    func testOriginalWatchNormalSignatureTravelsThroughOpaquePhoneRelay() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let watch=try f.command(["op":"watch"]),credential=try JSONDecoder().decode(DeviceCredential.self,from:JSONSerialization.data(withJSONObject:watch["credential"]!)),key=try XCTUnwrap(watch["privateKey"] as? String)
        let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway(),credential:credential,privateKey:key,role:.watch)
        let start=try await h.session.prepareStart(starter:true);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let end=try await h.session.prepare(.end,matchID:start.matchID);_=try await h.session.execute(end);try await waitForCapture(h.repo,matchID:start.matchID)
        try await saveCurrent(h,match:start.matchID)
        let intent=try await h.session.prepareNormalTermination(matchID:start.matchID,requestID:"watch-normal")
        do {_=try await f.client().send(intent);XCTFail("active phone PoP cannot normally release Watch lock")}catch{}
        let signed=try await h.client.signedRequest(path:intent.operation.path,body:intent.canonicalRequest,requestID:intent.requestID)
        let phoneRelay=try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development)
        let response=try await phoneRelay.send(signed);XCTAssertEqual(response.status,200)
        let verified=try VerifiedAuthorityReceiptV1.verify(response.body,expected:AuthorityExpectedIntent(intent,accountID:credential.accountID,epoch:credential.activationEpoch),trust:h.client.trust)
        _=try await h.session.acceptAuthorityResult(verified)
        let replay=try await phoneRelay.send(signed);XCTAssertEqual(replay.status,401)
        let original=try await h.client.query(requestID:intent.requestID);XCTAssertEqual(original,verified.raw)
        let snapshot=try await h.repo.snapshotV2(matchID:start.matchID);XCTAssertEqual(try snapshot.business.replay(now:h.date).state,.completed)
    }

    func testOriginalReceiptAlreadyTerminalRestoresOnlyHistoryAndTombstoneNeverRevivesIt() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let original=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await original.session.prepareStart(starter:true);_=try await original.session.execute(start);try await waitForCapture(original.repo,matchID:start.matchID)
        let originalBridge=CloudSessionBridge(repository:original.repo,client:original.client);try await originalBridge.attach(original.session)
        let scope=try scope(f),upload=try await originalBridge.prepareUpload(matchID:start.matchID,scope:scope)
        try await HTTPAuthorityIntegrationTests().terminateOnServer(original,request:start)
        let restore=try await HTTPAuthorityIntegrationTests().harness(f),bridge=CloudSessionBridge(repository:restore.repo,client:restore.client);try await bridge.attach(restore.session)
        let batch=try CloudFetchBatch(scope:scope,batchID:"history",records:[upload.record],expectedAppliedToken:nil,nextToken:Data([1]),fetchGeneration:0,moreComing:false)
        _=try await bridge.importBatch(batch)
        let coreScope=try CloudSessionBridge.coreScope(scope),history=try await restore.repo.cloudHistoryV4(scope:coreScope),ids=try await restore.repo.matchIDs(),state=try await restore.repo.authorityStateV4(matchID:start.matchID,now:restore.date)
        XCTAssertEqual(history.first?.facts.startIntent,start.startIntent);XCTAssertTrue(ids.isEmpty);XCTAssertEqual(state.status,.unknown)
        do {try await restore.repo.validateAuthorityStartV4(start.startIntent!,now:restore.date);XCTFail()}catch{}
        let deletion=try CloudRecord(scope:scope,payload:.deletion(CloudDeletion(matchID:start.matchID,deletionID:"deleted",deletedAt:restore.date)))
        let remove=try CloudFetchBatch(scope:scope,batchID:"delete",records:[deletion,upload.record],expectedAppliedToken:Data([1]),nextToken:Data([2]),fetchGeneration:0,moreComing:false)
        _=try await bridge.importBatch(remove)
        let hidden=try await restore.repo.cloudHistoryV4(scope:coreScope),tombstones=try await restore.repo.cloudDeletionsV4(scope:coreScope);XCTAssertTrue(hidden.isEmpty);XCTAssertEqual(tombstones.count,1)
        let noReceiptStart=StartIntent(id:"unknown-original",matchID:"unknown-history",recordingDeviceID:start.startIntent!.recordingDeviceID,requestedAt:restore.date)
        let unknown=try CloudRecord(scope:scope,payload:.matchFacts(CloudMatchFacts(startIntent:noReceiptStart,starter:true,events:[],captureRevisions:[])))
        let bad=try CloudFetchBatch(scope:scope,batchID:"missing-original",records:[unknown],expectedAppliedToken:Data([2]),nextToken:Data([3]),fetchGeneration:0,moreComing:false)
        do {_=try await bridge.importBatch(bad);XCTFail()}catch{}
        let cursor=try await bridge.appliedCursor(scope:scope);XCTAssertEqual(cursor.appliedToken,Data([2]))
    }

}
