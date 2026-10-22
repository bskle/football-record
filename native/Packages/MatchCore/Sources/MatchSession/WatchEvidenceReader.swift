import MatchStore

extension SQLiteSessionRepository: CurrentWatchRegistrationEvidenceReadingV4 {
    public func currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: Int64) async throws -> VerifiedLocalWatchRegistrationEvidenceV4? {
        try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration)
    }
}

extension SQLiteSessionRepository: WatchRegistrationSetupEvidenceReadingV4 {
    public func watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: Int64, deviceID: String, publicKey: String) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
        try await store.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration, deviceID: deviceID, publicKey: publicKey)
    }
}
