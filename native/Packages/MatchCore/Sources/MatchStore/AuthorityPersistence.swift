import Foundation
import MatchCore

struct StoredAuthorityResult: Codable { let intent: ControlIntentV1; let raw: Data; let receipt: AuthorityReceiptV4 }
struct StoredAuthorityProjection: Codable {
    var acquireRequestID: String?
    var releaseRequestID: String?
    var status: AuthorityStatusV4 = .unknown
    var liveRaw: Data?
    var liveQuery: LiveLockQueryV1?
}
extension MatchStore {
    func checkedV4<T: Codable>(_ type: T.Type, row: [SQLValue], table: String, key: String) throws -> T {
        guard let raw=row[0].data, row[1].string == Canonical.hash(raw) else { throw StoreError.corruptPayload(table:table,key:key) }
        let result=try JSONDecoder().decode(type,from:raw)
        guard try Canonical.data(result)==raw else { throw StoreError.corruptPayload(table:table,key:key) };return result
    }
    func writeV4<T: Encodable>(_ value:T,table:String,idColumn:String="id",id:String) throws {
        let raw=try Canonical.data(value)
        try db.execute("INSERT INTO " + table + " (" + idColumn + ",payload,checksum) VALUES (?,?,?) ON CONFLICT(" + idColumn + ") DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum",[.text(id),.blob(raw),.text(Canonical.hash(raw))])
    }
    func currentBindingV4() throws -> AccountBindingV4? {
        guard let row=try db.rows("SELECT payload,checksum FROM account_binding_v4 WHERE id='current'").first else { return nil }
        let b=try checkedV4(AccountBindingV4.self,row:row,table:"account_binding_v4",key:"current")
        guard let trust=authorityTrust, trust.environment==b.environment else { throw AuthorityError.unavailable };return b
    }
    func activeBindingV4() throws -> AccountBindingV4 {
        guard let binding=try currentBindingV4(), !binding.suspended else { throw AuthorityError.identityChanged };return binding
    }
    public func bindAccountV4(_ binding: AccountBindingV4) throws {
        guard let trust=authorityTrust,trust.environment==binding.environment else { throw AuthorityError.unavailable }
        switch syncEnvironment { case .production: guard binding.environment == .production else { throw AuthorityError.identityChanged }
        case .development: guard binding.environment == .development else { throw AuthorityError.identityChanged } }
        try db.transaction {
            if let prior=try currentBindingV4() { guard prior==binding else { throw AuthorityError.identityChanged };return }
            try writeV4(binding,table:"account_binding_v4",id:"current");try fail(.beforeCommit)
        }
        if fault == .afterCommit { throw StoreError.responseLost }
    }
    public func accountBindingV4() throws -> AccountBindingV4? { try currentBindingV4() }
    public func suspendAccountV4() throws {
        try db.transaction {
            _=try advanceIdentityGenerationLockedV4()
            guard let b=try currentBindingV4() else { return }
            try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")
            try fail(.beforeCommit)
        }
    }
    func controlV4(_ id:String) throws -> ControlIntentV1? {
        guard let row=try db.rows("SELECT payload,checksum FROM control_intents_v4 WHERE id=?",[.text(id)]).first else { return nil }
        return try checkedV4(ControlIntentV1.self,row:row,table:"control_intents_v4",key:id)
    }
    public func prepareControlV4(_ intent: ControlIntentV1) throws -> ControlIntentReceiptV4 {
        let result=try db.transaction {try prepareControlLockedV4(intent)}
        if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    func prepareControlLockedV4(_ intent:ControlIntentV1,initialDeletionConsumption:InitialDeletionSagaConsumptionV1?=nil)throws->ControlIntentReceiptV4 {
        try requireInitialDeletionControlClaimLockedV1(intent, consumption: initialDeletionConsumption)
        if let prior=try controlV4(intent.requestID) { guard prior==intent else { throw AuthorityError.conflict };return ControlIntentReceiptV4(requestID:intent.requestID,digest:intent.digest) }
        let b=try activeBindingV4()
        if let epoch=intent.fields.activationEpoch { guard epoch==b.activationEpoch else { throw AuthorityError.identityChanged } }
        if intent.operation == .acquire { guard try !migrationBlocksBusinessV4(),try !deletionBlocksBusinessV4(),b.role != .waiting else { throw AuthorityError.identityChanged } }
        let raw=try Canonical.data(intent)
        try db.execute("INSERT INTO control_intents_v4 VALUES (?,?,?,?)",[.text(intent.requestID),.text(intent.matchID),.blob(raw),.text(Canonical.hash(raw))]);try readyControlLockedV4(intent);try fail(.beforeCommit)
        return ControlIntentReceiptV4(requestID:intent.requestID,digest:intent.digest)
    }
    public func pendingControlsV4() throws -> [ControlIntentV1] {
        try controlQueueV4().filter{$0.state != .confirmed}.map(\.intent)
    }
    func resultV4(_ requestID:String) throws -> StoredAuthorityResult? {
        guard let row=try db.rows("SELECT payload,checksum FROM authority_results_v4 WHERE request_id=?",[.text(requestID)]).first else { return nil }
        return try checkedV4(StoredAuthorityResult.self,row:row,table:"authority_results_v4",key:requestID)
    }
    func projectionV4(_ matchID:String) throws -> StoredAuthorityProjection {
        guard let row=try db.rows("SELECT payload,checksum FROM authority_projection_v4 WHERE match_id=?",[.text(matchID)]).first else { return StoredAuthorityProjection() }
        return try checkedV4(StoredAuthorityProjection.self,row:row,table:"authority_projection_v4",key:matchID)
    }
    func verifiedResultV4(_ stored:StoredAuthorityResult,binding:AccountBindingV4) throws -> VerifiedAuthorityReceiptV1 {
        guard let trust=authorityTrust else { throw AuthorityError.unavailable }
        return try VerifiedAuthorityReceiptV1.verify(stored.raw,expected:AuthorityExpectedIntent(stored.intent,accountID:binding.accountID,epoch:binding.activationEpoch),trust:trust)
    }
    public func recordAuthorityResultV4(_ receipt: VerifiedAuthorityReceiptV1) throws -> AuthorityReceiptV4 {
        let result=try db.transaction {
            let b=try activeBindingV4(),r=receipt.body
            guard let intent=try controlV4(r.requestID),let trust=authorityTrust else { throw AuthorityError.intentMismatch }
            _ = try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:b.activationEpoch),trust:trust)
            if let first=try resultV4(r.requestID) { guard first.raw==receipt.raw else { throw AuthorityError.conflict };return first.receipt }
            var projection=try projectionV4(r.matchID)
            switch (r.operation,r.result) {
            case (.acquire,.held):
                guard r.matchID==intent.fields.matchID,r.recordingDeviceID==intent.fields.recordingDeviceID,!r.lockID.isEmpty else { throw AuthorityError.intentMismatch }
                if projection.acquireRequestID==nil { projection.acquireRequestID=r.requestID }
                if projection.status == .unknown { projection.status = .held }
            case (.acquire,.originalMatch): break
            case (.terminate,.releasedNormal),(.terminate,.releasedAbnormal),(.terminateLost,.releasedAbnormal):
                guard let acquireID=projection.acquireRequestID,let prior=try resultV4(acquireID) else { throw AuthorityError.intentMismatch }
                let a=try verifiedResultV4(prior,binding:b).body
                guard a.matchID==r.matchID,a.lockID==r.lockID,a.recordingDeviceID==r.recordingDeviceID,a.activationEpoch==r.activationEpoch,
                      (intent.fields.lockID ?? "")==r.lockID else { throw AuthorityError.intentMismatch }
                if let releaseID=projection.releaseRequestID,releaseID != r.requestID { throw AuthorityError.conflict }
                projection.releaseRequestID=r.requestID;projection.status = r.result == .releasedNormal ? .releasedNormal : .releasedAbnormal
                projection.liveRaw=nil;projection.liveQuery=nil
            default:
                guard r.matchID.isEmpty,r.lockID.isEmpty,r.recordingDeviceID.isEmpty else { throw AuthorityError.intentMismatch }
            }
            let output=AuthorityReceiptV4(requestID:r.requestID,receiptID:r.receiptID,rawDigest:AuthorityWire.hash(receipt.raw),status:projection.status)
            let stored=StoredAuthorityResult(intent:intent,raw:receipt.raw,receipt:output),raw=try Canonical.data(stored)
            try db.execute("INSERT INTO authority_results_v4 VALUES (?,?,?,?,?)",[.text(r.receiptID),.text(r.requestID),.text(r.matchID),.blob(raw),.text(Canonical.hash(raw))])
            if !r.matchID.isEmpty { try writeV4(projection,table:"authority_projection_v4",idColumn:"match_id",id:r.matchID) }
            try confirmControlLockedV4(intent);try fail(.afterReceipt);try fail(.beforeCommit);return output
        }
        if fault == .afterCommit { throw StoreError.responseLost };return result
    }
    public func recordLiveLockV4(_ proof: VerifiedLiveLockV1, now: Date) throws {
        try db.transaction {
            let b=try activeBindingV4();guard let trust=authorityTrust else { throw AuthorityError.unavailable }
            let verified=try VerifiedLiveLockV1.verify(proof.raw,query:proof.query,accountID:b.accountID,trust:trust,now:now)
            guard verified.body.activationEpoch==b.activationEpoch,let first=try resultV4(proof.query.acquireRequestID) else { throw AuthorityError.intentMismatch }
            let acquire=try verifiedResultV4(first,binding:b).body
            guard acquire.receiptID==proof.body.receiptID,acquire.matchID==proof.body.matchID,acquire.lockID==proof.body.lockID,acquire.recordingDeviceID==proof.body.recordingDeviceID else { throw AuthorityError.intentMismatch }
            var p=try projectionV4(proof.body.matchID)
            if [.releasedNormal,.releasedAbnormal,.terminal].contains(p.status),proof.body.status == .held { throw AuthorityError.terminalLock }
            if proof.body.status == .terminal && p.releaseRequestID==nil { p.status = .terminal }
            if proof.body.status == .mismatch { throw AuthorityError.intentMismatch }
            p.liveRaw=proof.raw;p.liveQuery=proof.query
            try writeV4(p,table:"authority_projection_v4",idColumn:"match_id",id:proof.body.matchID);try fail(.beforeCommit)
        }
        if fault == .afterCommit { throw StoreError.responseLost }
    }
    public func authorityStateV4(matchID: String, now: Date) throws -> AuthorityStateV4 {
        guard let b=try currentBindingV4() else { return AuthorityStateV4(status:.unknown,acquire:nil,verifiedNormalRelease:nil,latestLive:nil) }
        let p=try projectionV4(matchID)
        let acquire=try p.acquireRequestID.flatMap { try resultV4($0).map { try verifiedResultV4($0,binding:b) } }
        let release=try p.releaseRequestID.flatMap { try resultV4($0).map { try verifiedResultV4($0,binding:b) } }
        var live:VerifiedLiveLockV1?
        if let raw=p.liveRaw,let query=p.liveQuery,let trust=authorityTrust { live=try? VerifiedLiveLockV1.verify(raw,query:query,accountID:b.accountID,trust:trust,now:now) }
        return AuthorityStateV4(status:p.status,acquire:acquire,verifiedNormalRelease:release?.body.result == .releasedNormal ? release : nil,latestLive:live)
    }
    public func validateAuthorityStartV4(_ intent: StartIntent, now: Date) throws {
        let b=try activeBindingV4(),state=try authorityStateV4(matchID:intent.matchID,now:now)
        guard b.deviceID==intent.recordingDeviceID,b.role != .waiting,state.status == .held,
              let a=state.acquire,a.body.requestID==intent.id,a.body.matchID==intent.matchID,a.body.recordingDeviceID==intent.recordingDeviceID,
              let live=state.latestLive,live.body.status == .held,live.body.activationEpoch==b.activationEpoch else { throw AuthorityError.terminalLock }
    }
}
