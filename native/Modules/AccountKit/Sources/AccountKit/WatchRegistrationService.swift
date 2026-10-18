import Foundation
import MatchStore
import MatchSession

public enum WatchRegistrationAction:String,Codable,Sendable {case submit,recover}
public enum WatchRegistrationError:Error,Sendable,Equatable {case knownAbandoned}
public protocol WatchRegistrationAuthorizing:Sendable {
    func registrationContext() async throws->WatchRegistrationContextV4
    func authorizeRegistration(_ attempt:WatchRegistrationAttemptV4,action:WatchRegistrationAction) async throws->Data
}
enum WatchRegistrationClosure {
    static func receipt(_ raw:Data,attempt:WatchRegistrationAttemptV4,trust:AuthorityTrustConfiguration)throws->VerifiedAuthorityReceiptV1? {
        guard raw.count<=65536,let object=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else {throw AuthorityError.invalidWire}
        guard object["status"] != nil else {return nil}
        guard object["status"] as? String=="knownAbandoned",Set(object.keys)==["status","receipt"],try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])==raw,let value=object["receipt"] else {throw AuthorityError.invalidWire}
        let verified=try VerifiedAuthorityReceiptV1.verify(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]),expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.registerWatch,accountID:attempt.context.accountID,epoch:attempt.context.activationEpoch),trust:trust),b=verified.body
        guard b.result == .knownAbandoned,b.registration?.watchID==attempt.payload.watchID,b.registration?.watchPublicKey==attempt.payload.watchPublicKey,b.matchID.isEmpty,b.lockID.isEmpty,b.recordingDeviceID.isEmpty,b.migration==nil,b.peerGrant==nil,b.lostRecovery==nil,b.deletion==nil else {throw AuthorityError.intentMismatch};return verified
    }
}
struct WatchRegistrationReply {
    struct Claims:Decodable {let sessionID:String;let expiresAt:Int64}
    let receipt:VerifiedAuthorityReceiptV1
    let credential:DeviceCredential?
    let expired:Bool
    init(_ raw:Data,attempt:WatchRegistrationAttemptV4,trust:AuthorityTrustConfiguration,now:Date,credentialRequired:Bool)throws {
        guard raw.count<=65536,let object=try JSONSerialization.jsonObject(with:raw) as? [String:Any],Set(object.keys)==Set(credentialRequired ? ["receipt","sessionClaims","credential"]:["receipt","sessionClaims"]),
              try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])==raw,let receiptObject=object["receipt"],let claimsObject=object["sessionClaims"] as? [String:Any],Set(claimsObject.keys)==["sessionID","expiresAt"] else {throw AuthorityError.invalidWire}
        let receipt=try VerifiedAuthorityReceiptV1.verify(JSONSerialization.data(withJSONObject:receiptObject,options:[.sortedKeys,.withoutEscapingSlashes]),expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.registerWatch,accountID:attempt.context.accountID,epoch:attempt.context.activationEpoch),trust:trust)
        guard receipt.body.result == .registered,receipt.body.registration?.watchID==attempt.payload.watchID,receipt.body.registration?.watchPublicKey==attempt.payload.watchPublicKey else {throw AuthorityError.intentMismatch}
        let claims=try JSONDecoder().decode(Claims.self,from:JSONSerialization.data(withJSONObject:claimsObject)),seconds=now.timeIntervalSince1970
        try AuthorityWire.identifier(claims.sessionID)
        guard seconds.isFinite,seconds>=0,claims.expiresAt>0,claims.expiresAt<=9_007_199_254_740_991 else {throw AuthorityError.staleAttestation}
        if credentialRequired {
            guard let value=object["credential"] as? [String:Any],Set(value.keys)==["token","sessionID","accountID","deviceID","keyID","activationEpoch","expiresAt"] else {throw AuthorityError.invalidWire}
            let c=try JSONDecoder().decode(DeviceCredential.self,from:JSONSerialization.data(withJSONObject:value))
            guard c.accountID==attempt.context.accountID,c.deviceID==attempt.payload.watchID,c.keyID == (try AuthorityWire.deviceKeyID(publicKey:attempt.payload.watchPublicKey)),c.activationEpoch==attempt.context.activationEpoch,c.sessionID==claims.sessionID,c.expiresAt==claims.expiresAt else {throw AuthorityError.identityChanged}
            _=try AuthorityWire.decodeBase64URL(c.token,count:32);credential=c
        } else {credential=nil}
        self.receipt=receipt;expired=Double(claims.expiresAt)<seconds
    }
}
/// The active Phone authorizes an immutable Watch proof; it never writes the returned Watch credential to its vault.
public actor PhoneWatchRegistrationService:WatchRegistrationAuthorizing {
    let client:AuthorityClient
    let repository:any AccountLifecycleRepository & AuthorityRepository & WatchRegistrationRepository
    let coordinator:any WatchRegistrationCoordinator
    var admission:Int64?
    public init(client:AuthorityClient,repository:any AccountLifecycleRepository & AuthorityRepository & WatchRegistrationRepository,coordinator:any WatchRegistrationCoordinator){self.client=client;self.repository=repository;self.coordinator=coordinator}
    func facade() async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged}}
    public func admitCurrentIdentity(accountID:String) async throws {
        try await facade();guard let b=try await repository.accountBindingV4(),b.accountID==accountID,b.role == .phone,!b.suspended,b.environment==client.trust.environment else {throw AuthorityError.identityChanged}
        let generation=try await repository.identityGenerationV4();try await client.vault.advanceIdentityFence(to:generation)
        guard try await repository.identityGenerationV4()==generation,try await repository.accountBindingV4()==b else {throw AuthorityError.identityChanged};admission=generation
    }
    public func registrationContext() async throws->WatchRegistrationContextV4 {
        try await facade();guard let generation=admission,try await repository.identityGenerationV4()==generation,let b=try await repository.accountBindingV4(),b.role == .phone,!b.suspended,b.environment==client.trust.environment else {throw AuthorityError.identityChanged}
        let c=try await client.vault.credential()
        guard c.accountID==b.accountID,c.deviceID==b.deviceID,c.activationEpoch==b.activationEpoch,c.keyID == (try AuthorityWire.deviceKeyID(publicKey:client.signer.publicKey)),try await repository.identityGenerationV4()==generation else {throw AuthorityError.identityChanged}
        return try WatchRegistrationContextV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,phoneID:b.deviceID,activationEpoch:b.activationEpoch,environment:b.environment)
    }
    public func authorizeRegistration(_ attempt:WatchRegistrationAttemptV4,action:WatchRegistrationAction) async throws->Data {
        try attempt.validate();guard let generation=admission else {throw AuthorityError.identityChanged}
        let context=try await registrationContext();guard context==attempt.context,try await repository.identityGenerationV4()==generation else {throw AuthorityError.identityChanged}
        try await coordinator.saveWatchRegistrationAttempt(attempt,expectedIdentityGeneration:generation)
        if action == .recover {
            do {
                let original=try await client.query(requestID:attempt.requestID)
                if let closed=try WatchRegistrationClosure.receipt(original,attempt:attempt,trust:client.trust) {
                    try await coordinator.closeWatchRegistration(attempt,receipt:closed,expectedIdentityGeneration:generation);return original
                }
                let reply=try WatchRegistrationReply(original,attempt:attempt,trust:client.trust,now:client.now(),credentialRequired:false)
                if reply.expired {
                    try await coordinator.acceptWatchRegistration(attempt,receipt:reply.receipt,watchBinding:nil,expectedIdentityGeneration:generation)
                    guard try await repository.identityGenerationV4()==generation else {throw AuthorityError.identityChanged};return original
                }
            } catch let failure as AuthorityHTTPFailure where failure.code=="notFound" {} // Only explicit recovery may ask the backend to close the original attempt.
        }
        let raw=try await client.signed(path:action == .submit ? "/v1/devices/watches":"/v1/devices/watches/recover",body:attempt.canonicalRequest,requestID:attempt.requestID)
        if let closed=try WatchRegistrationClosure.receipt(raw,attempt:attempt,trust:client.trust) {
            try await coordinator.closeWatchRegistration(attempt,receipt:closed,expectedIdentityGeneration:generation);return raw
        }
        let reply=try WatchRegistrationReply(raw,attempt:attempt,trust:client.trust,now:client.now(),credentialRequired:true)
        try await coordinator.acceptWatchRegistration(attempt,receipt:reply.receipt,watchBinding:nil,expectedIdentityGeneration:generation)
        guard try await repository.identityGenerationV4()==generation,try await registrationContext()==context else {throw AuthorityError.identityChanged};return raw
    }
}
/// SDK/WC supplies the authorizer transport; all registration/recovery semantics remain here.
public actor WatchRegistrationService {
    let client:AuthorityClient
    let repository:any AccountLifecycleRepository & AuthorityRepository & WatchRegistrationRepository
    let coordinator:any WatchRegistrationCoordinator
    let deviceID,cloudSpaceID:String
    let authorizer:any WatchRegistrationAuthorizing
    var admission:(WatchRegistrationContextV4,Int64)?
    public init(client:AuthorityClient,repository:any AccountLifecycleRepository & AuthorityRepository & WatchRegistrationRepository,coordinator:any WatchRegistrationCoordinator,deviceID:String,cloudSpaceID:String,authorizer:any WatchRegistrationAuthorizing){self.client=client;self.repository=repository;self.coordinator=coordinator;self.deviceID=deviceID;self.cloudSpaceID=cloudSpaceID;self.authorizer=authorizer}
    func facade() async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged}}
    public func admitCurrentIdentity(context:WatchRegistrationContextV4) async throws {
        try await facade();guard context.cloudSpaceID==cloudSpaceID,context.environment==client.trust.environment,deviceID != context.phoneID else {throw AuthorityError.identityChanged}
        let generation=try await coordinator.admitWatchRegistrationContext(context,deviceID:deviceID,publicKey:client.signer.publicKey)
        try await client.vault.advanceIdentityFence(to:generation)
        guard try await repository.identityGenerationV4()==generation else {throw AuthorityError.identityChanged};admission=(context,generation)
    }
    func currentAdmission() async throws->(WatchRegistrationContextV4,Int64) {
        try await facade();guard let value=admission,try await repository.identityGenerationV4()==value.1 else {throw AuthorityError.identityChanged};return value
    }
    struct ChallengeRequest:Encodable {let version=1;let requestID,deviceID,devicePublicKey:String}
    struct Challenge:Codable {let version:Int;let requestID,challengeID:String;let challenge:String?;let expiresAt:Int64;let status:String?}
    public func register(requestID:String,challengeRequestID:String) async throws->AccountAuthentication {
        let (context,generation)=try await currentAdmission()
        if try await repository.watchRegistrationAttemptV4(requestID:requestID) != nil {return try await recover(requestID:requestID)}
        guard try await repository.pendingWatchRegistrationAttemptsV4().allSatisfy({$0.payload.watchID != deviceID || $0.context.activationEpoch<context.activationEpoch}) else {throw AuthorityError.conflict}
        let raw=try await client.unsigned(path:"/v1/auth/challenges",body:AuthorityWire.encode(ChallengeRequest(requestID:challengeRequestID,deviceID:deviceID,devicePublicKey:client.signer.publicKey))),challenge=try AuthorityWire.decode(Challenge.self,raw),seconds=client.now().timeIntervalSince1970
        guard seconds.isFinite,seconds>=0,seconds<=9_007_199_254_740_991,challenge.version==1,challenge.requestID==challengeRequestID,challenge.status==nil,let secret=challenge.challenge,challenge.expiresAt>=0,challenge.expiresAt<=9_007_199_254_740_991,Double(challenge.expiresAt)>=seconds,Double(challenge.expiresAt)-seconds<=300 else {throw AuthorityError.staleAttestation}
        let hash=AuthorityWire.hash(Data(secret.utf8));var signing:[String:Any]=["version":1,"requestID":requestID,"watchID":deviceID,"watchPublicKey":client.signer.publicKey,"challengeID":challenge.challengeID,"challengeSHA256":hash]
        let signature=try await client.signer.sign(AuthorityWire.signedInput("football-record.device.challenge.v1",body:JSONSerialization.data(withJSONObject:signing,options:[.sortedKeys,.withoutEscapingSlashes])))
        signing.removeAll() // The raw challenge is never persisted.
        let attempt=try WatchRegistrationAttemptV4(context:context,payload:WatchRegistrationPayloadV4(requestID:requestID,watchID:deviceID,watchPublicKey:client.signer.publicKey,challengeID:challenge.challengeID,deviceProof:AuthorityWire.base64URL(signature)),challengeRequestID:challengeRequestID,challengeSHA256:hash)
        try await coordinator.saveWatchRegistrationAttempt(attempt,expectedIdentityGeneration:generation)
        return try await finish(attempt,generation:generation,action:.submit)
    }
    public func recover(requestID:String) async throws->AccountAuthentication {
        let (context,generation)=try await currentAdmission()
        guard let attempt=try await repository.watchRegistrationAttemptV4(requestID:requestID),attempt.context==context,attempt.payload.watchID==deviceID,attempt.payload.watchPublicKey==client.signer.publicKey else {throw AuthorityError.identityChanged}
        return try await finish(attempt,generation:generation,action:.recover)
    }
    func finish(_ attempt:WatchRegistrationAttemptV4,generation:Int64,action:WatchRegistrationAction) async throws->AccountAuthentication {
        let raw=try await authorizer.authorizeRegistration(attempt,action:action)
        if let closed=try WatchRegistrationClosure.receipt(raw,attempt:attempt,trust:client.trust) {
            try await coordinator.closeWatchRegistration(attempt,receipt:closed,expectedIdentityGeneration:generation)
            throw WatchRegistrationError.knownAbandoned
        }
        guard let object=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else {throw AuthorityError.invalidWire}
        let reply=try WatchRegistrationReply(raw,attempt:attempt,trust:client.trust,now:client.now(),credentialRequired:object["credential"] != nil)
        if reply.expired {
            try await coordinator.acceptWatchRegistration(attempt,receipt:reply.receipt,watchBinding:nil,expectedIdentityGeneration:generation)
            throw AuthorityError.staleAttestation
        }
        guard let credential=reply.credential else {throw AuthorityError.invalidWire}
        let b=try AccountBindingV4(accountID:attempt.context.accountID,cloudSpaceID:cloudSpaceID,deviceID:deviceID,activationEpoch:attempt.context.activationEpoch,role:.watch,environment:attempt.context.environment)
        try await coordinator.acceptWatchRegistration(attempt,receipt:reply.receipt,watchBinding:b,expectedIdentityGeneration:generation)
        try await client.vault.replace(credential,expectedIdentityGeneration:generation)
        guard try await repository.identityGenerationV4()==generation else {throw AuthorityError.identityChanged}
        return AccountAuthentication(binding:b,receipt:reply.receipt,reauthenticationID:nil)
    }
}
