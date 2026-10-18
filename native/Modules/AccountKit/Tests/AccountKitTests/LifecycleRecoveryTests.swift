import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import CloudSync
@testable import AccountKit
actor ControlledAccountDeletion:CloudAccountDeletionDriver,AppWorkoutDeletionDriver,LocalTransportDeletionDriver {
    let emptyLedger:any CloudLedger
    var cloudFails:Bool,healthFails:Bool
    var cloudCalls=0,healthCalls=0
    init(emptyLedger:any CloudLedger,cloudFails:Bool=false,healthFails:Bool=false){self.emptyLedger=emptyLedger;self.cloudFails=cloudFails;self.healthFails=healthFails}
    func succeed(){cloudFails=false;healthFails=false}
    func purgeBusinessCopies(_ request:LocalTransportDeletionRequest) async throws {let scope=request.scope;guard try await emptyLedger.uploads(scope:scope).isEmpty,try await emptyLedger.batches(scope:scope).isEmpty,try await emptyLedger.conflicts(scope:scope).isEmpty,try await emptyLedger.saveEvidence(scope:scope).isEmpty else {throw AuthorityError.unavailable}}
    func deletePrivateZone(scope:CloudScope) async throws {cloudCalls += 1;if cloudFails {throw AuthorityError.unavailable}}
    func deleteAppCreatedWorkouts(confirmationID:String) async throws {healthCalls += 1;if healthFails {throw AuthorityError.unavailable}}
}
actor SingleOwnedLedgerEraser:LocalTransportDeletionDriver {
    let ledger:SQLiteCloudLedger
    var requestIDs:[String]=[]
    init(_ ledger:SQLiteCloudLedger){self.ledger=ledger}
    func purgeBusinessCopies(_ request:LocalTransportDeletionRequest) async throws {
        let id="file-erasure-"+AuthorityWire.hash(Data((request.requestID+"\0"+request.requestDigest+"\0fixture-owned-file").utf8));requestIDs.append(id)
        _=try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:id,scope:request.scope))
    }
}
final class LifecycleRecoveryTests:XCTestCase,@unchecked Sendable {
    func scope(_ binding:AccountBindingV4)throws->CloudScope {try CloudScope(accountID:binding.accountID,cloudSpaceID:binding.cloudSpaceID,zoneID:"matches",activationEpoch:binding.activationEpoch)}
    func testRealRevocationDeleteCommitLossRecoversByCapabilityAndIndependentChoicesSurviveReopen() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};_=try f.command(["op":"revoker"])
        let h=try await AuthenticationRecoveryTests().harness(f)
        _=try await h.service.signIn(requestID:"delete-login",challengeRequestID:"delete-login-challenge")
        let fresh=try await h.service.signIn(requestID:"delete-fresh",challengeRequestID:"delete-fresh-challenge"),reauth=try XCTUnwrap(fresh.reauthenticationID),scope=try scope(fresh.binding)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("lifecycle-cloud.sqlite")),driver=ControlledAccountDeletion(emptyLedger:ledger,cloudFails:true)
        let service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger,cloudDeletion:driver,healthDeletion:driver,localTransportDeletion:driver)
        let saga=try await service.requestDeletion(requestID:"delete-original",reauthenticationID:reauth,cloud:.delete,local:.delete,health:.delete,healthConfirmed:true)
        _=try f.command(["op":"fault","value":"deleteAccount"])
        let lost=try await service.resumeDeletion(requestID:saga.intent.requestID);XCTAssertFalse(lost.backendDeleted);XCTAssertEqual(lost.localProgress,.pending)
        try await h.repo.close();_=try f.command(["op":"fault","value":NSNull()])
        let after=try await AuthenticationRecoveryTests().harness(f,root:h.root,signer:h.signer),reopened=LifecycleService(client:after.client,repository:after.repo,coordinator:after.session,scope:scope,ledger:ledger,cloudDeletion:driver,healthDeletion:driver,localTransportDeletion:driver)
        let partial=try await reopened.resumeDeletion(requestID:saga.intent.requestID)
        XCTAssertTrue(partial.backendDeleted);XCTAssertEqual(partial.cloudProgress,.failed);XCTAssertEqual(partial.localProgress,.completed);XCTAssertEqual(partial.healthProgress,.completed);XCTAssertFalse(partial.finished);XCTAssertEqual(partial.recoveryCapability,saga.recoveryCapability)
        try await after.repo.close();await driver.succeed()
        let last=try await AuthenticationRecoveryTests().harness(f,root:h.root,signer:h.signer),resume=LifecycleService(client:last.client,repository:last.repo,coordinator:last.session,scope:scope,ledger:ledger,cloudDeletion:driver,healthDeletion:driver,localTransportDeletion:driver)
        let final=try await resume.resumeDeletion(requestID:saga.intent.requestID);XCTAssertTrue(final.finished)
        let healthCalls=await driver.healthCalls;XCTAssertEqual(healthCalls,1);try await ledger.close()
    }
    func testIdentityChangeFencesBothDatabasesAndDiscardsOnlyOptionalAnalytics() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:true);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let optional=try await h.repo.accountBindingV4(),binding=try XCTUnwrap(optional),scope=try scope(binding),ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("lifecycle-cloud.sqlite")),bridge=CloudSessionBridge(repository:h.repo,client:h.client)
        try await bridge.attach(h.session);let upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope);try await ledger.enqueue(upload)
        let service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        let event=try AnalyticsEventV4(requestID:"optional-active",metric:.activeDay,appVersion:"1.0",osFamily:"iOS",osMajor:17,qualification:"free")
        try await service.enqueueAnalytics(event);let off=try await h.repo.pendingAnalyticsV4();XCTAssertTrue(off.isEmpty)
        try await service.setAnalyticsEnabled(true);try await service.enqueueAnalytics(event)
        try await service.identityChanged()
        let state=try await ledger.scopeState(scope:scope),pending=try await ledger.uploads(scope:scope),analytics=try await h.repo.pendingAnalyticsV4(),facts=try await h.repo.snapshotV2(matchID:start.matchID)
        XCTAssertEqual(state.issue,.accountChanged);XCTAssertEqual(pending.first?.upload,upload);XCTAssertTrue(analytics.isEmpty);XCTAssertFalse(facts.business.events.isEmpty)
        do {_=try await h.session.prepare(.quick(.teamGoal),matchID:start.matchID);XCTFail()}catch{}
        try await ledger.close()
    }
    func testNormalMigrationRejectsLocalEndedPendingBeforeAnyHTTPMutation() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway())
        let start=try await h.session.prepareStart(starter:true);_=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let end=try await h.session.prepare(.end,matchID:start.matchID);_=try await h.session.execute(end);try await waitForCapture(h.repo,matchID:start.matchID)
        let optional=try await h.repo.accountBindingV4(),binding=try XCTUnwrap(optional),scope=try scope(binding),ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("lifecycle-cloud.sqlite"))
        let service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        do {_=try await service.prepareMigration(newPhoneID:"waiting",requestID:"blocked-prepare");XCTFail()}catch {XCTAssertEqual(error as? LifecycleClientError,.pendingBusiness)}
        try await ledger.close()
    }
    func testNonemptyTransportCopiesCannotBeCalledLocallyDeletedAfterStoreErasure() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};_=try f.command(["op":"revoker"])
        let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway()),start=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        let controls=AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session)
        _=try await controls.abnormal(matchID:start.matchID,requestID:"delete-first-abnormal");try await waitForCapture(h.repo,matchID:start.matchID)
        let apple=FixtureAppleSignIn(f,subject:"fixture-subject-never-stored"),auth=AccountService(client:h.client,repository:h.repo,coordinator:h.session,deviceID:f.metadata.credential.deviceID,cloudSpaceID:"fixture-cloud",apple:apple)
        try await auth.admitCurrentIdentity(accountID:try await h.repo.accountBindingV4()?.accountID)
        let fresh=try await auth.signIn(requestID:"delete-original-phone-fresh",challengeRequestID:"delete-original-phone-challenge"),reauth=try XCTUnwrap(fresh.reauthenticationID),scope=try scope(fresh.binding)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("nonempty-transport.sqlite")),bridge=CloudSessionBridge(repository:h.repo,client:h.client);try await bridge.attach(h.session)
        let upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope);try await ledger.enqueue(upload)
        let service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        _=try await service.requestDeletion(requestID:"delete-with-local-copy",reauthenticationID:reauth,cloud:.keep,local:.delete,health:.keep,healthConfirmed:false)
        let result=try await service.resumeDeletion(requestID:"delete-with-local-copy")
        XCTAssertTrue(result.backendDeleted);XCTAssertEqual(result.localProgress,.completed);XCTAssertEqual(result.localTransportProgress,.failed);XCTAssertFalse(result.finished)
        let remaining=try await ledger.uploads(scope:scope);XCTAssertEqual(remaining.first?.originalBytes,try upload.canonicalBytes())
        let saved=try await h.repo.deletionSagaV4(requestID:"delete-with-local-copy");XCTAssertEqual(saved?.recoveryCapability,result.recoveryCapability)
        try await ledger.close()
    }

    func testActualNonemptyLedgerPurgeReopenCanRetryRemainingCloudAndHealthWithoutUnfencing() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};_=try f.command(["op":"revoker"])
        let h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway()),start=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        _=try await h.session.execute(h.session.prepare(.end,matchID:start.matchID));try await waitForCapture(h.repo,matchID:start.matchID)
        let scope=try CloudBridgeTests().scope(f),url=h.root.appendingPathComponent("one-owned-ledger.sqlite"),ledger=try SQLiteCloudLedger(url:url),bridge=CloudSessionBridge(repository:h.repo,client:h.client,policy:.development(databaseNamespace:"http-session"));try await bridge.attach(h.session)
        let upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope);try await ledger.enqueue(upload)
        _=try await CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(),sink:bridge,clock:{h.date}).synchronize()
        let evidence=try await ledger.saveEvidence(scope:scope);_=try await bridge.acceptDevelopmentSave(upload:upload,evidence:XCTUnwrap(evidence.first),ledger:ledger)
        _=try await AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session).normal(matchID:start.matchID,requestID:"purge-normal-release")
        let auth=AccountService(client:h.client,repository:h.repo,coordinator:h.session,deviceID:f.metadata.credential.deviceID,cloudSpaceID:"fixture-cloud",apple:FixtureAppleSignIn(f,subject:"fixture-subject-never-stored"));try await auth.admitCurrentIdentity(accountID:scope.accountID)
        let fresh=try await auth.signIn(requestID:"purge-fresh",challengeRequestID:"purge-fresh-challenge"),reauth=try XCTUnwrap(fresh.reauthenticationID),driver=ControlledAccountDeletion(emptyLedger:ledger,cloudFails:true,healthFails:true),eraser=SingleOwnedLedgerEraser(ledger)
        let service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger,cloudDeletion:driver,healthDeletion:driver,localTransportDeletion:eraser)
        _=try await service.requestDeletion(requestID:"purge-original-saga",reauthenticationID:reauth,cloud:.delete,local:.delete,health:.delete,healthConfirmed:true)
        let first=try await service.resumeDeletion(requestID:"purge-original-saga");XCTAssertEqual(first.localDataProgress,.completed);XCTAssertEqual(first.cloudProgress,.failed);XCTAssertEqual(first.healthProgress,.failed);XCTAssertFalse(first.finished)
        let empty=try await ledger.uploads(scope:scope);XCTAssertTrue(empty.isEmpty)
        try await h.repo.close();try await ledger.close();await driver.succeed()
        let repo=try SQLiteSessionRepository(rootDirectory:h.root,databaseNamespace:"http-session",authorityTrust:h.client.trust,cloudSavePolicy:.development(databaseNamespace:"http-session")),session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:f.metadata.credential.deviceID),clock:FixedClock(date:h.date),ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"http-session")),reopenedLedger=try SQLiteCloudLedger(url:url),reopened=LifecycleService(client:h.client,repository:repo,coordinator:session,scope:scope,ledger:reopenedLedger,cloudDeletion:driver,healthDeletion:driver,localTransportDeletion:SingleOwnedLedgerEraser(reopenedLedger))
        let discovered=try await repo.deletionSagasV4(),id=try XCTUnwrap(discovered.first?.intent.requestID),final=try await reopened.resumeDeletion(requestID:id)
        XCTAssertTrue(final.finished);XCTAssertEqual(final.recoveryCapability,first.recoveryCapability)
        let fence=try await reopenedLedger.scopeState(scope:scope);XCTAssertEqual(fence.issue,.accountChanged)
        do {try await reopenedLedger.enqueue(upload);XCTFail("a retry must never remove the permanent file fence")}catch{}
        let ids=await eraser.requestIDs;XCTAssertEqual(ids.count,1)
        try await reopenedLedger.close();try await repo.close()
    }

    func testNormalMigrationWaitsForOriginalCaptureCleanupEvenAfterAbnormalRelease() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let gateway=TrackingGateway(suspendFinish:true),h=try await HTTPAuthorityIntegrationTests().harness(f,gateway:gateway),start=try await h.session.prepareStart(starter:true)
        _=try await h.session.execute(start);try await waitForCapture(h.repo,matchID:start.matchID)
        _=try await AuthorityControlService(client:h.client,repository:h.repo,coordinator:h.session).abnormal(matchID:start.matchID,requestID:"migration-pending-cleanup")
        let deadline=Date().addingTimeInterval(3)
        while !(await gateway.operations).contains(where:{$0.action == .finish}),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let next=try await AuthenticationRecoveryTests().harness(f,subject:"fixture-subject-never-stored",deviceID:"pending-next");_=try await next.service.signIn(requestID:"pending-next-auth",challengeRequestID:"pending-next-challenge")
        let scope=try CloudBridgeTests().scope(f),ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("pending-cloud.sqlite")),service=LifecycleService(client:h.client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        do {_=try await service.prepareMigration(newPhoneID:"pending-next",requestID:"must-wait-for-original-token");XCTFail("pending capture cleanup blocks migration before HTTP")}catch{}
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT request_id FROM requests WHERE request_id='must-wait-for-original-token'"])["rows"] as? [[String:Any]]);XCTAssertTrue(rows.isEmpty)
        await gateway.releaseFinish();try? await waitForCapture(h.repo,matchID:start.matchID);try await ledger.close()
    }

}
