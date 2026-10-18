import Foundation
import MatchCore

struct StoredCloudHistoryGrant:Codable {let scope:CloudScopeV1;let intent:ControlIntentV1;let raw:Data}
extension MatchStore {
    func validateCloudScopeV4(_ scope:CloudScopeV1)throws->AccountBindingV4 {
        let b=try activeBindingV4();guard scope.accountID==b.accountID,scope.cloudSpaceID==b.cloudSpaceID,scope.activationEpoch==b.activationEpoch else {throw CloudImportError.identityMismatch};return b
    }
    func loadCloudCursorV4(_ scope:CloudScopeV1)throws->CloudCursorV4 {
        let key=try scope.key
        guard let row=try db.rows("SELECT payload,checksum FROM cloud_cursors_v4 WHERE scope=?",[.text(key)]).first else {return try CloudCursorV4(appliedToken:nil,fetchGeneration:0)}
        return try checkedV4(CloudCursorV4.self,row:row,table:"cloud_cursors_v4",key:key)
    }
    public func cloudCursorV4(scope:CloudScopeV1)throws->CloudCursorV4 {try db.transaction {_=try validateCloudScopeV4(scope);return try loadCloudCursorV4(scope)}}
    public func resetCloudCursorV4(scope:CloudScopeV1,expectedGeneration:Int64)throws->CloudCursorV4 {
        let result=try db.transaction {
            _=try validateCloudScopeV4(scope);let prior=try loadCloudCursorV4(scope)
            guard prior.fetchGeneration==expectedGeneration,expectedGeneration<Int64.max else {throw CloudImportError.staleGeneration}
            let next=try CloudCursorV4(appliedToken:nil,fetchGeneration:expectedGeneration+1)
            try writeV4(next,table:"cloud_cursors_v4",idColumn:"scope",id:scope.key);try fail(.beforeCommit);return next
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    func historyGrantV4(scope:CloudScopeV1,matchID:String)throws->VerifiedCloudHistoryGrantV1? {
        let key="history-grant:"+scope.stableZoneKey+":"+matchID
        guard let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]).first,let trust=authorityTrust else {return nil}
        let stored=try checkedV4(StoredCloudHistoryGrant.self,row:row,table:"lifecycle_steps_v4",key:key)
        guard stored.scope==scope else {throw CloudImportError.identityMismatch}
        return try VerifiedCloudHistoryGrantV1.verify(scope:scope,intent:stored.intent,raw:stored.raw,trust:trust)
    }
    public func authorizeCloudHistoryV4(_ grant:VerifiedCloudHistoryGrantV1)throws {
        try db.transaction {
            let b=try activeBindingV4();guard grant.scope.accountID==b.accountID,grant.scope.cloudSpaceID==b.cloudSpaceID,let trust=authorityTrust else {throw CloudImportError.identityMismatch}
            _=try VerifiedCloudHistoryGrantV1.verify(scope:grant.scope,intent:grant.intent,raw:grant.originalAcquire.raw,trust:trust)
            try writeV4(StoredCloudHistoryGrant(scope:grant.scope,intent:grant.intent,raw:grant.originalAcquire.raw),table:"lifecycle_steps_v4",id:"history-grant:"+grant.scope.stableZoneKey+":"+grant.originalAcquire.body.matchID);try fail(.beforeCommit)
        }
    }
    public func cloudHistoryV4(scope:CloudScopeV1)throws->[CloudHistorySnapshotV4] {
        let b=try activeBindingV4();guard scope.accountID==b.accountID,scope.cloudSpaceID==b.cloudSpaceID else {throw CloudImportError.identityMismatch}
        return try db.rows("SELECT h.payload,h.checksum FROM cloud_history_v4 h WHERE h.scope=? AND NOT EXISTS(SELECT 1 FROM cloud_deletions_v4 d WHERE d.scope=h.scope AND d.match_id=h.match_id) ORDER BY h.match_id",[.text(scope.stableZoneKey)]).map {try checkedV4(CloudHistorySnapshotV4.self,row:$0,table:"cloud_history_v4",key:scope.stableZoneKey)}
    }
    public func cloudDeletionsV4(scope:CloudScopeV1)throws->[CloudDeletionV1] {
        let b=try activeBindingV4();guard scope.accountID==b.accountID,scope.cloudSpaceID==b.cloudSpaceID else {throw CloudImportError.identityMismatch}
        return try db.rows("SELECT payload,checksum FROM cloud_deletions_v4 WHERE scope=? ORDER BY match_id",[.text(scope.stableZoneKey)]).map {try checkedV4(CloudDeletionV1.self,row:$0,table:"cloud_deletions_v4",key:scope.stableZoneKey)}
    }
    public func commitCloudBatchV4(_ batch:ValidatedCloudBatchV1)throws->CloudImportReceiptV4 {
        let validated=try ValidatedCloudBatchV1(canonicalBytes:batch.raw),scope=batch.scope,key=try scope.key
        let expected=CloudImportReceiptV4(scope:scope,batchID:batch.batchID,batchDigest:batch.digest,appliedToken:batch.nextToken,fetchGeneration:batch.fetchGeneration)
        let result=try db.transaction {
            // First receipt precedes cursor CAS and current-activation fence. Replays never change a cursor.
            if let row=try db.rows("SELECT digest,receipt FROM cloud_applied_batches_v4 WHERE scope=? AND batch_id=?",[.text(key),.text(batch.batchID)]).first {
                guard row[0].string==batch.digest,let raw=row[1].data,try JSONDecoder().decode(CloudImportReceiptV4.self,from:raw)==expected,try Canonical.data(expected)==raw else {throw CloudImportError.conflict};return expected
            }
            _=try validateCloudScopeV4(scope)
            let cursor=try loadCloudCursorV4(scope)
            guard cursor.fetchGeneration==batch.fetchGeneration else {throw CloudImportError.staleGeneration}
            guard cursor.appliedToken==batch.expectedAppliedToken else {throw CloudImportError.cursorMismatch}
            // Deletions win within a batch regardless of record arrival order. Raw records remain auditable.
            for record in validated.records {
                let raw=try CloudCanonicalV1.encode(record)
                if let row=try db.rows("SELECT payload,checksum FROM cloud_records_v4 WHERE id=?",[.text(record.recordID)]).first {
                    guard row[0].data==raw,row[1].string==Canonical.hash(raw) else {throw CloudImportError.conflict}
                } else {try db.execute("INSERT INTO cloud_records_v4 VALUES (?,?,?,?)",[.text(record.recordID),.text(scope.stableZoneKey),.blob(raw),.text(Canonical.hash(raw))])}
                if case .deletion(let deletion)=try record.payload {
                    guard !deletion.matchID.isEmpty,!deletion.deletionID.isEmpty,deletion.deletedAt.timeIntervalSince1970.isFinite else {throw CloudImportError.invalidPayload}
                    let bytes=try Canonical.data(deletion)
                    try db.execute("INSERT INTO cloud_deletions_v4 VALUES (?,?,?,?) ON CONFLICT(scope,match_id) DO NOTHING",[.text(scope.stableZoneKey),.text(deletion.matchID),.blob(bytes),.text(Canonical.hash(bytes))])
                }
            }
            for record in validated.records {
                let payload=try record.payload
                switch payload {
                case .deletion:break
                case .checkpoint(let checkpoint):
                    guard !checkpoint.checkpointID.isEmpty,!checkpoint.recordIDs.isEmpty,Set(checkpoint.recordIDs).count==checkpoint.recordIDs.count else {throw CloudImportError.invalidPayload}
                    for id in checkpoint.recordIDs {guard try db.rows("SELECT id FROM cloud_records_v4 WHERE id=? AND scope=?",[.text(id),.text(scope.stableZoneKey)]).first != nil else {throw CloudImportError.invalidPayload}}
                case .matchFacts(let facts):
                    if try db.rows("SELECT match_id FROM cloud_deletions_v4 WHERE scope=? AND match_id=?",[.text(scope.stableZoneKey),.text(facts.matchID)]).first != nil {continue}
                    if let existing=try descriptorAndGeneration(facts.matchID) {
                        let current=try loadSnapshot(matchID:facts.matchID)
                        guard current.descriptor.startIntent==facts.startIntent,current.descriptor.starter==facts.starter,current.descriptor.startPermit != nil else {throw CloudImportError.conflict}
                        guard record.scope.activationEpoch==scope.activationEpoch else {throw CloudImportError.readOnly}
                        let priorRevisions=try loadCaptureRevisions(descriptor:current.descriptor)
                        try append(facts.events,matchID:facts.matchID)
                        for revision in facts.captureRevisions {try appendRevision(revision,descriptor:current.descriptor)}
                        if facts.events.contains(where:{!current.events.contains($0)}) || facts.captureRevisions.contains(where:{!priorRevisions.contains($0)}) {guard existing.1<Int64.max else {throw CloudImportError.conflict};try writeDescriptor(current.descriptor,generation:existing.1+1)}
                    } else {
                        guard let grant=try historyGrantV4(scope:record.scope,matchID:facts.matchID),grant.intent.requestID==facts.startIntent.id,grant.originalAcquire.body.recordingDeviceID==facts.startIntent.recordingDeviceID else {throw CloudImportError.proofUnavailable}
                        let history=CloudHistorySnapshotV4(scope:record.scope,recordID:record.recordID,facts:facts,originalAcquire:grant.originalAcquire.raw),raw=try Canonical.data(history)
                        if let row=try db.rows("SELECT payload,checksum FROM cloud_history_v4 WHERE scope=? AND match_id=?",[.text(scope.stableZoneKey),.text(facts.matchID)]).first {
                            let prior=try checkedV4(CloudHistorySnapshotV4.self,row:row,table:"cloud_history_v4",key:facts.matchID)
                            guard prior.facts.startIntent==facts.startIntent,prior.facts.starter==facts.starter,prior.facts.events.allSatisfy({old in !facts.events.contains(where:{$0.eventID==old.eventID && $0 != old})}),prior.facts.captureRevisions.allSatisfy({old in !facts.captureRevisions.contains(where:{$0.id==old.id && $0 != old})}) else {throw CloudImportError.conflict}
                            let merged=try CloudFactSetV1(startIntent:facts.startIntent,starter:facts.starter,events:Array(Dictionary((prior.facts.events+facts.events).map{($0.eventID,$0)},uniquingKeysWith:{$0==($1) ? $0:$1}).values),captureRevisions:Array(Dictionary((prior.facts.captureRevisions+facts.captureRevisions).map{($0.id,$0)},uniquingKeysWith:{$0==($1) ? $0:$1}).values))
                            let mergedRaw=try Canonical.data(CloudHistorySnapshotV4(scope:record.scope,recordID:record.recordID,facts:merged,originalAcquire:grant.originalAcquire.raw))
                            try db.execute("UPDATE cloud_history_v4 SET payload=?,checksum=? WHERE scope=? AND match_id=?",[.blob(mergedRaw),.text(Canonical.hash(mergedRaw)),.text(scope.stableZoneKey),.text(facts.matchID)])
                        } else {try db.execute("INSERT INTO cloud_history_v4 VALUES (?,?,?,?)",[.text(scope.stableZoneKey),.text(facts.matchID),.blob(raw),.text(Canonical.hash(raw))])}
                    }
                }
            }
            try fail(.afterInboundFacts)
            let next=try CloudCursorV4(appliedToken:batch.nextToken,fetchGeneration:batch.fetchGeneration)
            try writeV4(next,table:"cloud_cursors_v4",idColumn:"scope",id:key)
            try db.execute("INSERT INTO cloud_applied_batches_v4 VALUES (?,?,?,?)",[.text(key),.text(batch.batchID),.text(batch.digest),.blob(try Canonical.data(expected))]);try fail(.afterReceipt);try fail(.beforeCommit);return expected
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    func currentCloudFactsV4(_ matchID:String)throws->CloudFactSetV1 {
        let snapshot=try loadSnapshot(matchID:matchID)
        guard !snapshot.diagnostics.contains(where:{$0.severity == .blocking}) else {throw StoreError.unresolvedDiagnostics}
        return try CloudFactSetV1(startIntent:snapshot.descriptor.startIntent,starter:snapshot.descriptor.starter,events:snapshot.events,captureRevisions:loadCaptureRevisions(descriptor:snapshot.descriptor))
    }
    func validateCloudSaveV4(_ proof:VerifiedCloudSaveV1)throws {
        guard cloudSavePolicy==proof.policy else {throw CloudImportError.proofUnavailable}
        let binding=try validateCloudScopeV4(proof.input.record.scope)
        switch (cloudSavePolicy,syncEnvironment,binding.environment) {
        case (.development(let expected),.development(let actual),.development):guard expected==actual else {throw CloudImportError.identityMismatch}
        case (.productionSDK,.production,.production):break
        default:throw CloudImportError.proofUnavailable
        }
        _=try VerifiedCloudSaveV1.verifyReadback(proof.input,policy:cloudSavePolicy)
        guard case .matchFacts(let facts)=try proof.input.record.payload,facts == (try currentCloudFactsV4(facts.matchID)) else {throw StoreError.staleCompletionEvidence}
        let snapshot=try loadSnapshot(matchID:facts.matchID),horizon=([snapshot.descriptor.startIntent.requestedAt]+snapshot.events.map(\.updatedAt)+snapshot.events.map(\.occurredAt)).max() ?? snapshot.descriptor.startIntent.requestedAt
        let replay=MatchReplay.replay(descriptor:snapshot.descriptor,events:snapshot.events,now:horizon)
        guard replay.state == .endedPendingSync,replay.effectiveEvents.first(where:{$0.type == .matchEnded})?.eventID==proof.input.terminalEventID else {throw StoreError.staleCompletionEvidence}
    }
    public func saveCloudCheckpointV4(_ proof:VerifiedCloudSaveV1)throws->CloudCheckpointReceiptV4 {
        let result=try db.transaction {
            try validateCloudSaveV4(proof)
            let i=proof.input,raw=try Canonical.data(i)
            if let row=try db.rows("SELECT payload,checksum FROM cloud_checkpoints_v4 WHERE id=?",[.text(i.confirmationID)]).first {
                guard row[0].data==raw,row[1].string==Canonical.hash(raw) else {throw CloudImportError.conflict}
            } else {try db.execute("INSERT INTO cloud_checkpoints_v4 VALUES (?,?,?,?)",[.text(i.confirmationID),.text(try i.record.payload.matchID),.blob(raw),.text(Canonical.hash(raw))])}
            try fail(.beforeCommit)
            return CloudCheckpointReceiptV4(checkpointID:i.checkpointID,confirmationID:i.confirmationID,matchID:try i.record.payload.matchID,factDigest:i.factDigest,captureDigest:i.captureDigest)
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    public func matchingCloudSaveV4(matchID:String)throws->VerifiedCloudSaveV1? {
        for row in try db.rows("SELECT payload,checksum FROM cloud_checkpoints_v4 WHERE match_id=? ORDER BY rowid DESC",[.text(matchID)]) {
            let input=try checkedV4(CloudSaveInputV1.self,row:row,table:"cloud_checkpoints_v4",key:matchID)
            let proof=try VerifiedCloudSaveV1.verifyReadback(input,policy:cloudSavePolicy)
            do {try validateCloudSaveV4(proof);return proof} catch StoreError.staleCompletionEvidence {continue}
        };return nil
    }
    public func completeNormallyV4(release:VerifiedAuthorityReceiptV1,cloud:VerifiedCloudSaveV1,expectedGeneration:Int64,now:Date)throws {
        try db.transaction {
            let matchID=release.body.matchID,state=try authorityStateV4(matchID:matchID,now:now)
            guard state.status == .releasedNormal,state.verifiedNormalRelease?.raw==release.raw,let acquire=state.acquire,
                  release.body.lockID==acquire.body.lockID,release.body.recordingDeviceID==acquire.body.recordingDeviceID,release.body.activationEpoch==acquire.body.activationEpoch else {throw AuthorityError.intentMismatch}
            try validateCloudSaveV4(cloud)
            guard case .matchFacts(let facts)=try cloud.input.record.payload,facts.matchID==matchID,
                  let stored=try db.rows("SELECT payload,checksum FROM cloud_checkpoints_v4 WHERE id=?",[.text(cloud.input.confirmationID)]).first,
                  try checkedV4(CloudSaveInputV1.self,row:stored,table:"cloud_checkpoints_v4",key:cloud.input.confirmationID)==cloud.input else {throw CloudImportError.proofUnavailable}
            let snapshot=try loadSnapshot(matchID:matchID)
            guard snapshot.generation==expectedGeneration else {throw StoreError.staleGeneration}
            let evidence=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:snapshot.descriptor,events:snapshot.events,confirmationID:"m4:"+release.body.receiptID+":"+cloud.input.confirmationID,now:now)
            guard evidence.terminalEventID==cloud.input.terminalEventID else {throw StoreError.staleCompletionEvidence}
            try rememberCaptureCompletionConfirmation(evidence:evidence,digest:cloud.input.captureDigest,hasCapture:!facts.captureRevisions.isEmpty)
            try db.execute("INSERT INTO completion_v2 VALUES (?,?,?) ON CONFLICT(match_id) DO UPDATE SET evidence=excluded.evidence,capture_digest=excluded.capture_digest",[.text(matchID),.blob(try Canonical.data(evidence)),.text(cloud.input.captureDigest)])
            try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
