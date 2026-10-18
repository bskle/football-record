import Foundation
extension MatchStore {
    public func authAttemptV4(requestID:String)throws->AuthAttemptV4? {
        guard let row=try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?",[.text("auth-attempt:"+requestID)]).first else {return nil}
        return try checkedV4(AuthAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:requestID)
    }
    public func saveAuthAttemptV4(_ attempt:AuthAttemptV4)throws {
        try db.transaction {
            guard let trust=authorityTrust,trust.environment==attempt.environment else {throw AuthorityError.unavailable}
            if let b=try currentBindingV4() {guard b.deviceID==attempt.deviceID,b.cloudSpaceID==attempt.cloudSpaceID,b.environment==attempt.environment else {throw AuthorityError.identityChanged}}
            for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'auth-attempt:%'") {
                let prior=try checkedV4(AuthAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:attempt.requestID)
                guard prior.deviceID != attempt.deviceID || prior.publicKey==attempt.publicKey else {throw AuthorityError.identityChanged}
            }
            if let prior=try authAttemptV4(requestID:attempt.requestID) {guard prior==attempt else {throw AuthorityError.conflict};return}
            try writeV4(attempt,table:"lifecycle_steps_v4",id:"auth-attempt:"+attempt.requestID);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func acceptAuthenticationV4(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1)throws {
        var changedIdentity=false
        try db.transaction {
            guard let trust=authorityTrust,trust.environment==attempt.environment,try authAttemptV4(requestID:attempt.requestID)==attempt else {throw AuthorityError.intentMismatch}
            let verified=try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.authApple,accountID:binding.accountID,epoch:binding.activationEpoch),trust:trust)
            guard binding.deviceID==attempt.deviceID,binding.cloudSpaceID==attempt.cloudSpaceID,binding.environment==attempt.environment,!binding.suspended,
                  (verified.body.result == .registered && binding.role == .phone)||(verified.body.result == .waitingMigration && binding.role == .waiting) else {throw AuthorityError.intentMismatch}
            if let b=try currentBindingV4(),b.accountID != binding.accountID || b.cloudSpaceID != binding.cloudSpaceID || b.deviceID != binding.deviceID {
                try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")
                changedIdentity=true;return
            }
            if let prior=try currentBindingV4() {guard binding.activationEpoch>=prior.activationEpoch else {throw AuthorityError.identityChanged}}
            try writeV4(binding,table:"account_binding_v4",id:"current")
            try writeV4(receipt.raw,table:"lifecycle_steps_v4",id:"auth-receipt:"+attempt.requestID)
            try fail(.afterReceipt);try fail(.beforeCommit)
        }
        if changedIdentity {throw AuthorityError.identityChanged}
        if fault == .afterCommit {throw StoreError.responseLost}
    }
}
