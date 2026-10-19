import Foundation
public protocol HealthDeletionLedger: Sendable {
    func submit(_ request: WorkoutDeletionRequestV1) async throws -> HealthDeletionEntry
    func confirm(_ confirmation: WorkoutDeletionConfirmationV1, now: Int64) async throws -> HealthDeletionEntry
    func entry(_ requestID: UUID) async throws -> HealthDeletionEntry
    func pendingRequests() async throws -> [HealthDeletionEntry]
    func beginAttempt(_ requestID: UUID, attemptID: UUID) async throws -> HealthDeletionEntry
    func markAwaitingOutcome(_ requestID: UUID, digest: String, attemptID: UUID) async throws
    func finish(_ requestID: UUID, digest: String, attemptID: UUID, outcome: HealthDeletionDriverOutcome, now: Int64) async throws
    func close() async throws
}
enum DeletionWrite: Sendable { case submit, confirm, beginAttempt, awaitingOutcome, finish }
enum DeletionFault: Sendable { case beforeCommit, afterCommitResponseLost }
