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
    public func matches(_ candidate: WorkoutDeletionTargetV1) -> Bool {
        guard candidate.expectedSourceBundleID.utf8.elementsEqual(currentSourceBundleID.utf8) else { return false }
        // String equality admits Unicode canonical equivalence; the selection binds original bytes.
        return targets.contains {
            $0.workoutUUID == candidate.workoutUUID
                && $0.matchID.utf8.elementsEqual(candidate.matchID.utf8)
                && $0.recordingDeviceID.utf8.elementsEqual(candidate.recordingDeviceID.utf8)
                && $0.segmentToken.utf8.elementsEqual(candidate.segmentToken.utf8)
        }
    }
}
