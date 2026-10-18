import Foundation
public struct HealthDeletionDriverAttempt: Sendable {
    public let request: WorkoutDeletionRequestV1
    public let selectionDigest: String
    public let attemptID: UUID
}
public protocol HealthDeletionDriver: Sendable {
    func delete(_ attempt: HealthDeletionDriverAttempt, completion: @escaping @Sendable (HealthDeletionDriverOutcome) -> Void)
}
public struct UnavailableHealthDeletionDriver: HealthDeletionDriver {
    public init() {}
    public func delete(_ attempt: HealthDeletionDriverAttempt, completion: @escaping @Sendable (HealthDeletionDriverOutcome) -> Void) { completion(.failure(.unavailable)) }
}
/// A pure tuple plan consumed by the SDK adapter; no HealthStore is needed to validate scope.
public struct HealthDeletionPredicatePlan: Sendable {
    public let currentSourceBundleID: String
    public let targets: [WorkoutDeletionTargetV1]
    public init(request: WorkoutDeletionRequestV1, currentSourceBundleID: String) throws {
        try request.validate()
        guard DeletionValidation.source(currentSourceBundleID), request.targets.allSatisfy({ $0.expectedSourceBundleID == currentSourceBundleID }) else { throw HealthDeletionIssue.sourceMismatch }
        self.currentSourceBundleID=currentSourceBundleID;targets=request.targets
    }
    public func matches(_ candidate: WorkoutDeletionTargetV1) -> Bool { candidate.expectedSourceBundleID == currentSourceBundleID && targets.contains(candidate) }
}
