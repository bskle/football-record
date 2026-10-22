import MatchStore

extension SQLiteSessionRepository: CurrentWatchRegistrationEvidenceReadingV4 {
    public func currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: Int64) async throws -> VerifiedLocalWatchRegistrationEvidenceV4? {
        try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration)
    }
}
