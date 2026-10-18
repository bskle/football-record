import Foundation
import MatchCore
import MatchStore

public protocol AuthorityInboundCoordinator: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func prepareAuthorityControl(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4
    func acceptAuthorityResult(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4
    func acceptLiveLock(_ proof: VerifiedLiveLockV1) async throws
}
extension MatchSession: AuthorityInboundCoordinator {
    func authorityRepository() throws -> any AuthorityRepository {
        guard let value=store as? any AuthorityRepository else { throw AuthorityError.unavailable };return value
    }
    func authorityManaged() async throws -> Bool {
        guard let value=store as? any AuthorityRepository else { return false };return try await value.accountBindingV4() != nil
    }
    func requireAuthorityStart(_ intent:StartIntent) async throws {
        if try await authorityManaged() { try await authorityRepository().validateAuthorityStartV4(intent,now:clock.now()) }
    }
    func authorityReleased(_ matchID:String) async throws -> Bool {
        guard try await authorityManaged() else { return false }
        let state=try await authorityRepository().authorityStateV4(matchID:matchID,now:clock.now())
        return state.status == .releasedNormal || state.status == .releasedAbnormal
    }
    public func prepareAuthorityControl(_ intent:ControlIntentV1) async throws -> ControlIntentReceiptV4 {
        try await validateEnvironment();let repository=try authorityRepository()
        let key=intent.matchID.isEmpty ? "_authority-account" : intent.matchID
        await acquire(key);defer { release(key) }
        return try await repository.prepareControlV4(intent)
    }
    public func acceptAuthorityResult(_ receipt:VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4 {
        try await validateEnvironment();let repository=try authorityRepository()
        let key=receipt.body.matchID.isEmpty ? "_authority-account" : receipt.body.matchID
        await acquire(key);defer { release(key) }
        let result=try await repository.recordAuthorityResultV4(receipt)
        if !receipt.body.matchID.isEmpty,let snapshot=try? await store.snapshotV2(matchID:receipt.body.matchID) { publish(try projected(snapshot)) }
        return result
    }
    public func acceptLiveLock(_ proof:VerifiedLiveLockV1) async throws {
        try await validateEnvironment();let repository=try authorityRepository()
        await acquire(proof.body.matchID);defer { release(proof.body.matchID) }
        try await repository.recordLiveLockV4(proof,now:clock.now())
    }
}
