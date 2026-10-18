import Foundation

public struct CloudRetryPolicy: Sendable {
    public init() {}
    public func nextAttempt(issue: CloudIssue, attempt: Int, now: Date) throws -> Date? {
        try CloudCodec.date(now)
        switch issue {
        case .accountChanged, .conflict, .identityConflict, .invalidPayload, .unsupportedSchema, .payloadTooLarge, .staleGeneration, .cursorMismatch, .closed, .awaitingBusinessImport: return nil
        default: break
        }
        let base: Double = issue == .quotaExceeded ? 60 : 5
        let delay = min(3600, base * pow(2, Double(min(16,max(0,attempt-1)))))
        let result = now.addingTimeInterval(delay); try CloudCodec.date(result); return result
    }
}
