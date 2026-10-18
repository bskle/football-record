import CryptoKit
import Foundation
#if canImport(CloudKit)
@preconcurrency import CloudKit
#endif

public enum CloudKitEnvironment:String,Sendable,Codable {case development,production}
public struct CloudKitDriverConfiguration:Sendable {
    public let containerIdentifier:String
    public let environment:CloudKitEnvironment
    public init(containerIdentifier:String,environment:CloudKitEnvironment) throws {
        guard !containerIdentifier.isEmpty,containerIdentifier.utf8.count<=255,!containerIdentifier.utf8.contains(0) else {throw CloudError(.invalidPayload)}
        self.containerIdentifier=containerIdentifier;self.environment=environment
    }
    static func identityHash(_ domain:String,_ fields:[String])->String {
        CloudCodec.hash(Data(("football-record.cloud-identity."+domain+"\0"+fields.joined(separator:"\0")).utf8))
    }
    public func zoneID(accountID:String,cloudSpaceID:String) throws->String {
        try CloudCodec.id(accountID);try CloudCodec.id(cloudSpaceID)
        return "football-record-"+Self.identityHash("zone.v1",[accountID,cloudSpaceID])
    }
    func cloudSpaceID(userRecordName:String) throws->String {
        guard !userRecordName.isEmpty,userRecordName.utf8.count<=1024,!userRecordName.utf8.contains(0) else {throw CloudError(.invalidPayload)}
        return "ck-"+Self.identityHash("space.v1",[containerIdentifier,environment.rawValue,userRecordName])
    }
}
struct CloudKitIOContext:Sendable {let operation:CloudStagingOperation;let staging:CloudOwnedStaging}
protocol CloudKitTransport:Sendable {
    func currentCloudSpaceID() async throws->String
    func fetch(scope:CloudScope,cursor:CloudCursor,context:CloudKitIOContext) async throws->CloudFetchBatch
    func save(_ upload:CloudUpload,package:CloudAssetPackage,context:CloudKitIOContext) async throws->CloudSaveResult
    func deleteZone(scope:CloudScope) async throws
    func cancel(_ id:UUID)
}
enum CloudChangeTokenEnvelope {
    private struct Envelope:Codable {let version:Int;let containerIdentifier,environment,stableZoneKey:String;let archive:Data}
    static func wrap(_ raw:Data,scope:CloudScope,configuration:CloudKitDriverConfiguration) throws->Data {
        guard !raw.isEmpty,raw.count<=512*1024 else {throw CloudError(.invalidPayload)}
        let bytes=try CloudCodec.encode(Envelope(version:1,containerIdentifier:configuration.containerIdentifier,environment:configuration.environment.rawValue,stableZoneKey:scope.stableZoneKey,archive:raw))
        guard bytes.count<=1024*1024 else {throw CloudError(.payloadTooLarge)};return bytes
    }
    static func unwrap(_ bytes:Data,scope:CloudScope,configuration:CloudKitDriverConfiguration) throws->Data {
        let e=try CloudCodec.decode(Envelope.self,bytes,limit:1024*1024)
        guard e.version==1,e.containerIdentifier.utf8.elementsEqual(configuration.containerIdentifier.utf8),e.environment==configuration.environment.rawValue,e.stableZoneKey==scope.stableZoneKey,!e.archive.isEmpty,e.archive.count<=512*1024 else {throw CloudError(.invalidPayload)};return e.archive
    }
}
// Pure values copied from the actual fetched manifest record, never expected upload fields.
struct CloudManifestReadbackMetadata:Sendable {
    let actualRecordID,changeTag,ownerRecordID:String
    let scope:CloudScope
    let bytes:Data
}
enum CloudManifestBinding {
    static func manifest(_ metadata:CloudManifestReadbackMetadata,referencedID:String,recordID:String,recordDigest:String,scope:CloudScope) throws->CloudSaveManifest {
        let decoded=try CloudAssetCodec.boundedManifest(metadata.bytes,scope:scope)
        guard metadata.actualRecordID.utf8.elementsEqual(referencedID.utf8),
              metadata.actualRecordID.utf8.elementsEqual(decoded.checkpointID.utf8),
              metadata.scope==scope,metadata.ownerRecordID.utf8.elementsEqual(recordID.utf8),
              decoded.recordID.utf8.elementsEqual(recordID.utf8),decoded.recordDigest==recordDigest,decoded.scope==scope else {throw CloudError(.invalidPayload)}
        return decoded
    }
    static func readback(upload:CloudUpload,record:CloudRecord,manifest:CloudManifestReadbackMetadata,parts:[CloudSavedPart],recordChangeTag:String) throws->CloudSaveReadback {
        guard record==upload.record,manifest.actualRecordID.utf8.elementsEqual(upload.checkpointID.utf8) else {throw CloudError(.conflict)}
        _=try self.manifest(manifest,referencedID:manifest.actualRecordID,recordID:record.recordID,recordDigest:record.digest,scope:record.scope)
        return CloudSaveReadback(scope:upload.scope,recordID:record.recordID,manifestRecordID:manifest.actualRecordID,manifestBytes:manifest.bytes,manifestChangeTag:manifest.changeTag,manifestCondition:.ifServerRecordUnchanged,parts:parts,confirmationID:UUID().uuidString.lowercased(),recordChangeTag:recordChangeTag,recordCondition:.ifServerRecordUnchanged)
    }
}
private struct DisabledCloudKitTransport:CloudKitTransport {
    func currentCloudSpaceID() async throws->String {throw CloudError(.accountUnavailable)}
    func fetch(scope:CloudScope,cursor:CloudCursor,context:CloudKitIOContext) async throws->CloudFetchBatch {throw CloudError(.networkUnavailable)}
    func save(_ upload:CloudUpload,package:CloudAssetPackage,context:CloudKitIOContext) async throws->CloudSaveResult {throw CloudError(.networkUnavailable)}
    func deleteZone(scope:CloudScope) async throws {throw CloudError(.accountUnavailable)}
    func cancel(_ id:UUID) {}
}
/// Only this sealed factory selects the SDK transport. Controlled transports are internal/test-only.
public final class CloudKitDriver:CloudDriver,@unchecked Sendable {
    private let configuration:CloudKitDriverConfiguration
    private let staging:CloudOwnedStaging
    private let identityGeneration:Int64
    private let transport:any CloudKitTransport
    public convenience init(configuration:CloudKitDriverConfiguration,staging:CloudOwnedStaging,identityGeneration:Int64,executionEnabled:Bool=false) {
        #if canImport(CloudKit)
        self.init(configuration:configuration,staging:staging,identityGeneration:identityGeneration,transport:executionEnabled ? CloudKitSDKTransport(configuration:configuration) : DisabledCloudKitTransport())
        #else
        self.init(configuration:configuration,staging:staging,identityGeneration:identityGeneration,transport:DisabledCloudKitTransport())
        #endif
    }
    init(configuration:CloudKitDriverConfiguration,staging:CloudOwnedStaging,identityGeneration:Int64,transport:any CloudKitTransport) {
        self.configuration=configuration;self.staging=staging;self.identityGeneration=identityGeneration;self.transport=transport
    }
    private func identity(_ scope:CloudScope) async throws {
        try Task.checkCancellation()
        guard try configuration.zoneID(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID)==scope.zoneID,
              try await transport.currentCloudSpaceID().utf8.elementsEqual(scope.cloudSpaceID.utf8) else {throw CloudError(.accountChanged)}
    }
    public func fetch(scope:CloudScope,cursor:CloudCursor) async throws->CloudFetchBatch {
        let op=try staging.begin(scope:scope,identityGeneration:identityGeneration),context=CloudKitIOContext(operation:op,staging:staging)
        defer {staging.cancel(op);transport.cancel(op.id)}
        return try await withTaskCancellationHandler {
            try await identity(scope);try staging.check(op)
            let batch=try await transport.fetch(scope:scope,cursor:cursor,context:context)
            try staging.check(op);try await identity(scope);try staging.check(op)
            guard batch.scope==scope,batch.expectedAppliedToken==cursor.appliedToken,batch.fetchGeneration==cursor.fetchGeneration else {throw CloudError(.cursorMismatch)}
            return try CloudFetchBatch(scope:scope,batchID:batch.batchID,records:batch.records,expectedAppliedToken:cursor.appliedToken,nextToken:batch.nextToken,fetchGeneration:cursor.fetchGeneration,moreComing:batch.moreComing)
        } onCancel: {[staging,transport] in staging.cancel(op);transport.cancel(op.id)}
    }
    public func save(_ upload:CloudUpload) async throws->CloudSaveResult {
        let op=try staging.begin(scope:upload.scope,identityGeneration:identityGeneration),context=CloudKitIOContext(operation:op,staging:staging)
        defer {staging.cancel(op);transport.cancel(op.id)}
        return try await withTaskCancellationHandler {
            try await identity(upload.scope);try staging.check(op)
            let result=try await transport.save(upload,package:CloudAssetCodec.package(upload),context:context)
            try staging.check(op);try await identity(upload.scope);try staging.check(op)
            switch result {
            case .complete(let readback):try CloudAssetCodec.validate(readback,upload:upload)
            case .partial(let parts):
                guard parts.count<=64 else {throw CloudError(.invalidPayload)}
                for part in parts {try CloudCodec.id(part.changeTag);guard part.condition == .ifServerRecordUnchanged,part.readBackBytes.count==part.reference.byteCount,CloudCodec.hash(part.readBackBytes)==part.reference.digest else {throw CloudError(.invalidPayload)}}
            case .conflict(let id,let remote,let tag):
                try CloudCodec.id(tag);guard id==upload.record.recordID,remote.scope.stableZoneKey==upload.scope.stableZoneKey else {throw CloudError(.invalidPayload)}
            }
            return result
        } onCancel: {[staging,transport] in staging.cancel(op);transport.cancel(op.id)}
    }
    func deleteZone(scope:CloudScope,originalScope:CloudScope) async throws {
        guard scope==originalScope else {throw CloudError(.accountChanged)}
        try await identity(scope)
        for id in try staging.fenceZone(scope) {transport.cancel(id)}
        try await transport.deleteZone(scope:scope)
        try await identity(scope)
    }
}
///026 wraps this in AccountKit's deletion driver using the persisted saga originalScope.
public struct CloudPrivateZoneDeletion:Sendable {
    let driver:CloudKitDriver
    public let originalScope:CloudScope
    public init(driver:CloudKitDriver,originalScope:CloudScope) {self.driver=driver;self.originalScope=originalScope}
    public func deletePrivateZone(scope:CloudScope) async throws {try await driver.deleteZone(scope:scope,originalScope:originalScope)}
}
#if canImport(CloudKit)
private final class CloudSDKLatch<Value:Sendable>:@unchecked Sendable {
    private let lock=NSLock()
    private var result:Result<Value,any Error>?
    private var continuation:CheckedContinuation<Value,any Error>?
    func finish(_ value:Result<Value,any Error>) {lock.withLock {guard result==nil else {return};result=value;continuation?.resume(with:value);continuation=nil}}
    func value() async throws->Value {try await withCheckedThrowingContinuation {c in lock.withLock {if let result {c.resume(with:result)} else {continuation=c}}}}
}
private final class CloudOperationPool:@unchecked Sendable {
    private let lock=NSLock()
    private var operations:[UUID:[(operation:CKOperation,onCancel:@Sendable ()->Void)]]=[:]
    func add(_ operation:CKDatabaseOperation,context:CloudKitIOContext,database:CKDatabase,onCancel:@escaping @Sendable ()->Void) throws {
        try lock.withLock {try context.staging.check(context.operation);operations[context.operation.id,default:[]].append((operation,onCancel))}
        if !operation.isCancelled {database.add(operation)}
    }
    func remove(_ operation:CKOperation,id:UUID) {lock.withLock {operations[id]?.removeAll {$0.operation === operation};if operations[id]?.isEmpty==true {operations[id]=nil}}}
    func cancel(_ id:UUID) {let active=lock.withLock {operations.removeValue(forKey:id) ?? []};for entry in active {entry.operation.cancel();entry.onCancel()}}
}
private struct CloudSDKRecord:Sendable {let record:CKRecord;let scope:CloudScope;let assetBytes:Data?}
private final class CloudSDKRecords:@unchecked Sendable {
    let lock=NSLock()
    var values:[String:CloudSDKRecord]=[:]
    var error:(any Error)?
    func fail(_ value:any Error) {lock.withLock {if error==nil {error=value}}}
    func insert(_ value:CloudSDKRecord) throws {try lock.withLock {guard values[value.record.recordID.recordName]==nil else {throw CloudError(.invalidPayload)};values[value.record.recordID.recordName]=value}}
    func result() throws->[String:CloudSDKRecord] {try lock.withLock {if let error {throw error};return values}}
}
private enum CloudSDKSchema {
    static let part="FootballAssetV1",manifest="FootballManifestV1"
    static let facts:Set<String>=["MatchFactsV1","CheckpointV1","DeletionV1"]
    static func scope(_ record:CKRecord,current:CloudScope) throws->CloudScope {
        guard record.recordID.zoneID==CKRecordZone.ID(zoneName:current.zoneID,ownerName:CKCurrentUserDefaultName),
              let data=record["scope"] as? Data,data.count<=16*1024 else {throw CloudError(.invalidPayload)}
        let scope=try CloudCodec.decode(CloudScope.self,data,limit:16*1024)
        guard scope.stableZoneKey==current.stableZoneKey else {throw CloudError(.accountChanged)};return scope
    }
    static func snapshot(_ record:CKRecord,context:CloudKitIOContext,expectedAsset:CloudAssetReference?=nil) throws->CloudSDKRecord {
        try context.staging.check(context.operation)
        let scope=try scope(record,current:context.operation.scope),keys=Set(record.allKeys())
        if facts.contains(record.recordType) {
            guard keys==["scope","manifestID","digest"],let manifest=record["manifestID"] as? String,let digest=record["digest"] as? String,CloudAssetReference.validDigest(manifest),CloudAssetReference.validDigest(digest),CloudAssetReference.validDigest(record.recordID.recordName) else {throw CloudError(.invalidPayload)}
            return CloudSDKRecord(record:record,scope:scope,assetBytes:nil)
        }
        guard let owner=record["owner"] as? String,CloudAssetReference.validDigest(owner),let asset=record["bytes"] as? CKAsset,let url=asset.fileURL else {throw CloudError(.partialSave)}
        let reference:CloudAssetReference
        if record.recordType==part {
            guard keys==["scope","owner","reference","bytes"],let data=record["reference"] as? Data,data.count<=8192 else {throw CloudError(.invalidPayload)}
            reference=try CloudCodec.decode(CloudAssetReference.self,data,limit:8192)
            guard reference.partID.utf8.elementsEqual(record.recordID.recordName.utf8) else {throw CloudError(.invalidPayload)}
            if let expectedAsset {guard try CloudCodec.encode(reference)==CloudCodec.encode(expectedAsset) else {throw CloudError(.invalidPayload)}}
        } else if record.recordType==manifest {
            guard keys==["scope","owner","count","digest","bytes"],let count=record["count"] as? NSNumber,let digest=record["digest"] as? String,
                  count.doubleValue.isFinite,count.doubleValue==Double(count.int64Value),(1...1024*1024).contains(count.intValue) else {throw CloudError(.invalidPayload)}
            reference=try CloudAssetReference(partID:record.recordID.recordName,index:0,byteCount:count.intValue,digest:digest)
        } else {throw CloudError(.unsupportedSchema)}
        // This entire copy/hash happens in the per-record SDK callback, before it returns.
        let owned=try context.staging.copyAsset(from:url,recordID:owner,reference:reference,operation:context.operation)
        let bytes=try Data(contentsOf:owned)
        record["bytes"]=nil // Never retain a system staging URL for an async read.
        return CloudSDKRecord(record:record,scope:scope,assetBytes:bytes)
    }
}
private final class CloudKitSDKTransport:CloudKitTransport,@unchecked Sendable {
    let configuration:CloudKitDriverConfiguration
    private let pool=CloudOperationPool()
    init(configuration:CloudKitDriverConfiguration) {self.configuration=configuration}
    private var database:CKDatabase {CKContainer(identifier:configuration.containerIdentifier).privateCloudDatabase}
    static func mapped(_ error:any Error)->CloudError {
        if let error=error as? CloudError {return error}
        guard let error=error as? CKError else {return CloudError(.unknown)}
        switch error.code {
        case .notAuthenticated,.accountTemporarilyUnavailable:return CloudError(.accountUnavailable)
        case .permissionFailure:return CloudError(.permissionDenied)
        case .quotaExceeded:return CloudError(.quotaExceeded)
        case .changeTokenExpired:return CloudError(.changeTokenExpired)
        case .serverRecordChanged:return CloudError(.conflict)
        case .partialFailure:return CloudError(.partialSave)
        case .networkFailure,.networkUnavailable,.serviceUnavailable,.requestRateLimited,.zoneBusy:return CloudError(.networkUnavailable)
        default:return CloudError(.unknown)
        }
    }
    func currentCloudSpaceID() async throws->String {
        let container=CKContainer(identifier:configuration.containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {throw CloudError(.accountUnavailable)}
            let id=try await container.userRecordID()
            return try configuration.cloudSpaceID(userRecordName:id.recordName)
        } catch {throw Self.mapped(error)}
    }
    private func zoneID(_ scope:CloudScope)->CKRecordZone.ID {CKRecordZone.ID(zoneName:scope.zoneID,ownerName:CKCurrentUserDefaultName)}
    private func recordID(_ name:String,_ scope:CloudScope)->CKRecord.ID {CKRecord.ID(recordName:name,zoneID:zoneID(scope))}
    private func ensureZone(_ scope:CloudScope,context:CloudKitIOContext) async throws {
        let op=CKModifyRecordZonesOperation(recordZonesToSave:[CKRecordZone(zoneID:zoneID(scope))]),latch=CloudSDKLatch<Void>()
        op.modifyRecordZonesResultBlock={[pool,weak op] result in if let op {pool.remove(op,id:context.operation.id)};latch.finish(result.mapError {Self.mapped($0)})}
        try pool.add(op,context:context,database:database,onCancel:{latch.finish(.failure(CancellationError()))});try await latch.value();try context.staging.check(context.operation)
    }
    private func fetched(_ names:[String],scope:CloudScope,context:CloudKitIOContext,allowMissing:Bool=false,expectedAssets:[String:CloudAssetReference]=[:]) async throws->[String:CloudSDKRecord] {
        guard !names.isEmpty,names.count<=66,Set(names).count==names.count else {throw CloudError(.invalidPayload)}
        let op=CKFetchRecordsOperation(recordIDs:names.map {recordID($0,scope)}),collector=CloudSDKRecords(),latch=CloudSDKLatch<[String:CloudSDKRecord]>()
        op.perRecordResultBlock={id,result in
            do {
                switch result {
                case .success(let record):try collector.insert(CloudSDKSchema.snapshot(record,context:context,expectedAsset:expectedAssets[id.recordName]))
                case .failure(let error):if allowMissing,(error as? CKError)?.code == .unknownItem {return};throw Self.mapped(error)
                }
            } catch {collector.fail(error)}
        }
        op.fetchRecordsResultBlock={[pool,weak op] result in
            if let op {pool.remove(op,id:context.operation.id)}
            do {
                // Per-record unknownItem is expected only while preparing immutable conditional saves.
                if case .failure(let error)=result,!(allowMissing && (error as? CKError)?.code == .partialFailure) {throw Self.mapped(error)}
                let values=try collector.result();if !allowMissing,values.count != names.count {throw CloudError(.partialSave)}
                latch.finish(.success(values))
            } catch {latch.finish(.failure(error))}
        }
        try pool.add(op,context:context,database:database,onCancel:{latch.finish(.failure(CancellationError()))});return try await latch.value()
    }
    private func canonical(_ top:CloudSDKRecord,scope:CloudScope,context:CloudKitIOContext) async throws->(CloudRecord,CloudSDKRecord,[CloudSDKRecord]) {
        guard let manifestID=top.record["manifestID"] as? String,let expectedDigest=top.record["digest"] as? String else {throw CloudError(.invalidPayload)}
        let manifests=try await fetched([manifestID],scope:scope,context:context)
        guard let manifest=manifests[manifestID],manifest.record.recordType==CloudSDKSchema.manifest,manifest.scope==top.scope,let owner=manifest.record["owner"] as? String,owner.utf8.elementsEqual(top.record.recordID.recordName.utf8),let bytes=manifest.assetBytes else {throw CloudError(.invalidPayload)}
        guard let manifestTag=manifest.record.recordChangeTag else {throw CloudError(.partialSave)}
        let metadata=CloudManifestReadbackMetadata(actualRecordID:manifest.record.recordID.recordName,changeTag:manifestTag,ownerRecordID:owner,scope:manifest.scope,bytes:bytes)
        let decoded=try CloudManifestBinding.manifest(metadata,referencedID:manifestID,recordID:top.record.recordID.recordName,recordDigest:expectedDigest,scope:top.scope)
        let partMap=try await fetched(decoded.parts.map(\.partID),scope:scope,context:context,expectedAssets:Dictionary(uniqueKeysWithValues:decoded.parts.map {($0.partID,$0)}))
        let parts=try decoded.parts.map {ref -> CloudSDKRecord in
            guard let part=partMap[ref.partID],part.record.recordType==CloudSDKSchema.part,part.scope==decoded.scope,part.record["owner"] as? String==decoded.recordID,
                  let raw=part.record["reference"] as? Data,raw == (try CloudCodec.encode(ref)),part.assetBytes != nil else {throw CloudError(.invalidPayload)};return part
        }
        let record=try CloudAssetCodec.record(scope:scope,manifestBytes:bytes,parts:parts.map {$0.assetBytes!})
        guard (try record.payload).recordType==top.record.recordType else {throw CloudError(.invalidPayload)}
        return (record,manifest,parts)
    }
    func fetch(scope:CloudScope,cursor:CloudCursor,context:CloudKitIOContext) async throws->CloudFetchBatch {
        try await ensureZone(scope,context:context)
        let config=CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        if let bytes=cursor.appliedToken {
            let raw=try CloudChangeTokenEnvelope.unwrap(bytes,scope:scope,configuration:configuration)
            do {guard let token=try NSKeyedUnarchiver.unarchivedObject(ofClass:CKServerChangeToken.self,from:raw) else {throw CloudError(.invalidPayload)};config.previousServerChangeToken=token} catch {throw CloudError(.invalidPayload)}
        }
        // One physical change/page bounds a logical payload to8MiB even when auxiliary records interleave.
        config.resultsLimit=1;config.desiredKeys=["scope","manifestID","digest"]
        let zone=zoneID(scope),op=CKFetchRecordZoneChangesOperation(recordZoneIDs:[zone],configurationsByRecordZoneID:[zone:config]),collector=CloudSDKRecords(),latch=CloudSDKLatch<(Data,Bool)>()
        op.fetchAllChanges=false
        let tokenLock=NSLock()
        final class Page:@unchecked Sendable {var value:(Data,Bool)?;var error:(any Error)?}
        let page=Page()
        op.recordWasChangedBlock={_,result in
            do {
                let record=try result.get()
                if [CloudSDKSchema.part,CloudSDKSchema.manifest].contains(record.recordType) {return}
                guard CloudSDKSchema.facts.contains(record.recordType) else {throw CloudError(.unsupportedSchema)}
                try collector.insert(CloudSDKSchema.snapshot(record,context:context))
            } catch {collector.fail(Self.mapped(error))}
        }
        // Physical absence is never a business tombstone; only typed DeletionV1 changes local facts.
        op.recordWithIDWasDeletedBlock={_,_ in}
        op.recordZoneFetchResultBlock={returned,result in
            do {
                guard returned==zone else {throw CloudError(.accountChanged)}
                let value=try result.get(),raw=try NSKeyedArchiver.archivedData(withRootObject:value.serverChangeToken,requiringSecureCoding:true)
                let data=try CloudChangeTokenEnvelope.wrap(raw,scope:scope,configuration:self.configuration)
                tokenLock.withLock {page.value=(data,value.moreComing)}
            } catch {tokenLock.withLock {page.error=Self.mapped(error)}}
        }
        op.fetchRecordZoneChangesResultBlock={[pool,weak op] result in
            if let op {pool.remove(op,id:context.operation.id)}
            do {
                try result.get();_=try collector.result()
                let value=try tokenLock.withLock {if let error=page.error {throw error};guard let value=page.value else {throw CloudError(.partialSave)};return value}
                latch.finish(.success(value))
            } catch {latch.finish(.failure(Self.mapped(error)))}
        }
        try pool.add(op,context:context,database:database,onCancel:{latch.finish(.failure(CancellationError()))})
        let (token,more)=try await latch.value(),changed=try collector.result()
        guard changed.count<=64 else {throw CloudError(.payloadTooLarge)}
        var records:[CloudRecord]=[],total=0
        for id in changed.keys.sorted() {
            let (record,_,_)=try await canonical(changed[id]!,scope:scope,context:context)
            total += record.canonicalBytes.count;guard total<=CloudCodec.maximumEnvelopeBytes/2 else {throw CloudError(.payloadTooLarge)};records.append(record)
        }
        let fields=[scope.stableZoneKey,String(scope.activationEpoch),String(cursor.fetchGeneration),CloudCodec.hash(cursor.appliedToken ?? Data()),CloudCodec.hash(token),String(more)]+records.map {$0.recordID+":"+$0.digest}
        return try CloudFetchBatch(scope:scope,batchID:CloudCodec.hash(fields,domain:"SDK-fetch-batch"),records:records,expectedAppliedToken:cursor.appliedToken,nextToken:token,fetchGeneration:cursor.fetchGeneration,moreComing:more)
    }
    private func readback(_ upload:CloudUpload,context:CloudKitIOContext) async throws->CloudSaveReadback {
        let facts=try await fetched([upload.record.recordID],scope:upload.scope,context:context)
        guard let top=facts[upload.record.recordID] else {throw CloudError(.partialSave)}
        let (record,manifest,parts)=try await canonical(top,scope:upload.scope,context:context)
        guard record==upload.record,let manifestTag=manifest.record.recordChangeTag,let recordTag=top.record.recordChangeTag,let owner=manifest.record["owner"] as? String,let bytes=manifest.assetBytes else {throw CloudError(.conflict)}
        let refs=try CloudCodec.decode(CloudSaveManifest.self,bytes,limit:1024*1024).parts
        let saved=try parts.enumerated().map {i,part -> CloudSavedPart in
            guard let tag=part.record.recordChangeTag,let bytes=part.assetBytes else {throw CloudError(.partialSave)}
            return CloudSavedPart(reference:refs[i],changeTag:tag,condition:.ifServerRecordUnchanged,readBackBytes:bytes)
        }
        let metadata=CloudManifestReadbackMetadata(actualRecordID:manifest.record.recordID.recordName,changeTag:manifestTag,ownerRecordID:owner,scope:manifest.scope,bytes:bytes)
        return try CloudManifestBinding.readback(upload:upload,record:record,manifest:metadata,parts:saved,recordChangeTag:recordTag)
    }
    func save(_ upload:CloudUpload,package:CloudAssetPackage,context:CloudKitIOContext) async throws->CloudSaveResult {
        try await ensureZone(upload.scope,context:context)
        let names=package.parts.map {$0.reference.partID}+[upload.checkpointID,upload.record.recordID]
        let existing=try await fetched(names,scope:upload.scope,context:context,allowMissing:true,expectedAssets:Dictionary(uniqueKeysWithValues:package.parts.map {($0.reference.partID,$0.reference)}))
        if let top=existing[upload.record.recordID] {
            if top.scope != upload.scope || (upload.expectedChangeTag != nil && upload.expectedChangeTag != top.record.recordChangeTag) || top.record["digest"] as? String != upload.record.digest {
                let (remote,_,_)=try await canonical(top,scope:upload.scope,context:context)
                guard let tag=top.record.recordChangeTag else {throw CloudError(.conflict)};return .conflict(recordID:upload.record.recordID,remote:remote,changeTag:tag)
            }
        } else if upload.expectedChangeTag != nil {throw CloudError(.conflict)}
        var records:[CKRecord]=[]
        for part in package.parts {
            if let old=existing[part.reference.partID] {guard old.scope==upload.scope,old.assetBytes==part.bytes else {throw CloudError(.conflict)}}
            let record=existing[part.reference.partID]?.record ?? CKRecord(recordType:CloudSDKSchema.part,recordID:recordID(part.reference.partID,upload.scope))
            let url=try context.staging.store(part.bytes,recordID:upload.record.recordID,reference:part.reference,operation:context.operation)
            record["scope"]=try CloudCodec.encode(upload.scope) as CKRecordValue;record["owner"]=upload.record.recordID as CKRecordValue;record["reference"]=try CloudCodec.encode(part.reference) as CKRecordValue;record["bytes"]=CKAsset(fileURL:url);records.append(record)
        }
        if let old=existing[upload.checkpointID] {guard old.scope==upload.scope,old.assetBytes==package.manifestBytes else {throw CloudError(.conflict)}}
        let manifest=existing[upload.checkpointID]?.record ?? CKRecord(recordType:CloudSDKSchema.manifest,recordID:recordID(upload.checkpointID,upload.scope)),reference=try CloudAssetReference(partID:upload.checkpointID,index:0,byteCount:package.manifestBytes.count,digest:CloudCodec.hash(package.manifestBytes))
        let manifestURL=try context.staging.store(package.manifestBytes,recordID:upload.record.recordID,reference:reference,operation:context.operation)
        manifest["scope"]=try CloudCodec.encode(upload.scope) as CKRecordValue;manifest["owner"]=upload.record.recordID as CKRecordValue;manifest["count"]=NSNumber(value:package.manifestBytes.count);manifest["digest"]=reference.digest as CKRecordValue;manifest["bytes"]=CKAsset(fileURL:manifestURL);records.append(manifest)
        let top=existing[upload.record.recordID]?.record ?? CKRecord(recordType:package.manifest.recordType,recordID:recordID(upload.record.recordID,upload.scope))
        top["scope"]=try CloudCodec.encode(upload.scope) as CKRecordValue;top["manifestID"]=upload.checkpointID as CKRecordValue;top["digest"]=upload.record.digest as CKRecordValue;records.append(top)
        let op=CKModifyRecordsOperation(recordsToSave:records),latch=CloudSDKLatch<Void>(),savedLock=NSLock()
        final class Save:@unchecked Sendable {var ids:Set<CKRecord.ID>=[];var error:(any Error)?}
        let saved=Save();op.savePolicy = .ifServerRecordUnchanged;op.isAtomic=true
        op.perRecordSaveBlock={id,result in
            do {let record=try result.get();guard let tag=record.recordChangeTag,!tag.isEmpty else {throw CloudError(.partialSave)};savedLock.withLock {_=saved.ids.insert(id)}} catch {savedLock.withLock {if saved.error==nil {saved.error=Self.mapped(error)}}}
        }
        op.modifyRecordsResultBlock={[pool,weak op] result in
            if let op {pool.remove(op,id:context.operation.id)}
            do {try savedLock.withLock {if let error=saved.error {throw error}};try result.get();try savedLock.withLock {guard saved.ids.count==records.count else {throw CloudError(.partialSave)}};latch.finish(.success(()))} catch {latch.finish(.failure(Self.mapped(error)))}
        }
        try pool.add(op,context:context,database:database,onCancel:{latch.finish(.failure(CancellationError()))})
        do {try await latch.value()} catch let error as CloudError where error.issue == .conflict {
            let current=try await fetched([upload.record.recordID],scope:upload.scope,context:context)
            guard let top=current[upload.record.recordID],let tag=top.record.recordChangeTag else {throw error}
            let (remote,_,_)=try await canonical(top,scope:upload.scope,context:context);return .conflict(recordID:upload.record.recordID,remote:remote,changeTag:tag)
        }
        let proof=try await readback(upload,context:context);try CloudAssetCodec.validate(proof,upload:upload);return .complete(proof)
    }
    func deleteZone(scope:CloudScope) async throws {
        let zone=zoneID(scope)
        do {_=try await database.deleteRecordZone(withID:zone)} catch let error as CKError where error.code == .zoneNotFound {} catch {throw Self.mapped(error)}
        // Confirm absence; a successful callback alone is not complete deletion evidence.
        do {_=try await database.recordZone(for:zone);throw CloudError(.conflict)} catch let error as CKError where error.code == .zoneNotFound {} catch {throw Self.mapped(error)}
    }
    func cancel(_ id:UUID) {pool.cancel(id)}
}
#endif
