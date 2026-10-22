import MatchStore

extension SQLiteSessionRepository: CurrentAuthenticationEvidenceReadingV4 {
    public func currentAuthenticationEvidenceV4(expectedIdentityGeneration: Int64) async throws -> VerifiedLocalAuthenticationEvidenceV4? {
        try await store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration)
    }
}
