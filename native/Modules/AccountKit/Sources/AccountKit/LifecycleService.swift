import Foundation
import MatchCore
import MatchStore
import MatchSession
import CloudSync
public enum LifecycleClientError:Error,Sendable,Equatable {case pendingBusiness,pendingCloud,cloudConflict,invalidCheckpoint,receiptExpired,reauthenticationRequired,unknownOriginal}
public protocol CloudAccountDeletionDriver:Sendable {func deletePrivateZone(scope:CloudScope) async throws}
public protocol AppWorkoutDeletionDriver:Sendable {func deleteAppCreatedWorkouts(confirmationID:String) async throws}
public struct UnavailableCloudAccountDeletionDriver:CloudAccountDeletionDriver {public init(){};public func deletePrivateZone(scope:CloudScope) async throws {throw AuthorityError.unavailable}}
public struct UnavailableAppWorkoutDeletionDriver:AppWorkoutDeletionDriver {public init(){};public func deleteAppCreatedWorkouts(confirmationID:String) async throws {throw AuthorityError.unavailable}}
public actor LifecycleService {
    let client:AuthorityClient
    let repository:any SessionRepository & AuthorityRepository & CloudImportRepository & LifecycleStateRepository
    let coordinator:any LifecycleInboundCoordinator
    let scope:CloudScope
    let ledger:any CloudLedger
    let cloudDeletion:any CloudAccountDeletionDriver
    let healthDeletion:any AppWorkoutDeletionDriver
    public init(client:AuthorityClient,repository:any SessionRepository & AuthorityRepository & CloudImportRepository & LifecycleStateRepository,coordinator:any LifecycleInboundCoordinator,scope:CloudScope,ledger:any CloudLedger,cloudDeletion:any CloudAccountDeletionDriver=UnavailableCloudAccountDeletionDriver(),healthDeletion:any AppWorkoutDeletionDriver=UnavailableAppWorkoutDeletionDriver()){self.client=client;self.repository=repository;self.coordinator=coordinator;self.scope=scope;self.ledger=ledger;self.cloudDeletion=cloudDeletion;self.healthDeletion=healthDeletion}

    func facade() async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged}}
    func binding(allowSuspended:Bool=false) async throws->AccountBindingV4 {
        try await facade();guard let b=try await repository.accountBindingV4(),(allowSuspended || !b.suspended),b.accountID==scope.accountID,b.cloudSpaceID==scope.cloudSpaceID,b.activationEpoch==scope.activationEpoch,b.environment==client.trust.environment else {throw AuthorityError.identityChanged};return b
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
        try await ledger.recordScopeIssue(scope:scope,issue:.accountChanged,at:client.now(),nextAttemptAt:nil)
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
                let receipt=try await deleteOnServer(saga)
                saga=try await coordinator.acceptDeletion(requestID:requestID,receipt:receipt,expectedRevision:saga.revision)
                try await client.vault.replace(nil)
            } catch {return try await save(saga) {$0.lastIssue=issue(error)}}
        }
        try await ledger.recordScopeIssue(scope:scope,issue:.accountChanged,at:client.now(),nextAttemptAt:nil)
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
        if saga.healthChoice == .delete,saga.healthProgress != .completed {
            guard saga.healthConfirmed else {throw AuthorityError.invalidWire}
            saga=try await save(saga) {$0.healthProgress = .running}
            do {try await healthDeletion.deleteAppCreatedWorkouts(confirmationID:saga.intent.requestID);saga=try await save(saga) {$0.healthProgress = .completed;$0.lastIssue=nil}}
            catch {saga=try await save(saga) {$0.healthProgress = .failed;$0.lastIssue=issue(error)}}
        }
        return saga
    }
    public func identityChanged() async throws {
        try await facade();try await coordinator.suspendAccount();try await coordinator.setAnalyticsEnabled(false)
        try await ledger.recordScopeIssue(scope:scope,issue:.accountChanged,at:client.now(),nextAttemptAt:nil)
        try await client.vault.replace(nil)
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
        let raw:Data
        do {raw=try await client.query(requestID:intent.requestID)}
        catch let failure as AuthorityHTTPFailure where failure.code=="notFound" {raw=try await client.send(intent)}
        return try await acceptLifecycle(intent,raw:raw,binding:b)
    }
    func acceptLifecycle(_ intent:ControlIntentV1,raw:Data,binding b:AccountBindingV4) async throws->VerifiedAuthorityReceiptV1 {
        struct Envelope:Codable {let body:AuthorityReceiptBodyV1;let signature:String}
        let envelope=try AuthorityWire.decode(Envelope.self,raw)
        let activates=intent.operation == .activateMigration || intent.operation == .forceMigration
        let epoch=activates ? envelope.body.activationEpoch:b.activationEpoch
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:epoch),trust:client.trust)
        try await coordinator.acceptLifecycleResult(intent:intent,receipt:receipt)
        if receipt.body.result == .checkpointAccepted || receipt.body.result == .activated {try await ledger.recordScopeIssue(scope:scope,issue:.accountChanged,at:client.now(),nextAttemptAt:nil)}
        return receipt
    }
    public func prepareMigration(newPhoneID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        try await migrationReady();let b=try await binding();guard b.role == .phone else {throw AuthorityError.identityChanged}
        var fields=AuthorityFields();fields.newPhoneID=newPhoneID;fields.activationEpoch=b.activationEpoch
        return try await reconcileLifecycle(ControlIntentV1(requestID:requestID,operation:.prepareMigration,fields:fields))
    }
}
