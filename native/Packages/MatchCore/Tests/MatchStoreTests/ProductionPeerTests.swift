import XCTest
import Foundation
import CryptoKit
import MatchCore
import MatchSession
import MatchSync
@testable import MatchStore
private struct PeerIdentity:DeviceIdentityProvider {let id:String;func localDeviceID() async throws->String {id}}
private struct PeerClock:SessionClock,SyncClock {let date:Date;func now()->Date {date}}
private actor PeerGateway:WorkoutGateway {
    var operations:[CaptureOperation]=[]
    func perform(_ operation:CaptureOperation) async->WorkoutObservation {operations.append(operation);return try! WorkoutObservation(operationID:operation.id,binding:operation.binding,externalToken:operation.externalToken,observedAt:operation.requestedAt,outcome:.linked(workoutID:"original-workout"),window:CaptureWindow(start:nil,end:operation.requestedAt))}
    func reconcile(_ operation:CaptureOperation) async->WorkoutObservation {await perform(operation)}
}
private struct ControlledProductionPeerProvider:ProductionPeerTrustProvider {
    let grant:VerifiedPeerGrantV1,key:Curve25519.Signing.PrivateKey
    func currentGrant() async throws->VerifiedPeerGrantV1 {grant}
    func signEnvelopeBody(_ bytes:Data) async throws->Data {try key.signature(for:bytes)}
}
private actor PeerTransport:ProductionPeerTransport {
    var bytes:[Data]=[]
    func sendEnvelope(_ originalBytes:Data,deliveryID:String) async throws {bytes.append(originalBytes)}
}
final class ProductionPeerTests:XCTestCase,@unchecked Sendable {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    struct Fixture {
        let authority,phone,watch:Curve25519.Signing.PrivateKey
        let trust:AuthorityTrustConfiguration
        let phoneBinding,watchBinding:AccountBindingV4
        let grantIntent,acquireIntent:ControlIntentV1
        let grantRaw,acquireRaw:Data
        let descriptor:MatchDescriptor
    }
    func signed(_ body:AuthorityReceiptBodyV1,_ key:Curve25519.Signing.PrivateKey)throws->Data {
        struct Envelope:Encodable {let body:AuthorityReceiptBodyV1;let signature:String}
        return try AuthorityWire.encode(Envelope(body:body,signature:AuthorityWire.base64URL(key.signature(for:AuthorityWire.signedInput("football-record.authority.receipt.v1",body:AuthorityWire.encode(body))))))
    }
    func fixture(pair:String="pair",watchID:String="watch",keys:Fixture?=nil,expires:Int64=1_800_003_600,issued:Int64=1_800_000_000,roles:Bool=true,environment:AuthorityEnvironment = .production)throws->Fixture {
        let authority=keys?.authority ?? Curve25519.Signing.PrivateKey(),phone=keys?.phone ?? Curve25519.Signing.PrivateKey(),watch=keys?.watch ?? Curve25519.Signing.PrivateKey()
        let trust=try AuthorityTrustConfiguration(environment:environment,publicKeys:["fixed-production-key":AuthorityWire.base64URL(authority.publicKey.rawRepresentation)]),pb=try AccountBindingV4(accountID:"account",cloudSpaceID:"cloud",deviceID:"phone",activationEpoch:42,role:.phone,environment:environment),wb=try AccountBindingV4(accountID:"account",cloudSpaceID:"cloud",deviceID:watchID,activationEpoch:42,role:.watch,environment:environment)
        var fields=AuthorityFields();fields.localDeviceID="phone";fields.remoteDeviceID=watchID;fields.activationEpoch=42;fields.pairingID=pair
        let gi=try ControlIntentV1(requestID:"grant-request-"+pair+String(issued),operation:.peerGrant,fields:fields),si=StartIntent(id:"original-start",matchID:"match",recordingDeviceID:watchID,requestedAt:now),ai=try ControlIntentV1.acquire(si,epoch:42)
        let grant=AuthorityPeerGrantV1(grantID:"grant-"+pair,pairingID:pair,localDeviceID:"phone",remoteDeviceID:watchID,localPublicKey:AuthorityWire.base64URL(phone.publicKey.rawRepresentation),remotePublicKey:AuthorityWire.base64URL(watch.publicKey.rawRepresentation),localRole:roles ? "phone":"watch",remoteRole:"watch",activePhoneID:"phone",expiresAt:expires)
        func body(_ i:ControlIntentV1,_ peer:AuthorityPeerGrantV1?)->AuthorityReceiptBodyV1 {AuthorityReceiptBodyV1(version:1,environment:environment,keyID:"fixed-production-key",receiptID:"receipt-"+i.requestID,requestID:i.requestID,requestDigest:i.digest,operation:i.operation,accountID:"account",activationEpoch:42,matchID:peer==nil ? "match":"",lockID:peer==nil ? "lock":"",recordingDeviceID:peer==nil ? watchID:"",result:peer==nil ? .held:.grantIssued,issuedAt:issued,migration:nil,peerGrant:peer,registration:nil,lostRecovery:nil,deletion:nil)}
        return Fixture(authority:authority,phone:phone,watch:watch,trust:trust,phoneBinding:pb,watchBinding:wb,grantIntent:gi,acquireIntent:ai,grantRaw:try signed(body(gi,grant),authority),acquireRaw:try signed(body(ai,nil),authority),descriptor:MatchDescriptor(startIntent:si,starter:true,startPermit:.acceptedByTrustedNetworkBoundary(for:si,permitID:"receipt-original-start"),backendLockState:.held))
    }
    func grant(_ f:Fixture,binding:AccountBindingV4?=nil)throws->VerifiedPeerGrantV1 {try VerifiedPeerGrantV1.verify(f.grantRaw,intent:f.grantIntent,trust:f.trust,binding:binding ?? f.phoneBinding,now:now)}
    func envelope(_ bytes:Data,kind:ProductionPeerPayloadKindV1,f:Fixture,source:String="watch",binding:AccountBindingV4?=nil)throws->VerifiedPeerEnvelopeV1 {
        let g=try grant(f,binding:binding),body=try ProductionPeerEnvelopeV1.body(grant:g,sourceDeviceID:source,kind:kind,bytes:bytes),key=source=="phone" ? f.phone:f.watch
        let wire=ProductionPeerEnvelopeV1(body:body,signature:AuthorityWire.base64URL(try key.signature(for:ProductionPeerEnvelopeV1.signingBytes(body))))
        return try VerifiedPeerEnvelopeV1.verify(AuthorityWire.encode(wire),grant:g,trust:f.trust,binding:binding ?? f.phoneBinding,now:now)
    }
    func packet(_ f:Fixture,id:String="packet",eventID:String="started")throws->MatchPacketV2 {
        let event=MatchEvent(eventID:eventID,matchID:"match",sequence:0,occurredAt:now,matchElapsed:0,type:.matchStarted,sourceDeviceID:f.watchBinding.deviceID,createdAt:now,updatedAt:now)
        return try MatchPacketV2(packetID:id,idempotencyKey:"idem-"+id,sequence:1,sourceDeviceID:f.watchBinding.deviceID,targetDeviceID:"phone",descriptor:f.descriptor,events:[event],captureRevisions:[])
    }
    func testGrantRequiresSignedRolesFixedProductionKeyEpochAndExactDeviceEnvelope() throws {
        let f=try fixture(),g=try grant(f),packet=try packet(f),verified=try envelope(packet.canonicalBytes(),kind:.packet,f:f)
        XCTAssertEqual(verified.payload,try packet.canonicalBytes());XCTAssertEqual(g.grant.activePhoneID,"phone")
        for bad in [try fixture(keys:f,roles:false),try fixture(keys:f,environment:.development),try fixture(keys:f,expires:1_799_999_999)] {XCTAssertThrowsError(try grant(bad))}
        let wrong=try fixture();XCTAssertThrowsError(try VerifiedPeerGrantV1.verify(f.grantRaw,intent:f.grantIntent,trust:wrong.trust,binding:f.phoneBinding,now:now))
        var bytes=verified.raw;bytes[bytes.count-8] ^= 1;XCTAssertThrowsError(try VerifiedPeerEnvelopeV1.verify(bytes,grant:g,trust:f.trust,binding:f.phoneBinding,now:now))
        var object=try JSONSerialization.jsonObject(with:f.grantRaw) as! [String:Any],body=object["body"] as! [String:Any],peer=body["peerGrant"] as! [String:Any];peer.removeValue(forKey:"remoteRole");body["peerGrant"]=peer;object["body"]=body
        let missing=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]);XCTAssertThrowsError(try VerifiedPeerGrantV1.verify(missing,intent:f.grantIntent,trust:f.trust,binding:f.phoneBinding,now:now))
    }
    func seed(_ store:MatchStore,_ f:Fixture) async throws {
        try await store.bindAccountV4(f.phoneBinding)
        let a=try VerifiedAuthorityReceiptV1.verify(f.acquireRaw,expected:AuthorityExpectedIntent(f.acquireIntent,accountID:"account",epoch:42),trust:f.trust)
        try await store.authorizeProductionMatchV4(intent:f.acquireIntent,receipt:a)
    }
    func testProductionInboxFaultsReopenExactV2BytesAndConflictsNeverCreateCompletion() async throws {
        let f=try fixture(),p=try packet(f),verified=try envelope(p.canonicalBytes(),kind:.packet,f:f)
        for fault in [StoreFault.afterInboundFacts,.afterInboundReceipt,.beforeCommit,.afterCommit] {
            let url=TransactionTests().path(),seed=try MatchStore(url:url,authorityTrust:f.trust);try await self.seed(seed,f);try await seed.close()
            let failing=try MatchStore(url:url,fault:fault,authorityTrust:f.trust)
            do {_=try await failing.receiveProductionEnvelopeV4(verified,matchID:"match",now:now);XCTFail()}catch{}
            try await failing.close();let reopened=try MatchStore(url:url,authorityTrust:f.trust)
            let receipt=try await reopened.receiveProductionEnvelopeV4(verified,matchID:"match",now:now),again=try await reopened.receiveProductionEnvelopeV4(verified,matchID:"match",now:now)
            XCTAssertEqual(receipt,again);XCTAssertEqual(try receipt.ack.canonicalBytes(),try DurableACKV2(packet:p).canonicalBytes())
            let snapshot=try await reopened.snapshotV2(matchID:"match");XCTAssertNotEqual(try snapshot.business.replay(now:now).state,.completed);XCTAssertEqual(snapshot.business.descriptor,f.descriptor)
            let collision=try packet(f,eventID:"different-start"),bad=try envelope(collision.canonicalBytes(),kind:.packet,f:f)
            do {_=try await reopened.receiveProductionEnvelopeV4(bad,matchID:"match",now:now);XCTFail()}catch{}
            try await reopened.close()
        }
    }
    func testRoutesACKRefreshAndPairChangeKeepOriginalBytesAndLegacyContextUntouched() async throws {
        let f=try fixture(),url=TransactionTests().path(),store=try MatchStore(url:url,authorityTrust:f.trust),g=try grant(f)
        var recorder=LiveMatchRecorder(descriptor:f.descriptor);try recorder.start(eventID:"start",sourceDeviceID:"watch",now:now);try recorder.transition(.matchEnded,eventID:"end",sourceDeviceID:"watch",now:now.addingTimeInterval(1))
        let delta=try BusinessOutboxItem(id:"phone-delta",matchID:"match",sourceDeviceID:"phone",payload:BusinessDeltaV2(descriptor:f.descriptor,events:recorder.events,captureRevisions:[]))
        _=try await store.commit(StoreCommit(commandID:"source-intent",expectedGeneration:0,descriptor:MatchDescriptor(startIntent:f.descriptor.startIntent,starter:true),events:[],packets:[]))
        _=try await store.commitV2(StoreCommitV2(commandID:"source-facts",expectedGeneration:1,descriptor:f.descriptor,events:recorder.events,captureRevisions:[],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[delta]))
        try await seed(store,f)
        let route=try await store.routeProductionOutboxV4(outboxID:delta.id,grant:g,now:now);XCTAssertEqual(route.packet.body.targetDeviceID,"watch")
        try await store.close()
        let inspect=try SQLite(url:url,fault:nil);XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM sync_context_v3").number,0);XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM sync_routes_v3").number,0);try inspect.close()
        let after=try MatchStore(url:url,authorityTrust:f.trust),other=try fixture(pair:"new-pair",watchID:"new-watch",keys:f),newGrant=try grant(other)
        do {_=try await after.routeProductionOutboxV4(outboxID:delta.id,grant:newGrant,now:now);XCTFail("old route must never bind a replacement Watch")}catch{}
        let paused=try await after.pendingProductionPacketsV4(matchID:"match",grant:newGrant,now:now);XCTAssertTrue(paused.isEmpty)
        let pending=try await after.pendingProductionPacketsV4(matchID:"match",grant:g,now:now);XCTAssertEqual(pending,[route.packet])
        do {_=try await after.pendingProductionPacketsV4(matchID:"match",grant:g,now:now.addingTimeInterval(3600));XCTFail("expiry pauses sends")}catch{}
        let refreshed=try fixture(keys:f,expires:1_800_007_200,issued:1_800_003_600),freshGrant=try VerifiedPeerGrantV1.verify(refreshed.grantRaw,intent:refreshed.grantIntent,trust:f.trust,binding:f.phoneBinding,now:now.addingTimeInterval(3600))
        let afterRefresh=try await after.pendingProductionPacketsV4(matchID:"match",grant:freshGrant,now:now.addingTimeInterval(3600));XCTAssertEqual(afterRefresh,[route.packet])
        let ack=try DurableACKV2(packet:route.packet),envelope=try envelope(ack.canonicalBytes(),kind:.ack,f:f)
        try await after.acknowledgeProductionEnvelopeV4(envelope,now:now)
        let done=try await after.pendingProductionPacketsV4(matchID:"match",grant:g,now:now),snapshot=try await after.snapshotV2(matchID:"match")
        XCTAssertTrue(done.isEmpty);XCTAssertEqual(try snapshot.business.replay(now:now.addingTimeInterval(2)).state,.endedPendingSync)
        let authority=try await after.authorityStateV4(matchID:"match",now:now);XCTAssertNil(authority.verifiedNormalRelease)
        let persisted=try await after.routeProductionOutboxV4(outboxID:delta.id,grant:g,now:now);XCTAssertEqual(try persisted.packet.canonicalBytes(),try route.packet.canonicalBytes())
        try await after.close()
    }
    func testOldDevelopmentEntryStillRejectsProductionEvenWithSignedNetworkDescriptor() async throws {
        let f=try fixture(),store=try MatchStore(url:TransactionTests().path(),authorityTrust:f.trust),p=try packet(f)
        let peer=try PeerAuthorization(localDeviceID:"phone",remoteDeviceID:"watch",accountSubject:"account",pairingID:"pair",trustEpoch:"42",environment:.production,issuedAt:now,expiresAt:now.addingTimeInterval(3600))
        do {_=try await store.receiveV2(p.canonicalBytes(),peer:peer,expectedMatchID:"match",now:now);XCTFail()}catch{}
        let missing=try MatchStore(url:TransactionTests().path(),authorityTrust:f.trust);try await missing.bindAccountV4(f.phoneBinding)
        do {_=try await missing.receiveProductionEnvelopeV4(envelope(p.canonicalBytes(),kind:.packet,f:f),matchID:"match",now:now);XCTFail("peer alone cannot vouch for a permit")}catch{}
        try await store.close();try await missing.close()
    }

    func testProductionFacadeSessionAndTransportKeepPacketACKBytesAndNeverCreatePhoneWorkout() async throws {
        let f=try fixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"production",authorityTrust:f.trust),gateway=PeerGateway(),clock=PeerClock(date:now.addingTimeInterval(2))
        try await repo.bindAccountV4(f.phoneBinding)
        let session=MatchSession(store:repo,deviceIdentity:PeerIdentity(id:"phone"),clock:clock,ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:gateway,environment:.production)
        let acquire=try VerifiedAuthorityReceiptV1.verify(f.acquireRaw,expected:AuthorityExpectedIntent(f.acquireIntent,accountID:"account",epoch:42),trust:f.trust)
        try await session.authorizeProductionMatch(intent:f.acquireIntent,receipt:acquire)
        var recorder=LiveMatchRecorder(descriptor:f.descriptor);try recorder.start(eventID:"start",sourceDeviceID:"watch",now:now);try recorder.transition(.matchEnded,eventID:"end",sourceDeviceID:"watch",now:now.addingTimeInterval(1))
        let p=try MatchPacketV2(packetID:"original-v2",idempotencyKey:"original-idem",sequence:1,sourceDeviceID:"watch",targetDeviceID:"phone",descriptor:f.descriptor,events:recorder.events,captureRevisions:[])
        let receipt=try await session.receiveProductionPeer(envelope(p.canonicalBytes(),kind:.packet,f:f),matchID:"match")
        XCTAssertEqual(try receipt.ack.canonicalBytes(),try DurableACKV2(packet:p).canonicalBytes())
        let delta=try BusinessOutboxItem(id:"phone-current-delta",matchID:"match",sourceDeviceID:"phone",payload:BusinessDeltaV2(descriptor:f.descriptor,events:[],captureRevisions:[]))
        _=try await repo.commitV2(StoreCommitV2(commandID:"phone-delta-command",expectedGeneration:receipt.generation,descriptor:f.descriptor,events:[],captureRevisions:[],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[delta]))
        let transport=PeerTransport(),g=try grant(f),sync=ProductionPeerSyncService(repository:repo,provider:ControlledProductionPeerProvider(grant:g,key:f.phone),transport:transport,clock:clock)
        try await sync.synchronize(matchID:"match");try await sync.synchronize(matchID:"match")
        let sent=await transport.bytes;XCTAssertEqual(sent.count,2);XCTAssertEqual(try AuthorityWire.decode(ProductionPeerEnvelopeV1.self,sent[0],limit:12*1024*1024).body,try AuthorityWire.decode(ProductionPeerEnvelopeV1.self,sent[1],limit:12*1024*1024).body)
        let verified=try VerifiedPeerEnvelopeV1.verify(sent[0],grant:grant(f,binding:f.watchBinding),trust:f.trust,binding:f.watchBinding,now:clock.date),routed=try JSONDecoder().decode(MatchPacketV2.self,from:verified.payload)
        let ack=try DurableACKV2(packet:routed);try await session.acknowledgeProductionPeer(envelope(ack.canonicalBytes(),kind:.ack,f:f))
        let pending=try await repo.pendingProductionPacketsV4(matchID:"match",grant:g,now:clock.date),snapshot=try await session.snapshot(matchID:"match"),calls=await gateway.operations
        XCTAssertTrue(pending.isEmpty);XCTAssertTrue(calls.isEmpty);XCTAssertEqual(snapshot.replay.state,.endedPendingSync)
        let authority=try await repo.authorityStateV4(matchID:"match",now:clock.date);XCTAssertNil(authority.verifiedNormalRelease)
        try await repo.close()
    }
    func testProductionPeerTerminalClosesOnlyOriginalWatchTokenWithoutReleaseOrCompletion() async throws {
        let f=try fixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"production",authorityTrust:f.trust),gateway=PeerGateway(),clock=PeerClock(date:now.addingTimeInterval(2))
        let binding=try CaptureBinding(matchID:"match",recordingDeviceID:"watch"),operation=try CaptureOperation(id:"original-token",binding:binding,associatedCommandID:"watch-started",action:.start,requestedAt:now,externalToken:"original-token")
        _=try await repo.commitV2(StoreCommitV2(commandID:"original-intent",expectedGeneration:0,descriptor:MatchDescriptor(startIntent:f.descriptor.startIntent,starter:true),events:[],captureRevisions:[],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[]))
        var recorder=LiveMatchRecorder(descriptor:f.descriptor);try recorder.start(eventID:"start",sourceDeviceID:"watch",now:now)
        _=try await repo.commitV2(CaptureTransactionTests().request("watch-started",generation:1,descriptor:f.descriptor,events:recorder.events,operations:[operation],outboxID:"watch-started-delta"))
        let dispatch=try CaptureOperationUpdate(operationID:operation.id,expectedState:.pending,state:.needsReconciliation,observation:nil)
        _=try await repo.commitV2(CaptureTransactionTests().request("watch-dispatch",generation:2,descriptor:f.descriptor,updates:[dispatch]))
        let observation=try WorkoutObservation(operationID:operation.id,binding:binding,externalToken:operation.externalToken,observedAt:now,outcome:.running,window:CaptureWindow(start:now,end:nil)),revision=try CaptureRevision(id:"real-capture",binding:binding,parentID:nil,revision:1,observedAt:now,metadata:CaptureMetadata(binding:binding,segments:[CaptureSegment(id:"segment",binding:binding,workoutID:"original-workout",window:CaptureWindow(start:now,end:nil))],gaps:[])),update=try CaptureOperationUpdate(operationID:operation.id,expectedState:.needsReconciliation,state:.settled,observation:observation)
        _=try await repo.commitV2(CaptureTransactionTests().request("watch-observed",generation:3,descriptor:f.descriptor,revisions:[revision],updates:[update],outboxID:"watch-observation-delta"))
        try await repo.bindAccountV4(f.watchBinding)
        let session=MatchSession(store:repo,deviceIdentity:PeerIdentity(id:"watch"),clock:clock,ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:gateway,environment:.production),acquire=try VerifiedAuthorityReceiptV1.verify(f.acquireRaw,expected:AuthorityExpectedIntent(f.acquireIntent,accountID:"account",epoch:42),trust:f.trust)
        try await session.authorizeProductionMatch(intent:f.acquireIntent,receipt:acquire)
        let terminal=try PostMatchEditor.terminateAbnormally(terminationID:"peer-terminal",descriptor:f.descriptor,events:recorder.events,sourceDeviceID:"phone",now:now.addingTimeInterval(1)),packet=try MatchPacketV2(packetID:"peer-terminal-packet",idempotencyKey:"peer-terminal-idem",sequence:1,sourceDeviceID:"phone",targetDeviceID:"watch",descriptor:f.descriptor,events:recorder.events+[terminal],captureRevisions:[revision])
        _=try await session.receiveProductionPeer(envelope(packet.canonicalBytes(),kind:.packet,f:f,source:"phone",binding:f.watchBinding),matchID:"match")
        let deadline=Date().addingTimeInterval(3)
        while (await gateway.operations).isEmpty,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        while !(try await repo.pendingCaptureOperations(matchID:"match")).isEmpty,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let calls=await gateway.operations;XCTAssertFalse(calls.isEmpty);XCTAssertTrue(calls.allSatisfy{$0.action == .finish && $0.externalToken=="original-token"})
        let snapshot=try await session.snapshot(matchID:"match"),authority=try await repo.authorityStateV4(matchID:"match",now:clock.date)
        XCTAssertEqual(snapshot.replay.state,.incomplete);XCTAssertNil(authority.verifiedNormalRelease);XCTAssertEqual(authority.status,.held)
        try await repo.close()
    }

}
