import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore
final class CloudImportTests:XCTestCase,@unchecked Sendable {
    let h=TransactionTests()
    func scope()throws->CloudScopeV1 {try CloudScopeV1(accountID:"cloud-account",cloudSpaceID:"cloud-space",zoneID:"zone",activationEpoch:1)}
    func binding()throws->AccountBindingV4 {try AccountBindingV4(accountID:"cloud-account",cloudSpaceID:"cloud-space",deviceID:"watch",activationEpoch:1,role:.watch,environment:.development)}
    func trust()throws->AuthorityTrustConfiguration {try AuthorityTrustConfiguration(environment:.development,publicKeys:["test":AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)])}
    func batch(id:String="batch",events:[MatchEvent],descriptor:MatchDescriptor,parent:Data?=nil,next:Data?=Data([1]),generation:Int64=0)throws->ValidatedCloudBatchV1 {
        let f=try CloudFactSetV1(startIntent:descriptor.startIntent,starter:descriptor.starter,events:events,captureRevisions:[])
        let record=try CloudRecordV1(scope:scope(),payload:.matchFacts(f))
        return try ValidatedCloudBatchV1(canonicalBytes:CloudCanonicalV1.encode(ValidatedCloudBatchV1.Wire(scope:scope(),batchID:id,records:[record],expectedAppliedToken:parent,nextToken:next,fetchGeneration:generation,moreComing:false)))
    }
    func testFactsCursorReceiptAreOneTransactionAndFirstReceiptReplaysWithoutCursorRegression() async throws {
        let url=h.path();try await h.prepare(url);let (d,e)=try h.facts(),t=try trust()
        let store=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:t)
        try await store.bindAccountV4(binding());_=try await store.commit(h.request("local-permit",descriptor:d,events:[]));let b=try batch(events:e,descriptor:d)
        let receipt=try await store.commitCloudBatchV4(b)
        let s=try await store.snapshotV2(matchID:"match"),cursor=try await store.cloudCursorV4(scope:scope())
        XCTAssertEqual(s.business.events.sorted {$0.eventID<$1.eventID},e.sorted {$0.eventID<$1.eventID});XCTAssertEqual(cursor.appliedToken,b.nextToken)
        let b2=try batch(id:"second",events:e,descriptor:d,parent:b.nextToken,next:Data([2]))
        _=try await store.commitCloudBatchV4(b2);let replay=try await store.commitCloudBatchV4(b);XCTAssertEqual(replay,receipt)
        let advanced=try await store.cloudCursorV4(scope:scope());XCTAssertEqual(advanced.appliedToken,Data([2]));try await store.close()
    }
    func testResetGenerationRejectsDelayedUncommittedBatch() async throws {
        let url=h.path();try await h.prepare(url);let (d,e)=try h.facts(),store=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust())
        try await store.bindAccountV4(binding());let old=try batch(events:e,descriptor:d)
        let reset=try await store.resetCloudCursorV4(scope:scope(),expectedGeneration:0);XCTAssertEqual(reset.fetchGeneration,1)
        do {_=try await store.commitCloudBatchV4(old);XCTFail()}catch{}
        let s=try await store.snapshotV2(matchID:"match");XCTAssertTrue(s.business.events.isEmpty);try await store.close()
    }

    func testEveryImportFaultIsAtomicAcrossFactsCursorAndFirstReceiptAfterReopen() async throws {
        for fault in [StoreFault.afterInboundFacts,.afterReceipt,.beforeCommit,.afterCommit] {
            let url=h.path();try await h.prepare(url);let (d,e)=try h.facts(),trust=try trust()
            let seed=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
            try await seed.bindAccountV4(binding());_=try await seed.commit(h.request("permit",descriptor:d,events:[]));try await seed.close()
            let failing=try MatchStore(url:url,fault:fault,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust),b=try batch(events:e,descriptor:d)
            do {_=try await failing.commitCloudBatchV4(b);XCTFail()}catch{}
            try await failing.close()
            let reopened=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
            let before=try await reopened.snapshotV2(matchID:"match"),cursor=try await reopened.cloudCursorV4(scope:scope())
            XCTAssertEqual(before.business.events.count,fault == .afterCommit ? e.count:0);XCTAssertEqual(cursor.appliedToken,fault == .afterCommit ? b.nextToken:nil)
            let receipt=try await reopened.commitCloudBatchV4(b),duplicate=try await reopened.commitCloudBatchV4(b);XCTAssertEqual(receipt,duplicate);try await reopened.close()
        }
    }
    func testBadRecordAndLocalIdentityConflictRollBackWholeBatch() async throws {
        let url=h.path();try await h.prepare(url);let (d,e)=try h.facts(),trust=try trust()
        let store=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
        try await store.bindAccountV4(binding());_=try await store.commit(h.request("permit",descriptor:d,events:[]))
        let good=try CloudRecordV1(scope:scope(),payload:.matchFacts(CloudFactSetV1(startIntent:d.startIntent,starter:d.starter,events:e,captureRevisions:[])))
        let different=StartIntent(id:"foreign",matchID:"match",recordingDeviceID:"other",requestedAt:h.t)
        let bad=try CloudRecordV1(scope:scope(),payload:.matchFacts(CloudFactSetV1(startIntent:different,starter:false,events:[],captureRevisions:[])))
        let b=try ValidatedCloudBatchV1(canonicalBytes:CloudCanonicalV1.encode(ValidatedCloudBatchV1.Wire(scope:scope(),batchID:"conflict",records:[good,bad],expectedAppliedToken:nil,nextToken:Data([7]),fetchGeneration:0,moreComing:false)))
        do {_=try await store.commitCloudBatchV4(b);XCTFail()}catch{}
        let after=try await store.snapshotV2(matchID:"match"),cursor=try await store.cloudCursorV4(scope:scope());XCTAssertTrue(after.business.events.isEmpty);XCTAssertNil(cursor.appliedToken)
    }
    func testTwoConnectionsCASOnlyOneParentTokenWinner() async throws {
        let url=h.path();try await h.prepare(url);let (d,e)=try h.facts(),trust=try trust()
        let one=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
        try await one.bindAccountV4(binding());_=try await one.commit(h.request("permit",descriptor:d,events:[]))
        let two=try MatchStore(url:url,syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
        let a=try batch(id:"worker-one",events:e,descriptor:d,next:Data([1])),b=try batch(id:"worker-two",events:e,descriptor:d,next:Data([2]))
        async let ra=try? one.commitCloudBatchV4(a);async let rb=try? two.commitCloudBatchV4(b)
        let results=await [ra,rb];XCTAssertEqual(results.compactMap {$0}.count,1)
        try await one.close();try await two.close()
    }
    func testOldEpochOriginalReceiptAuthorizesOnlyHistoryAndMissingReceiptDoesNotAdvanceToken() async throws {
        let (raw,trust,expected,_)=try AuthorityTransactionTests().vector()
        let scope=try CloudScopeV1(accountID:expected.accountID,cloudSpaceID:"fixture-cloud",zoneID:"zone",activationEpoch:43)
        let old=try CloudScopeV1(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:42)
        let start=StartIntent(id:"fixture-acquire-v1",matchID:"fixture-match-v1",recordingDeviceID:"fixture-watch-v1",requestedAt:h.t)
        let facts=try CloudFactSetV1(startIntent:start,starter:true,events:[],captureRevisions:[]),record=try CloudRecordV1(scope:old,payload:.matchFacts(facts))
        let b=try ValidatedCloudBatchV1(canonicalBytes:CloudCanonicalV1.encode(ValidatedCloudBatchV1.Wire(scope:scope,batchID:"old-history",records:[record],expectedAppliedToken:nil,nextToken:Data([1]),fetchGeneration:0,moreComing:false)))
        let store=try MatchStore(url:h.path(),syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust)
        try await store.bindAccountV4(AccountBindingV4(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,deviceID:"new-phone",activationEpoch:43,role:.phone,environment:.development))
        do {_=try await store.commitCloudBatchV4(b);XCTFail()}catch{}
        let cursor=try await store.cloudCursorV4(scope:scope);XCTAssertNil(cursor.appliedToken)
        let grant=try VerifiedCloudHistoryGrantV1.verify(scope:old,intent:ControlIntentV1.acquire(start,epoch:42),raw:raw,trust:trust)
        try await store.authorizeCloudHistoryV4(grant);_=try await store.commitCloudBatchV4(b)
        let history=try await store.cloudHistoryV4(scope:scope),ids=try await store.matchIDs(),state=try await store.authorityStateV4(matchID:start.matchID,now:h.t)
        XCTAssertEqual(history.map(\.facts),[facts]);XCTAssertTrue(ids.isEmpty);XCTAssertEqual(state.status,.unknown)
        do {try await store.validateAuthorityStartV4(start,now:h.t);XCTFail()}catch{}
    }
    func testMalformedCanonicalScopeAndDeletionCannotEnterValidatedBatch() throws {
        let badScope = Data(#"{"accountID":"cloud-account","activationEpoch":0,"cloudSpaceID":"cloud-space","zoneID":"zone"}"#.utf8)
        XCTAssertThrowsError(try CloudCanonicalV1.decode(CloudScopeV1.self,badScope))
        let badDeletion = Data(#"{"deletion":{"_0":{"deletedAt":0,"deletionID":"","matchID":"match"}}}"#.utf8)
        XCTAssertThrowsError(try CloudRecordV1(scope:scope(),canonicalBytes:badDeletion))
    }

    func testAccountCheckpointEmptyReferencesAreControlMetadataAndScopeBound() async throws {
        let scope=try scope(),control=try CloudCheckpointV1(matchID:"account-checkpoint:"+scope.stableZoneKey,checkpointID:"00112233-4455-6677-8899-aabbccddeeff",recordIDs:[])
        let record=try CloudRecordV1(scope:scope,payload:.checkpoint(control))
        let store=try MatchStore(url:h.path(),syncEnvironment:.development(databaseNamespace:"cloud-test"),authorityTrust:trust());try await store.bindAccountV4(binding())
        let batch=try ValidatedCloudBatchV1(canonicalBytes:CloudCanonicalV1.encode(ValidatedCloudBatchV1.Wire(scope:scope,batchID:"empty-account-checkpoint",records:[record],expectedAppliedToken:nil,nextToken:Data([1]),fetchGeneration:0,moreComing:false)))
        _=try await store.commitCloudBatchV4(batch);let ids=try await store.matchIDs();XCTAssertTrue(ids.isEmpty)
        let other=try CloudScopeV1(accountID:"other",cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:1)
        XCTAssertThrowsError(try CloudRecordV1(scope:other,payload:.checkpoint(control)))
        XCTAssertThrowsError(try CloudCheckpointV1(matchID:"ordinary-match",checkpointID:"ordinary",recordIDs:[]))
    }

}
