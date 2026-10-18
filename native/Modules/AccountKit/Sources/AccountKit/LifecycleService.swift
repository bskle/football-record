import Foundation
import MatchCore
import MatchStore
import MatchSession
import CloudSync
public enum LifecycleClientError:Error,Sendable,Equatable {case pendingBusiness,pendingCloud,cloudConflict,invalidCheckpoint,receiptExpired,reauthenticationRequired,unknownOriginal}
public protocol CloudAccountDeletionDriver:Sendable {func deletePrivateZone(scope:CloudScope) async throws}
public struct LocalTransportDeletionRequest:Sendable {
    public let scope:CloudScope
    public let requestID,requestDigest:String
    public init(scope:CloudScope,saga:DeletionSagaV4)throws {guard saga.backendDeleted,saga.localChoice == .delete,saga.accountID==scope.accountID,saga.activationEpoch==scope.activationEpoch else {throw AuthorityError.intentMismatch};self.scope=scope;requestID=saga.intent.requestID;requestDigest=saga.intent.digest}
}
public protocol LocalTransportDeletionDriver:Sendable {func purgeBusinessCopies(_ request:LocalTransportDeletionRequest) async throws}
public struct UnavailableLocalTransportDeletionDriver:LocalTransportDeletionDriver {public init(){};public func purgeBusinessCopies(_ request:LocalTransportDeletionRequest) async throws {throw AuthorityError.unavailable}}
public protocol AppWorkoutDeletionDriver:Sendable {func deleteAppCreatedWorkouts(confirmationID:String) async throws}
public struct UnavailableCloudAccountDeletionDriver:CloudAccountDeletionDriver {public init(){};public func deletePrivateZone(scope:CloudScope) async throws {throw AuthorityError.unavailable}}
public struct UnavailableAppWorkoutDeletionDriver:AppWorkoutDeletionDriver {public init(){};public func deleteAppCreatedWorkouts(confirmationID:String) async throws {throw AuthorityError.unavailable}}
public actor LifecycleService {
    let client:AuthorityClient
    let repository:any SessionRepository & AuthorityRepository & CloudImportRepository & LifecycleStateRepository & AccountLifecycleRepository
    let coordinator:any LifecycleInboundCoordinator
    let scope:CloudScope
    let ledger:any CloudLedger
    let cloudDeletion:any CloudAccountDeletionDriver
    let healthDeletion:any AppWorkoutDeletionDriver
    let localTransportDeletion:any LocalTransportDeletionDriver
    public init(client:AuthorityClient,repository:any SessionRepository & AuthorityRepository & CloudImportRepository & LifecycleStateRepository & AccountLifecycleRepository,coordinator:any LifecycleInboundCoordinator,scope:CloudScope,ledger:any CloudLedger,cloudDeletion:any CloudAccountDeletionDriver=UnavailableCloudAccountDeletionDriver(),healthDeletion:any AppWorkoutDeletionDriver=UnavailableAppWorkoutDeletionDriver(),localTransportDeletion:any LocalTransportDeletionDriver=UnavailableLocalTransportDeletionDriver()){self.client=client;self.repository=repository;self.coordinator=coordinator;self.scope=scope;self.ledger=ledger;self.cloudDeletion=cloudDeletion;self.healthDeletion=healthDeletion;self.localTransportDeletion=localTransportDeletion}

    func facade() async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged}}
    func binding(allowSuspended:Bool=false) async throws->AccountBindingV4 {
        try await facade();guard let b=try await repository.accountBindingV4(),(allowSuspended || !b.suspended),b.accountID==scope.accountID,b.cloudSpaceID==scope.cloudSpaceID,b.activationEpoch==scope.activationEpoch,b.environment==client.trust.environment else {throw AuthorityError.identityChanged};return b
    }
    func fenceTransport() async throws {
        do {try await ledger.recordScopeIssue(scope:scope,issue:.accountChanged,at:client.now(),nextAttemptAt:nil)}
        catch let error as CloudError where error.issue == .accountChanged {
            guard try await ledger.scopeState(scope:scope).issue == .accountChanged else {throw error}
        }
    }
    func issue(_ error:any Error)->LifecycleIssueV4 {
        if let e=error as? AuthorityHTTPFailure {switch e.code {case "reauthenticationRequired":return .reauthenticationRequired;case "waitingPeriod":return .waitingPeriod;case "activationMismatch","cloudIdentityMismatch":return .accountChanged;case "migrationBlocked","activeMatchExists":return .blocked;case "unavailable":return .unavailable;default:return .unknown}}
        if error is URLError || (error as? AuthorityError) == .unavailable {return .unavailable};return .unknown
    }
    public func requestDeletion(requestID:String,reauthenticationID:String,cloud:ClientDeletionChoiceV4,local:ClientDeletionChoiceV4,health:ClientDeletionChoiceV4,healthConfirmed:Bool) async throws->DeletionSagaV4 {
        try await facade()
        if let prior=try await repository.deletionSagaV4(requestID:requestID) {guard prior.accountID==scope.accountID,prior.cloudChoice==cloud,prior.localChoice==local,prior.healthChoice==health,prior.healthConfirmed==healthConfirmed else {throw AuthorityError.conflict};return prior}
        let b=try await binding();guard b.role == .phone else {throw AuthorityError.identityChanged}
        var random=SystemRandomNumberGenerator();let cap=AuthorityWire.base64URL(Data((0..<32).map {_ in UInt8.random(in:0...255,using:&random)}))
        var f=AuthorityFields();f.reauthenticationID=reauthenticationID;f.recoveryCapabilityDigest=AuthorityWire.hash(Data(cap.utf8))
        let saga=try DeletionSagaV4(intent:ControlIntentV1(requestID:requestID,operation:.deleteAccount,fields:f),accountID:b.accountID,activationEpoch:b.activationEpoch,recoveryCapability:cap,cloudChoice:cloud,localChoice:local,healthChoice:health,healthConfirmed:healthConfirmed)
        try await coordinator.createDeletionSaga(saga)
        try await coordinator.setAnalyticsEnabled(false)
        try await fenceTransport()
        return saga
    }
    struct DeleteStatusRequest:Encodable {let version=1;let requestID,deleteRequestID,recoveryCapability:String}
    func deletionReceipt(_ saga:DeletionSagaV4,raw:Data)throws->VerifiedAuthorityReceiptV1 {try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(saga.intent,accountID:saga.accountID,epoch:saga.activationEpoch),trust:client.trust)}
    func deletionStatus(_ saga:DeletionSagaV4) async throws->VerifiedAuthorityReceiptV1 {
        let request=DeleteStatusRequest(requestID:UUID().uuidString,deleteRequestID:saga.intent.requestID,recoveryCapability:saga.recoveryCapability)
        let raw=try await client.unsigned(path:"/v1/accounts/delete-status",body:AuthorityWire.encode(request))
        guard let object=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else {throw AuthorityError.invalidWire}
        if object["status"] as? String=="receiptExpired",Set(object.keys)==["status"] {throw LifecycleClientError.receiptExpired}
        guard object["status"] as? String=="backendDeleted",Set(object.keys)==["status","receipt"],let receipt=object["receipt"] else {throw AuthorityError.invalidWire}
        return try deletionReceipt(saga,raw:JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.withoutEscapingSlashes]))
    }
    func deleteOnServer(_ saga:DeletionSagaV4) async throws->VerifiedAuthorityReceiptV1 {
        guard (try? await client.vault.credential()) != nil else {return try await deletionStatus(saga)}
        let raw:Data
        do {raw=try await client.query(requestID:saga.intent.requestID)}
        catch let failure as AuthorityHTTPFailure {
            if failure.code=="unauthorized" || failure.code=="accountDeleted" {return try await deletionStatus(saga)}
            guard failure.code=="notFound" || failure.code=="unavailable" else {throw failure}
            raw=try await client.send(saga.intent)
        }
        return try deletionReceipt(saga,raw:raw)
    }
    func save(_ saga:DeletionSagaV4,change:(inout DeletionSagaV4)->Void) async throws->DeletionSagaV4 {
        guard saga.revision<Int64.max else {throw AuthorityError.conflict}
        var next=saga;change(&next);next.revision += 1
        try await coordinator.updateDeletionSaga(next,expectedRevision:saga.revision);return next
    }
    public func resumeDeletion(requestID:String) async throws->DeletionSagaV4 {
        try await facade();guard var saga=try await repository.deletionSagaV4(requestID:requestID),saga.accountID==scope.accountID else {throw AuthorityError.intentMismatch}
        if !saga.backendDeleted {
            do {
                try await ControlQueueSupport.begin(saga.intent,coordinator:coordinator,at:client.now())
                let receipt=try await deleteOnServer(saga)
                saga=try await coordinator.acceptDeletion(requestID:requestID,receipt:receipt,expectedRevision:saga.revision)
                try await client.vault.advanceIdentityFence(to:repository.identityGenerationV4())
            } catch {try await ControlQueueSupport.failed(saga.intent,error:error,coordinator:coordinator,at:client.now());return try await save(saga) {$0.lastIssue=issue(error)}}
        }
        try await fenceTransport()
        // Each user choice remains independently retryable; one failed part does not hide another result.
        if saga.cloudChoice == .delete,saga.cloudProgress != .completed {
            saga=try await save(saga) {$0.cloudProgress = .running}
            do {try await cloudDeletion.deletePrivateZone(scope:scope);saga=try await save(saga) {$0.cloudProgress = .completed;$0.lastIssue=nil}}
            catch {saga=try await save(saga) {$0.cloudProgress = .failed;$0.lastIssue=issue(error)}}
        }
        if saga.localChoice == .delete,saga.localProgress != .completed {
            do {saga=try await coordinator.eraseLocalBusiness(requestID:requestID,expectedRevision:saga.revision)}
            catch {saga=try await save(saga) {$0.localProgress = .failed;$0.lastIssue=issue(error)}}
        }
        if saga.localChoice == .delete,saga.localTransportProgress != .completed {
            saga=try await save(saga) {$0.localTransportProgress = .running}
            do {try await localTransportDeletion.purgeBusinessCopies(LocalTransportDeletionRequest(scope:scope,saga:saga));saga=try await save(saga) {$0.localTransportProgress = .completed}}
            catch {saga=try await save(saga) {$0.localTransportProgress = .failed;$0.lastIssue=issue(error)}}
        }
        if saga.healthChoice == .delete,saga.healthProgress != .completed {
            guard saga.healthConfirmed else {throw AuthorityError.invalidWire}
            saga=try await save(saga) {$0.healthProgress = .running}
            do {try await healthDeletion.deleteAppCreatedWorkouts(confirmationID:saga.intent.requestID);saga=try await save(saga) {$0.healthProgress = .completed;$0.lastIssue=nil}}
            catch {saga=try await save(saga) {$0.healthProgress = .failed;$0.lastIssue=issue(error)}}
        }
        return saga
    }
    public func identityChanged() async throws {
        try await facade();try await coordinator.suspendAccount()
        try await client.vault.advanceIdentityFence(to:repository.identityGenerationV4())
        try await coordinator.setAnalyticsEnabled(false)
        try await fenceTransport()
    }
    public func setAnalyticsEnabled(_ value:Bool) async throws {try await facade();if value {_=try await binding()};try await coordinator.setAnalyticsEnabled(value)}
    public func enqueueAnalytics(_ event:AnalyticsEventV4) async throws {try await facade();try await coordinator.enqueueAnalytics(event)}
    public func flushAnalytics() async throws {
        _=try await binding()
        for event in try await repository.pendingAnalyticsV4() {
            guard try await repository.analyticsEnabledV4() else {return}
            let raw=try await client.signed(path:"/v1/analytics",body:AuthorityWire.encode(event),requestID:event.requestID)
            struct Reply:Codable {let version:Int;let requestID:String;let accepted:Bool}
            let reply=try AuthorityWire.decode(Reply.self,raw)
            guard reply.version==1,reply.requestID==event.requestID else {throw AuthorityError.intentMismatch}
            _=try await binding()
            try await coordinator.acknowledgeAnalytics(requestID:event.requestID)
        }
    }
    func migrationReady() async throws {
        _=try await binding()
        for id in try await repository.matchIDs() {
            let s=try await repository.snapshotV2(matchID:id),state=try s.business.replay(now:client.now()).state
            guard state == .completed || state == .incomplete else {throw LifecycleClientError.pendingBusiness}
            guard try await repository.pendingCaptureOperations(matchID:id).isEmpty else {throw LifecycleClientError.pendingBusiness}
            let a=try await repository.authorityStateV4(matchID:id,now:client.now())
            guard [.terminal,.releasedAbnormal,.releasedNormal].contains(a.status) else {throw LifecycleClientError.pendingBusiness}
        }
        guard try await ledger.conflicts(scope:scope).isEmpty else {throw LifecycleClientError.cloudConflict}
        guard try await ledger.uploads(scope:scope).allSatisfy({$0.state == .confirmed}),try await ledger.batches(scope:scope).allSatisfy({$0.state == .confirmed}) else {throw LifecycleClientError.pendingCloud}
    }
    public func reconcileLifecycle(_ intent:ControlIntentV1) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding(allowSuspended:true)
        if let original=try await repository.lifecycleControlIntentV4(requestID:intent.requestID) {guard original==intent else {throw AuthorityError.conflict}}
        else {_=try await coordinator.prepareLifecycleControl(intent)}
        try await ControlQueueSupport.begin(intent,coordinator:coordinator,at:client.now())
        do {
            let raw:Data
            do {raw=try await client.query(requestID:intent.requestID)}
            catch let failure as AuthorityHTTPFailure where failure.code=="notFound" {raw=try await client.send(intent)}
            return try await acceptLifecycle(intent,raw:raw,binding:b)
        } catch {try await ControlQueueSupport.failed(intent,error:error,coordinator:coordinator,at:client.now());throw error}
    }

    func acceptLifecycle(_ intent:ControlIntentV1,raw:Data,binding b:AccountBindingV4) async throws->VerifiedAuthorityReceiptV1 {
        struct Envelope:Codable {let body:AuthorityReceiptBodyV1;let signature:String}
        let envelope=try AuthorityWire.decode(Envelope.self,raw)
        let epoch=envelope.body.activationEpoch
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:epoch),trust:client.trust)
        try await coordinator.acceptLifecycleResult(intent:intent,receipt:receipt)
        if (receipt.body.result == .checkpointAccepted || receipt.body.result == .activated),try await repository.accountBindingV4()?.suspended == true {try await fenceTransport()}
        return receipt
    }
    public func retryPendingControls() async throws->[VerifiedAuthorityReceiptV1] {
        guard let queue=repository as? any ControlQueueRepository else {throw AuthorityError.unavailable}
        let operations:Set<AuthorityOperation>=[.prepareMigration,.checkpointMigration,.activateMigration,.requestLostMigration,.lostRecovery,.terminateLost,.forceMigration]
        var results:[VerifiedAuthorityReceiptV1]=[]
        for entry in try await queue.controlQueueV4() where operations.contains(entry.intent.operation) && [.ready,.inFlight,.retryScheduled].contains(entry.state) && (entry.nextAttemptAt.map{$0<=client.now()} ?? true) {results.append(try await reconcileLifecycle(entry.intent))}
        return results
    }
    public func prepareMigration(newPhoneID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        try await migrationReady();let b=try await binding();guard b.role == .phone else {throw AuthorityError.identityChanged}
        var fields=AuthorityFields();fields.newPhoneID=newPhoneID;fields.activationEpoch=b.activationEpoch
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.prepareMigration,fields:fields))
    }

    public func prepareFinalCheckpoint(checkpointID:UUID) async throws->CloudUpload {
        let b=try await binding();guard let m=try await repository.latestMigrationV4(),m.state=="oldPhonePrepared",m.oldPhoneID==b.deviceID else {throw LifecycleClientError.invalidCheckpoint}
        let records=try await repository.accountFactRecordsV4(scope:CloudSessionBridge.coreScope(scope)),refs=records.map(\.recordID).sorted(),existing=try await ledger.uploads(scope:scope)
        for entry in existing {if case .checkpoint(let checkpoint)=try entry.upload.record.payload,checkpoint.checkpointID==checkpointID.uuidString.lowercased() {guard checkpoint.matchID==CloudCheckpoint.accountMatchID(for:scope),checkpoint.recordIDs==refs else {throw AuthorityError.conflict};return entry.upload}}
        try await migrationReady()
        for record in records {
            let confirmed=existing.contains {$0.state == .confirmed && $0.upload.record.recordID==record.recordID && $0.upload.record.canonicalBytes==record.canonicalBytes}
            let downloaded=try await repository.cloudRecordV4(scope:CloudSessionBridge.coreScope(scope),recordID:record.recordID)
            guard confirmed || downloaded?.canonicalBytes==record.canonicalBytes else {throw LifecycleClientError.pendingCloud}
        }
        let checkpoint=try CloudCheckpoint.account(scope:scope,checkpointID:checkpointID,recordIDs:refs),upload=try CloudUpload(scope:scope,record:CloudRecord(scope:scope,payload:.checkpoint(checkpoint)))
        try await ledger.enqueue(upload);return upload
    }
    public func acceptDevelopmentFinalCheckpoint(upload:CloudUpload,evidence:DevelopmentCloudSaveEvidence,migrationID:String) async throws {
        _=try await binding();let namespace=await repository.databaseNamespace();guard namespace != SQLiteSessionRepository.productionNamespace,client.trust.environment == .development else {throw CloudImportError.proofUnavailable}
        let input=try await CloudSessionBridge.developmentReadbackInput(upload:upload,evidence:evidence,ledger:ledger)
        let proof=try VerifiedAccountCheckpointV4.verifyReadback(input,policy:.development(databaseNamespace:namespace))
        try await coordinator.acceptMigrationCheckpoint(migrationID:migrationID,proof:proof)
    }
    public func acceptSDKFinalCheckpoint(_ proof:VerifiedAccountCheckpointV4,migrationID:String) async throws {
        guard proof.policy == .productionSDK,client.trust.environment == .production else {throw CloudImportError.proofUnavailable}
        try await coordinator.acceptMigrationCheckpoint(migrationID:migrationID,proof:proof)
    }
    public func commitMigrationCheckpoint(migrationID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        if let prior=try await repository.lifecycleControlIntentV4(requestID:requestID) {guard prior.operation == .checkpointMigration,prior.fields.migrationID==migrationID else {throw AuthorityError.conflict};return try await reconcileLifecycle(prior)}
        let b=try await binding();guard let proof=try await repository.migrationCheckpointV4(migrationID:migrationID) else {throw LifecycleClientError.invalidCheckpoint}
        var fields=AuthorityFields();fields.migrationID=migrationID;fields.checkpointID=proof.input.record.recordID;fields.contentCommitment=proof.input.record.digest;fields.activationEpoch=b.activationEpoch
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.checkpointMigration,fields:fields))
    }
    public func learnMigration(intent:ControlIntentV1,raw:Data) async throws {
        let b=try await binding(allowSuspended:true);guard [.prepareMigration,.checkpointMigration,.requestLostMigration].contains(intent.operation) else {throw AuthorityError.invalidWire}
        _=try await coordinator.prepareLifecycleControl(intent);_=try await acceptLifecycle(intent,raw:raw,binding:b)
    }
    public func activateMigration(migrationID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding();guard b.role == .waiting,let migration=try await repository.latestMigrationV4(),migration.migrationID==migrationID,migration.newPhoneID==b.deviceID,migration.state=="oldPhoneDeactivated",!migration.checkpointID.isEmpty else {throw LifecycleClientError.invalidCheckpoint}
        guard let record=try await repository.cloudRecordV4(scope:CloudSessionBridge.coreScope(scope),recordID:migration.checkpointID),record.digest==migration.contentCommitment,
              case .checkpoint(let checkpoint)=try record.payload,checkpoint.matchID==CloudCheckpointV1.accountAnchorPrefix+scope.stableZoneKey else {throw LifecycleClientError.invalidCheckpoint}
        for id in checkpoint.recordIDs {guard try await repository.cloudRecordV4(scope:CloudSessionBridge.coreScope(scope),recordID:id) != nil else {throw LifecycleClientError.invalidCheckpoint}}
        var fields=AuthorityFields();fields.migrationID=migrationID;fields.checkpointID=record.recordID;fields.contentCommitment=record.digest;fields.cloudSpaceID=b.cloudSpaceID
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.activateMigration,fields:fields))
    }
    public func requestLostMigration(requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding();guard b.role == .waiting else {throw AuthorityError.identityChanged}
        var fields=AuthorityFields();fields.newPhoneID=b.deviceID;fields.cloudSpaceID=b.cloudSpaceID
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.requestLostMigration,fields:fields))
    }
    public func requestLostRecovery(migrationID:String,originalAcquire:VerifiedAuthorityReceiptV1,reauthenticationID:String,confirmedAt:Int64,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding(),a=originalAcquire.body
        guard b.role == .waiting,let m=try await repository.latestMigrationV4(),m.migrationID==migrationID,m.kind=="lost",m.newPhoneID==b.deviceID,m.oldActivationEpoch==a.activationEpoch,a.operation == .acquire,[.held,.originalMatch].contains(a.result),!a.matchID.isEmpty,!a.lockID.isEmpty,!a.recordingDeviceID.isEmpty else {throw AuthorityError.intentMismatch}
        _=try VerifiedAuthorityReceiptV1.verify(originalAcquire.raw,expected:AuthorityExpectedIntent(requestID:a.requestID,digest:a.requestDigest,operation:.acquire,accountID:b.accountID,epoch:m.oldActivationEpoch),trust:client.trust)
        var fields=AuthorityFields();fields.migrationID=migrationID;fields.matchID=a.matchID;fields.lockID=a.lockID;fields.originalRecordingDeviceID=a.recordingDeviceID;fields.originalActivationEpoch=a.activationEpoch;fields.reauthenticationID=reauthenticationID;fields.confirmedAt=confirmedAt
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.lostRecovery,fields:fields))
    }
    public func terminateLost(grant:VerifiedAuthorityReceiptV1,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding(),r=grant.body
        guard b.role == .waiting,let g=r.lostRecovery,g.newPhoneID==b.deviceID,g.expiresAt>=0,Double(g.expiresAt)>=client.now().timeIntervalSince1970,let original=try await repository.lifecycleControlIntentV4(requestID:r.requestID),original.operation == .lostRecovery else {throw LifecycleClientError.receiptExpired}
        _=try VerifiedAuthorityReceiptV1.verify(grant.raw,expected:AuthorityExpectedIntent(original,accountID:b.accountID,epoch:b.activationEpoch),trust:client.trust)
        var fields=AuthorityFields();fields.migrationID=g.migrationID;fields.grantID=g.grantID;fields.matchID=r.matchID;fields.lockID=r.lockID;fields.originalRecordingDeviceID=r.recordingDeviceID;fields.originalActivationEpoch=original.fields.originalActivationEpoch
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.terminateLost,fields:fields))
    }
    public func forceMigration(migrationID:String,reauthenticationID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await binding();guard b.role == .waiting,let m=try await repository.latestMigrationV4(),m.migrationID==migrationID,m.kind=="lost",m.newPhoneID==b.deviceID else {throw AuthorityError.identityChanged}
        var fields=AuthorityFields();fields.migrationID=migrationID;fields.reauthenticationID=reauthenticationID
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.forceMigration,fields:fields))
    }

}
