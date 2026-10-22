import Foundation
import MatchStore

public protocol InitialDeletionAuthenticationCoordinatorV1: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func prepareInitialDeletionAuthentication(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1
    func saveInitialDeletionAttempt(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws
    func acceptInitialDeletionAuthentication(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws
    func closePreparedInitialDeletionAttempt(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws
    func resolveInitialDeletionAttempt(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws
    func reserveInitialDeletion(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1
}

extension MatchSession: InitialDeletionAuthenticationCoordinatorV1 {
    public func prepareInitialDeletionAuthentication(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4,
        authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1 {
        try beginBusiness(); defer { endBusiness() }
        try requireBusinessActive(); try await validateEnvironment(allowSuspendedRead: true); try requireBusinessActive()
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }; try requireBusinessActive()
        return try await repository.prepareInitialDeletionAuthenticationV4(request: request, expectedSource: expectedSource,
            authRequestID: authRequestID, challengeRequestID: challengeRequestID)
    }
    public func saveInitialDeletionAttempt(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws {
        try beginBusiness(); defer { endBusiness() }
        try requireBusinessActive(); try await validateEnvironment(allowSuspendedRead: true); try requireBusinessActive()
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }; try requireBusinessActive()
        try await repository.saveInitialDeletionAttemptV4(creationID: creationID, authentication: authentication, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func closePreparedInitialDeletionAttempt(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws {
        try beginBusiness(); defer { endBusiness() }
        try requireBusinessActive(); try await validateEnvironment(allowSuspendedRead: true); try requireBusinessActive()
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }; try requireBusinessActive()
        try await repository.closePreparedInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func reserveInitialDeletion(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 {
        try beginBusiness(); defer { endBusiness() }
        try requireBusinessActive(); try await validateEnvironment(allowSuspendedRead: true); try requireBusinessActive()
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }; try requireBusinessActive()
        return try await repository.reserveInitialDeletionV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    /// Only already-persisted attempt facts may cross retirement; no business entry is admitted.
    public func acceptInitialDeletionAuthentication(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1,
        opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }
        try await validateEnvironment(allowSuspendedRead: true)
        try await repository.acceptInitialDeletionAuthenticationV4(creationID: creationID, authRequestID: authRequestID,
            receipt: receipt, opaqueReauthenticationID: opaqueReauthenticationID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func resolveInitialDeletionAttempt(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1,
        expectedIdentityGeneration: Int64) async throws {
        try await validateEnvironment(allowSuspendedRead: true)
        guard let repository = store as? any InitialDeletionAuthenticationRepositoryV1 else { throw AuthorityError.unavailable }
        await acquire("_authority-account"); defer { release("_authority-account") }
        try await validateEnvironment(allowSuspendedRead: true)
        try await repository.resolveInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID,
            resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration)
    }
}

// The identity is the existing facade's identity; these methods use its original Store.
extension SQLiteSessionRepository: InitialDeletionAuthenticationRepositoryV1 {
    public func initialDeletionContextV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionContextV1? {
        try await store.initialDeletionContextV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func prepareInitialDeletionAuthenticationV4(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4,
        authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1 {
        try await store.prepareInitialDeletionAuthenticationV4(request: request, expectedSource: expectedSource,
            authRequestID: authRequestID, challengeRequestID: challengeRequestID)
    }
    public func saveInitialDeletionAttemptV4(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws {
        try await store.saveInitialDeletionAttemptV4(creationID: creationID, authentication: authentication, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func acceptInitialDeletionAuthenticationV4(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1,
        opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws {
        try await store.acceptInitialDeletionAuthenticationV4(creationID: creationID, authRequestID: authRequestID,
            receipt: receipt, opaqueReauthenticationID: opaqueReauthenticationID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func closePreparedInitialDeletionAttemptV4(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws {
        try await store.closePreparedInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func resolveInitialDeletionAttemptV4(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws {
        try await store.resolveInitialDeletionAttemptV4(creationID: creationID, authRequestID: authRequestID, resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration)
    }
    public func reserveInitialDeletionV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1 {
        try await store.reserveInitialDeletionV4(creationID: creationID, expectedIdentityGeneration: expectedIdentityGeneration)
    }
}
extension SQLiteSessionRepository {
    public func requireOrdinaryAuthenticationV4(authRequestID: String, challengeRequestID: String?) async throws {
        try await store.requireOrdinaryAuthenticationV4(authRequestID: authRequestID, challengeRequestID: challengeRequestID)
    }
}
