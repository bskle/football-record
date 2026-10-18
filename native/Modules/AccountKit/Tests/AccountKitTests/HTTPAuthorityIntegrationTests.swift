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
    func harness(_ f:NodeAuthorityFixture,root:URL?=nil) async throws -> Harness {
        let client=try f.client(),meta=f.metadata,date=Date(timeIntervalSince1970:Double(meta.now))
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"http-session",authorityTrust:client.trust)
        try await repo.bindAccountV4(AccountBindingV4(accountID:meta.credential.accountID,cloudSpaceID:"fixture-cloud",deviceID:meta.credential.deviceID,activationEpoch:meta.credential.activationEpoch,role:.phone,environment:.development))
        let provider=AuthorityStartPermitProvider(client:client,repository:repo,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:meta.credential.deviceID),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:provider,workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"http-session"))
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
        let response=try await proxy.send(signed);XCTAssertEqual(response.status,200)
        let replay=try await proxy.send(signed);XCTAssertEqual(replay.status,401)
        let original=try VerifiedAuthorityReceiptV1.verify(response.body,expected:AuthorityExpectedIntent(intent,accountID:c.accountID,epoch:c.activationEpoch),trust:client.trust)
        let query=try await client.query(requestID:intent.requestID);XCTAssertEqual(query,original.raw)
    }
    func testOriginalSessionStartsThroughRealNodeHTTPAndPersistsOriginalIDs() async throws {
        let f=try NodeAuthorityFixture();defer { f.close() }
        let client=try f.client(),meta=f.metadata,date=Date(timeIntervalSince1970:Double(meta.now))
        let repo=try SQLiteSessionRepository(rootDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),databaseNamespace:"http-session",authorityTrust:client.trust)
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
}
