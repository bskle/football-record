import Foundation
extension MatchStore {
    struct StoredWatchAdmission:Codable {let context:WatchRegistrationContextV4;let publicKey:String}
    public func admitWatchRegistrationContextV4(_ context:WatchRegistrationContextV4,deviceID:String,publicKey:String)throws->Int64 {
        try db.transaction {
            _=try WatchRegistrationContextV4(accountID:context.accountID,cloudSpaceID:context.cloudSpaceID,phoneID:context.phoneID,activationEpoch:context.activationEpoch,environment:context.environment)
            try AuthorityWire.identifier(deviceID);_=try AuthorityWire.deviceKeyID(publicKey:publicKey)
            guard let trust=authorityTrust,trust.environment==context.environment,deviceID != context.phoneID else {throw AuthorityError.identityChanged}
            var changes=false
            if let old=try readLifecycleV4(StoredWatchAdmission.self,"watch-admission:"+deviceID) {
                guard old.publicKey==publicKey,old.context.accountID==context.accountID,old.context.cloudSpaceID==context.cloudSpaceID,context.activationEpoch>=old.context.activationEpoch,
                      context.activationEpoch>old.context.activationEpoch || context==old.context else {throw AuthorityError.identityChanged}
                changes=old.context != context
            }
            if let b=try currentBindingV4() {
                guard b.role == .watch,b.deviceID==deviceID,b.accountID==context.accountID,b.cloudSpaceID==context.cloudSpaceID,b.environment==context.environment,b.activationEpoch<=context.activationEpoch else {throw AuthorityError.identityChanged}
                if b.activationEpoch<context.activationEpoch {changes=true}
                if changes {try writeV4(AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:b.activationEpoch,role:b.role,environment:b.environment,suspended:true),table:"account_binding_v4",id:"current")}
            }
            if changes {_=try advanceIdentityGenerationLockedV4()}
            try writeV4(StoredWatchAdmission(context:context,publicKey:publicKey),table:"lifecycle_steps_v4",id:"watch-admission:"+deviceID);try fail(.beforeCommit);return try identityGenerationV4()
        }
    }
    public func watchRegistrationAttemptV4(requestID:String)throws->WatchRegistrationAttemptV4? {
        guard let attempt=try readLifecycleV4(WatchRegistrationAttemptV4.self,"watch-attempt:"+requestID) else {return nil};try attempt.validate();guard attempt.requestID==requestID else {throw AuthorityError.intentMismatch};return attempt
    }
    public func watchRegistrationReceiptV4(requestID:String)throws->Data? {
        guard let raw=try readLifecycleV4(Data.self,"watch-receipt:"+requestID),let attempt=try watchRegistrationAttemptV4(requestID:requestID) else {return nil}
        _=try verifyWatchRegistrationV4(attempt,raw:raw);return raw
    }
    public func pendingWatchRegistrationAttemptsV4()throws->[WatchRegistrationAttemptV4] {
        try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'watch-attempt:%' ORDER BY rowid").map {row in let a=try checkedV4(WatchRegistrationAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:"watch-attempt");try a.validate();return a}.filter {try watchRegistrationReceiptV4(requestID:$0.requestID)==nil}
    }
    func validateWatchParticipantV4(_ attempt:WatchRegistrationAttemptV4,allowSuspended:Bool)throws {
        guard let trust=authorityTrust,trust.environment==attempt.context.environment else {throw AuthorityError.unavailable}
        if let b=try currentBindingV4() {
            guard (allowSuspended || !b.suspended),b.accountID==attempt.context.accountID,b.cloudSpaceID==attempt.context.cloudSpaceID,(b.role == .watch ? b.activationEpoch<=attempt.context.activationEpoch:b.activationEpoch==attempt.context.activationEpoch),b.environment==attempt.context.environment,
                  (b.role == .phone && b.deviceID==attempt.context.phoneID)||(b.role == .watch && b.deviceID==attempt.payload.watchID) else {throw AuthorityError.identityChanged}
        }
        if (try currentBindingV4())?.role != .phone {
            guard let admission=try readLifecycleV4(StoredWatchAdmission.self,"watch-admission:"+attempt.payload.watchID),admission.context==attempt.context,admission.publicKey==attempt.payload.watchPublicKey else {throw AuthorityError.identityChanged}
        }
    }
    func verifyWatchRegistrationV4(_ attempt:WatchRegistrationAttemptV4,raw:Data)throws->VerifiedAuthorityReceiptV1 {
        guard let trust=authorityTrust else {throw AuthorityError.unavailable}
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.registerWatch,accountID:attempt.context.accountID,epoch:attempt.context.activationEpoch),trust:trust)
        guard receipt.body.result == .registered,receipt.body.registration?.watchID==attempt.payload.watchID,receipt.body.registration?.watchPublicKey==attempt.payload.watchPublicKey else {throw AuthorityError.intentMismatch};return receipt
    }
    public func saveWatchRegistrationAttemptV4(_ attempt:WatchRegistrationAttemptV4,expectedIdentityGeneration:Int64)throws {
        try db.transaction {
            try attempt.validate();guard try identityGenerationV4()==expectedIdentityGeneration else {throw AuthorityError.identityChanged};try validateWatchParticipantV4(attempt,allowSuspended:true)
            if let prior=try watchRegistrationAttemptV4(requestID:attempt.requestID) {guard prior==attempt else {throw AuthorityError.conflict};return}
            for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'watch-attempt:%'") {
                let prior=try checkedV4(WatchRegistrationAttemptV4.self,row:row,table:"lifecycle_steps_v4",key:"watch-attempt")
                if prior.payload.watchID==attempt.payload.watchID {guard prior.payload.watchPublicKey==attempt.payload.watchPublicKey else {throw AuthorityError.identityChanged};guard try prior.context.activationEpoch<attempt.context.activationEpoch || watchRegistrationReceiptV4(requestID:prior.requestID) != nil else {throw AuthorityError.conflict}}
            }
            try writeV4(attempt,table:"lifecycle_steps_v4",id:"watch-attempt:"+attempt.requestID);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func acceptWatchRegistrationV4(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,watchBinding:AccountBindingV4?,expectedIdentityGeneration:Int64)throws {
        try db.transaction {
            guard try identityGenerationV4()==expectedIdentityGeneration,try watchRegistrationAttemptV4(requestID:attempt.requestID)==attempt else {throw AuthorityError.identityChanged}
            try validateWatchParticipantV4(attempt,allowSuspended:true);_=try verifyWatchRegistrationV4(attempt,raw:receipt.raw)
            if let first=try watchRegistrationReceiptV4(requestID:attempt.requestID) {guard first==receipt.raw else {throw AuthorityError.conflict}}
            if let b=watchBinding {
                guard b.role == .watch,!b.suspended,b.accountID==attempt.context.accountID,b.cloudSpaceID==attempt.context.cloudSpaceID,b.deviceID==attempt.payload.watchID,b.activationEpoch==attempt.context.activationEpoch,b.environment==attempt.context.environment else {throw AuthorityError.identityChanged}
                if let current=try currentBindingV4() {guard current.role == .watch,current.deviceID==b.deviceID else {throw AuthorityError.identityChanged}}
                try writeV4(b,table:"account_binding_v4",id:"current")
            } else if let b=try currentBindingV4(),b.role == .phone {guard b.deviceID==attempt.context.phoneID,!b.suspended else {throw AuthorityError.identityChanged}}
            try writeV4(receipt.raw,table:"lifecycle_steps_v4",id:"watch-receipt:"+attempt.requestID);try fail(.afterReceipt);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
extension MatchStore:WatchRegistrationRepository {}
