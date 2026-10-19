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
        return state.status == .terminal || state.status == .releasedNormal || state.status == .releasedAbnormal
    }
    public func prepareAuthorityControl(_ intent:ControlIntentV1) async throws -> ControlIntentReceiptV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try authorityRepository()
        let key=intent.matchID.isEmpty ? "_authority-account" : intent.matchID
        await acquire(key);defer { release(key) }
        try requireBusinessActive()
        return try await repository.prepareControlV4(intent)
    }
    public func acceptAuthorityResult(_ receipt:VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try authorityRepository()
        let key=receipt.body.matchID.isEmpty ? "_authority-account" : receipt.body.matchID
        await acquire(key);defer { release(key) }
        try requireBusinessActive()
        let result=try await repository.recordAuthorityResultV4(receipt)
        if receipt.body.result == .releasedNormal || receipt.body.result == .releasedAbnormal { authorityTerminalMatches.insert(receipt.body.matchID); scheduleCapture(receipt.body.matchID) }
        if receipt.body.result == .releasedNormal {try await completeNormallyLocked(receipt.body.matchID)}
        if !receipt.body.matchID.isEmpty,let snapshot=try? await store.snapshotV2(matchID:receipt.body.matchID) { publish(try projected(snapshot)) }
        return result
    }
    public func acceptLiveLock(_ proof:VerifiedLiveLockV1) async throws {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try authorityRepository()
        await acquire(proof.body.matchID);defer { release(proof.body.matchID) }
        try requireBusinessActive()
        try await repository.recordLiveLockV4(proof,now:clock.now())
        if proof.body.status == .terminal { authorityTerminalMatches.insert(proof.body.matchID);scheduleCapture(proof.body.matchID) }
    }
}

extension MatchSession {
    /// Pure SQL read inside the queue. A persisted terminal fence never expires with an attestation.
    func updateAuthorityFence(_ snapshot:StoreSnapshotV2) async throws {
        guard try await authorityManaged() else {return}
        let repository=try authorityRepository()
        guard let b=try await repository.accountBindingV4(),!b.suspended else {throw AuthorityError.identityChanged}
        let state=try await repository.authorityStateV4(matchID:snapshot.business.descriptor.matchID,now:clock.now())
        if [.terminationPending,.terminal,.releasedNormal,.releasedAbnormal].contains(state.status) {authorityTerminalMatches.insert(snapshot.business.descriptor.matchID);return}
        if snapshot.business.descriptor.startPermit != nil {
            guard let acquire=state.acquire,acquire.body.accountID==b.accountID,acquire.body.activationEpoch==b.activationEpoch,
                  acquire.body.matchID==snapshot.business.descriptor.matchID,acquire.body.recordingDeviceID==snapshot.business.descriptor.recordingDeviceID else {throw AuthorityError.identityChanged}
        }
    }
    /// Opportunity to learn server terminal state. A network failure does not revoke an existing lock.
    /// Only an as-yet unperformed first start needs a fresh held proof before creating a Workout.
    func learnAuthorityForRecovery(_ snapshot:StoreSnapshotV2) async throws {
        guard try await authorityManaged(),snapshot.business.descriptor.startPermit != nil else {return}
        try await updateAuthorityFence(snapshot)
        if terminal(snapshot) {return}
        do {_=try await acquireBusinessPermit(for:snapshot.business.descriptor.startIntent)}
        catch {
            try await updateAuthorityFence(snapshot)
            if terminal(snapshot) {return}
            let transient=(error is URLError) || ((error as? any AuthorityTransientFailure)?.permitsOfflineContinuation == true)
            let positive=snapshot.captureOperations.contains {$0.observation?.hasPositiveCaptureEvidence == true}
            let uncertain=snapshot.captureOperations.contains {$0.operation.action == .start && $0.state == .needsReconciliation}
            guard transient,(positive || uncertain) else {throw error}
        }
        try await updateAuthorityFence(snapshot)
    }
}
