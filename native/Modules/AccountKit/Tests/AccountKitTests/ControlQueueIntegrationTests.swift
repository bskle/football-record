import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import CloudSync
@testable import AccountKit
final class ControlQueueIntegrationTests:XCTestCase,@unchecked Sendable {
    func testUnpreparedControlCannotMutateRealAuthority() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway()),start=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let state=try await h.repo.authorityStateV4(matchID:start.matchID,now:h.date),a=try XCTUnwrap(state.acquire)
        var fields=AuthorityFields();fields.matchID=start.matchID;fields.lockID=a.body.lockID;fields.recordingDeviceID=a.body.recordingDeviceID;fields.activationEpoch=a.body.activationEpoch;fields.mode="abnormal"
        let unsafe=try ControlIntentV1(requestID:"unprepared-release",operation:.terminate,fields:fields),service=AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session)
        do {_=try await service.reconcile(unsafe);XCTFail()}catch{}
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT request_id FROM requests WHERE request_id='unprepared-release'"])["rows"] as? [[String:Any]])
        XCTAssertTrue(rows.isEmpty,"an unprepared control must stop before HTTP")
        let generic=try ControlIntentV1(requestID:"generic-prepared-release",operation:.terminate,fields:fields)
        _=try await h.session.prepareAuthorityControl(generic)
        do {_=try await service.reconcile(generic);XCTFail()}catch{}
        let preparedRows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT request_id FROM requests WHERE request_id='generic-prepared-release'"])["rows"] as? [[String:Any]])
        XCTAssertTrue(preparedRows.isEmpty,"generic control persistence does not replace the dedicated incomplete transaction")
    }
    func testSuccessfulLifecycleControlIsNotAnUnresolvedControlAfterReopen() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let old=try await HTTPAuthorityIntegrationTests().harness(f),next=try await AuthenticationRecoveryTests().harness(f,subject:"fixture-subject-never-stored",deviceID:"queue-next")
        _=try await next.service.signIn(requestID:"queue-waiting",challengeRequestID:"queue-waiting-challenge")
        let scope=try CloudBridgeTests().scope(f),ledger=try SQLiteCloudLedger(url:old.root.appendingPathComponent("queue-cloud.sqlite")),service=LifecycleService(client:old.client,repository:old.repo,coordinator:old.session,scope:scope,ledger:ledger)
        _=try await service.prepareMigration(newPhoneID:"queue-next",requestID:"queue-prepare")
        try await old.repo.close();let after=try await HTTPAuthorityIntegrationTests().harness(f,root:old.root),pending=try await after.repo.pendingControlsV4();XCTAssertTrue(pending.isEmpty)
        try await ledger.close()
    }
    func testActualDevelopmentHTTPGrantIncludesSignedRolesButCannotBecomeProductionContext() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f)
        let response=try f.command(["op":"watch","deviceID":"grant-watch"])
        let bytes=try JSONSerialization.data(withJSONObject:response["credential"]!),watch=try JSONDecoder().decode(DeviceCredential.self,from:bytes)
        var fields=AuthorityFields();fields.localDeviceID=f.metadata.credential.deviceID;fields.remoteDeviceID=watch.deviceID;fields.activationEpoch=f.metadata.credential.activationEpoch;fields.pairingID="signed-role-pair"
        let intent=try ControlIntentV1(requestID:"actual-development-grant",operation:.peerGrant,fields:fields),raw=try await h.client.send(intent),receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:f.metadata.credential.accountID,epoch:f.metadata.credential.activationEpoch),trust:h.client.trust)
        XCTAssertEqual(receipt.body.peerGrant?.localRole,"phone");XCTAssertEqual(receipt.body.peerGrant?.remoteRole,"watch");XCTAssertEqual(receipt.body.peerGrant?.activePhoneID,f.metadata.credential.deviceID)
        let bindingValue=try await h.repo.accountBindingV4(),binding=try XCTUnwrap(bindingValue)
        XCTAssertThrowsError(try VerifiedPeerGrantV1.verify(raw,intent:intent,trust:h.client.trust,binding:binding,now:h.date))
        let service=ProductionPeerService(client:h.client,repository:h.repo,coordinator:h.session)
        do {_=try await service.requestGrant(localDeviceID:binding.deviceID,remoteDeviceID:watch.deviceID,pairingID:"must-not-upgrade",requestID:"must-not-upgrade");XCTFail()}catch{}
    }

}
