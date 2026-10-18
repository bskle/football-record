import Foundation
import MatchCore
import MatchStore
import MatchSession
import CloudSync

/// Uses the original business facade; the transport ledger never becomes a business repository.
public actor CloudSessionBridge:CloudCommitSink {
    let repository:any SessionRepository & AuthorityRepository & CloudImportRepository
    let client:AuthorityClient?
    let policy:CloudSaveProofPolicy
    var coordinator:(any CloudInboundCoordinator)?
    public init(repository:any SessionRepository & AuthorityRepository & CloudImportRepository,client:AuthorityClient?=nil,policy:CloudSaveProofPolicy = .unavailable){self.repository=repository;self.client=client;self.policy=policy}
    public func attach(_ coordinator:any CloudInboundCoordinator) async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged};self.coordinator=coordinator}

    static func coreScope(_ scope:CloudScope)throws->CloudScopeV1 {try CloudScopeV1(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:scope.activationEpoch)}
    func active(_ scope:CloudScope) async throws {
        guard let b=try await repository.accountBindingV4(),!b.suspended,b.accountID==scope.accountID,b.cloudSpaceID==scope.cloudSpaceID,b.activationEpoch==scope.activationEpoch else {throw CloudError(.accountChanged)}
    }
    func map(_ error:any Error)->any Error {
        guard let cloud=error as? CloudImportError else {return error}
        switch cloud {case .cursorMismatch:return CloudError(.cursorMismatch);case .staleGeneration:return CloudError(.staleGeneration);case .identityMismatch:return CloudError(.accountChanged);case .conflict:return CloudError(.conflict);case .proofUnavailable:return CloudError(.awaitingBusinessImport);default:return CloudError(.invalidPayload)}
    }
    public func importBatch(_ batch:CloudFetchBatch) async throws->CloudImportAcknowledgement {
        guard let coordinator else {throw CloudError(.awaitingBusinessImport)}
        do {
            let validated=try ValidatedCloudBatchV1(canonicalBytes:batch.canonicalBytes())
            // Try the transaction first: an existing first receipt may replay after an epoch fence.
            do {_=try await coordinator.importCloudBatch(validated);return try CloudImportAcknowledgement(batch:batch)}
            catch CloudImportError.proofUnavailable {
                try await active(batch.scope)
                let local=Set(try await repository.matchIDs())
                guard let client else {throw CloudImportError.proofUnavailable}
                for record in validated.records {
                    guard case .matchFacts(let facts)=try record.payload,!local.contains(facts.matchID) else {continue}
                    let intent=try ControlIntentV1.acquire(facts.startIntent,epoch:record.scope.activationEpoch)
                    // Current credentials may read their original account result. This grants history only.
                    let raw=try await client.query(requestID:intent.requestID)
                    let grant=try VerifiedCloudHistoryGrantV1.verify(scope:record.scope,intent:intent,raw:raw,trust:client.trust)
                    try await coordinator.authorizeCloudHistory(grant)
                }
                _=try await coordinator.importCloudBatch(validated)
                return try CloudImportAcknowledgement(batch:batch)
            }
        } catch {throw map(error)}
    }
    public func appliedCursor(scope:CloudScope) async throws->CloudCursor {
        do {try await active(scope);let c=try await repository.cloudCursorV4(scope:Self.coreScope(scope));return try CloudCursor(appliedToken:c.appliedToken,fetchGeneration:c.fetchGeneration)}catch {throw map(error)}
    }
    public func resetCursor(scope:CloudScope,expectedGeneration:Int64) async throws->CloudCursor {
        guard let coordinator else {throw CloudError(.awaitingBusinessImport)}
        do {let c=try await coordinator.resetCloudCursor(scope:Self.coreScope(scope),expectedGeneration:expectedGeneration);return try CloudCursor(appliedToken:c.appliedToken,fetchGeneration:c.fetchGeneration)}catch {throw map(error)}
    }
    public func prepareUpload(matchID:String,scope:CloudScope) async throws->CloudUpload {
        try await active(scope)
        let snapshot=try await repository.snapshotV2(matchID:matchID)
        let facts=try CloudMatchFacts(startIntent:snapshot.business.descriptor.startIntent,starter:snapshot.business.descriptor.starter,events:snapshot.business.events,captureRevisions:snapshot.captureRevisions)
        // Explicit translation; no cloud fact digest is ever used as legacy timelineVersion.
        let mirror=try CloudFactSetV1(startIntent:facts.startIntent,starter:facts.starter,events:facts.events,captureRevisions:facts.captureRevisions)
        guard try mirror.factDigest==facts.factDigest,try mirror.captureDigest==facts.captureDigest else {throw CloudError(.invalidPayload)}
        return try CloudUpload(scope:scope,record:CloudRecord(scope:scope,payload:.matchFacts(facts)))
    }
    public func acceptDevelopmentSave(upload:CloudUpload,evidence:DevelopmentCloudSaveEvidence,ledger:any CloudLedger) async throws->CloudCheckpointReceiptV4 {
        guard case .development(let namespace)=policy,namespace != SQLiteSessionRepository.productionNamespace,evidence.matches(upload),evidence.boundary=="controlledDevelopmentTransport",
              evidence.parts.count==evidence.partChangeTags.count,let terminal=evidence.terminalEventID else {throw CloudImportError.proofUnavailable}
        try await active(upload.scope)
        let saved=try await ledger.uploads(scope:upload.scope),receipts=try await ledger.saveEvidence(scope:upload.scope)
        guard saved.contains(where:{$0.upload==upload && $0.state == .confirmed && $0.originalBytes == (try? upload.canonicalBytes())}),receipts.contains(evidence) else {throw CloudImportError.proofUnavailable}
        var offset=0,parts:[CloudSavedAssetV1]=[]
        for (i,ref) in evidence.parts.enumerated() {
            guard ref.index==i,ref.byteCount>0,offset<=upload.record.canonicalBytes.count-ref.byteCount else {throw CloudImportError.invalidPayload}
            let end=offset+ref.byteCount,bytes=upload.record.canonicalBytes.subdata(in:offset..<end);offset=end
            parts.append(CloudSavedAssetV1(partID:ref.partID,index:ref.index,byteCount:ref.byteCount,digest:ref.digest,changeTag:evidence.partChangeTags[i],bytes:bytes,conditional:true))
        }
        let input=CloudSaveInputV1(record:try CloudRecordV1(scope:Self.coreScope(upload.scope),canonicalBytes:upload.record.canonicalBytes),checkpointID:evidence.checkpointID,confirmationID:evidence.confirmationID,factDigest:evidence.factDigest,captureDigest:evidence.captureDigest,terminalEventID:terminal,manifestBytes:evidence.manifestBytes,manifestChangeTag:evidence.manifestChangeTag,recordChangeTag:evidence.recordChangeTag,conditional:true,parts:parts)
        guard let coordinator else {throw CloudImportError.proofUnavailable}
        return try await coordinator.acceptCloudSave(VerifiedCloudSaveV1.verifyReadback(input,policy:policy))
    }
    /// 024 supplies actual production SDK readback. Development evidence cannot call this boundary.
    public func acceptSDKReadback(upload:CloudUpload,readback:CloudSaveReadback) async throws->CloudCheckpointReceiptV4 {
        guard policy == .productionSDK,let coordinator,readback.scope==upload.scope,readback.recordID==upload.record.recordID,readback.manifestRecordID==upload.checkpointID,
              readback.manifestCondition == .ifServerRecordUnchanged,readback.recordCondition == .ifServerRecordUnchanged else {throw CloudImportError.proofUnavailable}
        try await active(upload.scope)
        let manifest=try JSONDecoder().decode(CloudSaveManifest.self,from:readback.manifestBytes)
        guard let terminal=manifest.terminalEventID else {throw CloudImportError.invalidPayload}
        let parts=readback.parts.map {CloudSavedAssetV1(partID:$0.reference.partID,index:$0.reference.index,byteCount:$0.reference.byteCount,digest:$0.reference.digest,changeTag:$0.changeTag,bytes:$0.readBackBytes,conditional:$0.condition == .ifServerRecordUnchanged)}
        let input=CloudSaveInputV1(record:try CloudRecordV1(scope:Self.coreScope(upload.scope),canonicalBytes:upload.record.canonicalBytes),checkpointID:upload.checkpointID,confirmationID:readback.confirmationID,factDigest:manifest.factDigest,captureDigest:manifest.captureDigest,terminalEventID:terminal,manifestBytes:readback.manifestBytes,manifestChangeTag:readback.manifestChangeTag,recordChangeTag:readback.recordChangeTag,conditional:true,parts:parts)
        return try await coordinator.acceptCloudSave(VerifiedCloudSaveV1.verifyReadback(input,policy:policy))
    }
}
