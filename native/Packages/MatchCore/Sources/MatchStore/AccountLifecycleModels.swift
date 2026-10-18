import Foundation
public struct AuthAttemptV4:Codable,Sendable,Equatable {
    public let requestID,deviceID,publicKey,keyID,cloudSpaceID,challengeID,requestDigest:String
    public let environment:AuthorityEnvironment
    public init(requestID:String,deviceID:String,publicKey:String,cloudSpaceID:String,challengeID:String,requestDigest:String,environment:AuthorityEnvironment)throws {
        for id in [requestID,deviceID,cloudSpaceID,challengeID] {try AuthorityWire.identifier(id)}
        guard requestDigest.count==64,requestDigest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw AuthorityError.invalidWire}
        self.requestID=requestID;self.deviceID=deviceID;self.publicKey=publicKey;keyID=try AuthorityWire.deviceKeyID(publicKey:publicKey);self.cloudSpaceID=cloudSpaceID;self.challengeID=challengeID;self.requestDigest=requestDigest;self.environment=environment
    }
    private enum CodingKeys:String,CodingKey {case requestID,deviceID,publicKey,keyID,cloudSpaceID,challengeID,requestDigest,environment}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(requestID:c.decode(String.self,forKey:.requestID),deviceID:c.decode(String.self,forKey:.deviceID),publicKey:c.decode(String.self,forKey:.publicKey),cloudSpaceID:c.decode(String.self,forKey:.cloudSpaceID),challengeID:c.decode(String.self,forKey:.challengeID),requestDigest:c.decode(String.self,forKey:.requestDigest),environment:c.decode(AuthorityEnvironment.self,forKey:.environment));guard keyID == (try c.decode(String.self,forKey:.keyID)) else {throw AuthorityError.invalidWire}}
}
public enum AuthResolutionV4:String,Codable,Sendable {case knownRevoked,knownExpired,knownNotFound,knownAbandoned}
public protocol AccountLifecycleRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func pendingAuthAttemptsV4() async throws->[AuthAttemptV4]
    func resolveAuthAttemptV4(requestID:String,resolution:AuthResolutionV4) async throws
    func authAttemptV4(requestID:String) async throws->AuthAttemptV4?
    func saveAuthAttemptV4(_ attempt:AuthAttemptV4) async throws
    func acceptAuthenticationV4(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1) async throws
}

