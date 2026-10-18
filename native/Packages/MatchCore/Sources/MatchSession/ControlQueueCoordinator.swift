import Foundation
import MatchStore
public protocol ControlQueueInboundCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func beginControlAttempt(_ intent:ControlIntentV1,at:Date) async throws
    func failControlAttempt(_ intent:ControlIntentV1,issue:LifecycleIssueV4,retryable:Bool,at:Date) async throws
}
extension MatchSession:ControlQueueInboundCoordinator {
    public func beginControlAttempt(_ intent:ControlIntentV1,at:Date) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any ControlQueueRepository else {throw AuthorityError.unavailable}
        let key=intent.matchID.isEmpty ? "_authority-account":intent.matchID
        await acquire(key);defer {release(key)};try await repository.beginControlAttemptV4(intent:intent,at:at)
    }
    public func failControlAttempt(_ intent:ControlIntentV1,issue:LifecycleIssueV4,retryable:Bool,at:Date) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any ControlQueueRepository else {throw AuthorityError.unavailable}
        let key=intent.matchID.isEmpty ? "_authority-account":intent.matchID
        await acquire(key);defer {release(key)};try await repository.failControlAttemptV4(intent:intent,issue:issue,retryable:retryable,at:at)
    }
}
extension SQLiteSessionRepository:ControlQueueRepository {
    public func controlQueueV4() async throws->[ControlQueueEntryV4] {try await store.controlQueueV4()}
    public func beginControlAttemptV4(intent:ControlIntentV1,at:Date) async throws {try await store.beginControlAttemptV4(intent:intent,at:at)}
    public func failControlAttemptV4(intent:ControlIntentV1,issue:LifecycleIssueV4,retryable:Bool,at:Date) async throws {try await store.failControlAttemptV4(intent:intent,issue:issue,retryable:retryable,at:at)}
}
