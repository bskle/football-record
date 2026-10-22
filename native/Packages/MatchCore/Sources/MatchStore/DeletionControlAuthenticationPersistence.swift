import Foundation
import MatchCore

struct StoredDeletionControlParentV1:Codable {
    let parentRequestID,parentDigest,originalAuthRequestID:String
    let originalScope:CloudScopeV1
    let binding:AccountBindingV4
    let publicKey,keyID:String
}
extension MatchStore {
    private func deletionControlKeyV1(_ kind:String,_ id:String)->String {"delete-control-v1:"+kind+":"+id}
    private func readDeletionControlV1<T:Codable>(_ type:T.Type,_ key:String)throws->T? {
        guard let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]).first else {return nil}
        guard let raw=row[0].data,raw.count<=65536 else {throw DeletionControlIssueV1.capacity}
        return try checkedV4(type,row:row,table:"lifecycle_steps_v4",key:key)
    }
    private func sourceDeletionControlV1(parentID:String,expectedIdentityGeneration:Int64)throws->(DeletionControlContextV1,StoredDeletionControlParentV1) {
        try AuthorityWire.identifier(parentID)
        guard try identityGenerationV4()==expectedIdentityGeneration,let saga=try deletionSagaV4(requestID:parentID),let scope=saga.originalScope,
              !saga.backendDeleted,saga.backendReceipt==nil,saga.localProgress != .completed,let binding=try currentBindingV4(),binding.role == .phone,
              let authID=try currentAuthRequestIDV4(),let original=try authAttemptV4(requestID:authID),let raw=try readLifecycleV4(Data.self,"auth-receipt:"+authID),let trust=authorityTrust,
              let control=try controlV4(parentID),try Canonical.data(control)==Canonical.data(saga.intent),
              try db.scalar("SELECT match_id FROM control_intents_v4 WHERE id=?",[.text(parentID)]).string == "" else {throw AuthorityError.identityChanged}
        _=try DeletionSagaV4(intent:saga.intent,accountID:saga.accountID,activationEpoch:saga.activationEpoch,recoveryCapability:saga.recoveryCapability,cloudChoice:saga.cloudChoice,localChoice:saga.localChoice,healthChoice:saga.healthChoice,healthConfirmed:saga.healthConfirmed,originalScope:scope)
        try validateDeletionScopeLockedV4(saga)
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:authID,digest:original.requestDigest,operation:.authApple,accountID:saga.accountID,epoch:saga.activationEpoch),trust:trust)
        guard receipt.body.result == .registered,original.environment == binding.environment,trust.environment == binding.environment,
              DeletionControlWireV1.same(original.deviceID,binding.deviceID),DeletionControlWireV1.same(original.cloudSpaceID,binding.cloudSpaceID),
              DeletionControlWireV1.same(binding.accountID,scope.accountID),DeletionControlWireV1.same(binding.cloudSpaceID,scope.cloudSpaceID),binding.activationEpoch == scope.activationEpoch else {throw AuthorityError.identityChanged}
        let header=StoredDeletionControlParentV1(parentRequestID:parentID,parentDigest:saga.intent.digest,originalAuthRequestID:authID,originalScope:scope,binding:binding,publicKey:original.publicKey,keyID:original.keyID)
        if let first=try readDeletionControlV1(StoredDeletionControlParentV1.self,deletionControlKeyV1("parent",parentID)) {
            guard first.parentRequestID==parentID,first.parentDigest==header.parentDigest,first.originalAuthRequestID==authID,DeletionControlWireV1.scope(first.originalScope,scope),
                  first.publicKey==header.publicKey,first.keyID==header.keyID,DeletionControlWireV1.same(first.binding.deviceID,binding.deviceID),first.binding.environment==binding.environment else {throw AuthorityError.identityChanged}
        }
        return (DeletionControlContextV1(saga:saga,binding:binding,originalScope:scope,publicKey:original.publicKey,keyID:original.keyID,identityGeneration:expectedIdentityGeneration),header)
    }
    public func deletionControlContextV4(parentID:String,expectedIdentityGeneration:Int64)throws->DeletionControlContextV1 {
        try db.transaction {try validateDeletionControlRowsLockedV4();return try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration).0}
    }
    /// A read-only linearization point for one exact authorization, never a cached ready flag.
    public func deletionControlReadyContextV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,expectedIdentityGeneration:Int64,at:Date)throws->DeletionControlContextV1 {
        try db.transaction {
            try validateDeletionControlRowsLockedV4()
            let (context,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration)
            guard let attempt=try loadDeletionControlAttemptV1(parentID:parentID,authRequestID:authorization.body.requestID),
                  attempt.identityGeneration==expectedIdentityGeneration,attempt.parentDigest==context.saga.intent.digest,
                  DeletionControlWireV1.scope(attempt.originalScope,context.originalScope),
                  try Canonical.data(attempt.binding)==Canonical.data(context.binding),
                  attempt.publicKey==context.publicKey,attempt.keyID==context.keyID,let trust=authorityTrust else {throw AuthorityError.identityChanged}
            let original=try VerifiedDeletionControlAuthorizationV1.verify(authorization.raw,expectedParent:context.saga,expectedAttempt:attempt,trust:trust)
            guard let stored=try loadDeletionControlAuthorizationV1(parentID:parentID,authRequestID:attempt.authentication.requestID),
                  stored.authorization.raw==original.raw,stored.authorization.body.result == .ready,stored.resolution==nil else {throw DeletionControlIssueV1.needsFreshAuthorization}
            let now=try DeletionControlWireV1.seconds(at)
            guard original.body.issuedAt<=now+60,original.body.expiresAt>now else {throw AuthorityError.staleAttestation}
            return context
        }
    }
    private func loadDeletionControlAttemptsV1(parentID:String)throws->[DeletionControlAttemptV1] {
        try AuthorityWire.identifier(parentID)
        return try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:attempt:%' ORDER BY rowid").map {try checkedV4(DeletionControlAttemptV1.self,row:$0,table:"lifecycle_steps_v4",key:parentID)}.filter {$0.parentRequestID==parentID}
    }
    private func loadDeletionControlAttemptV1(parentID:String,authRequestID:String)throws->DeletionControlAttemptV1? {
        try AuthorityWire.identifier(parentID);try AuthorityWire.identifier(authRequestID)
        let value=try readDeletionControlV1(DeletionControlAttemptV1.self,deletionControlKeyV1("attempt",authRequestID))
        guard value==nil || value?.parentRequestID==parentID else {throw AuthorityError.conflict};return value
    }
    private func insertDeletionControlV1<T:Codable>(_ value:T,key:String)throws {
        let raw=try Canonical.data(value)
        guard raw.count<=65536 else {throw DeletionControlIssueV1.capacity}
        if let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]).first {
            guard row[0].data==raw,row[1].string==Canonical.hash(raw) else {throw AuthorityError.conflict};return
        }
        let rows=try db.rows("SELECT payload FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-%'")
        guard rows.count<512,try rows.reduce(raw.count,{sum,row in guard let bytes=row[0].data else {throw AuthorityError.invalidWire};return sum+bytes.count})<=16*1024*1024 else {throw DeletionControlIssueV1.capacity}
        try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)",[.text(key),.blob(raw),.text(Canonical.hash(raw))])
    }
    public func saveDeletionControlAttemptV4(_ attempt:DeletionControlAttemptV1)throws {
        try db.transaction {
            try validateDeletionControlRowsLockedV4()
            let initialIDs = try initialDeletionClaimedIDsLockedV1()
            guard !initialIDs.contains(Data(attempt.authentication.requestID.utf8)), !initialIDs.contains(Data(attempt.challengeRequestID.utf8)) else { throw AuthorityError.conflict }
            let (c,header)=try sourceDeletionControlV1(parentID:attempt.parentRequestID,expectedIdentityGeneration:attempt.identityGeneration)
            guard attempt.parentDigest==c.saga.intent.digest,DeletionControlWireV1.scope(attempt.originalScope,c.originalScope),try Canonical.data(attempt.binding)==Canonical.data(c.binding),attempt.publicKey==c.publicKey,attempt.keyID==c.keyID else {throw AuthorityError.identityChanged}
            if let prior=try loadDeletionControlAttemptV1(parentID:attempt.parentRequestID,authRequestID:attempt.authentication.requestID) {guard try Canonical.data(prior)==Canonical.data(attempt) else {throw AuthorityError.conflict};return}
            let all=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:attempt:%'").map {try checkedV4(DeletionControlAttemptV1.self,row:$0,table:"lifecycle_steps_v4",key:"attempt")}
            guard all.count<256,all.filter({$0.parentRequestID==attempt.parentRequestID}).count<64 else {throw DeletionControlIssueV1.capacity}
            for prior in all where prior.parentRequestID==attempt.parentRequestID {
                guard try loadDeletionControlAuthorizationV1(parentID:prior.parentRequestID,authRequestID:prior.authentication.requestID) != nil else {throw DeletionControlIssueV1.unresolved}
            }
            for id in [attempt.authentication.requestID,attempt.challengeRequestID] {
                guard try controlV4(id)==nil,try authAttemptV4(requestID:id)==nil,try watchRegistrationAttemptV4(requestID:id)==nil else {throw AuthorityError.conflict}
                for prefix in ["auth-resolved:","auth-receipt:","auth-admission:","watch-attempt:","watch-receipt:","watch-admission:"] {guard try db.rows("SELECT 1 FROM lifecycle_steps_v4 WHERE id=?",[.text(prefix+id)]).isEmpty else {throw AuthorityError.conflict}}
                for prior in all {guard prior.authentication.requestID != id,prior.challengeRequestID != id else {throw AuthorityError.conflict}}
            }
            let parents=try db.rows("SELECT id FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:parent:%'")
            if try readDeletionControlV1(StoredDeletionControlParentV1.self,deletionControlKeyV1("parent",attempt.parentRequestID))==nil {guard parents.count<64 else {throw DeletionControlIssueV1.capacity};try insertDeletionControlV1(header,key:deletionControlKeyV1("parent",attempt.parentRequestID))}
            try insertDeletionControlV1(attempt,key:deletionControlKeyV1("attempt",attempt.authentication.requestID));try validateDeletionControlRowsLockedV4();try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
struct StoredDeletionControlProofV1:Codable {
    let parentRequestID,parentDigest,authRequestID,referenceID,kind:String
    let raw:Data
    let originalAcquire:Data?
    let query:LiveLockQueryV1?
    let acceptedAt:Int64?
}
extension MatchStore {
    private func deletionControlProofKeyV1(_ kind:String,parentID:String,digest:String,referenceID:String)throws->String {
        deletionControlKeyV1("proof",AuthorityWire.hash(try AuthorityWire.encode([kind,parentID,digest,referenceID])))
    }
    private func deletionControlParentV1(_ parentID:String)throws->StoredDeletionControlParentV1 {
        guard let p=try readDeletionControlV1(StoredDeletionControlParentV1.self,deletionControlKeyV1("parent",parentID)) else {throw AuthorityError.intentMismatch};return p
    }
    private func deletionControlSagaHistoryV1(_ parent:StoredDeletionControlParentV1)throws->DeletionSagaV4 {
        guard let saga=try deletionSagaV4(requestID:parent.parentRequestID),let scope=saga.originalScope,let trust=authorityTrust,
              saga.intent.digest==parent.parentDigest,DeletionControlWireV1.scope(scope,parent.originalScope),
              DeletionControlWireV1.same(saga.accountID,parent.binding.accountID),saga.activationEpoch==parent.binding.activationEpoch,
              parent.binding.role == .phone,parent.binding.environment==trust.environment,
              let original=try authAttemptV4(requestID:parent.originalAuthRequestID),original.publicKey==parent.publicKey,original.keyID==parent.keyID,
              original.deviceID==parent.binding.deviceID,original.cloudSpaceID==parent.binding.cloudSpaceID,original.environment==parent.binding.environment,
              let raw=try readLifecycleV4(Data.self,"auth-receipt:"+parent.originalAuthRequestID),let control=try controlV4(saga.intent.requestID),
              try Canonical.data(control)==Canonical.data(saga.intent),try db.scalar("SELECT match_id FROM control_intents_v4 WHERE id=?",[.text(saga.intent.requestID)]).string=="" else {throw AuthorityError.intentMismatch}
        _=try DeletionSagaV4(intent:saga.intent,accountID:saga.accountID,activationEpoch:saga.activationEpoch,recoveryCapability:saga.recoveryCapability,cloudChoice:saga.cloudChoice,localChoice:saga.localChoice,healthChoice:saga.healthChoice,healthConfirmed:saga.healthConfirmed,originalScope:scope)
        let proof=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:original.requestID,digest:original.requestDigest,operation:.authApple,accountID:saga.accountID,epoch:saga.activationEpoch),trust:trust)
        guard proof.body.result == .registered,try AuthorityWire.deviceKeyID(publicKey:parent.publicKey)==parent.keyID else {throw AuthorityError.intentMismatch}
        return saga
    }
    private func deletionControlProofsV1(parentID:String)throws->[StoredDeletionControlProofV1] {
        try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:proof:%' ORDER BY rowid").map {try checkedV4(StoredDeletionControlProofV1.self,row:$0,table:"lifecycle_steps_v4",key:parentID)}.filter {$0.parentRequestID==parentID}
    }
    private func verifiedDeletionControlProofV1(_ saved:StoredDeletionControlProofV1)throws->VerifiedDeletionControlAuthorizationV1 {
        guard let a=try loadDeletionControlAttemptV1(parentID:saved.parentRequestID,authRequestID:saved.authRequestID),let trust=authorityTrust else {throw AuthorityError.intentMismatch}
        let parent=try deletionControlParentV1(saved.parentRequestID),saga=try deletionControlSagaHistoryV1(parent)
        guard saved.parentDigest==saga.intent.digest,saved.referenceID==a.authentication.requestID,saved.query==nil,saved.acceptedAt==nil else {throw AuthorityError.intentMismatch}
        let verified=try VerifiedDeletionControlAuthorizationV1.verify(saved.raw,expectedParent:saga,expectedAttempt:a,trust:trust)
        if saved.kind=="authorization" {guard [.ready,.knownAbandoned,.knownExpired,.knownRevoked].contains(verified.body.result) else {throw AuthorityError.intentMismatch}}
        else {guard saved.kind=="resolution",[.knownExpired,.knownRevoked].contains(verified.body.result),saved.originalAcquire==nil else {throw AuthorityError.intentMismatch}}
        try verifyDeletionControlAcquireV1(saved.originalAcquire,authorization:verified,parent:parent)
        return verified
    }
    private func verifyDeletionControlAcquireV1(_ raw:Data?,authorization:VerifiedDeletionControlAuthorizationV1,parent:StoredDeletionControlParentV1)throws {
        guard authorization.body.lockState == .pinned else {guard raw==nil else {throw AuthorityError.intentMismatch};return}
        guard let raw,let pin=authorization.body.lock,let trust=authorityTrust,raw.count<=16384,AuthorityWire.hash(raw)==pin.acquireReceiptDigest else {throw AuthorityError.intentMismatch}
        let proof=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:pin.acquireRequestID,digest:pin.acquireRequestDigest,operation:.acquire,accountID:parent.binding.accountID,epoch:parent.originalScope.activationEpoch),trust:trust)
        guard proof.body.result == .held,proof.body.matchID==pin.matchID,proof.body.lockID==pin.lockID,proof.body.recordingDeviceID==pin.recordingDeviceID else {throw AuthorityError.intentMismatch}
        if let original=try resultV4(pin.acquireRequestID) {guard original.raw==raw else {throw AuthorityError.conflict}}
    }
    private func loadDeletionControlAuthorizationV1(parentID:String,authRequestID:String)throws->DeletionControlAuthorizationRecordV1? {
        let records=try deletionControlProofsV1(parentID:parentID).filter {$0.authRequestID==authRequestID}
        guard let first=records.first(where:{$0.kind=="authorization"}) else {return nil}
        let authorization=try verifiedDeletionControlProofV1(first),resolution=try records.first(where:{$0.kind=="resolution"}).map {try verifiedDeletionControlProofV1($0)}
        guard resolution==nil || authorization.body.result == .ready else {throw AuthorityError.conflict}
        return DeletionControlAuthorizationRecordV1(authorization:authorization,originalAcquire:first.originalAcquire,resolution:resolution)
    }
    private func loadDeletionControlConfirmationV1(parentID:String)throws->DeletionControlLockConfirmationV1? {
        try readDeletionControlV1(DeletionControlLockConfirmationV1.self,deletionControlKeyV1("confirmation",parentID))
    }
    public func deletionControlAttemptsV4(parentID:String)throws->[DeletionControlAttemptV1] {try db.transaction {try validateDeletionControlRowsLockedV4();return try loadDeletionControlAttemptsV1(parentID:parentID)}}
    public func deletionControlAttemptV4(parentID:String,authRequestID:String)throws->DeletionControlAttemptV1? {try db.transaction {try validateDeletionControlRowsLockedV4();return try loadDeletionControlAttemptV1(parentID:parentID,authRequestID:authRequestID)}}
    public func deletionControlAuthorizationV4(parentID:String,authRequestID:String)throws->DeletionControlAuthorizationRecordV1? {try db.transaction {try validateDeletionControlRowsLockedV4();return try loadDeletionControlAuthorizationV1(parentID:parentID,authRequestID:authRequestID)}}
    public func deletionControlLockConfirmationV4(parentID:String)throws->DeletionControlLockConfirmationV1? {try db.transaction {try validateDeletionControlRowsLockedV4();return try loadDeletionControlConfirmationV1(parentID:parentID)}}
    func validateDeletionControlRowsLockedV4()throws {
        let initialIDs = try initialDeletionClaimedIDsLockedV1()
        let rows=try db.rows("SELECT id,payload,checksum,CAST(id AS BLOB) FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-%' ORDER BY rowid")
        guard rows.count<=512 else {throw DeletionControlIssueV1.capacity};var total=0,parents:[String:StoredDeletionControlParentV1]=[:],attempts:[String:DeletionControlAttemptV1]=[:],proofs:[StoredDeletionControlProofV1]=[],confirmations:[DeletionControlLockConfirmationV1]=[]
        for row in rows {
            guard let key=row[0].string,row[3].data==Data(key.utf8),key.hasPrefix("delete-control-v1:"),let raw=row[1].data,raw.count<=65536 else {throw AuthorityError.invalidWire}
            total+=raw.count;guard total<=16*1024*1024 else {throw DeletionControlIssueV1.capacity}
            let tail=String(key.dropFirst("delete-control-v1:".count));guard let separator=tail.firstIndex(of:":") else {throw AuthorityError.invalidWire};let kind=String(tail[..<separator]),payload=Array(row[1...2])
            switch kind {
            case "parent":let p=try checkedV4(StoredDeletionControlParentV1.self,row:payload,table:"lifecycle_steps_v4",key:key);guard key==deletionControlKeyV1("parent",p.parentRequestID),parents.updateValue(p,forKey:p.parentRequestID)==nil else {throw AuthorityError.conflict}
            case "attempt":let a=try checkedV4(DeletionControlAttemptV1.self,row:payload,table:"lifecycle_steps_v4",key:key);guard key==deletionControlKeyV1("attempt",a.authentication.requestID),attempts.updateValue(a,forKey:a.authentication.requestID)==nil else {throw AuthorityError.conflict}
            case "confirmation":let c=try checkedV4(DeletionControlLockConfirmationV1.self,row:payload,table:"lifecycle_steps_v4",key:key);guard key==deletionControlKeyV1("confirmation",c.parentRequestID) else {throw AuthorityError.conflict};confirmations.append(c)
            case "proof":let p=try checkedV4(StoredDeletionControlProofV1.self,row:payload,table:"lifecycle_steps_v4",key:key);guard key == (try deletionControlProofKeyV1(p.kind,parentID:p.parentRequestID,digest:p.parentDigest,referenceID:p.referenceID)),["authorization","resolution","live","abnormal"].contains(p.kind) else {throw AuthorityError.invalidWire};proofs.append(p)
            default:throw AuthorityError.invalidWire
            }
        }
        guard parents.count<=64,attempts.count<=256 else {throw DeletionControlIssueV1.capacity}
        for p in parents.values {_=try deletionControlSagaHistoryV1(p);guard attempts.values.contains(where:{$0.parentRequestID==p.parentRequestID}) else {throw AuthorityError.intentMismatch}}
        var ids=Set<String>()
        func claim(_ id:String)throws {try AuthorityWire.identifier(id);guard ids.insert(id).inserted else {throw AuthorityError.conflict}}
        for a in attempts.values {
            guard let p=parents[a.parentRequestID],p.parentDigest==a.parentDigest,DeletionControlWireV1.scope(p.originalScope,a.originalScope),p.publicKey==a.publicKey,p.keyID==a.keyID,
                  DeletionControlWireV1.same(p.binding.accountID,a.binding.accountID),DeletionControlWireV1.same(p.binding.deviceID,a.binding.deviceID),DeletionControlWireV1.same(p.binding.cloudSpaceID,a.binding.cloudSpaceID),p.binding.activationEpoch==a.binding.activationEpoch,p.binding.environment==a.binding.environment,
                  attempts.values.filter({$0.parentRequestID==a.parentRequestID}).count<=64 else {throw AuthorityError.intentMismatch}
            try claim(a.authentication.requestID);try claim(a.challengeRequestID)
        }
        for c in confirmations {guard let p=parents[c.parentRequestID],c.parentDigest==p.parentDigest else {throw AuthorityError.intentMismatch};try claim(c.confirmationID);try claim(c.intent.requestID);try validateDeletionControlConfirmationV1(c)}
        for id in ids {
            guard !initialIDs.contains(Data(id.utf8)) else { throw AuthorityError.conflict }
            guard try controlV4(id)==nil,try authAttemptV4(requestID:id)==nil,try watchRegistrationAttemptV4(requestID:id)==nil else {throw AuthorityError.conflict}
            for prefix in ["auth-resolved:","auth-receipt:","auth-admission:","watch-attempt:","watch-receipt:","watch-admission:"] {guard try db.rows("SELECT 1 FROM lifecycle_steps_v4 WHERE id=?",[.text(prefix+id)]).isEmpty else {throw AuthorityError.conflict}}
        }
        for p in proofs {
            guard let parent=parents[p.parentRequestID],parent.parentDigest==p.parentDigest,let attempt=attempts[p.authRequestID],attempt.parentRequestID==p.parentRequestID else {throw AuthorityError.intentMismatch}
            if p.kind=="authorization"||p.kind=="resolution" {_=try verifiedDeletionControlProofV1(p);if p.kind=="resolution" {guard proofs.contains(where:{$0.parentRequestID==p.parentRequestID&&$0.authRequestID==p.authRequestID&&$0.kind=="authorization"}) else {throw AuthorityError.intentMismatch}}}
            else {try validateDeletionControlLockProofV1(p)}
        }
        for parent in parents.values {
            let ready=try proofs.filter({$0.parentRequestID==parent.parentRequestID&&$0.kind=="authorization"}).map {try verifiedDeletionControlProofV1($0)}.filter {$0.body.result == .ready}
            if let first=ready.first {for next in ready {guard next.body.lockState==first.body.lockState,try AuthorityWire.encode(next.body.lock)==AuthorityWire.encode(first.body.lock) else {throw AuthorityError.conflict}}}
        }
    }
    public func acceptDeletionControlAuthorizationV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,originalAcquire:Data?,expectedIdentityGeneration:Int64,at:Date)throws {
        try db.transaction {
            try validateDeletionControlRowsLockedV4();let (c,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration)
            guard let attempt=try loadDeletionControlAttemptV1(parentID:parentID,authRequestID:authorization.body.requestID),attempt.identityGeneration==expectedIdentityGeneration,try Canonical.data(attempt.binding)==Canonical.data(c.binding),let trust=authorityTrust else {throw AuthorityError.identityChanged}
            if let previous=try loadDeletionControlAuthorizationV1(parentID:parentID,authRequestID:attempt.authentication.requestID) {
                guard previous.authorization.body.result == .ready,previous.resolution==nil else {throw DeletionControlIssueV1.needsFreshAuthorization}
            }
            let proof=try VerifiedDeletionControlAuthorizationV1.verify(authorization.raw,expectedParent:c.saga,expectedAttempt:attempt,trust:trust),now=try DeletionControlWireV1.seconds(at)
            guard proof.body.result == .ready,proof.body.issuedAt<=now+60,proof.body.expiresAt>now else {throw AuthorityError.staleAttestation}
            let saved=StoredDeletionControlProofV1(parentRequestID:parentID,parentDigest:c.saga.intent.digest,authRequestID:attempt.authentication.requestID,referenceID:attempt.authentication.requestID,kind:"authorization",raw:proof.raw,originalAcquire:originalAcquire,query:nil,acceptedAt:nil)
            try verifyDeletionControlAcquireV1(originalAcquire,authorization:proof,parent:deletionControlParentV1(parentID));try insertDeletionControlV1(saved,key:deletionControlProofKeyV1("authorization",parentID:parentID,digest:c.saga.intent.digest,referenceID:saved.referenceID));try validateDeletionControlRowsLockedV4();try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func resolveDeletionControlAttemptV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,expectedIdentityGeneration:Int64)throws {
        try db.transaction {
            try validateDeletionControlRowsLockedV4();let (c,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration)
            guard let attempt=try loadDeletionControlAttemptV1(parentID:parentID,authRequestID:authorization.body.requestID),attempt.identityGeneration==expectedIdentityGeneration,let trust=authorityTrust else {throw AuthorityError.identityChanged}
            let proof=try VerifiedDeletionControlAuthorizationV1.verify(authorization.raw,expectedParent:c.saga,expectedAttempt:attempt,trust:trust)
            guard [.knownAbandoned,.knownExpired,.knownRevoked].contains(proof.body.result) else {throw AuthorityError.intentMismatch}
            let first=try loadDeletionControlAuthorizationV1(parentID:parentID,authRequestID:attempt.authentication.requestID),kind:String
            if let first {
                if first.authorization.body.result == proof.body.result {
                    guard first.authorization.raw==proof.raw,first.resolution==nil else {throw AuthorityError.conflict};kind="authorization"
                }else{
                    guard first.authorization.body.result == .ready,[.knownExpired,.knownRevoked].contains(proof.body.result) else {throw AuthorityError.conflict};kind="resolution"
                }
            }else{
                // The original ready response can be lost through its entire TTL.
                // A fixed-trust closing proof closes only this original attempt;
                // it never invents ready, installs credentials or advances identity.
                kind="authorization"
            }
            let saved=StoredDeletionControlProofV1(parentRequestID:parentID,parentDigest:c.saga.intent.digest,authRequestID:attempt.authentication.requestID,referenceID:attempt.authentication.requestID,kind:kind,raw:proof.raw,originalAcquire:nil,query:nil,acceptedAt:nil)
            try insertDeletionControlV1(saved,key:deletionControlProofKeyV1(kind,parentID:parentID,digest:c.saga.intent.digest,referenceID:saved.referenceID));try validateDeletionControlRowsLockedV4();try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    private func activeDeletionControlAuthorizationV1(parentID:String,generation:Int64,at:Int64)throws->(DeletionControlAttemptV1,DeletionControlAuthorizationRecordV1) {
        for a in try loadDeletionControlAttemptsV1(parentID:parentID).reversed() where a.identityGeneration==generation {
            if let saved=try loadDeletionControlAuthorizationV1(parentID:parentID,authRequestID:a.authentication.requestID),saved.authorization.body.result == .ready,saved.resolution==nil,saved.authorization.body.expiresAt>at {return (a,saved)}
        };throw DeletionControlIssueV1.needsFreshAuthorization
    }
    private func validateDeletionControlConfirmationV1(_ c:DeletionControlLockConfirmationV1)throws {
        let parent=try deletionControlParentV1(c.parentRequestID)
        guard parent.parentDigest==c.parentDigest else {throw AuthorityError.intentMismatch}
        let pins=try deletionControlProofsV1(parentID:c.parentRequestID).filter {$0.kind=="authorization"}.map {try verifiedDeletionControlProofV1($0)}.filter {$0.body.lockState == .pinned}
        guard let authorization=pins.last,let pin=authorization.body.lock,c.intent.fields.matchID==pin.matchID,c.intent.fields.lockID==pin.lockID,c.intent.fields.recordingDeviceID==pin.recordingDeviceID,c.intent.fields.activationEpoch==pin.activationEpoch,c.intent.fields.mode=="abnormal",c.intent.requestID != c.parentRequestID,c.confirmationID != c.parentRequestID,c.confirmationID != c.intent.requestID else {throw AuthorityError.intentMismatch}
        try verifyDeletionControlAcquireV1(c.acquireRaw,authorization:authorization,parent:parent)
    }
    public func saveDeletionControlLockConfirmationV4(parentID:String,confirmation:DeletionControlLockConfirmationV1,expectedIdentityGeneration:Int64)throws {
        try db.transaction {
            let initialIDs = try initialDeletionClaimedIDsLockedV1()
            guard !initialIDs.contains(Data(confirmation.confirmationID.utf8)), !initialIDs.contains(Data(confirmation.intent.requestID.utf8)) else { throw AuthorityError.conflict }
            try validateDeletionControlRowsLockedV4();let (c,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration)
            guard confirmation.parentRequestID==parentID,confirmation.parentDigest==c.saga.intent.digest else {throw AuthorityError.intentMismatch}
            _=try activeDeletionControlAuthorizationV1(parentID:parentID,generation:expectedIdentityGeneration,at:confirmation.confirmedAt);try validateDeletionControlConfirmationV1(confirmation)
            try insertDeletionControlV1(confirmation,key:deletionControlKeyV1("confirmation",parentID));try validateDeletionControlRowsLockedV4();try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    private func validateDeletionControlLockProofV1(_ saved:StoredDeletionControlProofV1)throws {
        let parent=try deletionControlParentV1(saved.parentRequestID)
        guard let authorization=try loadDeletionControlAuthorizationV1(parentID:saved.parentRequestID,authRequestID:saved.authRequestID),let pin=authorization.authorization.body.lock,let acquire=authorization.originalAcquire,let trust=authorityTrust else {throw DeletionControlIssueV1.lockMappingUnavailable}
        if saved.kind=="live" {
            guard saved.originalAcquire==nil,let query=saved.query,let at=saved.acceptedAt,saved.referenceID==query.requestID,query.acquireRequestID==pin.acquireRequestID,query.matchID==pin.matchID,query.lockID==pin.lockID,query.recordingDeviceID==pin.recordingDeviceID,query.activationEpoch==pin.activationEpoch else {throw AuthorityError.intentMismatch}
            let verified=try VerifiedLiveLockV1.verify(saved.raw,query:query,accountID:parent.binding.accountID,trust:trust,now:Date(timeIntervalSince1970:Double(at)))
            let original=try VerifiedAuthorityReceiptV1.verify(acquire,expected:AuthorityExpectedIntent(requestID:pin.acquireRequestID,digest:pin.acquireRequestDigest,operation:.acquire,accountID:parent.binding.accountID,epoch:parent.originalScope.activationEpoch),trust:trust)
            guard verified.body.receiptID==original.body.receiptID,verified.body.status != .mismatch else {throw AuthorityError.intentMismatch}
        }else{
            guard saved.kind=="abnormal",saved.query==nil,saved.acceptedAt==nil,saved.originalAcquire==nil,let confirmation=try loadDeletionControlConfirmationV1(parentID:saved.parentRequestID),saved.referenceID==confirmation.intent.requestID else {throw AuthorityError.intentMismatch}
            try validateDeletionControlConfirmationV1(confirmation)
            let verified=try VerifiedAuthorityReceiptV1.verify(saved.raw,expected:AuthorityExpectedIntent(confirmation.intent,accountID:parent.binding.accountID,epoch:parent.originalScope.activationEpoch),trust:trust)
            guard verified.body.result == .releasedAbnormal,verified.body.matchID==pin.matchID,verified.body.lockID==pin.lockID,verified.body.recordingDeviceID==pin.recordingDeviceID else {throw AuthorityError.intentMismatch}
        }
    }
    public func acceptDeletionControlLiveLockV4(parentID:String,proof:VerifiedLiveLockV1,expectedIdentityGeneration:Int64,at:Date)throws {
        try db.transaction {
            try validateDeletionControlRowsLockedV4();let (c,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration),now=try DeletionControlWireV1.seconds(at)
            let (attempt,_)=try activeDeletionControlAuthorizationV1(parentID:parentID,generation:expectedIdentityGeneration,at:now)
            let saved=StoredDeletionControlProofV1(parentRequestID:parentID,parentDigest:c.saga.intent.digest,authRequestID:attempt.authentication.requestID,referenceID:proof.query.requestID,kind:"live",raw:proof.raw,originalAcquire:nil,query:proof.query,acceptedAt:now)
            try validateDeletionControlLockProofV1(saved);try insertDeletionControlV1(saved,key:deletionControlProofKeyV1("live",parentID:parentID,digest:c.saga.intent.digest,referenceID:saved.referenceID));try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func acceptDeletionControlAbnormalResultV4(parentID:String,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64)throws {
        try db.transaction {
            try validateDeletionControlRowsLockedV4();let (c,_)=try sourceDeletionControlV1(parentID:parentID,expectedIdentityGeneration:expectedIdentityGeneration)
            guard let confirmation=try loadDeletionControlConfirmationV1(parentID:parentID) else {throw AuthorityError.intentMismatch}
            let records=try deletionControlProofsV1(parentID:parentID).filter {$0.kind=="authorization"};guard let first=records.first(where:{$0.originalAcquire==confirmation.acquireRaw}) else {throw AuthorityError.intentMismatch}
            let saved=StoredDeletionControlProofV1(parentRequestID:parentID,parentDigest:c.saga.intent.digest,authRequestID:first.authRequestID,referenceID:receipt.body.requestID,kind:"abnormal",raw:receipt.raw,originalAcquire:nil,query:nil,acceptedAt:nil)
            try validateDeletionControlLockProofV1(saved);try insertDeletionControlV1(saved,key:deletionControlProofKeyV1("abnormal",parentID:parentID,digest:c.saga.intent.digest,referenceID:saved.referenceID));try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
