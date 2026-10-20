import Foundation
import MatchCore
import MatchStore
public protocol CloudInboundCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func importCloudBatch(_ batch:ValidatedCloudBatchV1) async throws->CloudImportReceiptV4
    func acceptCloudSave(_ proof:VerifiedCloudSaveV1) async throws->CloudCheckpointReceiptV4
    func resetCloudCursor(scope:CloudScopeV1,expectedGeneration:Int64) async throws->CloudCursorV4
    func authorizeCloudHistory(_ grant:VerifiedCloudHistoryGrantV1) async throws
}
extension MatchSession:CloudInboundCoordinator {
    func cloudRepository()throws->any CloudImportRepository {guard let value=store as? any CloudImportRepository else {throw CloudImportError.proofUnavailable};return value}
    public func importCloudBatch(_ batch:ValidatedCloudBatchV1) async throws->CloudImportReceiptV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment(allowSuspendedRead:true);let repository=try cloudRepository()
        let matches=try Set(batch.records.map {try $0.payload.matchID}).sorted()
        let keys=Array(Set(matches+["_cloud-cursor:"+(try batch.scope.key)])).sorted()
        for key in keys {await acquire(key)}
        defer {for key in keys.reversed(){release(key)}}
        try requireBusinessActive()
        let receipt=try await repository.commitCloudBatchV4(batch)
        let binding=try await (store as? any AuthorityRepository)?.accountBindingV4()
        let canPublish=binding.map {!$0.suspended && $0.accountID==batch.scope.accountID && $0.activationEpoch==batch.scope.activationEpoch} ?? false
        for match in matches where canPublish {
            if let s=try? await store.snapshotV2(matchID:match) {
                try await updateAuthorityFence(s);publish(try projected(s))
                if s.business.descriptor.recordingDeviceID == (try await identity()) {scheduleCapture(match)}
            }
        };return receipt
    }
    public func acceptCloudSave(_ proof:VerifiedCloudSaveV1) async throws->CloudCheckpointReceiptV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try cloudRepository(),match=try proof.input.record.payload.matchID
        await acquire(match);defer {release(match)}
        try requireBusinessActive()
        let receipt=try await repository.saveCloudCheckpointV4(proof)
        try await completeNormallyLocked(match)
        publish(try projected(await store.snapshotV2(matchID:match)));return receipt
    }
    public func resetCloudCursor(scope:CloudScopeV1,expectedGeneration:Int64) async throws->CloudCursorV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try cloudRepository(),key="_cloud-cursor:"+(try scope.key)
        await acquire(key);defer {release(key)}
        try requireBusinessActive()
        return try await repository.resetCloudCursorV4(scope:scope,expectedGeneration:expectedGeneration)
    }
    public func authorizeCloudHistory(_ grant:VerifiedCloudHistoryGrantV1) async throws {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();let repository=try cloudRepository(),match=grant.originalAcquire.body.matchID
        await acquire(match);defer {release(match)};try requireBusinessActive();try await repository.authorizeCloudHistoryV4(grant)
    }
    func completeNormallyLocked(_ match:String) async throws {
        guard let repository=store as? any CloudImportRepository,let authority=store as? any AuthorityRepository else {return}
        let state=try await authority.authorityStateV4(matchID:match,now:clock.now())
        guard let release=state.verifiedNormalRelease,let cloud=try await repository.matchingCloudSaveV4(matchID:match) else {return}
        let snapshot=try await store.snapshotV2(matchID:match)
        try await repository.completeNormallyV4(release:release,cloud:cloud,expectedGeneration:snapshot.business.generation,now:clock.now())
    }
}
extension SQLiteSessionRepository:CloudImportRepository {
    public func cloudCursorV4(scope:CloudScopeV1) async throws->CloudCursorV4 {try await store.cloudCursorV4(scope:scope)}
    public func resetCloudCursorV4(scope:CloudScopeV1,expectedGeneration:Int64) async throws->CloudCursorV4 {try await store.resetCloudCursorV4(scope:scope,expectedGeneration:expectedGeneration)}
    public func commitCloudBatchV4(_ batch:ValidatedCloudBatchV1) async throws->CloudImportReceiptV4 {try await store.commitCloudBatchV4(batch)}
    public func authorizeCloudHistoryV4(_ grant:VerifiedCloudHistoryGrantV1) async throws {try await store.authorizeCloudHistoryV4(grant)}
    public func cloudHistoryV4(scope:CloudScopeV1) async throws->[CloudHistorySnapshotV4] {try await store.cloudHistoryV4(scope:scope)}
    public func cloudDeletionsV4(scope:CloudScopeV1) async throws->[CloudDeletionV1] {try await store.cloudDeletionsV4(scope:scope)}
    public func saveCloudCheckpointV4(_ proof:VerifiedCloudSaveV1) async throws->CloudCheckpointReceiptV4 {try await store.saveCloudCheckpointV4(proof)}
    public func matchingCloudSaveV4(matchID:String) async throws->VerifiedCloudSaveV1? {try await store.matchingCloudSaveV4(matchID:matchID)}
    public func completeNormallyV4(release:VerifiedAuthorityReceiptV1,cloud:VerifiedCloudSaveV1,expectedGeneration:Int64,now:Date) async throws {try await store.completeNormallyV4(release:release,cloud:cloud,expectedGeneration:expectedGeneration,now:now)}
}
