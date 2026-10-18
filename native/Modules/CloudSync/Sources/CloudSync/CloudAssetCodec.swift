import Foundation

struct CloudAssetPart:Sendable {let reference:CloudAssetReference;let bytes:Data}
struct CloudAssetPackage:Sendable {let manifest:CloudSaveManifest;let manifestBytes:Data;let parts:[CloudAssetPart]}
/// Preserves the original canonical payload; manifest and assets are transport envelopes only.
enum CloudAssetCodec {
    static func package(_ upload:CloudUpload,partByteLimit:Int=256*1024) throws->CloudAssetPackage {
        guard (1...256*1024).contains(partByteLimit),!upload.record.canonicalBytes.isEmpty else {throw CloudError(.invalidPayload)}
        let bytes=upload.record.canonicalBytes
        guard bytes.count<=CloudCodec.maximumBytes,(bytes.count+partByteLimit-1)/partByteLimit<=64 else {throw CloudError(.payloadTooLarge)}
        var parts:[CloudAssetPart]=[]
        for start in stride(from:0,to:bytes.count,by:partByteLimit) {
            let data=bytes.subdata(in:start..<min(start+partByteLimit,bytes.count)),index=parts.count,digest=CloudCodec.hash(data)
            let id=try CloudCodec.hash([upload.record.recordID,String(index),digest],domain:"asset-part")
            parts.append(CloudAssetPart(reference:try CloudAssetReference(partID:id,index:index,byteCount:data.count,digest:digest),bytes:data))
        }
        let manifest=try CloudSaveManifest(upload:upload,parts:parts.map(\.reference))
        return CloudAssetPackage(manifest:manifest,manifestBytes:try CloudCodec.encode(manifest),parts:parts)
    }
    static func record(scope:CloudScope,manifestBytes:Data,parts:[Data]) throws->CloudRecord {
        let manifest=try CloudCodec.decode(CloudSaveManifest.self,manifestBytes,limit:1024*1024)
        guard manifest.scope.stableZoneKey==scope.stableZoneKey,manifest.version==1,manifest.byteCount>0,manifest.byteCount<=CloudCodec.maximumBytes,
              !manifest.parts.isEmpty,manifest.parts.count<=64,parts.count==manifest.parts.count else {throw CloudError(.invalidPayload)}
        var original=Data()
        for (i,bytes) in parts.enumerated() {
            let ref=manifest.parts[i]
            _=try CloudAssetReference(partID:ref.partID,index:ref.index,byteCount:ref.byteCount,digest:ref.digest)
            guard ref.index==i,bytes.count==ref.byteCount,CloudCodec.hash(bytes)==ref.digest,original.count<=CloudCodec.maximumBytes-bytes.count else {throw CloudError(.invalidPayload)}
            original.append(bytes)
        }
        let record=try CloudRecord(scope:manifest.scope,canonicalBytes:original),upload=try CloudUpload(scope:manifest.scope,record:record)
        guard original.count==manifest.byteCount,record.recordID==manifest.recordID,record.digest==manifest.recordDigest,
              try CloudCodec.encode(CloudSaveManifest(upload:upload,parts:manifest.parts))==manifestBytes else {throw CloudError(.invalidPayload)}
        return record
    }
    static func validate(_ readback:CloudSaveReadback,upload:CloudUpload) throws {
        guard readback.scope==upload.scope,readback.recordID==upload.record.recordID,readback.manifestRecordID==upload.checkpointID,
              readback.manifestCondition == .ifServerRecordUnchanged,readback.recordCondition == .ifServerRecordUnchanged else {throw CloudError(.invalidPayload)}
        for tag in [readback.manifestChangeTag,readback.recordChangeTag,readback.confirmationID] {try CloudCodec.id(tag)}
        let manifest=try CloudCodec.decode(CloudSaveManifest.self,readback.manifestBytes,limit:1024*1024)
        guard manifest.scope==upload.scope,manifest.parts.count==readback.parts.count else {throw CloudError(.invalidPayload)}
        for (index,part) in readback.parts.enumerated() {
            try CloudCodec.id(part.changeTag)
            guard part.reference==manifest.parts[index],part.condition == .ifServerRecordUnchanged else {throw CloudError(.invalidPayload)}
        }
        guard try record(scope:upload.scope,manifestBytes:readback.manifestBytes,parts:readback.parts.map(\.readBackBytes))==upload.record else {throw CloudError(.invalidPayload)}
    }
}
