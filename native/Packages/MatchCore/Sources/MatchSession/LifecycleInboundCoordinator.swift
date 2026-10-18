import Foundation
import MatchStore
public protocol LifecycleInboundCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func prepareLifecycleControl(_ intent:ControlIntentV1) async throws->ControlIntentReceiptV4
    func acceptLifecycleResult(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws
    func suspendAccount() async throws
    func createDeletionSaga(_ saga:DeletionSagaV4) async throws
    func updateDeletionSaga(_ saga:DeletionSagaV4,expectedRevision:Int64) async throws
    func acceptDeletion(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64) async throws->DeletionSagaV4
    func eraseLocalBusiness(requestID:String,expectedRevision:Int64) async throws->DeletionSagaV4
    func setAnalyticsEnabled(_ enabled:Bool) async throws
    func enqueueAnalytics(_ event:AnalyticsEventV4) async throws
    func acknowledgeAnalytics(requestID:String) async throws
}
extension MatchSession:LifecycleInboundCoordinator {
    public func prepareLifecycleControl(_ intent:ControlIntentV1) async throws->ControlIntentReceiptV4 {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        return try await authorityRepository().prepareControlV4(intent)
    }
    public func acceptLifecycleResult(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.acceptLifecycleResultV4(intent:intent,receipt:receipt)
    }
    public func suspendAccount() async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await authorityRepository().suspendAccountV4()
    }
    public func createDeletionSaga(_ saga:DeletionSagaV4) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.createDeletionSagaV4(saga)
    }
    public func updateDeletionSaga(_ saga:DeletionSagaV4,expectedRevision:Int64) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.updateDeletionSagaV4(saga,expectedRevision:expectedRevision)
    }
    public func acceptDeletion(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64) async throws->DeletionSagaV4 {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        return try await repository.acceptDeletionV4(requestID:requestID,receipt:receipt,expectedRevision:expectedRevision)
    }
    public func eraseLocalBusiness(requestID:String,expectedRevision:Int64) async throws->DeletionSagaV4 {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        return try await repository.eraseLocalBusinessV4(requestID:requestID,expectedRevision:expectedRevision)
    }
    public func setAnalyticsEnabled(_ enabled:Bool) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.setAnalyticsEnabledV4(enabled)
    }
    public func enqueueAnalytics(_ event:AnalyticsEventV4) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.enqueueAnalyticsV4(event)
    }
    public func acknowledgeAnalytics(requestID:String) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any LifecycleStateRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        try await repository.acknowledgeAnalyticsV4(requestID:requestID)
    }
}
extension SQLiteSessionRepository:LifecycleStateRepository {
    public func lifecycleControlIntentV4(requestID:String) async throws->ControlIntentV1? {return try await store.lifecycleControlIntentV4(requestID:requestID)}
    public func lifecycleReceiptV4(requestID:String) async throws->Data? {return try await store.lifecycleReceiptV4(requestID:requestID)}
    public func acceptLifecycleResultV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws {try await store.acceptLifecycleResultV4(intent:intent,receipt:receipt)}
    public func latestMigrationV4() async throws->AuthorityMigrationV1? {return try await store.latestMigrationV4()}
    public func deletionSagaV4(requestID:String) async throws->DeletionSagaV4? {return try await store.deletionSagaV4(requestID:requestID)}
    public func createDeletionSagaV4(_ saga:DeletionSagaV4) async throws {try await store.createDeletionSagaV4(saga)}
    public func updateDeletionSagaV4(_ saga:DeletionSagaV4,expectedRevision:Int64) async throws {try await store.updateDeletionSagaV4(saga,expectedRevision:expectedRevision)}
    public func acceptDeletionV4(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64) async throws->DeletionSagaV4 {return try await store.acceptDeletionV4(requestID:requestID,receipt:receipt,expectedRevision:expectedRevision)}
    public func eraseLocalBusinessV4(requestID:String,expectedRevision:Int64) async throws->DeletionSagaV4 {return try await store.eraseLocalBusinessV4(requestID:requestID,expectedRevision:expectedRevision)}
    public func analyticsEnabledV4() async throws->Bool {return try await store.analyticsEnabledV4()}
    public func setAnalyticsEnabledV4(_ enabled:Bool) async throws {try await store.setAnalyticsEnabledV4(enabled)}
    public func enqueueAnalyticsV4(_ event:AnalyticsEventV4) async throws {try await store.enqueueAnalyticsV4(event)}
    public func pendingAnalyticsV4() async throws->[AnalyticsEventV4] {return try await store.pendingAnalyticsV4()}
    public func acknowledgeAnalyticsV4(requestID:String) async throws {try await store.acknowledgeAnalyticsV4(requestID:requestID)}
    public func cloudRecordV4(scope:CloudScopeV1,recordID:String) async throws->CloudRecordV1? {return try await store.cloudRecordV4(scope:scope,recordID:recordID)}
}
