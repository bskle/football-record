import Foundation
public enum ControlQueueStateV4:String,Codable,Sendable {case ready,inFlight,retryScheduled,blocked,confirmed}
public struct ControlQueueEntryV4:Codable,Sendable,Equatable {
    public let intent:ControlIntentV1
    public var state:ControlQueueStateV4
    public var attemptCount:Int64
    public var lastAttemptAt,nextAttemptAt:Date?
    public var lastIssue:LifecycleIssueV4?
}
public protocol ControlQueueRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func controlQueueV4() async throws->[ControlQueueEntryV4]
    func beginControlAttemptV4(intent:ControlIntentV1,at:Date) async throws
    func failControlAttemptV4(intent:ControlIntentV1,issue:LifecycleIssueV4,retryable:Bool,at:Date) async throws
}
