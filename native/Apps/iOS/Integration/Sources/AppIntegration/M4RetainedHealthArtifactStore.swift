import Foundation
import Darwin
import SQLite3
import MatchStore

enum M4HealthArtifactError:Error,Sendable,Equatable {case invalidOwner,identityConflict,storageBlocked,leaseInUse,limitExceeded,closed}
struct M4HealthArtifactOwner:Codable,Sendable {let installationID,namespace:String;let scope:CloudScopeV1}
struct M4HealthArtifactLimits:Sendable {
  let artifactBytes,parentBytes,parents,rows,totalBytes:Int
  init(artifactBytes:Int=16*1024*1024,parentBytes:Int=32*1024*1024,parents:Int=64,rows:Int=128,totalBytes:Int=256*1024*1024) throws {
    guard artifactBytes>0,artifactBytes<=16*1024*1024,parentBytes>0,parentBytes<=32*1024*1024,parents>0,parents<=64,rows>0,rows<=128,totalBytes>0,totalBytes<=256*1024*1024 else {throw M4HealthArtifactError.limitExceeded}
    self.artifactBytes=artifactBytes;self.parentBytes=parentBytes;self.parents=parents;self.rows=rows;self.totalBytes=totalBytes
  }
}
/// Stores artifacts only. The actual parent saga and full catalog seal remain039/026 responsibilities.
actor M4RetainedHealthArtifactStore:M4HealthMappingStore {
  private let storage:M4HealthArtifactStorage
  private let fullSealProvider:@Sendable(String) async throws->M4HealthFullSeal?
  private var closed=false
  init(directory:URL,owner:M4HealthArtifactOwner,removableRoots:[URL],limits:M4HealthArtifactLimits = try! M4HealthArtifactLimits(),fullSealProvider:@escaping @Sendable(String)async throws->M4HealthFullSeal? = {_ in throw M4HealthBridgeError.mappingUnavailable}) throws {
    storage=try M4HealthArtifactStorage(directory:directory,owner:owner,removableRoots:removableRoots,limits:limits);self.fullSealProvider=fullSealProvider
  }
  func reserve(_ value:M4HealthRawReservation) throws {try storage.insert(parent:Data(value.parentID.utf8),kind:1,bytes:value.canonicalBytes())}
  func readReservation(parentID:String) throws->M4HealthRawReservation? {try storage.raw(parent:Data(parentID.utf8))}
  func putPrepared(_ value:M4HealthPreparedMapping) throws {try storage.insert(parent:Data(value.parentID.utf8),kind:2,bytes:value.canonicalBytes())}
  func readPrepared(parentID:String) throws->M4HealthPreparedMapping? {try storage.prepared(parent:Data(parentID.utf8))}
  func readFullSeal(parentID:String) async throws->M4HealthFullSeal? {
    try storage.validate();let result=try await fullSealProvider(parentID)
    guard !closed else {throw M4HealthArtifactError.closed};try storage.validate();return result
  }
  func close() throws {closed=true;storage.close()}
}
private final class M4HealthArtifactStorage {
  private var db:OpaquePointer?,ownerFD:Int32 = -1
  private let directory:URL,owner:M4HealthArtifactOwner,ownerBytes:Data,limits:M4HealthArtifactLimits
  private let ownerURL:URL
  private struct Row {let parent:Data;let kind:Int;let bytes:Data}
  init(directory:URL,owner:M4HealthArtifactOwner,removableRoots:[URL],limits:M4HealthArtifactLimits)throws {
    self.directory=directory;self.owner=owner;self.limits=limits;ownerURL=directory.appendingPathComponent("health.owner")
    guard UUID(uuidString:owner.installationID)?.uuidString==owner.installationID,!owner.namespace.isEmpty,owner.namespace.utf8.count<=4096,!owner.namespace.utf8.contains(0) else {throw M4HealthArtifactError.invalidOwner}
    ownerBytes=try M4HealthBytes.encode(owner);guard ownerBytes.count<=65536 else {throw M4HealthArtifactError.limitExceeded}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    if !FileManager.default.fileExists(atPath:ownerURL.path) {try ownerBytes.write(to:ownerURL,options:.withoutOverwriting)}
    ownerFD=Darwin.open(ownerURL.path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
    guard ownerFD>=0 else {throw M4HealthArtifactError.storageBlocked}
    do {
      guard flock(ownerFD,LOCK_EX|LOCK_NB)==0 else {throw M4HealthArtifactError.leaseInUse}
      try validate()
      guard sqlite3_open_v2(directory.appendingPathComponent("health.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}
      try execute("PRAGMA journal_mode=WAL");try execute("PRAGMA synchronous=FULL")
      try execute("CREATE TABLE IF NOT EXISTS health_artifacts(parent BLOB NOT NULL,kind INTEGER NOT NULL,canonical BLOB NOT NULL,digest BLOB NOT NULL,PRIMARY KEY(parent,kind)) WITHOUT ROWID")
    }catch {close();throw error}
  }
  func validate()throws {
    guard ownerFD>=0 else {throw M4HealthArtifactError.closed}
    guard try Data(contentsOf:ownerURL)==ownerBytes else {throw M4HealthArtifactError.invalidOwner}
  }
  func close(){if let db {sqlite3_close(db);self.db=nil};if ownerFD>=0 {flock(ownerFD,LOCK_UN);Darwin.close(ownerFD);ownerFD = -1}}
  deinit {close()}
  private func execute(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}}
  private func all()throws->[Row] {
    try validate();var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT parent,kind,canonical,digest FROM health_artifacts ORDER BY parent,kind",-1,&s,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(s)}
    var rows:[Row]=[]
    while true {
      let status=sqlite3_step(s);if status==SQLITE_DONE{break};guard status==SQLITE_ROW,rows.count<128 else {throw M4HealthArtifactError.storageBlocked}
      func blob(_ i:Int32)throws->Data {guard sqlite3_column_type(s,i)==SQLITE_BLOB else {throw M4HealthArtifactError.storageBlocked};let size=Int(sqlite3_column_bytes(s,i));guard size>0,size<=16*1024*1024,let pointer=sqlite3_column_blob(s,i)else{throw M4HealthArtifactError.storageBlocked};return Data(bytes:pointer,count:size)}
      let parent=try blob(0),kind=Int(sqlite3_column_int64(s,1)),bytes=try blob(2),digest=try blob(3)
      guard sqlite3_column_type(s,1)==SQLITE_INTEGER,[1,2].contains(kind),parent.count<=4096,String(data:parent,encoding:.utf8) != nil,digest==Data(M4HealthBytes.hash(bytes).utf8) else {throw M4HealthArtifactError.storageBlocked}
      rows.append(Row(parent:parent,kind:kind,bytes:bytes))
    }
    for row in rows where row.kind==1 {
      let raw=try JSONDecoder().decode(M4HealthRawReservation.self,from:row.bytes)
      guard try raw.canonicalBytes()==row.bytes,Data(raw.parentID.utf8)==row.parent,M4HealthBytes.scope(raw.scope,owner.scope) else {throw M4HealthArtifactError.identityConflict}
    }
    for row in rows where row.kind==2 {
      let prepared=try JSONDecoder().decode(M4HealthPreparedMapping.self,from:row.bytes)
      guard let rawRow=rows.first(where:{$0.parent==row.parent && $0.kind==1}) else {throw M4HealthArtifactError.identityConflict}
      let raw=try JSONDecoder().decode(M4HealthRawReservation.self,from:rawRow.bytes),expected=try M4HealthPreparedMapping(reservation:raw,parentDigest:prepared.parentDigest)
      guard Data(prepared.parentID.utf8)==row.parent,try prepared.canonicalBytes()==row.bytes,try expected.canonicalBytes()==row.bytes else {throw M4HealthArtifactError.identityConflict}
    }
    return rows
  }
  func raw(parent:Data)throws->M4HealthRawReservation? {try all().first(where:{$0.parent==parent && $0.kind==1}).map{try JSONDecoder().decode(M4HealthRawReservation.self,from:$0.bytes)}}
  func prepared(parent:Data)throws->M4HealthPreparedMapping? {try all().first(where:{$0.parent==parent && $0.kind==2}).map{try JSONDecoder().decode(M4HealthPreparedMapping.self,from:$0.bytes)}}
  func insert(parent:Data,kind:Int,bytes:Data)throws {
    try validate();try execute("BEGIN IMMEDIATE");var committed=false;defer{if !committed{try? execute("ROLLBACK")}}
    let rows=try all()
    if let old=rows.first(where:{$0.parent==parent && $0.kind==kind}) {guard old.bytes==bytes else {throw M4HealthArtifactError.identityConflict};try execute("COMMIT");committed=true;return}
    if kind==1 {
      let raw=try JSONDecoder().decode(M4HealthRawReservation.self,from:bytes)
      guard M4HealthBytes.scope(raw.scope,owner.scope),Data(raw.parentID.utf8)==parent else {throw M4HealthArtifactError.identityConflict}
    }else {
      guard let rawRow=rows.first(where:{$0.parent==parent && $0.kind==1}) else {throw M4HealthArtifactError.identityConflict}
      let raw=try JSONDecoder().decode(M4HealthRawReservation.self,from:rawRow.bytes),value=try JSONDecoder().decode(M4HealthPreparedMapping.self,from:bytes)
      guard try M4HealthPreparedMapping(reservation:raw,parentDigest:value.parentDigest).canonicalBytes()==bytes else {throw M4HealthArtifactError.identityConflict}
    }
    guard bytes.count<=limits.artifactBytes,rows.filter({$0.parent==parent}).reduce(bytes.count,{$0+$1.bytes.count})<=limits.parentBytes,Set(rows.map(\.parent)+[parent]).count<=limits.parents,rows.count+1<=limits.rows,rows.reduce(bytes.count,{$0+$1.bytes.count})<=limits.totalBytes else {throw M4HealthArtifactError.limitExceeded}
    var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"INSERT INTO health_artifacts(parent,kind,canonical,digest) VALUES(?,?,?,?)",-1,&s,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(s)}
    let digest=Data(M4HealthBytes.hash(bytes).utf8),transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    for (i,value) in [(Int32(1),parent),(3,bytes),(4,digest)] {guard value.withUnsafeBytes({sqlite3_bind_blob(s,i,$0.baseAddress,Int32($0.count),transient)})==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}}
    guard sqlite3_bind_int(s,2,Int32(kind))==SQLITE_OK,sqlite3_step(s)==SQLITE_DONE else {throw M4HealthArtifactError.storageBlocked}
    try execute("COMMIT");committed=true
  }
}
