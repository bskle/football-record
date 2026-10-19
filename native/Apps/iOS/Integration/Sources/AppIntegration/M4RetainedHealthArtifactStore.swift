import Foundation
import Darwin
import SQLite3
import MatchStore

enum M4HealthArtifactError:Error,Sendable,Equatable {case invalidOwner,identityConflict,storageBlocked,leaseInUse,limitExceeded,closed}
enum M4HealthArtifactFault:Sendable {case beforeCommit,afterCommitLost,directorySync,parentSync}
enum M4HealthArtifactBoundary:String,Sendable {case afterDatabaseSync,afterOwnerSync,beforePublication,afterPublicationRename,afterParentSync,beforeSQLCommit,afterSQLCommit,afterDirectorySync}
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
  init(directory:URL,owner:M4HealthArtifactOwner,removableRoots:[URL],boundaryHook:@escaping @Sendable(M4HealthArtifactBoundary)->Void = {_ in},limits:M4HealthArtifactLimits = try! M4HealthArtifactLimits(),fullSealProvider:@escaping @Sendable(String)async throws->M4HealthFullSeal? = {_ in throw M4HealthBridgeError.mappingUnavailable}) throws {
    storage=try M4HealthArtifactStorage(directory:directory,owner:owner,removableRoots:removableRoots,limits:limits,boundaryHook:boundaryHook);self.fullSealProvider=fullSealProvider
  }
  func reserve(_ value:M4HealthRawReservation) throws {try storage.insert(parent:Data(value.parentID.utf8),kind:1,bytes:value.canonicalBytes())}
  func readReservation(parentID:String) throws->M4HealthRawReservation? {try storage.raw(parent:Data(parentID.utf8))}
  func putPrepared(_ value:M4HealthPreparedMapping) throws {try storage.insert(parent:Data(value.parentID.utf8),kind:2,bytes:value.canonicalBytes())}
  func readPrepared(parentID:String) throws->M4HealthPreparedMapping? {try storage.prepared(parent:Data(parentID.utf8))}
  func readFullSeal(parentID:String) async throws->M4HealthFullSeal? {
    // Only the nonblocking lifetime ownership lease survives this await; no SQL
    // transaction or file mutation critical section spans the provider.
    try storage.validate();let result=try await fullSealProvider(parentID)
    guard !closed else {throw M4HealthArtifactError.closed};try storage.validate();return result
  }
  func injectNextFault(_ fault:M4HealthArtifactFault) {storage.injectNextFault(fault)}
  func close() throws {closed=true;storage.close()}
}
private struct M4HAAnchor:Codable,Equatable {
  let path:String
  let device,inode:UInt64
  static func ==(a:Self,b:Self)->Bool {Data(a.path.utf8)==Data(b.path.utf8) && a.device==b.device && a.inode==b.inode}
}
private struct M4HAOwnerRecord:Codable {
  let version:Int
  let identity:M4HealthArtifactOwner
  let directory,owner,database:M4HAAnchor
  let ancestors:[M4HAAnchor]
}
private enum M4HAFile {
  static let ownerLimit=65536,databaseLimit=384*1024*1024
  static func canonical(_ url:URL)throws->URL {
    guard url.isFileURL,!url.path.utf8.contains(0),url.path != "/" else {throw M4HealthArtifactError.invalidOwner}
    let path=url.standardizedFileURL.path
    return URL(fileURLWithPath:(path.hasPrefix("/tmp/") || path.hasPrefix("/var/")) ? "/private"+path:path,isDirectory:true)
  }
  static func exists(_ url:URL)->Bool {var value=stat();return lstat(url.path,&value)==0}
  static func anchor(_ url:URL,directory:Bool,path:String?=nil)throws->M4HAAnchor {
    var value=stat()
    guard lstat(url.path,&value)==0,value.st_mode&S_IFMT == (directory ? S_IFDIR:S_IFREG),directory || value.st_nlink==1 else {throw M4HealthArtifactError.storageBlocked}
    return M4HAAnchor(path:path ?? url.path,device:UInt64(UInt32(bitPattern:value.st_dev)),inode:value.st_ino)
  }
  static func chain(_ url:URL)throws->[M4HAAnchor] {
    var cursor=url,result:[M4HAAnchor]=[]
    while true {if exists(cursor){result.append(try anchor(cursor,directory:true))};if cursor.path=="/"{break};cursor.deleteLastPathComponent()};return result
  }
  static func outside(_ retained:URL,_ removable:URL)throws {
    let a=Data(retained.path.utf8),b=Data(removable.path.utf8)
    guard a != b,!a.starts(with:Data((removable.path+"/").utf8)),!b.starts(with:Data((retained.path+"/").utf8)) else {throw M4HealthArtifactError.invalidOwner}
    let aa=try chain(retained),bb=try chain(removable)
    for (root,other) in [(retained,bb),(removable,aa)] where exists(root) {
      let one=try anchor(root,directory:true)
      guard !other.contains(where:{$0.device==one.device && $0.inode==one.inode}) else {throw M4HealthArtifactError.invalidOwner}
    }
  }
  static func ensure(_ url:URL)throws {
    _=try chain(url);if exists(url){_=try anchor(url,directory:true);return}
    let parent=url.deletingLastPathComponent();try ensure(parent)
    guard mkdir(url.path,0o700)==0 else {throw M4HealthArtifactError.storageBlocked};try sync(url);try sync(parent)
  }
  static func sync(_ url:URL)throws {
    let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw M4HealthArtifactError.storageBlocked};defer{Darwin.close(fd)}
    guard fsync(fd)==0 else{throw M4HealthArtifactError.storageBlocked}
  }
  static func read(_ url:URL,maximum:Int,prefix:Bool=false)throws->Data {
    let original=try anchor(url,directory:false),fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0 else{throw M4HealthArtifactError.storageBlocked};defer{Darwin.close(fd)}
    var value=stat();guard fstat(fd,&value)==0,value.st_size>=0,(prefix || value.st_size<=maximum),UInt64(UInt32(bitPattern:value.st_dev))==original.device,value.st_ino==original.inode else{throw M4HealthArtifactError.storageBlocked}
    let length=prefix ? min(Int(value.st_size),maximum):Int(value.st_size);var bytes=Data(count:length)
    let count=bytes.withUnsafeMutableBytes{Darwin.pread(fd,$0.baseAddress,$0.count,0)}
    guard count==length,try anchor(url,directory:false)==original else{throw M4HealthArtifactError.storageBlocked};return bytes
  }
  static func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
  static func write(_ bytes:Data,_ url:URL)throws {
    let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw M4HealthArtifactError.storageBlocked};defer{Darwin.close(fd)}
    guard bytes.withUnsafeBytes({Darwin.pwrite(fd,$0.baseAddress,$0.count,0)})==bytes.count,fsync(fd)==0 else{throw M4HealthArtifactError.storageBlocked}
  }
}
private final class M4HealthArtifactStorage {
  private var db:OpaquePointer?,ownerFD:Int32 = -1,directoryFD:Int32 = -1
  private let directory:URL,owner:M4HealthArtifactOwner,limits:M4HealthArtifactLimits,removableRoots:[URL]
  private let ownerURL:URL
  private var record:M4HAOwnerRecord?,ownerBytes=Data()
  private var fault:M4HealthArtifactFault?
  private let boundaryHook:@Sendable(M4HealthArtifactBoundary)->Void
  private struct Row {let parent:Data;let kind:Int;let bytes:Data}
  private static let artifactsSQL="CREATE TABLE health_artifacts(parent BLOB NOT NULL,kind INTEGER NOT NULL,canonical BLOB NOT NULL,digest BLOB NOT NULL,PRIMARY KEY(parent,kind)) WITHOUT ROWID"
  private static let ownerSQL="CREATE TABLE health_owner(id INTEGER PRIMARY KEY CHECK(id=1),canonical BLOB NOT NULL)"
  private static let applicationID=1295271985
  init(directory:URL,owner:M4HealthArtifactOwner,removableRoots:[URL],limits:M4HealthArtifactLimits,boundaryHook:@escaping @Sendable(M4HealthArtifactBoundary)->Void)throws {
    self.boundaryHook=boundaryHook
    self.directory=try M4HAFile.canonical(directory);self.owner=owner;self.limits=limits;self.removableRoots=try removableRoots.map{try M4HAFile.canonical($0)};ownerURL=self.directory.appendingPathComponent("health.owner")
    guard UUID(uuidString:owner.installationID)?.uuidString==owner.installationID,!owner.namespace.isEmpty,owner.namespace.utf8.count<=4096,!owner.namespace.utf8.contains(0),!removableRoots.isEmpty else {throw M4HealthArtifactError.invalidOwner}
    do {
      for root in self.removableRoots {try M4HAFile.outside(self.directory,root)}
      try initializeIfAbsent()
      ownerFD=Darwin.open(ownerURL.path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
      guard ownerFD>=0 else {throw M4HealthArtifactError.storageBlocked}
      guard flock(ownerFD,LOCK_EX|LOCK_NB)==0 else {throw M4HealthArtifactError.leaseInUse}
      ownerBytes=try M4HAFile.read(ownerURL,maximum:M4HAFile.ownerLimit)
      let value=try JSONDecoder().decode(M4HAOwnerRecord.self,from:ownerBytes)
      guard value.version==1,try M4HAFile.encode(value)==ownerBytes,try M4HAFile.encode(value.identity)==M4HAFile.encode(owner) else {throw M4HealthArtifactError.invalidOwner};record=value
      directoryFD=Darwin.open(self.directory.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard directoryFD>=0 else {throw M4HealthArtifactError.storageBlocked}
      try validateFiles();try stabilize()
      try header()
      // A read-only connection validates known SQLite recovery state first. SQLite
      // may coordinate its own WAL/SHM; unknown names/types are rejected beforehand.
      guard sqlite3_open_v2(self.directory.appendingPathComponent("health.sqlite").path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}
      try validateSchema();_=try all();guard sqlite3_close(db)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked};db=nil
      try validate();try header()
      guard sqlite3_open_v2(self.directory.appendingPathComponent("health.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}
      sqlite3_busy_timeout(db,1000);sqlite3_limit(db,SQLITE_LIMIT_LENGTH,17*1024*1024)
      try execute("PRAGMA journal_mode=WAL");try execute("PRAGMA synchronous=FULL");try execute("PRAGMA wal_autocheckpoint=256");try execute("PRAGMA max_page_count=98304")
      try validateSchema();_=try all()
    }catch {close();if error is M4HealthArtifactError {throw error};throw M4HealthArtifactError.storageBlocked}
  }
  private func initializeIfAbsent()throws {
    if M4HAFile.exists(directory){return}
    let parent=directory.deletingLastPathComponent();try M4HAFile.ensure(parent)
    for root in removableRoots {try M4HAFile.outside(directory,root)}
    let future=M4HAAnchor(path:directory.path,device:UInt64.max,inode:UInt64.max),ownerAnchor=M4HAAnchor(path:ownerURL.path,device:UInt64.max,inode:UInt64.max),dbAnchor=M4HAAnchor(path:directory.appendingPathComponent("health.sqlite").path,device:UInt64.max,inode:UInt64.max)
    let worst=M4HAOwnerRecord(version:1,identity:owner,directory:future,owner:ownerAnchor,database:dbAnchor,ancestors:try M4HAFile.chain(parent))
    guard try M4HAFile.encode(worst).count<=M4HAFile.ownerLimit else{throw M4HealthArtifactError.limitExceeded}
    let candidate=parent.appendingPathComponent(".health-prepare-"+UUID().uuidString)
    guard !M4HAFile.exists(candidate),mkdir(candidate.path,0o700)==0 else {throw M4HealthArtifactError.storageBlocked}
    let main=candidate.appendingPathComponent("health.sqlite");var handle:OpaquePointer?
    guard sqlite3_open_v2(main.path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {if let handle{sqlite3_close(handle)};throw M4HealthArtifactError.storageBlocked}
    do {
      func sql(_ command:String)throws{guard sqlite3_exec(handle,command,nil,nil,nil)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked}}
      try sql("PRAGMA journal_mode=WAL");try sql("PRAGMA synchronous=FULL");try sql("BEGIN IMMEDIATE");try sql(Self.ownerSQL);try sql(Self.artifactsSQL)
      let identity=try M4HAFile.encode(owner);var s:OpaquePointer?;guard sqlite3_prepare_v2(handle,"INSERT INTO health_owner VALUES(1,?)",-1,&s,nil)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked}
      let status=identity.withUnsafeBytes{sqlite3_bind_blob(s,1,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
      guard status==SQLITE_OK,sqlite3_step(s)==SQLITE_DONE else{sqlite3_finalize(s);throw M4HealthArtifactError.storageBlocked};sqlite3_finalize(s)
      try sql("PRAGMA application_id=\(Self.applicationID)");try sql("PRAGMA user_version=1");try sql("COMMIT")
    }catch {sqlite3_close(handle);throw error}
    guard sqlite3_close(handle)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked}
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:main.path)
    let fd=Darwin.open(main.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw M4HealthArtifactError.storageBlocked};let synced=fsync(fd);Darwin.close(fd);guard synced==0 else{throw M4HealthArtifactError.storageBlocked};boundaryHook(.afterDatabaseSync)
    // Create the original owner inode before encoding its exact immutable identity.
    let candidateOwner=candidate.appendingPathComponent("health.owner");try M4HAFile.write(Data(),candidateOwner)
    let value=M4HAOwnerRecord(version:1,identity:owner,directory:try M4HAFile.anchor(candidate,directory:true,path:directory.path),owner:try M4HAFile.anchor(candidateOwner,directory:false,path:ownerURL.path),database:try M4HAFile.anchor(main,directory:false,path:directory.appendingPathComponent("health.sqlite").path),ancestors:try M4HAFile.chain(parent))
    let bytes=try M4HAFile.encode(value);guard bytes.count<=M4HAFile.ownerLimit else{throw M4HealthArtifactError.limitExceeded}
    let ownerHandle=Darwin.open(candidateOwner.path,O_WRONLY|O_NOFOLLOW|O_CLOEXEC);guard ownerHandle>=0 else{throw M4HealthArtifactError.storageBlocked};let written=bytes.withUnsafeBytes{Darwin.pwrite(ownerHandle,$0.baseAddress,$0.count,0)},ownerSync=fsync(ownerHandle);Darwin.close(ownerHandle)
    guard written==bytes.count,ownerSync==0 else{throw M4HealthArtifactError.storageBlocked};boundaryHook(.afterOwnerSync);try M4HAFile.sync(candidate)
    guard try M4HAFile.chain(parent)==value.ancestors else{throw M4HealthArtifactError.storageBlocked}
    boundaryHook(.beforePublication)
    guard renamex_np(candidate.path,directory.path,UInt32(RENAME_EXCL))==0 else{throw M4HealthArtifactError.storageBlocked};boundaryHook(.afterPublicationRename);try M4HAFile.sync(parent);boundaryHook(.afterParentSync)
  }
  private func validateFiles()throws {
    guard ownerFD>=0,directoryFD>=0,let record else{throw M4HealthArtifactError.closed}
    for root in removableRoots {try M4HAFile.outside(directory,root)}
    guard try M4HAFile.anchor(directory,directory:true)==record.directory,try M4HAFile.anchor(ownerURL,directory:false)==record.owner,try M4HAFile.anchor(directory.appendingPathComponent("health.sqlite"),directory:false)==record.database,try M4HAFile.chain(directory.deletingLastPathComponent())==record.ancestors,try M4HAFile.read(ownerURL,maximum:M4HAFile.ownerLimit)==ownerBytes else{throw M4HealthArtifactError.invalidOwner}
    for (fd,anchor) in [(ownerFD,record.owner),(directoryFD,record.directory)] {
      var value=stat();guard fstat(fd,&value)==0,UInt64(UInt32(bitPattern:value.st_dev))==anchor.device,value.st_ino==anchor.inode else{throw M4HealthArtifactError.invalidOwner}
    }
    let known:Set<Data>=Set(["health.owner","health.sqlite","health.sqlite-wal","health.sqlite-shm"].map{Data($0.utf8)})
    for name in try FileManager.default.contentsOfDirectory(atPath:directory.path) {
      guard known.contains(Data(name.utf8)) else{throw M4HealthArtifactError.storageBlocked}
      let url=directory.appendingPathComponent(name);_=try M4HAFile.anchor(url,directory:false)
      var value=stat();guard lstat(url.path,&value)==0,value.st_size>=0,value.st_size<=(name=="health.owner" ? Int64(M4HAFile.ownerLimit):name=="health.sqlite-shm" ? 4*1024*1024:Int64(M4HAFile.databaseLimit)) else{throw M4HealthArtifactError.storageBlocked}
      if name=="health.sqlite-wal",value.st_size>0 {
        let prefix=try M4HAFile.read(url,maximum:32,prefix:true)
        guard prefix.count==32,[[UInt8](arrayLiteral:0x37,0x7f,0x06,0x82),[0x37,0x7f,0x06,0x83]].contains(Array(prefix.prefix(4))),prefix[4..<8]==Data([0,0x2d,0xe2,0x18]) else{throw M4HealthArtifactError.storageBlocked}
      }
      if name=="health.sqlite-shm",value.st_size>0 {
        guard value.st_size>=96,value.st_size%(32*1024)==0 else{throw M4HealthArtifactError.storageBlocked}
        let prefix=try M4HAFile.read(url,maximum:4,prefix:true)
        guard prefix==Data([0x18,0xe2,0x2d,0]) || prefix==Data([0,0x2d,0xe2,0x18]) || prefix==Data(repeating:0,count:4) else{throw M4HealthArtifactError.storageBlocked}
      }
    }
  }
  private func stabilize()throws {
    try validateFiles();let parent=directory.deletingLastPathComponent(),fd=Darwin.open(parent.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0,let expected=record?.ancestors.first(where:{Data($0.path.utf8)==Data(parent.path.utf8)})else{if fd>=0{Darwin.close(fd)};throw M4HealthArtifactError.storageBlocked};defer{Darwin.close(fd)}
    var value=stat();guard fstat(fd,&value)==0,UInt64(UInt32(bitPattern:value.st_dev))==expected.device,value.st_ino==expected.inode else{throw M4HealthArtifactError.storageBlocked}
    try trip(.directorySync);guard fsync(directoryFD)==0 else{throw M4HealthArtifactError.storageBlocked};boundaryHook(.afterDirectorySync)
    try trip(.parentSync);guard fsync(fd)==0 else{throw M4HealthArtifactError.storageBlocked};try validateFiles()
    guard fstat(fd,&value)==0,UInt64(UInt32(bitPattern:value.st_dev))==expected.device,value.st_ino==expected.inode else{throw M4HealthArtifactError.storageBlocked}
  }
  private func header()throws {
    let bytes=try M4HAFile.read(directory.appendingPathComponent("health.sqlite"),maximum:100,prefix:true)
    guard bytes.count==100,bytes.prefix(16)==Data("SQLite format 3\0".utf8) else{throw M4HealthArtifactError.storageBlocked}
    func number(_ offset:Int)->UInt32{bytes[offset..<offset+4].reduce(0){($0<<8)|UInt32($1)}}
    guard number(60)==1,number(68)==UInt32(Self.applicationID) else{throw M4HealthArtifactError.storageBlocked}
  }
  func injectNextFault(_ value:M4HealthArtifactFault){fault=value}
  private func trip(_ value:M4HealthArtifactFault)throws {if fault==value{fault=nil;throw M4HealthArtifactError.storageBlocked}}
  func validate()throws {try validateFiles();try stabilize()}
  func close(){if let db{sqlite3_close_v2(db);self.db=nil};if directoryFD>=0{Darwin.close(directoryFD);directoryFD = -1};if ownerFD>=0{flock(ownerFD,LOCK_UN);Darwin.close(ownerFD);ownerFD = -1}}
  deinit {close()}
  private func execute(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked}}
  private func validateSchema()throws {
    func textRows(_ command:String)throws->[[Data]] {
      var s:OpaquePointer?;guard sqlite3_prepare_v2(db,command,-1,&s,nil)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(s)};var rows:[[Data]]=[]
      while true {let status=sqlite3_step(s);if status==SQLITE_DONE{break};guard status==SQLITE_ROW,rows.count<10 else{throw M4HealthArtifactError.storageBlocked};var row:[Data]=[]
        for i in 0..<sqlite3_column_count(s){guard sqlite3_column_type(s,i)==SQLITE_TEXT,let p=sqlite3_column_text(s,i)else{throw M4HealthArtifactError.storageBlocked};row.append(Data(bytes:p,count:Int(sqlite3_column_bytes(s,i))))};rows.append(row)};return rows
    }
    guard try textRows("PRAGMA journal_mode")==[[Data("wal".utf8)]],try textRows("PRAGMA quick_check")==[[Data("ok".utf8)]],try textRows("SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name")==[[Data(Self.artifactsSQL.utf8)],[Data(Self.ownerSQL.utf8)]],try textRows("SELECT name FROM sqlite_master WHERE type IN ('view','trigger') OR (type='index' AND sql IS NOT NULL)").isEmpty else{throw M4HealthArtifactError.storageBlocked}
    var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT canonical FROM health_owner WHERE id=1",-1,&s,nil)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(s)}
    guard sqlite3_step(s)==SQLITE_ROW,sqlite3_column_type(s,0)==SQLITE_BLOB,Int(sqlite3_column_bytes(s,0))<=M4HAFile.ownerLimit,let p=sqlite3_column_blob(s,0),Data(bytes:p,count:Int(sqlite3_column_bytes(s,0)))==(try M4HAFile.encode(owner)),sqlite3_step(s)==SQLITE_DONE else{throw M4HealthArtifactError.invalidOwner}
    for (command,expected) in [("PRAGMA user_version",1),("PRAGMA application_id",Self.applicationID),("SELECT count(*) FROM health_owner",1)] {
      var q:OpaquePointer?;guard sqlite3_prepare_v2(db,command,-1,&q,nil)==SQLITE_OK else{throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(q)}
      guard sqlite3_step(q)==SQLITE_ROW,sqlite3_column_int64(q,0)==Int64(expected),sqlite3_step(q)==SQLITE_DONE else{throw M4HealthArtifactError.storageBlocked}
    }
  }
  private func all()throws->[Row] {
    do {
    try validate();try validateSchema();var s:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT parent,kind,canonical,digest FROM health_artifacts ORDER BY parent,kind",-1,&s,nil)==SQLITE_OK else {throw M4HealthArtifactError.storageBlocked};defer{sqlite3_finalize(s)}
    var rows:[Row]=[],total=0,parents=Set<Data>()
    while true {
      let status=sqlite3_step(s);if status==SQLITE_DONE{break};guard status==SQLITE_ROW,rows.count<128 else {throw M4HealthArtifactError.storageBlocked}
      func blob(_ i:Int32)throws->Data {guard sqlite3_column_type(s,i)==SQLITE_BLOB else {throw M4HealthArtifactError.storageBlocked};let size=Int(sqlite3_column_bytes(s,i));guard size>0,size<=16*1024*1024,let pointer=sqlite3_column_blob(s,i)else{throw M4HealthArtifactError.storageBlocked};return Data(bytes:pointer,count:size)}
      let parent=try blob(0),kind=Int(sqlite3_column_int64(s,1)),bytes=try blob(2),digest=try blob(3)
      guard sqlite3_column_type(s,1)==SQLITE_INTEGER,[1,2].contains(kind),parent.count<=4096,String(data:parent,encoding:.utf8) != nil,digest==Data(M4HealthBytes.hash(bytes).utf8) else {throw M4HealthArtifactError.storageBlocked}
      total+=bytes.count;parents.insert(parent)
      guard total<=256*1024*1024,parents.count<=64 else{throw M4HealthArtifactError.storageBlocked}
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
    }catch {if let typed=error as? M4HealthArtifactError {throw typed};throw M4HealthArtifactError.storageBlocked}
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
    boundaryHook(.beforeSQLCommit);try trip(.beforeCommit)
    try execute("COMMIT");committed=true;boundaryHook(.afterSQLCommit);try trip(.afterCommitLost)
  }
}
