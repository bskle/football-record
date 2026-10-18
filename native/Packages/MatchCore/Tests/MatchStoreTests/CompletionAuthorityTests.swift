import Foundation
import CryptoKit
import XCTest
import MatchCore
@testable import MatchStore
final class CompletionAuthorityTests:XCTestCase,@unchecked Sendable {
    let h=TransactionTests()
    struct Context {let store:MatchStore;let key:Curve25519.Signing.PrivateKey;let trust:AuthorityTrustConfiguration;let scope:CloudScopeV1;let descriptor:MatchDescriptor}
    func receipt(_ intent:ControlIntentV1,result:String,key:Curve25519.Signing.PrivateKey,trust:AuthorityTrustConfiguration)throws->VerifiedAuthorityReceiptV1 {
        let body:[String:Any]=["version":1,"environment":"development","keyID":"test","receiptID":intent.requestID+"-receipt","requestID":intent.requestID,"requestDigest":intent.digest,"operation":intent.operation.rawValue,"accountID":"completion-account","activationEpoch":1,"matchID":intent.fields.matchID ?? "","lockID":"lock","recordingDeviceID":"watch","result":result,"issuedAt":Int64(h.t.timeIntervalSince1970)]
        let rawBody=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes])
        let signature=try key.signature(for:AuthorityWire.signedInput("football-record.authority.receipt.v1",body:rawBody))
        let raw=try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(signature)],options:[.sortedKeys,.withoutEscapingSlashes])
        return try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:"completion-account",epoch:1),trust:trust)
    }
    func context(acquired:Bool=true) async throws->Context {
        let key=Curve25519.Signing.PrivateKey(),trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:["test":AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        let store=try MatchStore(url:h.path(),syncEnvironment:.development(databaseNamespace:"completion-test"),authorityTrust:trust,cloudSavePolicy:.development(databaseNamespace:"completion-test"))
        let scope=try CloudScopeV1(accountID:"completion-account",cloudSpaceID:"cloud",zoneID:"zone",activationEpoch:1)
        try await store.bindAccountV4(AccountBindingV4(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,deviceID:"watch",activationEpoch:1,role:.watch,environment:.development))
        let start=StartIntent(id:"acquire",matchID:"match",recordingDeviceID:"watch",requestedAt:h.t)
        _=try await store.commit(StoreCommit(commandID:"local-intent",expectedGeneration:0,descriptor:MatchDescriptor(startIntent:start,starter:true),events:[],packets:[]))
        if acquired {let acquire=try ControlIntentV1.acquire(start,epoch:1);_=try await store.prepareControlV4(acquire);_=try await store.recordAuthorityResultV4(receipt(acquire,result:"held",key:key,trust:trust))}
        let d=MatchDescriptor(startIntent:start,starter:true,startPermit:DevelopmentStartFixture.permit(for:start),backendLockState:.held)
        var recorder=LiveMatchRecorder(descriptor:d);try recorder.start(eventID:"start",sourceDeviceID:"watch",now:h.t);try recorder.transition(.matchEnded,eventID:"end",sourceDeviceID:"watch",now:h.t.addingTimeInterval(30))
        _=try await store.commit(h.request("local-events",descriptor:d,events:recorder.events))
        return Context(store:store,key:key,trust:trust,scope:scope,descriptor:d)
    }
    func input(_ c:Context,confirmation:String="cloud-confirmation") async throws->CloudSaveInputV1 {
        let s=try await c.store.snapshotV2(matchID:"match"),facts=try CloudFactSetV1(startIntent:s.business.descriptor.startIntent,starter:s.business.descriptor.starter,events:s.business.events,captureRevisions:s.captureRevisions)
        let record=try CloudRecordV1(scope:c.scope,payload:.matchFacts(facts)),part=CloudAssetReferenceV1(partID:"asset",index:0,byteCount:record.canonicalBytes.count,digest:AuthorityWire.hash(record.canonicalBytes))
        let checkpoint=AuthorityWire.hash(Data((c.scope.stableZoneKey+"\0"+record.recordID+"\0checkpoint.v1").utf8))
        let manifest=CloudSaveManifestV1(version:1,scope:c.scope,recordID:record.recordID,recordDigest:record.digest,recordType:"MatchFactsV1",matchID:"match",factDigest:try facts.factDigest,captureDigest:try facts.captureDigest,checkpointID:checkpoint,terminalEventID:"end",byteCount:record.canonicalBytes.count,parts:[part])
        return CloudSaveInputV1(record:record,checkpointID:checkpoint,confirmationID:confirmation,factDigest:try facts.factDigest,captureDigest:try facts.captureDigest,terminalEventID:"end",manifestBytes:try CloudCanonicalV1.encode(manifest),manifestChangeTag:"manifest-tag",recordChangeTag:"record-tag",conditional:true,parts:[CloudSavedAssetV1(partID:part.partID,index:0,byteCount:part.byteCount,digest:part.digest,changeTag:"asset-tag",bytes:record.canonicalBytes,conditional:true)])
    }
    func normalRelease(_ c:Context,input:CloudSaveInputV1) async throws->VerifiedAuthorityReceiptV1 {
        var f=AuthorityFields();f.matchID="match";f.recordingDeviceID="watch";f.lockID="lock";f.activationEpoch=1;f.mode="normal";f.cloudConfirmationID=input.confirmationID;f.contentCommitment=input.factDigest
        let intent=try ControlIntentV1(requestID:"release",operation:.terminate,fields:f);_=try await c.store.prepareControlV4(intent)
        let release=try receipt(intent,result:"releasedNormal",key:c.key,trust:c.trust);_=try await c.store.recordAuthorityResultV4(release);return release
    }
    func testCloudAloneAndReleaseAloneRemainPendingAndBothEvidenceComplete() async throws {
        let c=try await context(),input=try await input(c),proof=try VerifiedCloudSaveV1.verifyReadback(input,policy:.development(databaseNamespace:"completion-test"))
        _=try await c.store.saveCloudCheckpointV4(proof)
        let onlyCloud=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try onlyCloud.business.replay(now:h.t.addingTimeInterval(60)).state,.endedPendingSync)
        let release=try await normalRelease(c,input:input)
        let before=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try before.business.replay(now:h.t.addingTimeInterval(60)).state,.endedPendingSync)
        try await c.store.completeNormallyV4(release:release,cloud:proof,expectedGeneration:before.business.generation,now:h.t.addingTimeInterval(60))
        let completed=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try completed.business.replay(now:h.t.addingTimeInterval(60)).state,.completed)
    }
    func testLegacyCompleteSaveCannotBypassAuthorityBinding() async throws {
        let c=try await context(),s=try await c.store.snapshotV2(matchID:"match"),now=h.t.addingTimeInterval(60)
        let evidence=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:s.business.descriptor,events:s.business.events,confirmationID:"forged-direct",now:now)
        do {try await c.store.saveCompletionProofV2(evidence:evidence,captureDigest:s.captureDigest,expectedGeneration:s.business.generation,now:now);XCTFail("direct legacy completion bypass")}catch{}
        let after=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try after.business.replay(now:now).state,.endedPendingSync)
    }
    func testAccountBindingBeforeAnyControlAlsoBlocksLegacyCompletion() async throws {
        let c=try await context(acquired:false),s=try await c.store.snapshotV2(matchID:"match"),now=h.t.addingTimeInterval(60)
        let e=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:s.business.descriptor,events:s.business.events,confirmationID:"legacy",now:now)
        do {try await c.store.saveCompletionEvidence(e,expectedGeneration:s.business.generation,now:now);XCTFail("binding alone must close the legacy entry")}catch{}
    }
    func testMalformedManifestCannotBecomeVerifiedSave() async throws {
        let c=try await context(),i=try await input(c)
        let malformed=CloudSaveInputV1(record:i.record,checkpointID:i.checkpointID,confirmationID:i.confirmationID,factDigest:i.factDigest,captureDigest:i.captureDigest,terminalEventID:i.terminalEventID,manifestBytes:Data("{}".utf8),manifestChangeTag:i.manifestChangeTag,recordChangeTag:i.recordChangeTag,conditional:true,parts:i.parts)
        XCTAssertThrowsError(try VerifiedCloudSaveV1.verifyReadback(malformed,policy:.development(databaseNamespace:"completion-test")))
    }

    func testCorrectionInvalidatesCompletionAndNewCloudProofReusesPermanentRelease() async throws {
        let c=try await context(),i=try await input(c),proof=try VerifiedCloudSaveV1.verifyReadback(i,policy:.development(databaseNamespace:"completion-test"))
        _=try await c.store.saveCloudCheckpointV4(proof);let release=try await normalRelease(c,input:i),before=try await c.store.snapshotV2(matchID:"match")
        try await c.store.completeNormallyV4(release:release,cloud:proof,expectedGeneration:before.business.generation,now:h.t.addingTimeInterval(60))
        let completed=try await c.store.snapshotV2(matchID:"match")
        let correction=try PostMatchEditor.insertScore(eventID:"late-score",descriptor:c.descriptor,events:completed.business.events,occurredAt:h.t.addingTimeInterval(10),goal:GoalPayload(scoreImpact:.forTeam,scoringTeamSnapshot:"team"),sourceDeviceID:"phone",now:h.t.addingTimeInterval(60))
        _=try await c.store.commit(h.request("correction",generation:completed.business.generation,descriptor:c.descriptor,events:[correction]))
        let changed=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try changed.business.replay(now:h.t.addingTimeInterval(60)).state,.endedPendingSync)
        let state=try await c.store.authorityStateV4(matchID:"match",now:h.t.addingTimeInterval(60));XCTAssertEqual(state.verifiedNormalRelease?.raw,release.raw)
        let next=try VerifiedCloudSaveV1.verifyReadback(try await input(c,confirmation:"corrected-cloud"),policy:.development(databaseNamespace:"completion-test"))
        _=try await c.store.saveCloudCheckpointV4(next);try await c.store.completeNormallyV4(release:release,cloud:next,expectedGeneration:changed.business.generation,now:h.t.addingTimeInterval(60))
        let recompleted=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try recompleted.business.replay(now:h.t.addingTimeInterval(60)).state,.completed)
    }
    func testReleaseOnlyCannotCompleteWithoutPersistedCurrentCloudProof() async throws {
        let c=try await context(),i=try await input(c),release=try await normalRelease(c,input:i),proof=try VerifiedCloudSaveV1.verifyReadback(i,policy:.development(databaseNamespace:"completion-test")),s=try await c.store.snapshotV2(matchID:"match")
        do {try await c.store.completeNormallyV4(release:release,cloud:proof,expectedGeneration:s.business.generation,now:h.t.addingTimeInterval(60));XCTFail()}catch{}
        let after=try await c.store.snapshotV2(matchID:"match");XCTAssertEqual(try after.business.replay(now:h.t.addingTimeInterval(60)).state,.endedPendingSync)
    }
    func testBothProofsRejectCanonicallyEquivalentUnicodeManifestScopeBytes() async throws {
        let c=try await context(),scope=try CloudScopeV1(accountID:c.scope.accountID,cloudSpaceID:c.scope.cloudSpaceID,zoneID:"zoné",activationEpoch:1),other=try CloudScopeV1(accountID:c.scope.accountID,cloudSpaceID:c.scope.cloudSpaceID,zoneID:"zone\u{301}",activationEpoch:1)
        let facts=try await input(Context(store:c.store,key:c.key,trust:c.trust,scope:scope,descriptor:c.descriptor))
        _=try VerifiedCloudSaveV1.verifyReadback(facts,policy:.development(databaseNamespace:"completion-test"))
        func changed(_ i:CloudSaveInputV1)throws->CloudSaveInputV1 {
            var object=try JSONSerialization.jsonObject(with:i.manifestBytes) as! [String:Any],value=object["scope"] as! [String:Any];value["zoneID"]=other.zoneID;object["scope"]=value
            return CloudSaveInputV1(record:i.record,checkpointID:i.checkpointID,confirmationID:i.confirmationID,factDigest:i.factDigest,captureDigest:i.captureDigest,terminalEventID:i.terminalEventID,manifestBytes:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]),manifestChangeTag:i.manifestChangeTag,recordChangeTag:i.recordChangeTag,conditional:i.conditional,parts:i.parts)
        }
        XCTAssertThrowsError(try VerifiedCloudSaveV1.verifyReadback(changed(facts),policy:.development(databaseNamespace:"completion-test")))
        let checkpoint=try CloudCheckpointV1(matchID:CloudCheckpointV1.accountAnchorPrefix+scope.stableZoneKey,checkpointID:"00112233-4455-6677-8899-aabbccddeeff",recordIDs:[]),record=try CloudRecordV1(scope:scope,payload:.checkpoint(checkpoint)),digest=try CaptureRevision.digest([]),manifestID=AuthorityWire.hash(Data((scope.stableZoneKey+"\0"+record.recordID+"\0checkpoint.v1").utf8)),part=CloudAssetReferenceV1(partID:"part",index:0,byteCount:record.canonicalBytes.count,digest:AuthorityWire.hash(record.canonicalBytes))
        let manifest=CloudSaveManifestV1(version:1,scope:scope,recordID:record.recordID,recordDigest:record.digest,recordType:"CheckpointV1",matchID:checkpoint.matchID,factDigest:record.digest,captureDigest:digest,checkpointID:manifestID,terminalEventID:nil,byteCount:record.canonicalBytes.count,parts:[part])
        let account=CloudSaveInputV1(record:record,checkpointID:manifestID,confirmationID:"confirmation",factDigest:record.digest,captureDigest:digest,terminalEventID:"",manifestBytes:try CloudCanonicalV1.encode(manifest),manifestChangeTag:"manifest",recordChangeTag:"record",conditional:true,parts:[CloudSavedAssetV1(partID:part.partID,index:0,byteCount:part.byteCount,digest:part.digest,changeTag:"part",bytes:record.canonicalBytes,conditional:true)])
        _=try VerifiedAccountCheckpointV4.verifyReadback(account,policy:.development(databaseNamespace:"completion-test"))
        XCTAssertThrowsError(try VerifiedAccountCheckpointV4.verifyReadback(changed(account),policy:.development(databaseNamespace:"completion-test")))
        XCTAssertNotEqual(scope,other);XCTAssertEqual(Set([scope,other]).count,2)
    }

}
