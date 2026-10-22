import Foundation
import MatchStore

/// A separate control capability; business retirement never grants a business admission.
public protocol DeletionControlAuthenticationCoordinator: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func saveDeletionControlAttempt(_ attempt: DeletionControlAttemptV1) async throws
    func acceptDeletionControlAuthorization(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, originalAcquire: Data?, expectedIdentityGeneration: Int64) async throws
    func resolveDeletionControlAttempt(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64) async throws
    func saveDeletionControlLockConfirmation(parentID: String, confirmation: DeletionControlLockConfirmationV1, expectedIdentityGeneration: Int64) async throws
    func acceptDeletionControlLiveLock(parentID: String, proof: VerifiedLiveLockV1, expectedIdentityGeneration: Int64) async throws
    func acceptDeletionControlAbnormalResult(parentID: String, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws
}

extension MatchSession: DeletionControlAuthenticationCoordinator {
    public func saveDeletionControlAttempt(_ attempt: DeletionControlAttemptV1) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.saveDeletionControlAttemptV4(attempt)
    }
    public func acceptDeletionControlAuthorization(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, originalAcquire: Data?, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.acceptDeletionControlAuthorizationV4(parentID: parentID, authorization: authorization, originalAcquire: originalAcquire, expectedIdentityGeneration: expectedIdentityGeneration, at: clock.now())
    }
    public func resolveDeletionControlAttempt(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.resolveDeletionControlAttemptV4(parentID: parentID, authorization: authorization, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func saveDeletionControlLockConfirmation(parentID: String, confirmation: DeletionControlLockConfirmationV1, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.saveDeletionControlLockConfirmationV4(parentID: parentID, confirmation: confirmation, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func acceptDeletionControlLiveLock(parentID: String, proof: VerifiedLiveLockV1, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.acceptDeletionControlLiveLockV4(parentID: parentID, proof: proof, expectedIdentityGeneration: expectedIdentityGeneration, at: clock.now())
    }
    public func acceptDeletionControlAbnormalResult(parentID: String, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any DeletionControlAuthenticationRepository else { throw AuthorityError.unavailable }
        await acquire("_authority-account")
        defer { release("_authority-account") }
        try await repository.acceptDeletionControlAbnormalResultV4(parentID: parentID, receipt: receipt, expectedIdentityGeneration: expectedIdentityGeneration)
    }
}

extension SQLiteSessionRepository: DeletionControlAuthenticationRepository {
    public func deletionControlContextV4(parentID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlContextV1 {
        return try await store.deletionControlContextV4(parentID: parentID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func deletionControlReadyContextV4(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64, at: Date) async throws -> DeletionControlContextV1 {
        return try await store.deletionControlReadyContextV4(parentID: parentID, authorization: authorization, expectedIdentityGeneration: expectedIdentityGeneration, at: at)
    }
    public func deletionControlAttemptsV4(parentID: String) async throws -> [DeletionControlAttemptV1] {
        return try await store.deletionControlAttemptsV4(parentID: parentID)
    }
    public func deletionControlAttemptV4(parentID: String, authRequestID: String) async throws -> DeletionControlAttemptV1? {
        return try await store.deletionControlAttemptV4(parentID: parentID, authRequestID: authRequestID)
    }
    public func deletionControlAuthorizationV4(parentID: String, authRequestID: String) async throws -> DeletionControlAuthorizationRecordV1? {
        return try await store.deletionControlAuthorizationV4(parentID: parentID, authRequestID: authRequestID)
    }
    public func deletionControlLockConfirmationV4(parentID: String) async throws -> DeletionControlLockConfirmationV1? {
        return try await store.deletionControlLockConfirmationV4(parentID: parentID)
    }
    public func saveDeletionControlAttemptV4(_ attempt: DeletionControlAttemptV1) async throws {
        try await store.saveDeletionControlAttemptV4(attempt)
    }
    public func acceptDeletionControlAuthorizationV4(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, originalAcquire: Data?, expectedIdentityGeneration: Int64, at: Date) async throws {
        try await store.acceptDeletionControlAuthorizationV4(parentID: parentID, authorization: authorization, originalAcquire: originalAcquire, expectedIdentityGeneration: expectedIdentityGeneration, at: at)
    }
    public func resolveDeletionControlAttemptV4(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64) async throws {
        try await store.resolveDeletionControlAttemptV4(parentID: parentID, authorization: authorization, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func saveDeletionControlLockConfirmationV4(parentID: String, confirmation: DeletionControlLockConfirmationV1, expectedIdentityGeneration: Int64) async throws {
        try await store.saveDeletionControlLockConfirmationV4(parentID: parentID, confirmation: confirmation, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func acceptDeletionControlLiveLockV4(parentID: String, proof: VerifiedLiveLockV1, expectedIdentityGeneration: Int64, at: Date) async throws {
        try await store.acceptDeletionControlLiveLockV4(parentID: parentID, proof: proof, expectedIdentityGeneration: expectedIdentityGeneration, at: at)
    }
    public func acceptDeletionControlAbnormalResultV4(parentID: String, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws {
        try await store.acceptDeletionControlAbnormalResultV4(parentID: parentID, receipt: receipt, expectedIdentityGeneration: expectedIdentityGeneration)
    }
}
