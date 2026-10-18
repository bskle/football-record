import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import AccountKit
final class HTTPAuthorityIntegrationTests:XCTestCase,@unchecked Sendable {
    struct Harness {
        let fixture:NodeAuthorityFixture
        let client:AuthorityClient
        let root:URL
        let repo:SQLiteSessionRepository
        let provider:AuthorityStartPermitProvider
        let session:MatchSession
        let date:Date
    }
    func harness(_ f:NodeAuthorityFixture,root:URL?=nil,gateway:any WorkoutGateway=UnavailableWorkoutGateway(),credential:DeviceCredential?=nil,privateKey:String?=nil,role:AccountBindingV4.Role = .phone) async throws -> Harness {
        let client=try f.client(credential:credential,privateKey:privateKey),meta=f.metadata,c=credential ?? meta.credential,date=Date(timeIntervalSince1970:Double(meta.now))
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"http-session",authorityTrust:client.trust,cloudSavePolicy:.development(databaseNamespace:"http-session"))
        try await repo.bindAccountV4(AccountBindingV4(accountID:c.accountID,cloudSpaceID:"fixture-cloud",deviceID:c.deviceID,activationEpoch:c.activationEpoch,role:role,environment:.development))
        let provider=AuthorityStartPermitProvider(client:client,repository:repo,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:c.deviceID),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:provider,workout:gateway,environment:.development(databaseNamespace:"http-session"))
        try await provider.attach(session)
        return Harness(fixture:f,client:client,root:root,repo:repo,provider:provider,session:session,date:date)
    }
    func testAcquireCOMMITLostResponseReopensSameIntentAndLock() async throws {
        let f=try NodeAuthorityFixture();defer { f.close() }
        let h=try await harness(f),request=try await h.session.prepareStart(starter:true)
        _=try f.command(["op":"fault","value":"acquire"])
        do { _=try await h.session.execute(request);XCTFail() } catch {}
        let pending=try await h.repo.snapshotV2(matchID:request.matchID);XCTAssertTrue(pending.business.events.isEmpty)
        try await h.repo.close();_=try f.command(["op":"fault","value":NSNull()])
        let reopened=try await harness(f,root:h.root),result=try await reopened.session.execute(request)
        XCTAssertEqual(result.snapshot.store.business.descriptor.startIntent,request.startIntent)
        let rows=try f.command(["op":"inspect","sql":"SELECT request_id,operation FROM requests WHERE operation='acquire'"])["rows"] as! [[String:Any]]
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0]["request_id"] as? String,request.commandID)
    }
    func testOldAcquireCannotStartAfterServerAbnormalTermination() async throws {
        let f=try NodeAuthorityFixture();defer { f.close() }
        let h=try await harness(f),request=try await h.session.prepareStart(starter:true)
        _=try f.command(["op":"fault","value":"acquire"])
        do { _=try await h.session.execute(request);XCTFail() } catch {}
        _=try f.command(["op":"fault","value":NSNull()])
        let acquireRaw=try await h.client.query(requestID:request.commandID)
        let control=try ControlIntentV1.acquire(request.startIntent!,epoch:f.metadata.credential.activationEpoch)
        let acquired=try VerifiedAuthorityReceiptV1.verify(acquireRaw,expected:AuthorityExpectedIntent(control,accountID:f.metadata.credential.accountID,epoch:f.metadata.credential.activationEpoch),trust:h.client.trust)
        var fields=AuthorityFields();fields.matchID=request.matchID;fields.lockID=acquired.body.lockID;fields.recordingDeviceID=request.startIntent!.recordingDeviceID;fields.activationEpoch=f.metadata.credential.activationEpoch;fields.mode="abnormal"
        _=try await h.client.send(ControlIntentV1(requestID:UUID().uuidString,operation:.terminate,fields:fields))
        do { _=try await h.session.execute(request);XCTFail("old acquire must not resurrect a terminal lock") } catch {}
        let snapshot=try await h.repo.snapshotV2(matchID:request.matchID),state=try await h.repo.authorityStateV4(matchID:request.matchID,now:h.date)
        XCTAssertTrue(snapshot.business.events.isEmpty);XCTAssertTrue(snapshot.captureOperations.isEmpty);XCTAssertEqual(state.status,.terminal)
    }
    func testLiveStatusTimeoutKeepsOriginalStartForReconciliation() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let h=try await harness(f),request=try await h.session.prepareStart(starter:false)
        _=try f.command(["op":"fault","value":"liveStatus"])
        do { _=try await h.session.execute(request);XCTFail() } catch {}
        let before=try await h.repo.snapshotV2(matchID:request.matchID);XCTAssertTrue(before.business.events.isEmpty)
        _=try f.command(["op":"fault","value":NSNull()])
        let result=try await h.session.execute(request);XCTAssertEqual(result.snapshot.store.business.descriptor.startIntent,request.startIntent)
    }
    func testRelayKeepsExactOriginalSignedRequestAndNonceReplayIsRejected() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let client=try f.client(),c=f.metadata.credential
        let start=StartIntent(id:"relay-start",matchID:"relay-match",recordingDeviceID:c.deviceID,requestedAt:Date(timeIntervalSince1970:Double(f.metadata.now)))
        let intent=try ControlIntentV1.acquire(start,epoch:c.activationEpoch)
        let signed=try await client.signedRequest(path:intent.operation.path,body:intent.canonicalRequest,requestID:intent.requestID)
        let proxy=try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development)
        let forward=try AuthorityHTTPRequest.opaqueRelay(method:signed.method,path:signed.path,body:signed.body,authorization:XCTUnwrap(signed.authorization),deviceProof:XCTUnwrap(signed.deviceProof))
        XCTAssertEqual(forward.method,signed.method);XCTAssertEqual(forward.path,signed.path);XCTAssertEqual(forward.body,signed.body);XCTAssertEqual(forward.authorization,signed.authorization);XCTAssertEqual(forward.deviceProof,signed.deviceProof)
        let response=try await proxy.send(forward);XCTAssertEqual(response.status,200)
        let replay=try await proxy.send(signed);XCTAssertEqual(replay.status,401)
        let original=try VerifiedAuthorityReceiptV1.verify(response.body,expected:AuthorityExpectedIntent(intent,accountID:c.accountID,epoch:c.activationEpoch),trust:client.trust)
        let query=try await client.query(requestID:intent.requestID);XCTAssertEqual(query,original.raw)
    }
    func testReopenedStartedMatchUsesFreshAuthorityAndTerminalOnlyFinishesOriginalToken() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let original=TrackingGateway(),h=try await harness(f,gateway:original),request=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(request);try await waitForCapture(h.repo,matchID:request.matchID)
        let state=try await h.repo.authorityStateV4(matchID:request.matchID,now:h.date)
        var fields=AuthorityFields();fields.matchID=request.matchID;fields.lockID=state.acquire!.body.lockID;fields.recordingDeviceID=request.startIntent!.recordingDeviceID;fields.activationEpoch=f.metadata.credential.activationEpoch;fields.mode="abnormal"
        _=try await h.client.send(ControlIntentV1(requestID:UUID().uuidString,operation:.terminate,fields:fields))
        try await h.repo.close()
        let after=TrackingGateway(),reopened=try await harness(f,root:h.root,gateway:after)
        _=try await reopened.session.recover()
        try await Task.sleep(for:.milliseconds(100))
        let operations=await after.operations
        XCTAssertFalse(operations.contains(where:{$0.action == .start || $0.action == .resume || $0.action == .recover}),"terminal authority must not recreate or resume a Workout")
        let current=try await reopened.repo.authorityStateV4(matchID:request.matchID,now:h.date)
        XCTAssertEqual(current.status,.terminal)
        XCTAssertTrue(operations.allSatisfy({$0.action == .finish && $0.externalToken==request.captureOperationID}))
    }
    func testStartedOriginalMatchCanRecoverAndReplaceSegmentWhenStatusNetworkFails() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let original=TrackingGateway(),h=try await harness(f,gateway:original),request=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(request);try await waitForCapture(h.repo,matchID:request.matchID);try await h.repo.close()
        _=try f.command(["op":"fault","value":"liveStatus"])
        let after=TrackingGateway(),reopened=try await harness(f,root:h.root,gateway:after)
        let recovered=try await reopened.session.recover()
        if case .active(let value)=recovered {XCTAssertEqual(value.store.business.descriptor.recordingDeviceID,request.startIntent!.recordingDeviceID)} else {XCTFail("offline recovery must remain available for an established match")}
        let deadline=Date().addingTimeInterval(3)
        while !(await after.operations).contains(where:{$0.action == .start}),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let operations=await after.operations
        XCTAssertTrue(operations.contains(where:{$0.action == .recover}));XCTAssertTrue(operations.contains(where:{$0.action == .start}))
        XCTAssertTrue(operations.allSatisfy({$0.binding.matchID==request.matchID && $0.binding.recordingDeviceID==request.startIntent!.recordingDeviceID}))
    }
    func terminateOnServer(_ h:Harness,request:SessionRequest) async throws {
        let state=try await h.repo.authorityStateV4(matchID:request.matchID,now:h.date)
        var fields=AuthorityFields();fields.matchID=request.matchID;fields.lockID=state.acquire!.body.lockID;fields.recordingDeviceID=request.startIntent!.recordingDeviceID;fields.activationEpoch=h.fixture.metadata.credential.activationEpoch;fields.mode="abnormal"
        _=try await h.client.send(ControlIntentV1(requestID:UUID().uuidString,operation:.terminate,fields:fields))
        let query=try LiveLockQueryV1(requestID:UUID().uuidString,acquireRequestID:request.commandID,matchID:request.matchID,lockID:state.acquire!.body.lockID,recordingDeviceID:request.startIntent!.recordingDeviceID,activationEpoch:h.fixture.metadata.credential.activationEpoch,nonce:UUID().uuidString)
        try await h.session.acceptLiveLock(h.client.liveStatus(query,accountID:h.fixture.metadata.credential.accountID))
    }
    func testPersistedTerminalFenceSurvivesReopenEvenWhenNetworkIsUnavailable() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let first=TrackingGateway(),h=try await harness(f,gateway:first),request=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(request);try await waitForCapture(h.repo,matchID:request.matchID)
        try await terminateOnServer(h,request:request);try await waitForCapture(h.repo,matchID:request.matchID);try await h.repo.close()
        _=try f.command(["op":"fault","value":"liveStatus"])
        let next=TrackingGateway(),reopened=try await harness(f,root:h.root,gateway:next)
        _=try await reopened.session.recover();try await Task.sleep(for:.milliseconds(30))
        let actions=await next.operations;XCTAssertFalse(actions.contains(where:{$0.action != .finish}))
        let state=try await reopened.repo.authorityStateV4(matchID:request.matchID,now:h.date);XCTAssertEqual(state.status,.terminal)
    }
    func testTerminalLearnedWhileRecoveryCallbackIsSuspendedCannotCreateReplacement() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let first=TrackingGateway(),h=try await harness(f,gateway:first),request=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(request);try await waitForCapture(h.repo,matchID:request.matchID);try await h.repo.close()
        let next=TrackingGateway(suspendRecovery:true),reopened=try await harness(f,root:h.root,gateway:next)
        _=try await reopened.session.recover()
        for _ in 0..<100 {if await next.operations.contains(where:{$0.action == .recover}) {break};try await Task.sleep(for:.milliseconds(5))}
        try await terminateOnServer(reopened,request:request)
        await next.releaseRecovery();try await Task.sleep(for:.milliseconds(60))
        let operations=await next.operations;XCTAssertFalse(operations.contains(where:{$0.action == .start || $0.action == .resume}))
    }
    func testOriginalSessionStartsThroughRealNodeHTTPAndPersistsOriginalIDs() async throws {
        let f=try NodeAuthorityFixture();defer { f.close() }
        let client=try f.client(),meta=f.metadata,date=Date(timeIntervalSince1970:Double(meta.now))
        let repo=try SQLiteSessionRepository(rootDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),databaseNamespace:"http-session",authorityTrust:client.trust,cloudSavePolicy:.development(databaseNamespace:"http-session"))
        try await repo.bindAccountV4(AccountBindingV4(accountID:meta.credential.accountID,cloudSpaceID:"fixture-cloud",deviceID:meta.credential.deviceID,activationEpoch:meta.credential.activationEpoch,role:.phone,environment:.development))
        let provider=AuthorityStartPermitProvider(client:client,repository:repo,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:meta.credential.deviceID),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:provider,workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"http-session"))
        try await provider.attach(session)
        let request=try await session.prepareStart(starter:true),result=try await session.execute(request)
        XCTAssertEqual(result.snapshot.store.business.descriptor.startIntent,request.startIntent)
        XCTAssertEqual(result.snapshot.store.business.descriptor.startPermit,DevelopmentStartFixture.permit(for:request.startIntent!))
        let state=try await repo.authorityStateV4(matchID:request.matchID,now:date)
        XCTAssertEqual(state.status,.held);XCTAssertEqual(state.latestLive?.body.status,.held)
    }
    func testAbnormalCommitsLocalIncompleteAndStableControlBeforeNetworkThenReopensRetry() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:true);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let service=AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session)
        _=try f.command(["op":"fault","value":"terminate"])
        do {_=try await service.abnormal(matchID:start.matchID,requestID:"abnormal-control");XCTFail()}catch{}
        let local=try await h.repo.snapshotV2(matchID:start.matchID),pending=try await h.repo.pendingControlsV4()
        XCTAssertEqual(try local.business.replay(now:h.date).state,.incomplete)
        let intent=try XCTUnwrap(pending.first(where:{$0.requestID=="abnormal-control"}))
        XCTAssertEqual(local.business.events.filter {$0.type == .matchTerminated}.count,1)
        try await h.repo.close();_=try f.command(["op":"fault","value":NSNull()])
        let after=TrackingGateway(),reopened=try await harness(f,root:h.root,gateway:after),retry=AuthorityControlService(client:reopened.client,repository:reopened.repo,coordinator:reopened.session)
        let release=try await retry.reconcile(intent);XCTAssertEqual(release.body.result,.releasedAbnormal)
        _=try await reopened.session.recover();try await Task.sleep(for:.milliseconds(40))
        let actions=await after.operations;XCTAssertTrue(actions.allSatisfy({$0.action == .finish && $0.externalToken==start.captureOperationID}))
        let result=try await reopened.repo.snapshotV2(matchID:start.matchID);XCTAssertEqual(try result.business.replay(now:h.date).state,.incomplete)
    }

}
