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
    func purgeBusinessCopies(scope:CloudScope) async throws {guard try await emptyLedger.uploads(scope:scope).isEmpty,try await emptyLedger.batches(scope:scope).isEmpty,try await emptyLedger.conflicts(scope:scope).isEmpty,try await emptyLedger.saveEvidence(scope:scope).isEmpty else {throw AuthorityError.unavailable}}
    func deletePrivateZone(scope:CloudScope) async throws {cloudCalls += 1;if cloudFails {throw AuthorityError.unavailable}}
    func deleteAppCreatedWorkouts(confirmationID:String) async throws {healthCalls += 1;if healthFails {throw AuthorityError.unavailable}}
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

}
