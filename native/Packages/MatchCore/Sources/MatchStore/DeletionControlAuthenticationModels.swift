import CryptoKit
import Foundation

/// A read from the original facade, never a business admission or caller-supplied verified flag.
public struct DeletionControlContextV1: Sendable {
    public let saga: DeletionSagaV4
    public let binding: AccountBindingV4
    public let originalScope: CloudScopeV1
    public let publicKey, keyID: String
    public let identityGeneration: Int64
}
public enum DeletionControlIssueV1: String, Error, Sendable { case unresolved, needsFreshAuthorization, parentUnavailable, lockMappingUnavailable, identityChanged, stopped, capacity }
public enum DeletionControlLockStateV1: String, Codable, Sendable { case none, pinned, unavailable }
public enum DeletionControlResultV1: String, Codable, Sendable { case ready, knownAbandoned, knownExpired, knownRevoked, parentUnavailable, lockMappingUnavailable }
public struct DeletionControlAttemptV1: Codable, Sendable, Equatable {
    public let parentRequestID, parentDigest, challengeRequestID: String
    public let originalScope: CloudScopeV1
    public let binding: AccountBindingV4
    public let publicKey, keyID: String
    public let identityGeneration: Int64
    public let authentication: AuthAttemptV4
    public init(context: DeletionControlContextV1, challengeRequestID: String, authentication: AuthAttemptV4) throws {
        try self.init(parentRequestID: context.saga.intent.requestID, parentDigest: context.saga.intent.digest, challengeRequestID: challengeRequestID, originalScope: context.originalScope, binding: context.binding, publicKey: context.publicKey, keyID: context.keyID, identityGeneration: context.identityGeneration, authentication: authentication)
    }
    private init(parentRequestID:String,parentDigest:String,challengeRequestID:String,originalScope:CloudScopeV1,binding:AccountBindingV4,publicKey:String,keyID:String,identityGeneration:Int64,authentication:AuthAttemptV4) throws {
        for id in [parentRequestID,challengeRequestID,authentication.requestID] { try AuthorityWire.identifier(id) }
        try DeletionControlWireV1.hash(parentDigest)
        guard identityGeneration >= 0, identityGeneration <= 9_007_199_254_740_991,
              parentRequestID != authentication.requestID, parentRequestID != challengeRequestID, challengeRequestID != authentication.requestID,
              try AuthorityWire.deviceKeyID(publicKey:publicKey) == keyID, keyID == authentication.keyID,
              DeletionControlWireV1.same(binding.accountID,originalScope.accountID),DeletionControlWireV1.same(binding.cloudSpaceID,originalScope.cloudSpaceID),binding.activationEpoch == originalScope.activationEpoch,
              DeletionControlWireV1.same(binding.deviceID,authentication.deviceID),DeletionControlWireV1.same(binding.cloudSpaceID,authentication.cloudSpaceID),binding.environment == authentication.environment,binding.role == .phone,
              publicKey == authentication.publicKey else { throw AuthorityError.intentMismatch }
        self.parentRequestID=parentRequestID;self.parentDigest=parentDigest;self.challengeRequestID=challengeRequestID;self.originalScope=originalScope;self.binding=binding;self.publicKey=publicKey;self.keyID=keyID;self.identityGeneration=identityGeneration;self.authentication=authentication
    }
    private enum CodingKeys:String,CodingKey { case parentRequestID,parentDigest,challengeRequestID,originalScope,binding,publicKey,keyID,identityGeneration,authentication }
    public init(from decoder:any Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(parentRequestID:c.decode(String.self,forKey:.parentRequestID),parentDigest:c.decode(String.self,forKey:.parentDigest),challengeRequestID:c.decode(String.self,forKey:.challengeRequestID),originalScope:c.decode(CloudScopeV1.self,forKey:.originalScope),binding:c.decode(AccountBindingV4.self,forKey:.binding),publicKey:c.decode(String.self,forKey:.publicKey),keyID:c.decode(String.self,forKey:.keyID),identityGeneration:c.decode(Int64.self,forKey:.identityGeneration),authentication:c.decode(AuthAttemptV4.self,forKey:.authentication))
    }
}
public struct DeletionControlLockPinV1: Codable, Sendable, Equatable {
    public let matchID,lockID,recordingDeviceID:String
    public let activationEpoch:Int64
    public let acquireRequestID,acquireRequestDigest,acquireReceiptDigest:String
}
public struct DeletionControlAuthorizationBodyV1: Codable, Sendable, Equatable {
    public let version:Int
    public let purpose:String
    public let environment:AuthorityEnvironment
    public let keyID,proofID,requestID,requestDigest,parentRequestID,parentDigest,recoveryCapabilityDigest,accountID,deviceID,deviceKeyID:String
    public let activationEpoch:Int64
    public let cloudSpaceID:String
    public let result:DeletionControlResultV1
    public let stage:String
    public let issuedAt,expiresAt:Int64
    public let sessionID,reauthenticationID:String?
    public let reauthenticationExpiresAt:Int64?
    public let lockState:DeletionControlLockStateV1
    public let lock:DeletionControlLockPinV1?
    private enum CodingKeys:String,CodingKey {case version,purpose,environment,keyID,proofID,requestID,requestDigest,parentRequestID,parentDigest,recoveryCapabilityDigest,accountID,deviceID,deviceKeyID,activationEpoch,cloudSpaceID,result,stage,issuedAt,expiresAt,sessionID,reauthenticationID,reauthenticationExpiresAt,lockState,lock}
    public func encode(to encoder:any Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(version,forKey:.version);try c.encode(purpose,forKey:.purpose);try c.encode(environment,forKey:.environment);try c.encode(keyID,forKey:.keyID);try c.encode(proofID,forKey:.proofID);try c.encode(requestID,forKey:.requestID);try c.encode(requestDigest,forKey:.requestDigest);try c.encode(parentRequestID,forKey:.parentRequestID);try c.encode(parentDigest,forKey:.parentDigest);try c.encode(recoveryCapabilityDigest,forKey:.recoveryCapabilityDigest);try c.encode(accountID,forKey:.accountID);try c.encode(deviceID,forKey:.deviceID);try c.encode(deviceKeyID,forKey:.deviceKeyID);try c.encode(activationEpoch,forKey:.activationEpoch);try c.encode(cloudSpaceID,forKey:.cloudSpaceID);try c.encode(result,forKey:.result);try c.encode(stage,forKey:.stage);try c.encode(issuedAt,forKey:.issuedAt);try c.encode(expiresAt,forKey:.expiresAt);try c.encode(sessionID,forKey:.sessionID);try c.encode(reauthenticationID,forKey:.reauthenticationID);try c.encode(reauthenticationExpiresAt,forKey:.reauthenticationExpiresAt);try c.encode(lockState,forKey:.lockState);try c.encode(lock,forKey:.lock)
    }
}
public struct VerifiedDeletionControlAuthorizationV1: Sendable, Equatable {
    public let raw:Data
    public let body:DeletionControlAuthorizationBodyV1
    private struct Envelope:Codable {let body:DeletionControlAuthorizationBodyV1;let signature:String}
    private init(raw:Data,body:DeletionControlAuthorizationBodyV1){self.raw=raw;self.body=body}
    public static func verify(_ raw:Data,expectedParent parent:DeletionSagaV4,expectedAttempt attempt:DeletionControlAttemptV1,trust:AuthorityTrustConfiguration)throws->Self {
        let e=try AuthorityWire.decode(Envelope.self,raw),b=e.body
        _=try DeletionSagaV4(intent:parent.intent,accountID:parent.accountID,activationEpoch:parent.activationEpoch,recoveryCapability:parent.recoveryCapability,cloudChoice:parent.cloudChoice,localChoice:parent.localChoice,healthChoice:parent.healthChoice,healthConfirmed:parent.healthConfirmed,originalScope:parent.originalScope)
        guard b.version == 1,b.purpose == "deleteControl.v1",b.environment == trust.environment,b.environment == attempt.binding.environment,let key=trust.publicKeys[b.keyID],
              b.parentRequestID == parent.intent.requestID,b.parentDigest == parent.intent.digest,b.recoveryCapabilityDigest == parent.intent.fields.recoveryCapabilityDigest,
              attempt.parentRequestID == b.parentRequestID,attempt.parentDigest == b.parentDigest,b.requestID == attempt.authentication.requestID,b.requestDigest == attempt.authentication.requestDigest,
              DeletionControlWireV1.same(b.accountID,parent.accountID),DeletionControlWireV1.same(b.accountID,attempt.binding.accountID),DeletionControlWireV1.same(b.deviceID,attempt.binding.deviceID),b.deviceKeyID == attempt.keyID,
              DeletionControlWireV1.same(b.cloudSpaceID,attempt.originalScope.cloudSpaceID),b.activationEpoch == parent.activationEpoch,b.activationEpoch == attempt.originalScope.activationEpoch,
              parent.originalScope.map({DeletionControlWireV1.scope($0,attempt.originalScope)}) == true,
              b.issuedAt >= 0,b.expiresAt >= b.issuedAt,b.expiresAt <= 9_007_199_254_740_991,["unreserved","requested","lockReconciled","appleRevocation"].contains(b.stage) else {throw AuthorityError.intentMismatch}
        for id in [b.proofID,b.requestID,b.parentRequestID,b.accountID,b.deviceID,b.deviceKeyID,b.cloudSpaceID] {try AuthorityWire.identifier(id)}
        for hash in [b.requestDigest,b.parentDigest,b.recoveryCapabilityDigest] {try DeletionControlWireV1.hash(hash)}
        if b.result == .ready {
            guard let session=b.sessionID,session.hasPrefix("dc."),UUID(uuidString:String(session.dropFirst(3))) != nil,b.expiresAt-b.issuedAt == 300,b.stage != "unreserved" else {throw AuthorityError.invalidWire}
            if b.stage == "appleRevocation" {guard b.reauthenticationID == nil,b.reauthenticationExpiresAt == nil else {throw AuthorityError.invalidWire}}
            else {guard let id=b.reauthenticationID,let expires=b.reauthenticationExpiresAt,expires>=b.issuedAt-300,expires<=b.issuedAt+360 else {throw AuthorityError.invalidWire};try AuthorityWire.identifier(id)}
        }else{guard b.sessionID == nil,b.reauthenticationID == nil,b.reauthenticationExpiresAt == nil,b.expiresAt == b.issuedAt else {throw AuthorityError.invalidWire}}
        if b.lockState == .pinned {
            guard let pin=b.lock,pin.activationEpoch == b.activationEpoch else {throw AuthorityError.invalidWire}
            for id in [pin.matchID,pin.lockID,pin.recordingDeviceID,pin.acquireRequestID] {try AuthorityWire.identifier(id)}
            for hash in [pin.acquireRequestDigest,pin.acquireReceiptDigest] {try DeletionControlWireV1.hash(hash)}
        }else{guard b.lock == nil else {throw AuthorityError.invalidWire}}
        if b.result != .ready {guard b.lockState == .none else {throw AuthorityError.invalidWire}}
        let pub=try Curve25519.Signing.PublicKey(rawRepresentation:AuthorityWire.decodeBase64URL(key,count:32))
        guard pub.isValidSignature(try AuthorityWire.decodeBase64URL(e.signature,count:64),for:AuthorityWire.signedInput("football-record.deletion-control-auth.v1",body:try AuthorityWire.encode(b))) else {throw AuthorityError.invalidSignature}
        return Self(raw:raw,body:b)
    }
}
public struct DeletionControlLockConfirmationV1: Codable, Sendable, Equatable {
    public let parentRequestID,parentDigest,confirmationID:String
    public let confirmedAt:Int64
    public let intent:ControlIntentV1
    public let acquireRaw:Data
    public init(parentRequestID:String,parentDigest:String,confirmationID:String,confirmedAt:Int64,intent:ControlIntentV1,acquireRaw:Data)throws {
        try AuthorityWire.identifier(parentRequestID);try AuthorityWire.identifier(confirmationID);try DeletionControlWireV1.hash(parentDigest)
        guard confirmedAt>=0,confirmedAt<=9_007_199_254_740_991,intent.operation == .terminate,intent.fields.mode == "abnormal",acquireRaw.count<=16384 else {throw AuthorityError.invalidWire}
        self.parentRequestID=parentRequestID;self.parentDigest=parentDigest;self.confirmationID=confirmationID;self.confirmedAt=confirmedAt;self.intent=intent;self.acquireRaw=acquireRaw
    }
    private enum CodingKeys:String,CodingKey {case parentRequestID,parentDigest,confirmationID,confirmedAt,intent,acquireRaw}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(parentRequestID:c.decode(String.self,forKey:.parentRequestID),parentDigest:c.decode(String.self,forKey:.parentDigest),confirmationID:c.decode(String.self,forKey:.confirmationID),confirmedAt:c.decode(Int64.self,forKey:.confirmedAt),intent:c.decode(ControlIntentV1.self,forKey:.intent),acquireRaw:c.decode(Data.self,forKey:.acquireRaw))}
}
/// Historical proof bytes only. An active control operation must recheck the original parent and identity.
public struct DeletionControlAuthorizationRecordV1: Sendable {
    public let authorization:VerifiedDeletionControlAuthorizationV1
    public let originalAcquire:Data?
    public let resolution:VerifiedDeletionControlAuthorizationV1?
}
public enum DeletionControlOutcomeV1:Sendable {case ready(reauthenticationID:String?,lockState:DeletionControlLockStateV1),needsFreshAuthorization,unresolved,knownAbandoned,knownExpired,knownRevoked,parentCompleted(VerifiedAuthorityReceiptV1),parentUnavailable,lockMappingUnavailable}
public protocol DeletionControlAuthenticationRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func deletionControlContextV4(parentID:String,expectedIdentityGeneration:Int64) async throws->DeletionControlContextV1
    /// Same-transaction active admission for this exact first proof; historical reads do not grant readiness.
    func deletionControlReadyContextV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,expectedIdentityGeneration:Int64,at:Date) async throws->DeletionControlContextV1
    func deletionControlAttemptsV4(parentID:String) async throws->[DeletionControlAttemptV1]
    func deletionControlAttemptV4(parentID:String,authRequestID:String) async throws->DeletionControlAttemptV1?
    func deletionControlAuthorizationV4(parentID:String,authRequestID:String) async throws->DeletionControlAuthorizationRecordV1?
    func deletionControlLockConfirmationV4(parentID:String) async throws->DeletionControlLockConfirmationV1?
    func saveDeletionControlAttemptV4(_ attempt:DeletionControlAttemptV1) async throws
    func acceptDeletionControlAuthorizationV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,originalAcquire:Data?,expectedIdentityGeneration:Int64,at:Date) async throws
    func resolveDeletionControlAttemptV4(parentID:String,authorization:VerifiedDeletionControlAuthorizationV1,expectedIdentityGeneration:Int64) async throws
    func saveDeletionControlLockConfirmationV4(parentID:String,confirmation:DeletionControlLockConfirmationV1,expectedIdentityGeneration:Int64) async throws
    func acceptDeletionControlLiveLockV4(parentID:String,proof:VerifiedLiveLockV1,expectedIdentityGeneration:Int64,at:Date) async throws
    func acceptDeletionControlAbnormalResultV4(parentID:String,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64) async throws
}
enum DeletionControlWireV1 {
    static func same(_ a:String,_ b:String)->Bool {a.utf8.elementsEqual(b.utf8)}
    static func scope(_ a:CloudScopeV1,_ b:CloudScopeV1)->Bool {same(a.accountID,b.accountID)&&same(a.cloudSpaceID,b.cloudSpaceID)&&same(a.zoneID,b.zoneID)&&a.activationEpoch==b.activationEpoch}
    static func hash(_ s:String)throws {guard s.utf8.count==64,s.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw AuthorityError.invalidWire}}
    static func seconds(_ date:Date)throws->Int64 {let t=date.timeIntervalSince1970;guard t.isFinite,t>=0,t<=9_007_199_254_740_991 else {throw AuthorityError.invalidWire};return Int64(t)}
}