public enum LifecycleIssueV4:String,Codable,Sendable {case unavailable,reauthenticationRequired,accountChanged,waitingPeriod,blocked,unknown}
public enum ClientDeletionChoiceV4:String,Codable,Sendable {case keep,delete}
public enum ClientDeletionProgressV4:String,Codable,Sendable {case pending,running,failed,completed,retained}
public struct DeletionSagaV4:Codable,Sendable,Equatable {
    public let intent:ControlIntentV1
    public let accountID:String
    public let activationEpoch:Int64
    public let recoveryCapability:String
    public let cloudChoice,localChoice,healthChoice:ClientDeletionChoiceV4
    public let healthConfirmed:Bool
    public var backendDeleted:Bool
    /// localProgress is the Store component; UI aggregates it with the scoped transport component.
    public var cloudProgress,localProgress,localTransportProgress,healthProgress:ClientDeletionProgressV4
    public var lastIssue:LifecycleIssueV4?
    public var revision:Int64
    public var backendReceipt:Data?
    public var finished:Bool {backendDeleted && [cloudProgress,localProgress,localTransportProgress,healthProgress].allSatisfy {$0 == .completed || $0 == .retained}}
    public init(intent:ControlIntentV1,accountID:String,activationEpoch:Int64,recoveryCapability:String,cloudChoice:ClientDeletionChoiceV4,localChoice:ClientDeletionChoiceV4,healthChoice:ClientDeletionChoiceV4,healthConfirmed:Bool)throws {
        try AuthorityWire.identifier(accountID);_=try AuthorityWire.decodeBase64URL(recoveryCapability,count:32)
        guard activationEpoch>0,intent.operation == .deleteAccount,intent.fields.recoveryCapabilityDigest==AuthorityWire.hash(Data(recoveryCapability.utf8)),healthChoice != .delete || healthConfirmed else {throw AuthorityError.invalidWire}
        self.intent=intent;self.accountID=accountID;self.activationEpoch=activationEpoch;self.recoveryCapability=recoveryCapability;self.cloudChoice=cloudChoice;self.localChoice=localChoice;self.healthChoice=healthChoice;self.healthConfirmed=healthConfirmed
        backendDeleted=false;cloudProgress=cloudChoice == .keep ? .retained:.pending;localProgress=localChoice == .keep ? .retained:.pending;localTransportProgress=localChoice == .keep ? .retained:.pending;healthProgress=healthChoice == .keep ? .retained:.pending;revision=0
    }
}
public enum AnalyticsMetricV4:String,Codable,Sendable {case registered,activeDay,matchCompleted,matchIncomplete,watchRecorded,syncSucceeded,syncFailed,recoverySucceeded,recoveryFailed}
public struct AnalyticsEventV4:Codable,Sendable,Equatable {
    public let version=1
    public let requestID:String
    public let metric:AnalyticsMetricV4
    public let count:Int
    public let appVersion,osFamily:String
    public let osMajor:Int
    public let qualification:String
    public init(requestID:String,metric:AnalyticsMetricV4,count:Int=1,appVersion:String,osFamily:String,osMajor:Int,qualification:String)throws {
        try AuthorityWire.identifier(requestID);try AuthorityWire.identifier(appVersion)
        guard (1...100).contains(count),["iOS","watchOS"].contains(osFamily),(1...999).contains(osMajor),["free","gifted","purchased"].contains(qualification) else {throw AuthorityError.invalidWire}
        self.requestID=requestID;self.metric=metric;self.count=count;self.appVersion=appVersion;self.osFamily=osFamily;self.osMajor=osMajor;self.qualification=qualification
    }
    private enum CodingKeys:String,CodingKey {case version,requestID,metric,count,appVersion,osFamily,osMajor,qualification}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);guard try c.decode(Int.self,forKey:.version)==1 else {throw AuthorityError.invalidWire};try self.init(requestID:c.decode(String.self,forKey:.requestID),metric:c.decode(AnalyticsMetricV4.self,forKey:.metric),count:c.decode(Int.self,forKey:.count),appVersion:c.decode(String.self,forKey:.appVersion),osFamily:c.decode(String.self,forKey:.osFamily),osMajor:c.decode(Int.self,forKey:.osMajor),qualification:c.decode(String.self,forKey:.qualification))}
}
public protocol LifecycleStateRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func lifecycleControlIntentV4(requestID:String) async throws->ControlIntentV1?
    func lifecycleReceiptV4(requestID:String) async throws->Data?
    func acceptLifecycleResultV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws
    func latestMigrationV4() async throws->AuthorityMigrationV1?
    func deletionSagaV4(requestID:String) async throws->DeletionSagaV4?
    func createDeletionSagaV4(_ saga:DeletionSagaV4) async throws
    func updateDeletionSagaV4(_ saga:DeletionSagaV4,expectedRevision:Int64) async throws
    func acceptDeletionV4(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64) async throws->DeletionSagaV4
    func eraseLocalBusinessV4(requestID:String,expectedRevision:Int64) async throws->DeletionSagaV4
    func analyticsEnabledV4() async throws->Bool
    func setAnalyticsEnabledV4(_ enabled:Bool) async throws
    func enqueueAnalyticsV4(_ event:AnalyticsEventV4) async throws
    func pendingAnalyticsV4() async throws->[AnalyticsEventV4]
    func acknowledgeAnalyticsV4(requestID:String) async throws
    func accountFactRecordsV4(scope:CloudScopeV1) async throws->[CloudRecordV1]
    func saveMigrationCheckpointV4(migrationID:String,proof:VerifiedAccountCheckpointV4) async throws
    func migrationCheckpointV4(migrationID:String) async throws->VerifiedAccountCheckpointV4?
    func cloudRecordV4(scope:CloudScopeV1,recordID:String) async throws->CloudRecordV1?
}
