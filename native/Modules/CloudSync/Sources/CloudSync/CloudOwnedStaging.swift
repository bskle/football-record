import CryptoKit
import Darwin
import Foundation

public struct CloudStagingEraseRequest:Sendable {
    public let requestID,requestDigest:String
    public let scope:CloudScope
    public init(requestID:String,requestDigest:String,scope:CloudScope) throws {
        try CloudCodec.id(requestID);guard CloudAssetReference.validDigest(requestDigest) else {throw CloudError(.invalidPayload)}
        self.requestID=requestID;self.requestDigest=requestDigest;self.scope=scope
    }
}
public struct CloudStagingEraseReceipt:Sendable,Equatable {public let requestID,requestDigest,stableZoneKey:String}
struct CloudStagingOperation:Sendable {let id:UUID;let scope:CloudScope;let identityGeneration:Int64}
enum CloudStagingFault:Sendable {case afterFence,beforeReceipt,afterReceiptResponseLost}
private final class StagingOwner:@unchecked Sendable {
    let lock=NSLock(),root:URL,control:URL,sql:CloudSQL
    var operations:[UUID:CloudStagingOperation]=[:]
    var closed=false
    private var descriptors:[Int32]=[]
    init(root:URL,control:URL) throws {
        self.root=root;self.control=control
        try FileManager.default.createDirectory(at:control.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:root.deletingLastPathComponent(),withIntermediateDirectories:true)
        // Lease both names: neither another control DB for the root nor another root for this DB may bypass the gate.
        for path in [control.path+".owner",root.path+".owner"].sorted() {
            let fd=Darwin.open(path,O_CREAT|O_RDWR|O_NOFOLLOW,S_IRUSR|S_IWUSR)
            guard fd>=0 else {for held in descriptors {Darwin.close(held)};throw CloudError(.storageUnavailable)}
            guard flock(fd,LOCK_EX|LOCK_NB)==0 else {Darwin.close(fd);for held in descriptors {Darwin.close(held)};throw CloudError(.storageUnavailable)}
            descriptors.append(fd)
        }
        do {sql=try CloudSQL(url:control)} catch {for held in descriptors {Darwin.close(held)};throw error}
        do {
            let version=try sql.rows("PRAGMA user_version").first?.first?.number ?? -1
            guard [0,1].contains(version) else {throw CloudError(.unsupportedSchema)}
            guard try sql.rows("PRAGMA quick_check(1)").first?.first?.string=="ok" else {throw CloudError(.storageUnavailable)}
            let tables=try sql.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").compactMap {$0.first?.string}.sorted()
            if version==0 {
                guard tables.isEmpty else {throw CloudError(.unsupportedSchema)}
                try sql.transaction {
                    try sql.execute("CREATE TABLE staging_identity(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL,scope BLOB,root_digest TEXT NOT NULL) STRICT")
                    try sql.execute("INSERT INTO staging_identity VALUES(1,0,NULL,?)",[.text(CloudCodec.hash(Data(root.path.utf8)))])
                    try sql.execute("CREATE TABLE staging_fences(stable TEXT PRIMARY KEY) STRICT")
                    try sql.execute("CREATE TABLE staging_receipts(id TEXT PRIMARY KEY,digest TEXT NOT NULL,stable TEXT NOT NULL,scope BLOB NOT NULL) STRICT")
                    try sql.execute("PRAGMA user_version=1")
                }
            } else {guard tables==["staging_fences","staging_identity","staging_receipts"] else {throw CloudError(.unsupportedSchema)}}
            try validate()
            try sql.execute("PRAGMA journal_mode=WAL");try sql.execute("PRAGMA synchronous=FULL")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        } catch {try? sql.close();for fd in descriptors {flock(fd,LOCK_UN);Darwin.close(fd)};descriptors.removeAll();throw error}
    }
    deinit {for fd in descriptors {flock(fd,LOCK_UN);Darwin.close(fd)}}
    func validate() throws {
        let rows=try sql.rows("SELECT id,generation,scope,root_digest FROM staging_identity")
        guard rows.count==1,rows[0][0].number==1,let generation=rows[0][1].number,generation>=0,generation<=9_007_199_254_740_991,rows[0][3].string==CloudCodec.hash(Data(root.path.utf8)) else {throw CloudError(.invalidPayload)}
        switch rows[0][2] {case .null:break;case .blob(let data):_=try CloudCodec.decode(CloudScope.self,data);default:throw CloudError(.invalidPayload)}
        let fences=try sql.rows("SELECT stable FROM staging_fences").map {row -> String in
            guard let stable=row[0].string,CloudAssetReference.validDigest(stable) else {throw CloudError(.invalidPayload)};return stable
        }
        for row in try sql.rows("SELECT id,digest,stable,scope FROM staging_receipts") {
            guard let id=row[0].string,let digest=row[1].string,let stable=row[2].string,let bytes=row[3].data,CloudAssetReference.validDigest(digest),fences.contains(stable),try CloudCodec.decode(CloudScope.self,bytes).stableZoneKey==stable else {throw CloudError(.invalidPayload)}
            try CloudCodec.id(id)
        }
    }
    func identity() throws->(Int64,CloudScope?) {
        guard !closed,let row=try sql.rows("SELECT generation,scope FROM staging_identity WHERE id=1").first,let generation=row[0].number else {throw CloudError(.closed)}
        return (generation,try row[1].data.map {try CloudCodec.decode(CloudScope.self,$0)})
    }
    func fenced(_ scope:CloudScope) throws->Bool {try !sql.rows("SELECT stable FROM staging_fences WHERE stable=?",[.text(scope.stableZoneKey)]).isEmpty}
    func check(_ op:CloudStagingOperation) throws {
        let current=try identity()
        guard let saved=operations[op.id],saved.scope==op.scope,saved.identityGeneration==op.identityGeneration,current.0==op.identityGeneration,current.1==op.scope,try !fenced(op.scope) else {throw CloudError(.accountChanged)}
    }
    func close() throws {
        guard !closed else {return};try sql.close();closed=true;operations.removeAll()
        for fd in descriptors {flock(fd,LOCK_UN);Darwin.close(fd)};descriptors.removeAll()
    }
}
private final class StagingOwners:@unchecked Sendable {
    static let shared=StagingOwners()
    private final class Weak {weak var value:StagingOwner?;init(_ value:StagingOwner) {self.value=value}}
    private let lock=NSLock()
    private var owners:[String:Weak]=[:]
    func owner(root:URL,control:URL) throws->StagingOwner {
        try lock.withLock {
            if let value=owners[control.path]?.value,!value.lock.withLock({value.closed}) {
                guard value.root.path.utf8.elementsEqual(root.path.utf8) else {throw CloudError(.identityConflict)};return value
            }
            let value=try StagingOwner(root:root,control:control);owners[control.path]=Weak(value);return value
        }
    }
}
/// Owns non-health asset files only. Control DB and live owner inode are retained by026 catalog.
public final class CloudOwnedStaging:@unchecked Sendable {
    private let owner:StagingOwner
    private let fault:CloudStagingFault?
    private let beforeCopy:(@Sendable ()->Void)?
    public convenience init(rootURL:URL,controlURL:URL) throws {try self.init(rootURL:rootURL,controlURL:controlURL,fault:nil,beforeCopy:nil)}
    init(rootURL:URL,controlURL:URL,fault:CloudStagingFault?=nil,beforeCopy:(@Sendable ()->Void)?=nil) throws {
        guard rootURL.isFileURL,controlURL.isFileURL else {throw CloudError(.invalidPayload)}
        let root=rootURL.standardizedFileURL.resolvingSymlinksInPath(),control=controlURL.standardizedFileURL.resolvingSymlinksInPath()
        guard control.path != root.path,!control.path.hasPrefix(root.path+"/"),!root.path.hasPrefix(control.path+"/") else {throw CloudError(.invalidPayload)}
        owner=try StagingOwners.shared.owner(root:root,control:control);self.fault=fault;self.beforeCopy=beforeCopy
    }
    public func admit(scope:CloudScope,identityGeneration:Int64) throws {
        try owner.lock.withLock {
            let current=try owner.identity()
            guard identityGeneration>=current.0,identityGeneration<=9_007_199_254_740_991,try !owner.fenced(scope),identityGeneration>current.0 || current.1==nil || current.1==scope else {throw CloudError(.accountChanged)}
            try owner.sql.transaction {try owner.sql.execute("UPDATE staging_identity SET generation=?,scope=? WHERE id=1",[.integer(identityGeneration),.blob(try CloudCodec.encode(scope))])}
            if identityGeneration>current.0 {owner.operations.removeAll()}
        }
    }
    public func advanceIdentityFence(to generation:Int64) throws {
        try owner.lock.withLock {
            let current=try owner.identity();guard generation>=current.0,generation<=9_007_199_254_740_991 else {throw CloudError(.accountChanged)}
            if generation>current.0 {try owner.sql.transaction {try owner.sql.execute("UPDATE staging_identity SET generation=?,scope=NULL WHERE id=1",[.integer(generation)])};owner.operations.removeAll()}
        }
    }
    func begin(scope:CloudScope,identityGeneration:Int64) throws->CloudStagingOperation {
        try owner.lock.withLock {
            let current=try owner.identity();guard current.0==identityGeneration,current.1==scope,try !owner.fenced(scope) else {throw CloudError(.accountChanged)}
            let op=CloudStagingOperation(id:UUID(),scope:scope,identityGeneration:identityGeneration);owner.operations[op.id]=op;return op
        }
    }
    func check(_ operation:CloudStagingOperation) throws {try owner.lock.withLock {try owner.check(operation)}}
    func cancel(_ operation:CloudStagingOperation) {owner.lock.withLock {owner.operations[operation.id]=nil}}
    private func destination(recordID:String,reference:CloudAssetReference,operation:CloudStagingOperation) throws->URL {
        try CloudCodec.id(recordID)
        _=try CloudAssetReference(partID:reference.partID,index:reference.index,byteCount:reference.byteCount,digest:reference.digest)
        let record=CloudCodec.hash(Data(recordID.utf8)),part=CloudCodec.hash(Data(reference.partID.utf8))
        let directory=owner.root.appendingPathComponent(operation.scope.stableZoneKey).appendingPathComponent(record)
        // Resolve each existing component. Resolving a nonexistent leaf alone can miss a symlink parent.
        for component in [owner.root,owner.root.appendingPathComponent(operation.scope.stableZoneKey),directory] {
            if let attributes=try? FileManager.default.attributesOfItem(atPath:component.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw CloudError(.invalidPayload)}
            } else {try FileManager.default.createDirectory(at:component,withIntermediateDirectories:false)}
        }
        return directory.appendingPathComponent(String(reference.index)+"-"+part+"-"+reference.digest+".asset")
    }
    private func install(recordID:String,reference:CloudAssetReference,operation:CloudStagingOperation,read:() throws->Data) throws->URL {
        try owner.check(operation);try CloudCodec.id(recordID)
        _=try CloudAssetReference(partID:reference.partID,index:reference.index,byteCount:reference.byteCount,digest:reference.digest)
        beforeCopy?()
        let bytes=try read()
        guard bytes.count==reference.byteCount,CloudCodec.hash(bytes)==reference.digest else {throw CloudError(.invalidPayload)}
        let destination=try destination(recordID:recordID,reference:reference,operation:operation)
        if FileManager.default.fileExists(atPath:destination.path) {
            guard destination.resolvingSymlinksInPath().path==destination.path,try Data(contentsOf:destination)==bytes else {throw CloudError(.invalidPayload)};return destination
        }
        let temp=destination.deletingLastPathComponent().appendingPathComponent(".tmp-"+UUID().uuidString)
        do {
            try bytes.write(to:temp,options:.withoutOverwriting)
            let fd=Darwin.open(temp.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw CloudError(.storageUnavailable)}
            let synced=fsync(fd);Darwin.close(fd);guard synced==0 else {throw CloudError(.storageUnavailable)}
            try FileManager.default.moveItem(at:temp,to:destination)
            try syncDirectory(destination.deletingLastPathComponent())
            return destination
        } catch {try? FileManager.default.removeItem(at:temp);throw error}
    }
    func copyAsset(from url:URL,recordID:String,reference:CloudAssetReference,operation:CloudStagingOperation) throws->URL {
        try owner.lock.withLock {
            try install(recordID:recordID,reference:reference,operation:operation) {
                guard url.isFileURL else {throw CloudError(.invalidPayload)}
                let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw CloudError(.storageUnavailable)}
                let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
                var data=Data()
                while let chunk=try handle.read(upToCount:min(65536,reference.byteCount-data.count+1)),!chunk.isEmpty {
                    guard data.count<=reference.byteCount-chunk.count else {throw CloudError(.payloadTooLarge)};data.append(chunk)
                }
                return data
            }
        }
    }
    func store(_ bytes:Data,recordID:String,reference:CloudAssetReference,operation:CloudStagingOperation) throws->URL {
        try owner.lock.withLock {try install(recordID:recordID,reference:reference,operation:operation) {bytes}}
    }
    private func syncDirectory(_ url:URL) throws {
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw CloudError(.storageUnavailable)}
        let result=fsync(fd);Darwin.close(fd);guard result==0 else {throw CloudError(.storageUnavailable)}
    }
    private func validateEraseDirectory(_ url:URL) throws {
        guard url.resolvingSymlinksInPath().path==url.path else {throw CloudError(.invalidPayload)}
        guard FileManager.default.fileExists(atPath:url.path) else {return}
        for record in try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) {
            let v=try record.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard v.isDirectory==true,v.isSymbolicLink != true,CloudAssetReference.validDigest(record.lastPathComponent) else {throw CloudError(.invalidPayload)}
            for file in try FileManager.default.contentsOfDirectory(at:record,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) {
                let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard v.isRegularFile==true,v.isSymbolicLink != true,(file.lastPathComponent.hasSuffix(".asset") || file.lastPathComponent.hasPrefix(".tmp-")) else {throw CloudError(.invalidPayload)}
            }
        }
    }
    public func erase(_ request:CloudStagingEraseRequest) throws->CloudStagingEraseReceipt {
        try owner.lock.withLock {
            _=try owner.identity();try owner.validate()
            let bytes=try CloudCodec.encode(request.scope),stable=request.scope.stableZoneKey,directory=owner.root.appendingPathComponent(stable)
            let receipt=CloudStagingEraseReceipt(requestID:request.requestID,requestDigest:request.requestDigest,stableZoneKey:stable)
            if let old=try owner.sql.rows("SELECT digest,stable,scope FROM staging_receipts WHERE id=?",[.text(request.requestID)]).first {
                guard old[0].string==request.requestDigest,old[1].string==stable,old[2].data==bytes,try owner.fenced(request.scope),!FileManager.default.fileExists(atPath:directory.path) else {throw CloudError(.identityConflict)};return receipt
            }
            try owner.sql.transaction {try owner.sql.execute("INSERT OR IGNORE INTO staging_fences VALUES(?)",[.text(stable)])}
            owner.operations=owner.operations.filter {$0.value.scope.stableZoneKey != stable}
            if fault == .afterFence {throw CloudError(.storageUnavailable)}
            try validateEraseDirectory(directory)
            if FileManager.default.fileExists(atPath:directory.path) {try FileManager.default.removeItem(at:directory);try syncDirectory(owner.root)}
            guard !FileManager.default.fileExists(atPath:directory.path) else {throw CloudError(.storageUnavailable)}
            if fault == .beforeReceipt {throw CloudError(.storageUnavailable)}
            try owner.sql.transaction {try owner.sql.execute("INSERT INTO staging_receipts VALUES(?,?,?,?)",[.text(request.requestID),.text(request.requestDigest),.text(stable),.blob(bytes)])}
            if fault == .afterReceiptResponseLost {throw CloudError(.storageUnavailable)}
            return receipt
        }
    }
    public func close() throws {try owner.lock.withLock {try owner.close()}}
}
