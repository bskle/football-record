import Foundation
struct StoredLifecycleControlV4:Codable {let intent:ControlIntentV1;let accountID:String;let epoch:Int64;let raw:Data}
struct StoredAnalyticsV4:Codable {var enabled=false;var pending:[AnalyticsEventV4]=[];var acknowledged:[AnalyticsEventV4]=[]}
public enum LocalBusinessErasureErrorV4: Error, Sendable, Equatable {
    case residualBusiness(table: String)
    case corruptControl
}
/// The same inventory is used by the mutating erasure and its read-only current-zero check.
private let localBusinessTablesV4 = ["matches","events","commands","outbox","inbound","diagnostics","completion","capture_identities","capture_revisions","capture_operations","capture_operation_history","business_outbox","commands_v2","completion_confirmations","completion_v2","sync_delivery_v3","sync_fragments_v3","sync_context_v3","sync_registry_v3","sync_routes_v3","sync_sequences_v3","sync_inbox_v3","sync_acknowledgements_v3","sync_ack_controls_v3","sync_receive_progress_v3","cloud_applied_batches_v4","cloud_checkpoints_v4","cloud_records_v4","cloud_history_v4","cloud_cursors_v4","cloud_deletions_v4","peer_contexts_v4","peer_inbox_v4","peer_grants_v4"]
private let localBusinessWitnessPredicateV4 = "id LIKE 'normal-intent:%' OR id LIKE 'migration-checkpoint:%'"
/// Evidence for one successful SQL snapshot, not a durable completion receipt.
public struct LocalBusinessErasureWitnessV4: Sendable {
    public let requestID: String
    public let requestDigest: String
    public let originalScope: CloudScopeV1
    public let currentSagaRevision: Int64
    public let backendReceiptDigest: String
}
extension MatchStore {
    func readLifecycleV4<T:Codable>(_ type:T.Type,_ key:String)throws->T? {
        guard let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]).first else {return nil}
        return try checkedV4(type,row:row,table:"lifecycle_steps_v4",key:key)
    }
    func verifyLifecycleV4(_ value:StoredLifecycleControlV4)throws->VerifiedAuthorityReceiptV1 {
        guard let trust=authorityTrust else {throw AuthorityError.unavailable}
        return try VerifiedAuthorityReceiptV1.verify(value.raw,expected:AuthorityExpectedIntent(value.intent,accountID:value.accountID,epoch:value.epoch),trust:trust)
    }
    public func lifecycleControlIntentV4(requestID:String)throws->ControlIntentV1? {try controlV4(requestID)}
    public func lifecycleReceiptV4(requestID:String)throws->Data? {
        guard let value=try readLifecycleV4(StoredLifecycleControlV4.self,"lifecycle-result:"+requestID) else {return nil}
        return try verifyLifecycleV4(value).raw
    }
    public func latestMigrationV4()throws->AuthorityMigrationV1? {
        guard let value=try readLifecycleV4(StoredLifecycleControlV4.self,"migration-latest") else {return nil}
        return try verifyLifecycleV4(value).body.migration
    }
    func migrationBlocksBusinessV4()throws->Bool {guard let m=try latestMigrationV4() else {return false};return m.state != "activated"}
    func deletionBlocksBusinessV4()throws->Bool {try db.rows("SELECT id FROM lifecycle_steps_v4 WHERE id LIKE 'deletion:%' LIMIT 1").first != nil}
    func validateAccountBusinessWriteV4()throws {if let b=try currentBindingV4() {guard !b.suspended,try !migrationBlocksBusinessV4(),try !deletionBlocksBusinessV4() else {throw AuthorityError.identityChanged}}}
    public func acceptLifecycleResultV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1)throws {
        try db.transaction {
            guard let b=try currentBindingV4(),let trust=authorityTrust,try controlV4(intent.requestID)==intent else {throw AuthorityError.intentMismatch}
            let key="lifecycle-result:"+intent.requestID
            // Original results are immutable reads. They never project historical state over a newer round.
            if let first=try readLifecycleV4(StoredLifecycleControlV4.self,key) {
                guard first.intent==intent,first.raw==receipt.raw,first.accountID==b.accountID else {throw AuthorityError.conflict}
                _=try verifyLifecycleV4(first);return
            }
            let activates=intent.operation == .activateMigration || intent.operation == .forceMigration
            let epoch=receipt.body.activationEpoch
            guard activates ? epoch>=b.activationEpoch:epoch==b.activationEpoch else {throw AuthorityError.identityChanged}
            let verified=try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:epoch),trust:trust)
            let r=verified.body
            switch intent.operation {
            case .prepareMigration,.checkpointMigration,.activateMigration,.requestLostMigration,.forceMigration:
                guard let m=r.migration,m.cloudSpaceID==b.cloudSpaceID,m.oldActivationEpoch>0,m.oldActivationEpoch<=epoch,
                      ["normal","lost"].contains(m.kind),["oldPhonePrepared","oldPhoneDeactivated","waitingPeriod","activated"].contains(m.state),
                      m.requestedAt>=0,m.eligibleAt>=m.requestedAt,m.eligibleAt<=9_007_199_254_740_991,
                      m.kind != "lost" || m.eligibleAt-m.requestedAt==604800 else {throw AuthorityError.intentMismatch}
                for id in [m.migrationID,m.newPhoneID,m.cloudSpaceID] {try AuthorityWire.identifier(id)}
                for id in [m.oldPhoneID,m.checkpointID,m.contentCommitment] {try AuthorityWire.identifier(id,empty:true)}
                if let prior=try latestMigrationV4() {
                    if prior.migrationID==m.migrationID {
                        let rank:[String:Int] = ["oldPhonePrepared":0,"waitingPeriod":0,"oldPhoneDeactivated":1,"activated":2]
                        guard prior.kind==m.kind,prior.oldPhoneID==m.oldPhoneID,prior.newPhoneID==m.newPhoneID,prior.cloudSpaceID==m.cloudSpaceID,prior.oldActivationEpoch==m.oldActivationEpoch,prior.requestedAt==m.requestedAt,prior.eligibleAt==m.eligibleAt,
                              rank[m.state,default:-1]>=rank[prior.state,default:3],prior.checkpointID.isEmpty || (prior.checkpointID==m.checkpointID && prior.contentCommitment==m.contentCommitment) else {throw AuthorityError.conflict}
                    } else {
                        guard prior.state=="activated",m.oldActivationEpoch==b.activationEpoch,m.oldActivationEpoch>prior.oldActivationEpoch,
                              (intent.operation == .prepareMigration && m.state=="oldPhonePrepared") || (intent.operation == .requestLostMigration && m.state=="waitingPeriod") else {throw AuthorityError.conflict}
                    }
                }
                let expected:AuthorityResult=switch intent.operation {case .prepareMigration:.waitingMigration;case .checkpointMigration:.checkpointAccepted;case .requestLostMigration:.waitingPeriod;default:.activated}
                guard r.result==expected,(intent.operation != .prepareMigration || m.oldPhoneID==b.deviceID || (m.newPhoneID==b.deviceID && b.role == .waiting)),(intent.operation != .activateMigration && intent.operation != .forceMigration) || (m.newPhoneID==b.deviceID && epoch>m.oldActivationEpoch) else {throw AuthorityError.intentMismatch}
                if intent.fields.checkpointID != nil {guard m.checkpointID==intent.fields.checkpointID,m.contentCommitment==intent.fields.contentCommitment else {throw AuthorityError.intentMismatch}}
                try writeV4(StoredLifecycleControlV4(intent:intent,accountID:b.accountID,epoch:epoch,raw:receipt.raw),table:"lifecycle_steps_v4",id:"migration-latest")
                if (r.result == .checkpointAccepted && m.oldPhoneID==b.deviceID && b.activationEpoch==m.oldActivationEpoch) || (r.result == .activated && b.activationEpoch==m.oldActivationEpoch) {_=try advanceIdentityGenerationLockedV4();try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")}
            case .lostRecovery:
                guard r.result == .grantIssued,let grant=r.lostRecovery,grant.newPhoneID==b.deviceID,grant.migrationID==intent.fields.migrationID,grant.expiresAt>=r.issuedAt,grant.expiresAt<=9_007_199_254_740_991,grant.expiresAt-r.issuedAt<=300,intent.fields.originalActivationEpoch==b.activationEpoch,r.matchID==intent.fields.matchID,r.lockID==intent.fields.lockID,r.recordingDeviceID==intent.fields.originalRecordingDeviceID else {throw AuthorityError.intentMismatch}
            case .terminateLost:
                guard r.result == .releasedAbnormal,intent.fields.originalActivationEpoch==b.activationEpoch,r.matchID==intent.fields.matchID,r.lockID==intent.fields.lockID,r.recordingDeviceID==intent.fields.originalRecordingDeviceID else {throw AuthorityError.intentMismatch}
            default:throw AuthorityError.invalidWire
            }
            let value=StoredLifecycleControlV4(intent:intent,accountID:b.accountID,epoch:epoch,raw:receipt.raw)
            try writeV4(value,table:"lifecycle_steps_v4",id:key)
            try confirmControlLockedV4(intent);try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func deletionSagasV4()throws->[DeletionSagaV4] {try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'deletion:%' ORDER BY rowid").map {try checkedV4(DeletionSagaV4.self,row:$0,table:"lifecycle_steps_v4",key:"deletion")}}
    public func deletionSagaV4(requestID:String)throws->DeletionSagaV4? {try readLifecycleV4(DeletionSagaV4.self,"deletion:"+requestID)}
    func validateDeletionScopeLockedV4(_ saga:DeletionSagaV4)throws {
        guard let original=saga.originalScope,let b=try currentBindingV4(),
              Array(saga.accountID.utf8)==Array(original.accountID.utf8),saga.activationEpoch==original.activationEpoch,
              Array(b.accountID.utf8)==Array(original.accountID.utf8),Array(b.cloudSpaceID.utf8)==Array(original.cloudSpaceID.utf8),b.activationEpoch==original.activationEpoch else {throw AuthorityError.identityChanged}
        _=try CloudScopeV1(accountID:original.accountID,cloudSpaceID:original.cloudSpaceID,zoneID:original.zoneID,activationEpoch:original.activationEpoch)
    }
    public func createDeletionSagaV4(_ saga:DeletionSagaV4)throws {
        try db.transaction {
            let rows = try validateInitialDeletionRowsLockedV1()
            let consumption = try initialDeletionConsumptionForSagaLockedV1(saga, rows: rows)
            let priorExists = try deletionSagaV4(requestID:saga.intent.requestID) != nil
            try createDeletionSagaLockedV4(saga, initialDeletionConsumption: consumption)
            if let consumption { try finishInitialDeletionConsumptionLockedV1(consumption, rows: rows) }
            try validateInitialDeletionRowsLockedV1(); if !priorExists { try fail(.beforeCommit) }
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    func createDeletionSagaLockedV4(_ saga:DeletionSagaV4,initialDeletionConsumption:InitialDeletionSagaConsumptionV1?)throws {
        try validateDeletionScopeLockedV4(saga)
        if let prior=try deletionSagaV4(requestID:saga.intent.requestID) {guard prior.originalScope==saga.originalScope,prior.intent==saga.intent,prior.accountID==saga.accountID,prior.recoveryCapability==saga.recoveryCapability,prior.cloudChoice==saga.cloudChoice,prior.localChoice==saga.localChoice,prior.healthChoice==saga.healthChoice else {throw AuthorityError.conflict};return}
        let b=try activeBindingV4();guard b.role == .phone,b.accountID==saga.accountID,b.activationEpoch==saga.activationEpoch,saga.revision==0,!saga.backendDeleted,try !migrationBlocksBusinessV4() else {throw AuthorityError.identityChanged}
        for id in try matchIDs() {let state=try authorityStateV4(matchID:id,now:Date());guard ![.held,.terminationPending].contains(state.status) else {throw AuthorityError.terminalLock}}
        _=try prepareControlLockedV4(saga.intent,initialDeletionConsumption:initialDeletionConsumption)
        try writeV4(saga,table:"lifecycle_steps_v4",id:"deletion:"+saga.intent.requestID);try fail(.afterReceipt)
    }
    func writeDeletionV4(_ saga:DeletionSagaV4,expectedRevision:Int64)throws {
        try validateDeletionScopeLockedV4(saga)
        guard let prior=try deletionSagaV4(requestID:saga.intent.requestID),prior.originalScope==saga.originalScope,prior.revision==expectedRevision,expectedRevision>=0,expectedRevision<Int64.max,saga.revision==expectedRevision+1,
              prior.intent==saga.intent,prior.accountID==saga.accountID,prior.activationEpoch==saga.activationEpoch,prior.recoveryCapability==saga.recoveryCapability,
              prior.cloudChoice==saga.cloudChoice,prior.localChoice==saga.localChoice,prior.healthChoice==saga.healthChoice,prior.healthConfirmed==saga.healthConfirmed,
              !prior.backendDeleted || saga.backendDeleted,prior.backendReceipt==nil || prior.backendReceipt==saga.backendReceipt else {throw StoreError.staleGeneration}
        guard saga.localProgress != .completed || prior.localProgress == .completed else {throw AuthorityError.intentMismatch}
        // A client progress update cannot invent backend deletion proof.
        guard prior.backendDeleted==saga.backendDeleted,prior.backendReceipt==saga.backendReceipt else {throw AuthorityError.intentMismatch}
        try writeV4(saga,table:"lifecycle_steps_v4",id:"deletion:"+saga.intent.requestID)
    }
    public func updateDeletionSagaV4(_ saga:DeletionSagaV4,expectedRevision:Int64)throws {
        try db.transaction {try writeDeletionV4(saga,expectedRevision:expectedRevision);try fail(.beforeCommit)};if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func acceptDeletionV4(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64)throws->DeletionSagaV4 {
        let result=try db.transaction {
            guard var saga=try deletionSagaV4(requestID:requestID),let trust=authorityTrust,saga.revision==expectedRevision,expectedRevision<Int64.max else {throw StoreError.staleGeneration}
            try validateDeletionScopeLockedV4(saga)
            let verified=try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(saga.intent,accountID:saga.accountID,epoch:saga.activationEpoch),trust:trust)
            guard verified.body.result == .deleted,verified.body.deletion?.backend=="backendDeleted",verified.body.deletion?.apple=="revoked" else {throw AuthorityError.intentMismatch}
            if saga.backendDeleted {guard saga.backendReceipt==receipt.raw else {throw AuthorityError.conflict};return saga}
            _=try advanceIdentityGenerationLockedV4()
            saga.backendDeleted=true;saga.backendReceipt=receipt.raw;saga.lastIssue=nil;saga.revision += 1
            try writeV4(saga,table:"lifecycle_steps_v4",id:"deletion:"+requestID)
            if let b=try currentBindingV4() {guard b.accountID==saga.accountID else {throw AuthorityError.identityChanged};try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")}
            var analytics=try analyticsStateV4();analytics.enabled=false;analytics.pending=[];try writeV4(analytics,table:"lifecycle_steps_v4",id:"analytics-state")
            try confirmControlLockedV4(saga.intent);try fail(.afterReceipt);try fail(.beforeCommit);return saga
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    public func eraseLocalBusinessV4(requestID:String,expectedRevision:Int64)throws->DeletionSagaV4 {
        let result=try db.transaction {
            let initialRows = try validateInitialDeletionRowsLockedV1()
            guard var saga=try deletionSagaV4(requestID:requestID),saga.revision==expectedRevision,saga.backendDeleted,saga.backendReceipt != nil,saga.localChoice == .delete,expectedRevision<Int64.max else {throw AuthorityError.intentMismatch}
            try validateDeletionScopeLockedV4(saga)
            for id in try matchIDs() {if let descriptor=try descriptorAndGeneration(id)?.0 {guard try loadOperations(matchID:id,descriptor:descriptor).allSatisfy({$0.state != .pending && $0.state != .needsReconciliation}) else {throw AuthorityError.unavailable}}}
            try db.validateLocalErasureLayoutV4()
            try validateDeletionControlRowsLockedV4()
            try validateCurrentWatchRegistrationRowsLockedV4()
            for table in localBusinessTablesV4 { try db.execute("DELETE FROM "+table) }
            try db.execute("DELETE FROM lifecycle_steps_v4 WHERE "+localBusinessWitnessPredicateV4)
            try assertLocalBusinessZeroLockedV4()
            saga.localProgress = .completed;saga.revision += 1
            try writeV4(saga,table:"lifecycle_steps_v4",id:"deletion:"+requestID)
            try compactInitialDeletionAfterEraseLockedV1(saga, rows: initialRows)
            try fail(.beforeCommit);return saga
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    func analyticsStateV4()throws->StoredAnalyticsV4 {try readLifecycleV4(StoredAnalyticsV4.self,"analytics-state") ?? StoredAnalyticsV4()}
    public func analyticsEnabledV4()throws->Bool {try analyticsStateV4().enabled}
    public func setAnalyticsEnabledV4(_ enabled:Bool)throws {
        try db.transaction {if enabled {_=try activeBindingV4();guard try !deletionBlocksBusinessV4() else {throw AuthorityError.identityChanged}};var state=try analyticsStateV4();state.enabled=enabled;if !enabled {state.pending=[]};try writeV4(state,table:"lifecycle_steps_v4",id:"analytics-state");try fail(.beforeCommit)}
    }
    public func enqueueAnalyticsV4(_ event:AnalyticsEventV4)throws {
        try db.transaction {
            var state=try analyticsStateV4();guard state.enabled else {return};_=try activeBindingV4()
            if let prior=(state.pending+state.acknowledged).first(where:{$0.requestID==event.requestID}) {guard prior==event else {throw AuthorityError.conflict};return}
            guard state.pending.count<1000,state.acknowledged.count<10000 else {throw AuthorityError.unavailable}
            state.pending.append(event);try writeV4(state,table:"lifecycle_steps_v4",id:"analytics-state");try fail(.beforeCommit)
        }
    }
    public func pendingAnalyticsV4()throws->[AnalyticsEventV4] {try analyticsStateV4().pending}
    public func acknowledgeAnalyticsV4(requestID:String)throws {
        try db.transaction {var state=try analyticsStateV4();if let first=state.pending.first(where:{$0.requestID==requestID}) {state.pending.removeAll {$0.requestID==requestID};state.acknowledged.append(first);try writeV4(state,table:"lifecycle_steps_v4",id:"analytics-state")};try fail(.beforeCommit)}
    }
    public func cloudRecordV4(scope:CloudScopeV1,recordID:String)throws->CloudRecordV1? {
        let b=try currentBindingV4();guard b?.accountID==scope.accountID,b?.cloudSpaceID==scope.cloudSpaceID else {throw CloudImportError.identityMismatch}
        guard let row=try db.rows("SELECT payload,checksum FROM cloud_records_v4 WHERE id=? AND scope=?",[.text(recordID),.text(scope.stableZoneKey)]).first else {return nil}
        return try checkedV4(CloudRecordV1.self,row:row,table:"cloud_records_v4",key:recordID)
    }
    public func accountFactRecordsV4(scope:CloudScopeV1)throws->[CloudRecordV1] {
        _=try validateCloudScopeV4(scope)
        let ids=try matchIDs();var result=try ids.map {try CloudRecordV1(scope:scope,payload:.matchFacts(currentCloudFactsV4($0)))}
        for history in try cloudHistoryV4(scope:scope) where !ids.contains(history.facts.matchID) {result.append(try CloudRecordV1(scope:scope,payload:.matchFacts(history.facts)))}
        return result.sorted {$0.recordID<$1.recordID}
    }
    func validateAccountCheckpointV4(migrationID:String,proof:VerifiedAccountCheckpointV4)throws {
        let input=proof.input,b=try validateCloudScopeV4(input.record.scope)
        guard proof.policy==cloudSavePolicy,let migration=try latestMigrationV4(),migration.migrationID==migrationID,migration.state=="oldPhonePrepared",migration.oldPhoneID==b.deviceID,
              case .checkpoint(let checkpoint)=try input.record.payload,
              checkpoint.recordIDs == (try accountFactRecordsV4(scope:input.record.scope).map(\.recordID).sorted()) else {throw CloudImportError.proofUnavailable}
        switch (cloudSavePolicy,syncEnvironment,b.environment) {
        case (.development(let expected),.development(let actual),.development):guard expected==actual else {throw CloudImportError.identityMismatch}
        case (.productionSDK,.production,.production):break
        default:throw CloudImportError.proofUnavailable
        }
        _=try VerifiedAccountCheckpointV4.verifyReadback(input,policy:cloudSavePolicy)
    }
    public func saveMigrationCheckpointV4(migrationID:String,proof:VerifiedAccountCheckpointV4)throws {
        try db.transaction {try validateAccountCheckpointV4(migrationID:migrationID,proof:proof)
            let key="migration-checkpoint:"+migrationID
            if let prior=try readLifecycleV4(CloudSaveInputV1.self,key) {guard prior==proof.input else {throw AuthorityError.conflict}}
            else {try writeV4(proof.input,table:"lifecycle_steps_v4",id:key)}
            try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func migrationCheckpointV4(migrationID:String)throws->VerifiedAccountCheckpointV4? {
        guard let input=try readLifecycleV4(CloudSaveInputV1.self,"migration-checkpoint:"+migrationID) else {return nil}
        let proof=try VerifiedAccountCheckpointV4.verifyReadback(input,policy:cloudSavePolicy);try validateAccountCheckpointV4(migrationID:migrationID,proof:proof);return proof
    }

}

extension MatchStore {
    private func assertLocalBusinessZeroLockedV4() throws {
        for table in localBusinessTablesV4 {
            // Count existence, never decode residual facts into an apparent empty result.
            guard try db.rows("SELECT 1 FROM "+table+" LIMIT 1").isEmpty else {
                throw LocalBusinessErasureErrorV4.residualBusiness(table: table)
            }
        }
        guard try db.rows("SELECT 1 FROM lifecycle_steps_v4 WHERE "+localBusinessWitnessPredicateV4+" LIMIT 1").isEmpty else {
            throw LocalBusinessErasureErrorV4.residualBusiness(table: "lifecycle_steps_v4")
        }
    }
    /// Read on the original facade after writers have drained. The witness is not cached authority.
    public func validateLocalBusinessErasedV4(requestID: String, requestDigest: String, scope: CloudScopeV1) throws -> LocalBusinessErasureWitnessV4 {
        do { return try db.transaction {
            try validateInitialDeletionRowsLockedV1()
            try db.validateLocalErasureLayoutV4()
            try validateDeletionControlRowsLockedV4()
            try validateCurrentWatchRegistrationRowsLockedV4()
            guard let saga = try deletionSagaV4(requestID: requestID), let original = saga.originalScope,
                  let receipt = saga.backendReceipt, let trust = authorityTrust,
                  saga.intent.requestID.utf8.elementsEqual(requestID.utf8), saga.intent.digest.utf8.elementsEqual(requestDigest.utf8),
                  original == scope, saga.backendDeleted, saga.localChoice == .delete, saga.localProgress == .completed,
                  saga.revision >= 2 else { throw AuthorityError.intentMismatch }
            // Codable's synthesized Saga initializer does not re-run these original invariants.
            _ = try DeletionSagaV4(intent: saga.intent, accountID: saga.accountID, activationEpoch: saga.activationEpoch,
                recoveryCapability: saga.recoveryCapability, cloudChoice: saga.cloudChoice, localChoice: saga.localChoice,
                healthChoice: saga.healthChoice, healthConfirmed: saga.healthConfirmed, originalScope: original)
            try validateDeletionScopeLockedV4(saga)
            guard let control = try controlV4(requestID), try Canonical.data(control) == Canonical.data(saga.intent),
                  try db.scalar("SELECT match_id FROM control_intents_v4 WHERE id=?", [.text(requestID)]).string == "" else { throw AuthorityError.intentMismatch }
            let verified = try VerifiedAuthorityReceiptV1.verify(receipt,
                expected: AuthorityExpectedIntent(saga.intent, accountID: saga.accountID, epoch: saga.activationEpoch), trust: trust)
            guard verified.body.result == .deleted, verified.body.deletion?.backend == "backendDeleted",
                  verified.body.deletion?.apple == "revoked" else { throw AuthorityError.intentMismatch }
            try assertLocalBusinessZeroLockedV4()
            return LocalBusinessErasureWitnessV4(requestID: saga.intent.requestID, requestDigest: saga.intent.digest,
                originalScope: original, currentSagaRevision: saga.revision, backendReceiptDigest: AuthorityWire.hash(receipt))
        } } catch is DecodingError {
            throw LocalBusinessErasureErrorV4.corruptControl
        }
    }
}
