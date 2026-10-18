import Foundation
import MatchCore

public enum CloudImportError:Error,Sendable,Equatable { case invalidPayload, identityMismatch, cursorMismatch, staleGeneration, conflict, readOnly, proofUnavailable }
public enum CloudCanonicalV1 {
    public static func encode<T:Encodable>(_ value:T) throws->Data { try AuthorityWire.encode(value) }
    public static func digest<T:Encodable>(_ value:T,domain:String) throws->String { AuthorityWire.hash(Data(("football-record.cloud."+domain+".v1\0").utf8)+(try encode(value))) }
    static func id(_ id:String)throws {guard !id.isEmpty,id.utf8.count<=512,!id.contains("\0"),!id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw CloudImportError.invalidPayload}}
    static func date(_ date:Date)throws {let n=date.timeIntervalSince1970*1000;guard n.isFinite,n>Double(Int64.min),n<Double(Int64.max) else {throw CloudImportError.invalidPayload}}
    static func decode<T:Codable>(_ type:T.Type,_ raw:Data,limit:Int=64*1024*1024)throws->T {
        guard raw.count<=limit else {throw CloudImportError.invalidPayload}
        let value=try JSONDecoder().decode(type,from:raw);guard try encode(value)==raw else {throw CloudImportError.invalidPayload};return value
    }
}
public struct CloudScopeV1:Codable,Sendable,Equatable,Hashable {
    public let accountID,cloudSpaceID,zoneID:String
    public let activationEpoch:Int64
    public init(accountID:String,cloudSpaceID:String,zoneID:String,activationEpoch:Int64)throws {
        for id in [accountID,cloudSpaceID,zoneID] {try CloudCanonicalV1.id(id)}
        guard activationEpoch>0 else {throw CloudImportError.invalidPayload};self.accountID=accountID;self.cloudSpaceID=cloudSpaceID;self.zoneID=zoneID;self.activationEpoch=activationEpoch
    }
    private enum CodingKeys:String,CodingKey {case accountID,cloudSpaceID,zoneID,activationEpoch}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(accountID:c.decode(String.self,forKey:.accountID),cloudSpaceID:c.decode(String.self,forKey:.cloudSpaceID),zoneID:c.decode(String.self,forKey:.zoneID),activationEpoch:c.decode(Int64.self,forKey:.activationEpoch))}
    public static func ==(lhs:Self,rhs:Self)->Bool {lhs.activationEpoch==rhs.activationEpoch && lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8) && lhs.cloudSpaceID.utf8.elementsEqual(rhs.cloudSpaceID.utf8) && lhs.zoneID.utf8.elementsEqual(rhs.zoneID.utf8)}
    public func hash(into hasher:inout Hasher) {hasher.combine(Data(accountID.utf8));hasher.combine(Data(cloudSpaceID.utf8));hasher.combine(Data(zoneID.utf8));hasher.combine(activationEpoch)}
    public var stableZoneKey:String {AuthorityWire.hash(Data((accountID+"\0"+cloudSpaceID+"\0"+zoneID).utf8))}
    public var key:String {get throws {try CloudCanonicalV1.digest(self,domain:"scope")}}
}
/// Full-facts cloud digest is deliberately distinct from legacy completion timelineVersion.
public struct CloudFactSetV1:Codable,Sendable,Equatable {
    public let startIntent:StartIntent
    public let starter:Bool
    public let events:[MatchEvent]
    public let captureRevisions:[CaptureRevision]
    public var matchID:String {startIntent.matchID}
    public var factDigest:String {get throws {try CloudCanonicalV1.digest(self,domain:"facts")}}
    public var captureDigest:String {get throws {try CaptureRevision.digest(captureRevisions)}}
    public init(startIntent:StartIntent,starter:Bool,events:[MatchEvent],captureRevisions:[CaptureRevision])throws {
        for id in [startIntent.id,startIntent.matchID,startIntent.recordingDeviceID] {try CloudCanonicalV1.id(id)}
        try CloudCanonicalV1.date(startIntent.requestedAt)
        guard Set(events.map(\.eventID)).count==events.count else {throw CloudImportError.invalidPayload}
        let ids=Set(events.map(\.eventID)),captures=captureRevisions.sorted {($0.revision,$0.id)<($1.revision,$1.id)}
        for event in events {
            for id in [event.eventID,event.sourceDeviceID] {try CloudCanonicalV1.id(id)}
            for date in [event.occurredAt,event.createdAt,event.updatedAt] {try CloudCanonicalV1.date(date)}
            guard event.matchID==startIntent.matchID,event.sequence>=0,event.matchElapsed.map({$0.isFinite && $0>=0}) != false,event.correctionOfEventID.map(ids.contains) != false else {throw CloudImportError.invalidPayload}
        }
        guard Set(captures.map(\.id)).count==captures.count else {throw CloudImportError.invalidPayload}
        for (i,revision) in captures.enumerated() {guard revision.binding.matchID==startIntent.matchID,revision.binding.recordingDeviceID==startIntent.recordingDeviceID,revision.revision==Int64(i)+1,revision.parentID==(i==0 ? nil:captures[i-1].id) else {throw CloudImportError.invalidPayload}}
        // Validation-only scratch value, never persisted or returned as a permit.
        let scratch=MatchDescriptor(startIntent:startIntent,starter:starter,startPermit:DevelopmentStartFixture.permit(for:startIntent))
        let horizon=([startIntent.requestedAt]+events.flatMap {[$0.occurredAt,$0.updatedAt]}).max() ?? startIntent.requestedAt
        let invalid:Set<DiagnosticCode>=[.invalidEvent,.invalidRevision,.unauthorizedWriter,.conflictingEventID,.duplicateSequence,.duplicateTermination]
        guard !MatchReplay.replay(descriptor:scratch,events:events,now:horizon).diagnostics.contains(where:{invalid.contains($0.code)}) else {throw CloudImportError.invalidPayload}
        self.startIntent=startIntent;self.starter=starter;self.events=events.sorted {$0.eventID<$1.eventID};self.captureRevisions=captures
    }
    private enum CodingKeys:String,CodingKey {case startIntent,starter,events,captureRevisions}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(startIntent:c.decode(StartIntent.self,forKey:.startIntent),starter:c.decode(Bool.self,forKey:.starter),events:c.decode([MatchEvent].self,forKey:.events),captureRevisions:c.decode([CaptureRevision].self,forKey:.captureRevisions))}
}
public struct CloudCheckpointV1:Codable,Sendable,Equatable {
    public static let accountAnchorPrefix="account-checkpoint:"
    public let matchID,checkpointID:String;public let recordIDs:[String]
    public init(matchID:String,checkpointID:String,recordIDs:[String])throws {
        for id in [matchID,checkpointID]+recordIDs {try CloudCanonicalV1.id(id)}
        let account=matchID.hasPrefix(Self.accountAnchorPrefix)
        if account {let key=matchID.dropFirst(Self.accountAnchorPrefix.count);guard key.utf8.count==64,key.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),let uuid=UUID(uuidString:checkpointID),checkpointID==uuid.uuidString.lowercased() else {throw CloudImportError.invalidPayload}}
        guard (account || !recordIDs.isEmpty),Set(recordIDs).count==recordIDs.count else {throw CloudImportError.invalidPayload}
        self.matchID=matchID;self.checkpointID=checkpointID;self.recordIDs=recordIDs.sorted()
    }
    func validate(scope:CloudScopeV1)throws {if matchID.hasPrefix(Self.accountAnchorPrefix),matchID != Self.accountAnchorPrefix+scope.stableZoneKey {throw CloudImportError.identityMismatch}}
    private enum CodingKeys:String,CodingKey {case matchID,checkpointID,recordIDs}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(matchID:c.decode(String.self,forKey:.matchID),checkpointID:c.decode(String.self,forKey:.checkpointID),recordIDs:c.decode([String].self,forKey:.recordIDs))}
}
public struct CloudDeletionV1:Codable,Sendable,Equatable {
    public let matchID,deletionID:String;public let deletedAt:Date
    public init(matchID:String,deletionID:String,deletedAt:Date)throws {try CloudCanonicalV1.id(matchID);try CloudCanonicalV1.id(deletionID);try CloudCanonicalV1.date(deletedAt);self.matchID=matchID;self.deletionID=deletionID;self.deletedAt=deletedAt}
    private enum CodingKeys:String,CodingKey {case matchID,deletionID,deletedAt}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(matchID:c.decode(String.self,forKey:.matchID),deletionID:c.decode(String.self,forKey:.deletionID),deletedAt:c.decode(Date.self,forKey:.deletedAt))}
}
public enum CloudPayloadV1:Codable,Sendable,Equatable {
    case matchFacts(CloudFactSetV1),checkpoint(CloudCheckpointV1),deletion(CloudDeletionV1)
    public var matchID:String {switch self {case .matchFacts(let f):f.matchID;case .checkpoint(let c):c.matchID;case .deletion(let d):d.matchID}}
    public var recordType:String {switch self {case .matchFacts:"MatchFactsV1";case .checkpoint:"CheckpointV1";case .deletion:"DeletionV1"}}
}
public struct CloudRecordV1:Codable,Sendable,Equatable {
    public let scope:CloudScopeV1
    public let recordID,digest:String
    public let canonicalBytes:Data
    public var payload:CloudPayloadV1 {get throws {try CloudCanonicalV1.decode(CloudPayloadV1.self,canonicalBytes,limit:8*1024*1024)}}
    public init(scope:CloudScopeV1,canonicalBytes:Data)throws {
        let payload=try CloudCanonicalV1.decode(CloudPayloadV1.self,canonicalBytes,limit:8*1024*1024)
        if case .checkpoint(let checkpoint)=payload {try checkpoint.validate(scope:scope)}
        self.scope=scope;self.canonicalBytes=canonicalBytes;digest=AuthorityWire.hash(canonicalBytes)
        recordID=try CloudCanonicalV1.digest([scope.stableZoneKey,payload.recordType,payload.matchID,digest],domain:"record-id")
    }
    public init(scope:CloudScopeV1,payload:CloudPayloadV1)throws {try self.init(scope:scope,canonicalBytes:CloudCanonicalV1.encode(payload))}
    private enum CodingKeys:String,CodingKey {case scope,recordID,digest,canonicalBytes}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(scope:c.decode(CloudScopeV1.self,forKey:.scope),canonicalBytes:c.decode(Data.self,forKey:.canonicalBytes));guard recordID == (try c.decode(String.self,forKey:.recordID)),digest == (try c.decode(String.self,forKey:.digest)) else {throw CloudImportError.invalidPayload}}
}
public struct CloudCursorV4:Codable,Sendable,Equatable {
    public let appliedToken:Data?
    public let fetchGeneration:Int64
    public init(appliedToken:Data?,fetchGeneration:Int64)throws {guard fetchGeneration>=0,appliedToken.map({$0.count<=1024*1024}) != false else {throw CloudImportError.invalidPayload};self.appliedToken=appliedToken;self.fetchGeneration=fetchGeneration}
    private enum CodingKeys:String,CodingKey {case appliedToken,fetchGeneration}
    public init(from decoder:any Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(appliedToken:c.decodeIfPresent(Data.self,forKey:.appliedToken),fetchGeneration:c.decode(Int64.self,forKey:.fetchGeneration))}
}
public struct ValidatedCloudBatchV1:Sendable {
    struct Wire:Codable {let scope:CloudScopeV1;let batchID:String;let records:[CloudRecordV1];let expectedAppliedToken,nextToken:Data?;let fetchGeneration:Int64;let moreComing:Bool}
    let wire:Wire
    public let raw:Data
    public var scope:CloudScopeV1 {wire.scope}
    public var batchID:String {wire.batchID}
    public var records:[CloudRecordV1] {wire.records}
    public var expectedAppliedToken:Data? {wire.expectedAppliedToken}
    public var nextToken:Data? {wire.nextToken}
    public var fetchGeneration:Int64 {wire.fetchGeneration}
    public var digest:String {AuthorityWire.hash(Data("football-record.cloud.batch.v1\0".utf8)+raw)}
    public init(canonicalBytes:Data)throws {
        wire=try CloudCanonicalV1.decode(Wire.self,canonicalBytes);raw=canonicalBytes
        _=try CloudCursorV4(appliedToken:wire.expectedAppliedToken,fetchGeneration:wire.fetchGeneration);_=try CloudCursorV4(appliedToken:wire.nextToken,fetchGeneration:wire.fetchGeneration)
        try CloudCanonicalV1.id(wire.batchID)
        guard wire.records.count<=64,Set(wire.records.map(\.recordID)).count==wire.records.count,wire.records.allSatisfy({$0.scope.stableZoneKey==wire.scope.stableZoneKey}) else {throw CloudImportError.invalidPayload}
    }
}
public struct CloudImportReceiptV4:Codable,Sendable,Equatable {public let scope:CloudScopeV1;public let batchID,batchDigest:String;public let appliedToken:Data?;public let fetchGeneration:Int64}
public struct CloudHistorySnapshotV4:Codable,Sendable,Equatable {public let scope:CloudScopeV1;public let recordID:String;public let facts:CloudFactSetV1;public let originalAcquire:Data}
public struct VerifiedCloudHistoryGrantV1:Sendable {
    public let scope:CloudScopeV1
    public let intent:ControlIntentV1
    public let originalAcquire:VerifiedAuthorityReceiptV1
    private init(scope:CloudScopeV1,intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1){self.scope=scope;self.intent=intent;originalAcquire=receipt}
    public static func verify(scope:CloudScopeV1,intent:ControlIntentV1,raw:Data,trust:AuthorityTrustConfiguration)throws->Self {
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:scope.accountID,epoch:scope.activationEpoch),trust:trust)
        guard intent.operation == .acquire,receipt.body.result == .held,receipt.body.matchID==intent.fields.matchID,receipt.body.recordingDeviceID==intent.fields.recordingDeviceID else {throw AuthorityError.intentMismatch}
        return Self(scope:scope,intent:intent,receipt:receipt)
    }
}
public enum CloudSaveProofPolicy:Sendable,Equatable {case unavailable,development(databaseNamespace:String),productionSDK}
public struct CloudSavedAssetV1:Codable,Sendable,Equatable {
    public let partID:String
    public let index,byteCount:Int
    public let digest,changeTag:String
    public let bytes:Data
    public let conditional:Bool
    public init(partID:String,index:Int,byteCount:Int,digest:String,changeTag:String,bytes:Data,conditional:Bool){self.partID=partID;self.index=index;self.byteCount=byteCount;self.digest=digest;self.changeTag=changeTag;self.bytes=bytes;self.conditional=conditional}
}
public struct CloudSaveInputV1:Codable,Sendable,Equatable {
    public let record:CloudRecordV1
    public let checkpointID,confirmationID,factDigest,captureDigest,terminalEventID:String
    public let manifestBytes:Data
    public let manifestChangeTag,recordChangeTag:String
    public let conditional:Bool
    public let parts:[CloudSavedAssetV1]
    public init(record:CloudRecordV1,checkpointID:String,confirmationID:String,factDigest:String,captureDigest:String,terminalEventID:String,manifestBytes:Data,manifestChangeTag:String,recordChangeTag:String,conditional:Bool,parts:[CloudSavedAssetV1]) {self.record=record;self.checkpointID=checkpointID;self.confirmationID=confirmationID;self.factDigest=factDigest;self.captureDigest=captureDigest;self.terminalEventID=terminalEventID;self.manifestBytes=manifestBytes;self.manifestChangeTag=manifestChangeTag;self.recordChangeTag=recordChangeTag;self.conditional=conditional;self.parts=parts}
}
struct CloudAssetReferenceV1:Codable,Sendable,Equatable {let partID:String;let index,byteCount:Int;let digest:String}
struct CloudSaveManifestV1:Codable,Sendable,Equatable {
    let version:Int
    let scope:CloudScopeV1
    let recordID,recordDigest,recordType,matchID,factDigest,captureDigest,checkpointID:String
    let terminalEventID:String?
    let byteCount:Int
    let parts:[CloudAssetReferenceV1]
}
public struct VerifiedCloudSaveV1:Sendable {
    public let input:CloudSaveInputV1
    public let policy:CloudSaveProofPolicy
    private init(input:CloudSaveInputV1,policy:CloudSaveProofPolicy){self.input=input;self.policy=policy}
    /// This checked boundary consumes trusted driver readback; production callers must be SDK adapters.
    /// The Store independently enforces its configured policy; Bootstrap defaults to unavailable.
    public static func verifyReadback(_ input:CloudSaveInputV1,policy:CloudSaveProofPolicy)throws->Self {
        guard policy != .unavailable,input.conditional,!input.confirmationID.isEmpty,!input.manifestChangeTag.isEmpty,!input.recordChangeTag.isEmpty,!input.manifestBytes.isEmpty,
              input.parts.count>0,input.parts.count<=64,Set(input.parts.map(\.partID)).count==input.parts.count,
              case .matchFacts(let facts)=try input.record.payload,try facts.factDigest==input.factDigest,try facts.captureDigest==input.captureDigest,
              facts.events.contains(where:{$0.eventID==input.terminalEventID && $0.type == .matchEnded}) else {throw CloudImportError.invalidPayload}
        let manifest=try CloudCanonicalV1.decode(CloudSaveManifestV1.self,input.manifestBytes,limit:1024*1024)
        let checkpoint=AuthorityWire.hash(Data((input.record.scope.stableZoneKey+"\0"+input.record.recordID+"\0checkpoint.v1").utf8))
        guard manifest.version==1,manifest.scope==input.record.scope,manifest.recordID==input.record.recordID,manifest.recordDigest==input.record.digest,
              manifest.recordType=="MatchFactsV1",manifest.matchID==facts.matchID,manifest.factDigest==input.factDigest,manifest.captureDigest==input.captureDigest,
              manifest.checkpointID==checkpoint,input.checkpointID==checkpoint,manifest.terminalEventID==input.terminalEventID,manifest.byteCount==input.record.canonicalBytes.count,
              manifest.parts==input.parts.map({CloudAssetReferenceV1(partID:$0.partID,index:$0.index,byteCount:$0.byteCount,digest:$0.digest)}) else {throw CloudImportError.invalidPayload}
        var bytes=Data()
        for (i,part) in input.parts.enumerated(){guard part.index==i,part.conditional,!part.partID.isEmpty,part.partID.utf8.count<=512,!part.changeTag.isEmpty,part.byteCount==part.bytes.count,part.byteCount>0,part.bytes.count<=input.record.canonicalBytes.count,bytes.count<=input.record.canonicalBytes.count-part.bytes.count,AuthorityWire.hash(part.bytes)==part.digest else {throw CloudImportError.invalidPayload};bytes.append(part.bytes)}
        guard bytes==input.record.canonicalBytes else {throw CloudImportError.invalidPayload}
        return Self(input:input,policy:policy)
    }
}
public struct CloudCheckpointReceiptV4:Codable,Sendable,Equatable {public let checkpointID,confirmationID,matchID,factDigest,captureDigest:String}
public protocol CloudImportRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func cloudCursorV4(scope:CloudScopeV1) async throws->CloudCursorV4
    func resetCloudCursorV4(scope:CloudScopeV1,expectedGeneration:Int64) async throws->CloudCursorV4
    func commitCloudBatchV4(_ batch:ValidatedCloudBatchV1) async throws->CloudImportReceiptV4
    func authorizeCloudHistoryV4(_ grant:VerifiedCloudHistoryGrantV1) async throws
    func cloudHistoryV4(scope:CloudScopeV1) async throws->[CloudHistorySnapshotV4]
    func cloudDeletionsV4(scope:CloudScopeV1) async throws->[CloudDeletionV1]
    func saveCloudCheckpointV4(_ proof:VerifiedCloudSaveV1) async throws->CloudCheckpointReceiptV4
    func matchingCloudSaveV4(matchID:String) async throws->VerifiedCloudSaveV1?
    func completeNormallyV4(release:VerifiedAuthorityReceiptV1,cloud:VerifiedCloudSaveV1,expectedGeneration:Int64,now:Date) async throws
}

