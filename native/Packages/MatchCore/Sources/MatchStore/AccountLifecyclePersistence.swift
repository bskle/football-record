import Foundation
extension MatchStore {
    public func identityGenerationV4()throws->Int64 {let value=try readLifecycleV4(Int64.self,"identity-generation") ?? 0;guard value>=0,value<=9_007_199_254_740_991 else {throw AuthorityError.invalidWire};return value}
    func advanceIdentityGenerationLockedV4()throws->Int64 {let current=try identityGenerationV4();guard current<9_007_199_254_740_991 else {throw AuthorityError.unavailable};let next=current+1;try writeV4(next,table:"lifecycle_steps_v4",id:"identity-generation");return next}
    public func currentAuthRequestIDV4()throws->String? {try readLifecycleV4(String.self,"auth-current")}

    public func pendingAuthAttemptsV4()throws->[AuthAttemptV4] {
        try authAttemptsV4().filter {attempt in
            if let raw=try readLifecycleV4(Data.self,"auth-receipt:"+attempt.requestID) {
                struct Envelope:Codable {let body:AuthorityReceiptBodyV1;let signature:String}
                let body=try AuthorityWire.decode(Envelope.self,raw).body
                guard let trust=authorityTrust else {throw AuthorityError.unavailable}
                _=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.authApple,accountID:body.accountID,epoch:body.activationEpoch),trust:trust)
                return false
            }
            return try authResolutionV4(requestID:attempt.requestID).map{!Self.authResolutionClosesV4($0)} ?? true
        }
    }
    static func authResolutionClosesV4(_ resolution:AuthResolutionV4)->Bool {switch resolution {case .knownRevoked,.knownExpired,.knownAbandoned:true;case .knownNotFound:false}}
    public func authAttemptsV4()throws->[AuthAttemptV4] {try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'auth-attempt:%' ORDER BY rowid").map {try checkedV4(AuthAttemptV4.self,row:$0,table:"lifecycle_steps_v4",key:"auth-attempt")}}
    public func authResolutionV4(requestID:String)throws->AuthResolutionV4? {try readLifecycleV4(AuthResolutionV4.self,"auth-resolved:"+requestID)}
    public func resolveTerminalAuthenticationV4(requestID:String,resolution:AuthResolutionV4,expectedIdentityGeneration:Int64)throws->Int64? {
        guard resolution == .knownRevoked || resolution == .knownExpired else {throw AuthorityError.invalidWire}
        let generation=try db.transaction {()->Int64? in
            guard try authAttemptV4(requestID:requestID) != nil else {throw AuthorityError.intentMismatch}
            try writeV4(resolution,table:"lifecycle_steps_v4",id:"auth-resolved:"+requestID)
            let current=try currentAuthRequestIDV4()
            guard (current==nil || current==requestID),try identityGenerationV4()==expectedIdentityGeneration else {return nil}
            let generation=try advanceIdentityGenerationLockedV4()
            if let b=try currentBindingV4() {try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")}
            var analytics=try analyticsStateV4();analytics.enabled=false;analytics.pending=[];try writeV4(analytics,table:"lifecycle_steps_v4",id:"analytics-state")
            try fail(.beforeCommit);return generation
        };if fault == .afterCommit {throw StoreError.responseLost};return generation
    }
    public func resolveAuthAttemptV4(requestID:String,resolution:AuthResolutionV4)throws {
        guard Self.authResolutionClosesV4(resolution) else {throw AuthorityError.invalidWire}
        try db.transaction {guard try authAttemptV4(requestID:requestID) != nil else {throw AuthorityError.intentMismatch};try writeV4(resolution,table:"lifecycle_steps_v4",id:"auth-resolved:"+requestID);try fail(.beforeCommit)}
    }

    public func authAttemptV4(requestID:String)throws->AuthAttemptV4? {
        guard let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text("auth-attempt:"+requestID)]).first else {return nil}
        return try checkedV4(AuthAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:requestID)
    }
    public func saveAuthAttemptV4(_ attempt:AuthAttemptV4,expectedIdentityGeneration:Int64=0)throws {
        try db.transaction {
            guard try identityGenerationV4()==expectedIdentityGeneration else {throw AuthorityError.identityChanged}
            guard let trust=authorityTrust,trust.environment==attempt.environment else {throw AuthorityError.unavailable}
            if let b=try currentBindingV4() {guard b.deviceID==attempt.deviceID,b.cloudSpaceID==attempt.cloudSpaceID,b.environment==attempt.environment else {throw AuthorityError.identityChanged}}
            for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'auth-attempt:%'") {
                let prior=try checkedV4(AuthAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:attempt.requestID)
                guard prior.deviceID != attempt.deviceID || prior.publicKey==attempt.publicKey else {throw AuthorityError.identityChanged}
            }
            if let prior=try authAttemptV4(requestID:attempt.requestID) {guard prior==attempt else {throw AuthorityError.conflict};return}
            guard try pendingAuthAttemptsV4().isEmpty else {throw AuthorityError.conflict}
            try writeV4(attempt,table:"lifecycle_steps_v4",id:"auth-attempt:"+attempt.requestID)
            try writeV4(expectedIdentityGeneration,table:"lifecycle_steps_v4",id:"auth-admission:"+attempt.requestID);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func acceptAuthenticationV4(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64=0)throws {
        var changedIdentity=false
        try db.transaction {
            guard try identityGenerationV4()==expectedIdentityGeneration else {throw AuthorityError.identityChanged}
            guard let trust=authorityTrust,trust.environment==attempt.environment,try authAttemptV4(requestID:attempt.requestID)==attempt else {throw AuthorityError.intentMismatch}
            let verified=try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.authApple,accountID:binding.accountID,epoch:binding.activationEpoch),trust:trust)
            guard binding.deviceID==attempt.deviceID,binding.cloudSpaceID==attempt.cloudSpaceID,binding.environment==attempt.environment,!binding.suspended,
                  (verified.body.result == .registered && binding.role == .phone)||(verified.body.result == .waitingMigration && binding.role == .waiting) else {throw AuthorityError.intentMismatch}
            if let b=try currentBindingV4(),b.accountID != binding.accountID || b.cloudSpaceID != binding.cloudSpaceID || b.deviceID != binding.deviceID {
                _=try advanceIdentityGenerationLockedV4()
                try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")
                changedIdentity=true;return
            }
            if let prior=try currentBindingV4() {guard binding.activationEpoch>=prior.activationEpoch else {throw AuthorityError.identityChanged}}
            try writeV4(binding,table:"account_binding_v4",id:"current")
            try writeV4(attempt.requestID,table:"lifecycle_steps_v4",id:"auth-current")
            try writeV4(receipt.raw,table:"lifecycle_steps_v4",id:"auth-receipt:"+attempt.requestID)
            try fail(.afterReceipt);try fail(.beforeCommit)
        }
        if changedIdentity {throw AuthorityError.identityChanged}
        if fault == .afterCommit {throw StoreError.responseLost}
    }
}
