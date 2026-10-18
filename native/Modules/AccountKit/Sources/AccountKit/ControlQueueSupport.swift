import Foundation
import MatchStore
import MatchSession
enum ControlQueueSupport {
    static func begin(_ intent:ControlIntentV1,coordinator:any Sendable,at:Date) async throws {
        guard let queue=coordinator as? any ControlQueueInboundCoordinator else {throw AuthorityError.unavailable}
        try await queue.beginControlAttempt(intent,at:at)
    }
    static func failed(_ intent:ControlIntentV1,error:any Error,coordinator:any Sendable,at:Date) async throws {
        guard let queue=coordinator as? any ControlQueueInboundCoordinator else {throw AuthorityError.unavailable}
        let issue:LifecycleIssueV4,retryable:Bool
        if let http=error as? AuthorityHTTPFailure {
            retryable=http.retryable
            switch http.code {case "unauthorized","reauthenticationRequired":issue = .reauthenticationRequired;case "activationMismatch","cloudIdentityMismatch","accountDeleted":issue = .accountChanged;case "waitingPeriod":issue = .waitingPeriod;case "migrationBlocked","activeMatchExists","lockMismatch","idempotencyConflict":issue = .blocked;case "unavailable":issue = .unavailable;default:issue = .unknown}
        } else if error is URLError || (error as? AuthorityError) == .unavailable || (error as? StoreError) == .responseLost {issue = .unavailable;retryable=true}
        else {issue = .unknown;retryable=false}
        try await queue.failControlAttempt(intent,issue:issue,retryable:retryable,at:at)
    }
}