public struct VerifiedAccountCheckpointV4:Sendable {
    public let input:CloudSaveInputV1
    public let policy:CloudSaveProofPolicy
    private init(input:CloudSaveInputV1,policy:CloudSaveProofPolicy){self.input=input;self.policy=policy}
    public static func verifyReadback(_ input:CloudSaveInputV1,policy:CloudSaveProofPolicy)throws->Self {
        guard policy != .unavailable,input.conditional,!input.confirmationID.isEmpty,!input.manifestChangeTag.isEmpty,!input.recordChangeTag.isEmpty,
              case .checkpoint(let checkpoint)=try input.record.payload,checkpoint.matchID==CloudCheckpointV1.accountAnchorPrefix+input.record.scope.stableZoneKey,
              input.factDigest==input.record.digest,input.captureDigest == (try CaptureRevision.digest([])),input.terminalEventID.isEmpty,
              !input.parts.isEmpty,input.parts.count<=64,Set(input.parts.map(\.partID)).count==input.parts.count else {throw CloudImportError.invalidPayload}
        let manifest=try CloudCanonicalV1.decode(CloudSaveManifestV1.self,input.manifestBytes,limit:1024*1024)
        let manifestID=AuthorityWire.hash(Data((input.record.scope.stableZoneKey+"\0"+input.record.recordID+"\0checkpoint.v1").utf8))
        guard manifest.version==1,manifest.scope==input.record.scope,manifest.recordID==input.record.recordID,manifest.recordDigest==input.record.digest,manifest.recordType=="CheckpointV1",
              manifest.matchID==checkpoint.matchID,manifest.factDigest==input.factDigest,manifest.captureDigest==input.captureDigest,manifest.checkpointID==manifestID,input.checkpointID==manifestID,
              manifest.terminalEventID==nil,manifest.byteCount==input.record.canonicalBytes.count,
              manifest.parts==input.parts.map({CloudAssetReferenceV1(partID:$0.partID,index:$0.index,byteCount:$0.byteCount,digest:$0.digest)}) else {throw CloudImportError.invalidPayload}
        var bytes=Data()
        for (i,part) in input.parts.enumerated() {guard part.index==i,part.conditional,!part.partID.isEmpty,!part.changeTag.isEmpty,part.byteCount==part.bytes.count,part.byteCount>0,part.bytes.count<=input.record.canonicalBytes.count,bytes.count<=input.record.canonicalBytes.count-part.bytes.count,AuthorityWire.hash(part.bytes)==part.digest else {throw CloudImportError.invalidPayload};bytes.append(part.bytes)}
        guard bytes==input.record.canonicalBytes else {throw CloudImportError.invalidPayload}
        return Self(input:input,policy:policy)
    }
}
