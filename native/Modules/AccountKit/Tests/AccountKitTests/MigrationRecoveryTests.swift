import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import CloudSync
@testable import AccountKit
final class MigrationRecoveryTests:XCTestCase,@unchecked Sendable {
    func normalMigration(nonempty:Bool,secondRound:Bool=false) async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let old=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway()),scope=try CloudBridgeTests().scope(f),ledger=try SQLiteCloudLedger(url:old.root.appendingPathComponent("migration-cloud.sqlite"))
        let bridge=CloudSessionBridge(repository:old.repo,client:old.client,policy:.development(databaseNamespace:"http-session"));try await bridge.attach(old.session)
        let started:SessionRequest?
        if nonempty {
            let start=try await old.session.prepareStart(starter:true);_=try await old.session.execute(start);try await waitForCapture(old.repo,matchID:start.matchID)
            let end=try await old.session.prepare(.end,matchID:start.matchID);_=try await old.session.execute(end);try await waitForCapture(old.repo,matchID:start.matchID)
            let upload=try await bridge.prepareUpload(matchID:start.matchID,scope:scope);try await ledger.enqueue(upload)
            let sync=CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(),sink:bridge,clock:{old.date});_=try await sync.synchronize()
            let evidence=try await ledger.saveEvidence(scope:scope);_=try await bridge.acceptDevelopmentSave(upload:upload,evidence:evidence[0],ledger:ledger)
            _=try await AuthorityControlService(client:old.client,repository:old.repo,coordinator:old.session).normal(matchID:start.matchID,requestID:"migration-old-release");started=start
        } else {started=nil}
        let next=try await AuthenticationRecoveryTests().harness(f,subject:"fixture-subject-never-stored",deviceID:"next-phone")
        let waiting=try await next.service.signIn(requestID:"next-waiting",challengeRequestID:"next-waiting-challenge");XCTAssertEqual(waiting.binding.role,.waiting)
        let service=LifecycleService(client:old.client,repository:old.repo,coordinator:old.session,scope:scope,ledger:ledger)
        let prepare=try await service.prepareMigration(newPhoneID:"next-phone",requestID:"migration-prepare"),migration=try XCTUnwrap(prepare.body.migration)
        let upload=try await service.prepareFinalCheckpoint(checkpointID:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!)
        guard case .checkpoint(let checkpoint)=try upload.record.payload else {return XCTFail()}
        XCTAssertEqual(checkpoint.recordIDs.count,nonempty ? 1:0);XCTAssertEqual(checkpoint.matchID,CloudCheckpoint.accountMatchID(for:scope))
        let sync=CloudSyncService(scope:scope,ledger:ledger,driver:ReadbackCloudDriver(),sink:bridge,clock:{old.date});let result=try await sync.synchronize();XCTAssertNil(result.issue)
        let evidence=try await ledger.saveEvidence(scope:scope),proof=try XCTUnwrap(evidence.first(where:{$0.uploadID==upload.id}))
        try await service.acceptDevelopmentFinalCheckpoint(upload:upload,evidence:proof,migrationID:migration.migrationID)
        let accepted=try await service.commitMigrationCheckpoint(migrationID:migration.migrationID,requestID:"migration-checkpoint")
        XCTAssertEqual(accepted.body.migration?.checkpointID,upload.record.recordID);XCTAssertEqual(accepted.body.migration?.contentCommitment,upload.record.digest)
        let nextLedger=try SQLiteCloudLedger(url:next.root.appendingPathComponent("next-cloud.sqlite")),nextService=LifecycleService(client:next.client,repository:next.repo,coordinator:next.session,scope:scope,ledger:nextLedger)
        let savedPrepare=try await old.repo.lifecycleControlIntentV4(requestID:"migration-prepare"),savedCheckpoint=try await old.repo.lifecycleControlIntentV4(requestID:"migration-checkpoint"),prepareIntent=try XCTUnwrap(savedPrepare),checkpointIntent=try XCTUnwrap(savedCheckpoint)
        try await nextService.learnMigration(intent:prepareIntent,raw:prepare.raw);try await nextService.learnMigration(intent:checkpointIntent,raw:accepted.raw)
        do {_=try await nextService.activateMigration(migrationID:migration.migrationID,requestID:"must-download-first");XCTFail()}catch{}
        let records=try await ledger.uploads(scope:scope).map(\.upload.record)
        let nextBridge=CloudSessionBridge(repository:next.repo,client:next.client);try await nextBridge.attach(next.session)
        let batch=try CloudFetchBatch(scope:scope,batchID:"full-final-download",records:records,expectedAppliedToken:nil,nextToken:Data([1,2]),fetchGeneration:0,moreComing:false)
        _=try await nextBridge.importBatch(batch)
        let activated=try await nextService.activateMigration(migrationID:migration.migrationID,requestID:"activate-after-download");XCTAssertEqual(activated.body.result,.activated)
        try await next.service.admitCurrentIdentity(accountID:try await next.repo.accountBindingV4()?.accountID)
        guard case .knownRevoked=try await next.service.recover(authRequestID:"next-waiting") else {return XCTFail()}
        try await next.service.admitCurrentIdentity(accountID:try await next.repo.accountBindingV4()?.accountID)
        let fresh=try await next.service.signIn(requestID:"next-active-fresh",challengeRequestID:"next-active-challenge");XCTAssertEqual(fresh.binding.role,.phone);XCTAssertGreaterThan(fresh.binding.activationEpoch,waiting.binding.activationEpoch)
        let ids=try await next.repo.matchIDs();XCTAssertTrue(ids.isEmpty)
        if let started {let history=try await next.repo.cloudHistoryV4(scope:CloudSessionBridge.coreScope(scope));XCTAssertEqual(history.first?.facts.startIntent,started.startIntent);do {try await next.repo.validateAuthorityStartV4(started.startIntent!,now:old.date);XCTFail()}catch{}}
        if secondRound {
            try await next.repo.close()
            let reopened=try await AuthenticationRecoveryTests().harness(f,root:next.root,signer:next.signer,subject:"fixture-subject-never-stored",deviceID:"next-phone")
            guard case .authenticated=try await reopened.service.recover(authRequestID:"next-active-fresh") else {return XCTFail()}
            let newScope=try CloudScope(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:fresh.binding.activationEpoch)
            let again=LifecycleService(client:reopened.client,repository:reopened.repo,coordinator:reopened.session,scope:newScope,ledger:nextLedger)
            let third=try await AuthenticationRecoveryTests().harness(f,subject:"fixture-subject-never-stored",deviceID:"third-phone")
            _=try await third.service.signIn(requestID:"third-waiting",challengeRequestID:"third-waiting-challenge")
            let secondPrepare=try await again.prepareMigration(newPhoneID:"third-phone",requestID:"second-migration-prepare"),second=try XCTUnwrap(secondPrepare.body.migration)
            XCTAssertNotEqual(second.migrationID,migration.migrationID)
            // Historical first receipts must return without projecting an earlier round over the current one.
            _=try await again.reconcileLifecycle(prepareIntent)
            _=try await again.reconcileLifecycle(checkpointIntent)
            let firstActivationValue=try await reopened.repo.lifecycleControlIntentV4(requestID:"activate-after-download"),firstActivation=try XCTUnwrap(firstActivationValue)
            _=try await again.reconcileLifecycle(firstActivation)
            let stillSecond=try await reopened.repo.latestMigrationV4();XCTAssertEqual(stillSecond?.migrationID,second.migrationID);XCTAssertEqual(stillSecond?.state,"oldPhonePrepared")
            let secondUpload=try await again.prepareFinalCheckpoint(checkpointID:UUID(uuidString:"11223344-5566-7788-99aa-bbccddeeff00")!)
            let newBridge=CloudSessionBridge(repository:reopened.repo,client:reopened.client,policy:.development(databaseNamespace:"auth-session"));try await newBridge.attach(reopened.session)
            let secondSync=try await CloudSyncService(scope:newScope,ledger:nextLedger,driver:ReadbackCloudDriver(),sink:newBridge,clock:{old.date}).synchronize();XCTAssertNil(secondSync.issue)
            let secondEvidence=try await nextLedger.saveEvidence(scope:newScope);try await again.acceptDevelopmentFinalCheckpoint(upload:secondUpload,evidence:XCTUnwrap(secondEvidence.first(where:{$0.uploadID==secondUpload.id})),migrationID:second.migrationID)
            let secondAccepted=try await again.commitMigrationCheckpoint(migrationID:second.migrationID,requestID:"second-migration-checkpoint")
            let thirdLedger=try SQLiteCloudLedger(url:third.root.appendingPathComponent("third-cloud.sqlite")),thirdService=LifecycleService(client:third.client,repository:third.repo,coordinator:third.session,scope:newScope,ledger:thirdLedger)
            let secondPrepareValue=try await reopened.repo.lifecycleControlIntentV4(requestID:"second-migration-prepare"),secondCheckpointValue=try await reopened.repo.lifecycleControlIntentV4(requestID:"second-migration-checkpoint"),secondPrepareIntent=try XCTUnwrap(secondPrepareValue),secondCheckpointIntent=try XCTUnwrap(secondCheckpointValue)
            try await thirdService.learnMigration(intent:secondPrepareIntent,raw:secondPrepare.raw);try await thirdService.learnMigration(intent:secondCheckpointIntent,raw:secondAccepted.raw)
            let thirdBridge=CloudSessionBridge(repository:third.repo,client:third.client);try await thirdBridge.attach(third.session)
            _=try await thirdBridge.importBatch(CloudFetchBatch(scope:newScope,batchID:"second-download",records:[secondUpload.record],expectedAppliedToken:nil,nextToken:Data([3]),fetchGeneration:0,moreComing:false))
            _=try await thirdService.activateMigration(migrationID:second.migrationID,requestID:"second-activate")
            try await third.service.admitCurrentIdentity(accountID:try await third.repo.accountBindingV4()?.accountID)
            let thirdFresh=try await third.service.signIn(requestID:"third-active-fresh",challengeRequestID:"third-active-challenge");XCTAssertGreaterThan(thirdFresh.binding.activationEpoch,fresh.binding.activationEpoch)
            let savedFirst=try await reopened.repo.lifecycleReceiptV4(requestID:"activate-after-download");XCTAssertEqual(savedFirst,activated.raw)
            try await reopened.repo.close();try await thirdLedger.close()
        }
        try await ledger.close();try await nextLedger.close()
    }
    func testTwoNormalMigrationRoundsReopenAndOldReceiptsNeverRollbackCurrentRound() async throws {try await normalMigration(nonempty:false,secondRound:true)}
    func testEmptyAccountFinalCheckpointAndNewPhoneActivationRequireDownloadedControl() async throws {try await normalMigration(nonempty:false)}
    func testFullOriginalSessionFactsFinalCheckpointRestoreHistoryWithoutOldRecordingRights() async throws {try await normalMigration(nonempty:true)}
    func testLostPhoneSevenDaysRequiresFreshReauthAndExactOriginalLockWithoutRecordingTakeover() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let old=try await HTTPAuthorityIntegrationTests().harness(f,gateway:TrackingGateway()),start=try await old.session.prepareStart(starter:true)
        _=try await old.session.execute(start);try await waitForCapture(old.repo,matchID:start.matchID)
        let oldState=try await old.repo.authorityStateV4(matchID:start.matchID,now:old.date),original=try XCTUnwrap(oldState.acquire),scope=try CloudBridgeTests().scope(f)
        let next=try await AuthenticationRecoveryTests().harness(f,subject:"fixture-subject-never-stored",deviceID:"lost-next")
        _=try await next.service.signIn(requestID:"lost-waiting",challengeRequestID:"lost-waiting-challenge")
        let ledger=try SQLiteCloudLedger(url:next.root.appendingPathComponent("lost-cloud.sqlite")),service=LifecycleService(client:next.client,repository:next.repo,coordinator:next.session,scope:scope,ledger:ledger)
        let requested=try await service.requestLostMigration(requestID:"lost-request"),migration=try XCTUnwrap(requested.body.migration)
        XCTAssertEqual(migration.eligibleAt-migration.requestedAt,604800)
        try await next.repo.close();_=try f.command(["op":"clock","now":migration.eligibleAt-1])
        let early=try await AuthenticationRecoveryTests().harness(f,root:next.root,signer:next.signer,subject:"fixture-subject-never-stored",now:Date(timeIntervalSince1970:Double(migration.eligibleAt-1)),deviceID:"lost-next")
        let earlyFresh=try await early.service.signIn(requestID:"early-fresh",challengeRequestID:"early-challenge"),earlyID=try XCTUnwrap(earlyFresh.reauthenticationID),earlyService=LifecycleService(client:early.client,repository:early.repo,coordinator:early.session,scope:scope,ledger:ledger)
        do {_=try await earlyService.forceMigration(migrationID:migration.migrationID,reauthenticationID:earlyID,requestID:"early-force");XCTFail()}catch{}
        let persisted=try await early.repo.latestMigrationV4();XCTAssertEqual(persisted?.eligibleAt,migration.eligibleAt)
        try await early.repo.close();_=try f.command(["op":"clock","now":migration.eligibleAt])
        let ready=try await AuthenticationRecoveryTests().harness(f,root:next.root,signer:next.signer,subject:"fixture-subject-never-stored",now:Date(timeIntervalSince1970:Double(migration.eligibleAt)),deviceID:"lost-next"),readyService=LifecycleService(client:ready.client,repository:ready.repo,coordinator:ready.session,scope:scope,ledger:ledger)
        let fresh=try await ready.service.signIn(requestID:"eligible-fresh",challengeRequestID:"eligible-challenge"),reauth=try XCTUnwrap(fresh.reauthenticationID)
        do {_=try await readyService.requestLostRecovery(migrationID:migration.migrationID,originalAcquire:original,reauthenticationID:earlyID,confirmedAt:migration.eligibleAt,requestID:"stale-apple-grant");XCTFail()}catch{}
        do {_=try await readyService.forceMigration(migrationID:migration.migrationID,reauthenticationID:reauth,requestID:"held-force");XCTFail()}catch{}
        let grant=try await readyService.requestLostRecovery(migrationID:migration.migrationID,originalAcquire:original,reauthenticationID:reauth,confirmedAt:migration.eligibleAt,requestID:"narrow-grant")
        XCTAssertEqual(grant.body.recordingDeviceID,start.startIntent?.recordingDeviceID)
        let release=try await readyService.terminateLost(grant:grant,requestID:"lost-original-release");XCTAssertEqual(release.body.result,.releasedAbnormal);XCTAssertEqual(release.body.matchID,start.matchID)
        let newIDs=try await ready.repo.matchIDs();XCTAssertTrue(newIDs.isEmpty)
        do {_=try await readyService.forceMigration(migrationID:migration.migrationID,reauthenticationID:reauth,requestID:"used-reauth-force");XCTFail()}catch{}
        let again=try await ready.service.signIn(requestID:"force-fresh",challengeRequestID:"force-fresh-challenge"),forceID=try XCTUnwrap(again.reauthenticationID)
        let activated=try await readyService.forceMigration(migrationID:migration.migrationID,reauthenticationID:forceID,requestID:"eligible-force");XCTAssertGreaterThan(activated.body.activationEpoch,scope.activationEpoch)
        try await ready.service.admitCurrentIdentity(accountID:try await ready.repo.accountBindingV4()?.accountID)
        let active=try await ready.service.signIn(requestID:"lost-active-fresh",challengeRequestID:"lost-active-challenge");XCTAssertEqual(active.binding.role,.phone)
        let noOldMatch=try await ready.repo.matchIDs();XCTAssertTrue(noOldMatch.isEmpty)
        let oldFacts=try await old.repo.snapshotV2(matchID:start.matchID);XCTAssertEqual(try oldFacts.business.replay(now:old.date).state,.running)
        try await ledger.close()
    }

}
