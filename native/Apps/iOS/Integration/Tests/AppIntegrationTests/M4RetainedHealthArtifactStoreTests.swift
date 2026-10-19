import Foundation
import Darwin
import SQLite3
import XCTest
import MatchCore
import MatchStore
import AccountKit
import HealthKitDeletion
@testable import AppIntegration

@MainActor final class M4RetainedHealthArtifactStoreTests: XCTestCase {
  func testOriginalRawAndPreparedBytesSurviveRealSQLiteCloseReopen() async throws {
    let h=try fixture(),raw=try reservation(),prepared=try M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64))
    let store=try open(h)
    try await store.reserve(raw);try await store.putPrepared(prepared)
    let rawBefore=try await store.readReservation(parentID:raw.parentID),preparedBefore=try await store.readPrepared(parentID:raw.parentID)
    XCTAssertEqual(try rawBefore?.canonicalBytes(),try raw.canonicalBytes());XCTAssertEqual(try preparedBefore?.canonicalBytes(),try prepared.canonicalBytes())
    try await store.close()
    let reopened=try open(h),rawAfter=try await reopened.readReservation(parentID:raw.parentID),preparedAfter=try await reopened.readPrepared(parentID:raw.parentID)
    XCTAssertEqual(try rawAfter?.canonicalBytes(),try raw.canonicalBytes());XCTAssertEqual(try rawAfter?.digest(),try raw.digest())
    XCTAssertEqual(try preparedAfter?.canonicalBytes(),try prepared.canonicalBytes())
    XCTAssertEqual(try scalar(h,"SELECT count(*) FROM health_artifacts"),2)
    try await reopened.close()
  }
  func testDuplicateDoesNotReplaceFirstFactsTimeOrPreparedParentDigest() async throws {
    let h=try fixture(),s=try open(h),raw=try reservation(),prepared=try M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64))
    try await s.reserve(raw);try await s.reserve(raw);try await s.putPrepared(prepared);try await s.putPrepared(prepared)
    await rejects(.identityConflict){try await s.reserve(reservation(createdAt:12))}
    await rejects(.identityConflict){try await s.putPrepared(M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"b",count:64)))}
    let saved=try await s.readReservation(parentID:raw.parentID),p=try await s.readPrepared(parentID:raw.parentID)
    XCTAssertEqual(try saved?.canonicalBytes(),try raw.canonicalBytes());XCTAssertEqual(try p?.canonicalBytes(),try prepared.canonicalBytes())
    XCTAssertEqual(try scalar(h,"SELECT count(*) FROM health_artifacts"),2);try await s.close()
  }
  func testPreparedRequiresStoredOriginalFactsAndCannotImportAnotherTuple() async throws {
    let h=try fixture(),s=try open(h),raw=try reservation(),other=try reservation(token:"other/capture/start")
    await rejects(.identityConflict){try await s.putPrepared(M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64)))}
    try await s.reserve(raw)
    await rejects(.identityConflict){try await s.putPrepared(M4HealthPreparedMapping(reservation:other,parentDigest:String(repeating:"a",count:64)))}
    let p=try await s.readPrepared(parentID:raw.parentID);XCTAssertNil(p);try await s.close()
  }
  func testRawUnicodeParentKeysRemainDistinctAndFullSealDefaultsUnavailable() async throws {
    let h=try fixture(),s=try open(h),a=try reservation(parentID:"parent-é"),b=try reservation(parentID:"parent-e\u{301}")
    try await s.reserve(a);try await s.reserve(b)
    let one=try await s.readReservation(parentID:a.parentID),two=try await s.readReservation(parentID:b.parentID)
    XCTAssertEqual(try one?.canonicalBytes(),try a.canonicalBytes());XCTAssertEqual(try two?.canonicalBytes(),try b.canonicalBytes())
    XCTAssertEqual(try scalar(h,"SELECT count(*) FROM health_artifacts"),2)
    do{_=try await s.readFullSeal(parentID:a.parentID);XCTFail("default provider must remain unavailable")}catch {XCTAssertEqual(error as? M4HealthBridgeError,.mappingUnavailable)}
    try await s.close()
  }
  func testOriginalOwnerIsImmutableAcrossNamespaceScopeAndInstallationChanges() async throws {
    let h=try fixture(),s=try open(h),raw=try reservation();try await s.reserve(raw);try await s.close()
    for owner in [M4HealthArtifactOwner(installationID:UUID().uuidString,namespace:h.owner.namespace,scope:h.owner.scope),M4HealthArtifactOwner(installationID:h.owner.installationID,namespace:"other",scope:h.owner.scope),M4HealthArtifactOwner(installationID:h.owner.installationID,namespace:h.owner.namespace,scope:try scope(epoch:2))] {
      XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:h.directory,owner:owner,removableRoots:[h.business]))
    }
    let next=try open(h),saved=try await next.readReservation(parentID:raw.parentID);XCTAssertEqual(try saved?.canonicalBytes(),try raw.canonicalBytes());try await next.close()
  }
  func testSecondHandleCannotShareLeaseAndClosedHandleCannotWrite() async throws {
    let h=try fixture(),s=try open(h)
    XCTAssertThrowsError(try open(h)){XCTAssertEqual($0 as? M4HealthArtifactError,.leaseInUse)}
    try await s.close();await rejects(.closed){try await s.reserve(reservation())}
    let next=try open(h);try await next.reserve(reservation());try await next.close()
  }
  func testRawScopeCannotCrossOwnerBoundaryEvenForUnicodeEquivalentID() async throws {
    let h=try fixture(space:"space-é"),s=try open(h),raw=try reservation(scope:scope(space:"space-e\u{301}"))
    await rejects(.identityConflict){try await s.reserve(raw)}
    XCTAssertEqual(try scalar(h,"SELECT count(*) FROM health_artifacts"),0);try await s.close()
  }

  func testUnknownFilesMissingOwnerAndMissingDatabaseArePreservedWithoutReinitialization() async throws {
    for damage in ["unknown","owner","database"] {
      let h=try fixture(),s=try open(h);try await s.reserve(reservation());try await s.close()
      if damage == "unknown" {try Data("foreign".utf8).write(to:h.directory.appendingPathComponent("unknown.data"))}
      else {try FileManager.default.removeItem(at:h.directory.appendingPathComponent(damage == "owner" ? "health.owner":"health.sqlite"))}
      let before=try inventory(h.directory)
      XCTAssertThrowsError(try open(h),damage)
      XCTAssertEqual(try inventory(h.directory),before,damage)
    }
  }
  func testFutureSchemaForeignMetadataAndCorruptCanonicalRejectBeforeWritableOpen() async throws {
    for sql in ["PRAGMA user_version=99","CREATE TABLE foreign_control(secret BLOB)","UPDATE health_artifacts SET canonical=x'7b7d'","UPDATE health_artifacts SET digest=zeroblob(64)"] {
      let h=try fixture(),s=try open(h);try await s.reserve(reservation());try await s.close();try modify(h,sql)
      let before=try inventory(h.directory)
      XCTAssertThrowsError(try open(h),sql)
      let after=try inventory(h.directory)
      if sql.hasPrefix("PRAGMA") {XCTAssertEqual(after,before,sql)}
      else {XCTAssertEqual(after.filter{!$0.key.hasSuffix("-wal") && !$0.key.hasSuffix("-shm")},before.filter{!$0.key.hasSuffix("-wal") && !$0.key.hasSuffix("-shm")},sql)}
    }
  }
  func testForeignDatabaseCannotReplaceOriginalInodeEvenWithValidCopiedCanonicalRows() async throws {
    let h=try fixture(),s=try open(h);try await s.reserve(reservation());try await s.close()
    let db=h.directory.appendingPathComponent("health.sqlite"),bytes=try Data(contentsOf:db)
    try FileManager.default.moveItem(at:db,to:h.root.appendingPathComponent("original.sqlite"));try bytes.write(to:db)
    let before=try inventory(h.directory);XCTAssertThrowsError(try open(h));XCTAssertEqual(try inventory(h.directory),before)
  }
  func testOwnerReplacementWithSameBytesAndParentReplacementBothFailClosed() async throws {
    let h=try fixture(),s=try open(h);try await s.reserve(reservation())
    let owner=h.directory.appendingPathComponent("health.owner"),bytes=try Data(contentsOf:owner)
    try FileManager.default.moveItem(at:owner,to:h.root.appendingPathComponent("original.owner"));try bytes.write(to:owner)
    let before=try inventory(h.directory)
    do{_=try await s.readReservation(parentID:"parent-delete");XCTFail("replaced owner inode")}catch{}
    XCTAssertEqual(try inventory(h.directory),before);try await s.close();XCTAssertThrowsError(try open(h))
    let other=try fixture(),next=try open(other);try await next.reserve(reservation());try await next.close()
    let moved=other.root.appendingPathComponent("moved");try FileManager.default.moveItem(at:other.directory,to:moved)
    try FileManager.default.createDirectory(at:other.directory,withIntermediateDirectories:false)
    for child in try FileManager.default.contentsOfDirectory(at:moved,includingPropertiesForKeys:nil){try FileManager.default.moveItem(at:child,to:other.directory.appendingPathComponent(child.lastPathComponent))}
    let second=try inventory(other.directory);XCTAssertThrowsError(try open(other));XCTAssertEqual(try inventory(other.directory),second)
  }
  func testRetainedDirectoryMustBeOutsideBothDirectionsOfAllRemovableRoots() throws {
    let h=try fixture()
    for (directory,business) in [(h.business.appendingPathComponent("retained"),h.business),(h.directory,h.root)] {
      XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:directory,owner:h.owner,removableRoots:[business]))
      XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("health.owner").path))
    }
    let h2=try fixture(),inside=h2.directory.appendingPathComponent("business")
    try FileManager.default.createDirectory(at:inside,withIntermediateDirectories:true)
    XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:h2.directory,owner:h2.owner,removableRoots:[inside]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:h2.directory.appendingPathComponent("health.owner").path))
  }
  func testRealCaseAliasAndSymlinkRootsCannotBypassRetainedSeparation() throws {
    let h=try fixture(),business=h.root.appendingPathComponent("CaseBusiness")
    try FileManager.default.createDirectory(at:business,withIntermediateDirectories:false)
    let alias=h.root.appendingPathComponent("casebusiness")
    var one=stat(),two=stat();guard lstat(business.path,&one)==0,lstat(alias.path,&two)==0,one.st_ino==two.st_ino,one.st_dev==two.st_dev else {throw XCTSkip("host volume does not expose a case alias")}
    XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:alias.appendingPathComponent("retained"),owner:h.owner,removableRoots:[business]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:business.appendingPathComponent("retained/health.owner").path))
    let link=h.root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:h.business)
    XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:link.appendingPathComponent("retained"),owner:h.owner,removableRoots:[h.business]))
  }
  func testKnownSidecarNamesNeverAuthorizeSymlinkOrForeignControl() async throws {
    for name in ["health.sqlite-wal","health.sqlite-shm","health.sqlite-journal"] {
      let h=try fixture(),s=try open(h);try await s.reserve(reservation());try await s.close()
      let foreign=h.root.appendingPathComponent("foreign");try Data("foreign-sidecar".utf8).write(to:foreign)
      let sidecar=h.directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath:sidecar.path){try FileManager.default.removeItem(at:sidecar)}
      try FileManager.default.createSymbolicLink(at:sidecar,withDestinationURL:foreign)
      let before=try inventory(h.directory);XCTAssertThrowsError(try open(h));XCTAssertEqual(try inventory(h.directory),before);XCTAssertEqual(try Data(contentsOf:foreign),Data("foreign-sidecar".utf8))
    }
  }
  func testTightenedArtifactParentRowCountAndAggregateBudgetsRollbackWithoutChangingFirstBytes() async throws {
    let raw=try reservation(),prepared=try M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64)),rawSize=try raw.canonicalBytes().count,pSize=try prepared.canonicalBytes().count
    let limits=[try M4HealthArtifactLimits(artifactBytes:rawSize-1),try M4HealthArtifactLimits(parentBytes:rawSize+pSize-1),try M4HealthArtifactLimits(parents:1),try M4HealthArtifactLimits(rows:1),try M4HealthArtifactLimits(totalBytes:rawSize+pSize-1)]
    for (index,limit) in limits.enumerated() {
      let h=try fixture(),s=try M4RetainedHealthArtifactStore(directory:h.directory,owner:h.owner,removableRoots:[h.business],limits:limit)
      if index==0 {await rejects(.limitExceeded){try await s.reserve(raw)};let none=try await s.readReservation(parentID:raw.parentID);XCTAssertNil(none)}
      else {
        try await s.reserve(raw)
        if index==2 {await rejects(.limitExceeded){try await s.reserve(reservation(parentID:"other-parent"))}}
        else {await rejects(.limitExceeded){try await s.putPrepared(prepared)}}
        try await s.reserve(raw);let first=try await s.readReservation(parentID:raw.parentID);XCTAssertEqual(try first?.canonicalBytes(),try raw.canonicalBytes())
        let absent=try await s.readPrepared(parentID:raw.parentID);XCTAssertNil(absent)
      }
      try await s.close()
    }
    XCTAssertThrowsError(try M4HealthArtifactLimits(parents:65));XCTAssertThrowsError(try M4HealthArtifactLimits(totalBytes:256*1024*1024+1))
  }
  func testTransactionFaultsPreserveFirstRawAndReplayCommittedPreparedAfterResponseLoss() async throws {
    for fault in [M4HealthArtifactFault.beforeCommit,.afterCommitLost] {
      let h=try fixture(),s=try open(h),raw=try reservation(),prepared=try M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64))
      try await s.reserve(raw);await s.injectNextFault(fault)
      await rejects(.storageBlocked){try await s.putPrepared(prepared)}
      let first=try await s.readReservation(parentID:raw.parentID);XCTAssertEqual(try first?.canonicalBytes(),try raw.canonicalBytes());try await s.close()
      let next=try open(h),saved=try await next.readPrepared(parentID:raw.parentID)
      XCTAssertEqual(saved != nil,fault == .afterCommitLost)
      if let saved {XCTAssertEqual(try saved.canonicalBytes(),try prepared.canonicalBytes())}
      try await next.putPrepared(prepared);try await next.close()
    }
  }
  func testDirectoryBarriersFailBeforeReadOrMutationAndPreservePublishedBytes() async throws {
    for fault in [M4HealthArtifactFault.directorySync,.parentSync] {
      let h=try fixture(),s=try open(h),raw=try reservation();try await s.reserve(raw)
      let before=try inventory(h.directory);await s.injectNextFault(fault)
      await rejects(.storageBlocked){_=try await s.readReservation(parentID:raw.parentID)}
      XCTAssertEqual(try inventory(h.directory),before)
      await s.injectNextFault(fault);await rejects(.storageBlocked){try await s.reserve(reservation(parentID:"not-admitted"))}
      let absent=try await s.readReservation(parentID:"not-admitted");XCTAssertNil(absent);try await s.close()
    }
  }
  func testRealChildCommitCrashRecoversOriginalWALAndMissingSHMWithoutNewOwner() async throws {
    let env=ProcessInfo.processInfo.environment
    if let path=env["NATIVE041_CHILD_ROOT"],let phase=env["NATIVE041_CHILD_PHASE"] {
      let h=try fixture(root:URL(fileURLWithPath:path)),s=try M4RetainedHealthArtifactStore(directory:h.directory,owner:h.owner,removableRoots:[h.business],boundaryHook:{if $0.rawValue==phase{_exit(86)}})
      let raw=try reservation();try await s.putPrepared(M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64)))
      try await s.close();return
    }
    for phase in ["beforeSQLCommit","afterSQLCommit","afterSQLCommit-no-shm"] {
      let h=try fixture(),s=try open(h),raw=try reservation();try await s.reserve(raw);try await s.close()
      let owner=try Data(contentsOf:h.directory.appendingPathComponent("health.owner"))
      try crashChild(h,method:#function,phase:phase)
      XCTAssertTrue(FileManager.default.fileExists(atPath:h.directory.appendingPathComponent("health.sqlite-wal").path))
      if phase.hasSuffix("no-shm") {let path=h.directory.appendingPathComponent("health.sqlite-shm");if FileManager.default.fileExists(atPath:path.path){try FileManager.default.removeItem(at:path)}}
      let next=try open(h),saved=try await next.readPrepared(parentID:raw.parentID),first=try await next.readReservation(parentID:raw.parentID)
      XCTAssertEqual(try first?.canonicalBytes(),try raw.canonicalBytes());XCTAssertEqual(saved != nil,phase != "beforeSQLCommit")
      if let saved {XCTAssertEqual(try saved.canonicalBytes(),try M4HealthPreparedMapping(reservation:raw,parentDigest:String(repeating:"a",count:64)).canonicalBytes())}
      XCTAssertEqual(try Data(contentsOf:h.directory.appendingPathComponent("health.owner")),owner);try await next.close()
    }
  }
  func testRealInitializationCrashesNeverExposePartialDirectoryAndReopenStabilizesOriginalOwner() async throws {
    let env=ProcessInfo.processInfo.environment
    if let path=env["NATIVE041_CHILD_ROOT"],let phase=env["NATIVE041_CHILD_PHASE"] {
      let h=try fixture(root:URL(fileURLWithPath:path)),s=try M4RetainedHealthArtifactStore(directory:h.directory,owner:h.owner,removableRoots:[h.business],boundaryHook:{if $0.rawValue==phase{_exit(86)}})
      try await s.close();return
    }
    for phase in ["afterDatabaseSync","afterOwnerSync","beforePublication","afterPublicationRename","afterParentSync"] {
      let h=try fixture();try crashChild(h,method:#function,phase:phase)
      let published=FileManager.default.fileExists(atPath:h.directory.path)
      XCTAssertEqual(published,["afterPublicationRename","afterParentSync"].contains(phase))
      let oldOwner=published ? try Data(contentsOf:h.directory.appendingPathComponent("health.owner")):nil
      let unclaimed=try FileManager.default.contentsOfDirectory(at:h.root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".")}
      let original=try unclaimed.map{try inventory($0)}
      let next=try open(h);try await next.reserve(reservation());try await next.close()
      if let oldOwner {XCTAssertEqual(try Data(contentsOf:h.directory.appendingPathComponent("health.owner")),oldOwner)}
      for (index,path) in unclaimed.enumerated(){XCTAssertEqual(try inventory(path),original[index])}
    }
  }
  func testConcurrentForeignFinalDirectoryIsNotOverwrittenByEXCLPublication() throws {
    let h=try fixture(),bytes=Data([0,255,7])
    XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:h.directory,owner:h.owner,removableRoots:[h.business],boundaryHook:{point in
      if point == .beforePublication {try? FileManager.default.createDirectory(at:h.directory,withIntermediateDirectories:false);try? bytes.write(to:h.directory.appendingPathComponent("foreign"))}
    }))
    XCTAssertEqual(try Data(contentsOf:h.directory.appendingPathComponent("foreign")),bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath:h.directory.appendingPathComponent("health.owner").path))
  }
  func testOwnerEncodingBudgetRejectsDeepOriginalPathsBeforeCandidateCreation() throws {
    let h=try fixture();var deep=h.root
    for _ in 0..<300 {deep.appendPathComponent("d")};try FileManager.default.createDirectory(at:deep,withIntermediateDirectories:true)
    let target=deep.appendingPathComponent("retained")
    XCTAssertThrowsError(try M4RetainedHealthArtifactStore(directory:target,owner:h.owner,removableRoots:[h.business])){XCTAssertEqual($0 as? M4HealthArtifactError,.limitExceeded)}
    XCTAssertFalse(FileManager.default.fileExists(atPath:target.path));XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:deep.path),[])
  }
  func testMalformedKnownSidecarsAreClassifiedBeforeSQLiteMayResetThem() async throws {
    for name in ["health.sqlite-wal","health.sqlite-shm"] {
      let h=try fixture(),s=try open(h);try await s.reserve(reservation());try await s.close()
      try Data("unrecognized control format".utf8).write(to:h.directory.appendingPathComponent(name))
      let before=try inventory(h.directory);XCTAssertThrowsError(try open(h));XCTAssertEqual(try inventory(h.directory),before)
    }
  }
  private func crashChild(_ h:Fixture,method:String,phase:String)throws {
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");p.arguments=["xctest","-XCTest","AppIntegrationTests.M4RetainedHealthArtifactStoreTests/"+method.replacingOccurrences(of:"()",with:""),Bundle(for:Self.self).bundleURL.path]
    var env=ProcessInfo.processInfo.environment;env["NATIVE041_CHILD_ROOT"]=h.root.path;env["NATIVE041_CHILD_PHASE"]=phase.replacingOccurrences(of:"-no-shm",with:"");p.environment=env
    let log=h.root.appendingPathComponent("child-"+phase+".log");XCTAssertTrue(FileManager.default.createFile(atPath:log.path,contents:nil));let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()};p.standardOutput=handle;p.standardError=handle
    try p.run();p.waitUntilExit();print("NATIVE041-crash phase=\(phase) status=\(p.terminationStatus)");XCTAssertEqual(p.terminationReason,.exit);XCTAssertEqual(p.terminationStatus,86)
  }
  private func inventory(_ directory:URL)throws->[String:Data] {
    var result:[String:Data]=[:]
    for name in try FileManager.default.contentsOfDirectory(atPath:directory.path) {
      let url=directory.appendingPathComponent(name);var value=stat();guard lstat(url.path,&value)==0 else {throw M4HealthBridgeError.mappingUnavailable}
      if value.st_mode&S_IFMT==S_IFLNK {result[name]=Data(("symlink:"+(try FileManager.default.destinationOfSymbolicLink(atPath:url.path))).utf8)}
      else if value.st_mode&S_IFMT==S_IFREG {result[name]=try Data(contentsOf:url)}
      else {result[name]=Data("directory".utf8)}
    };return result
  }
  private func modify(_ h:Fixture,_ sql:String)throws {
    var db:OpaquePointer?;guard sqlite3_open_v2(h.directory.appendingPathComponent("health.sqlite").path,&db,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};defer{sqlite3_close(db)}
    guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable}
  }

  private struct Fixture:Sendable {let root,directory,business:URL;let owner:M4HealthArtifactOwner}
  private func fixture(space:String="space",root requested:URL?=nil) throws -> Fixture {
    let root=requested ?? URL(fileURLWithPath:"/private/tmp").appendingPathComponent("NATIVE041-"+UUID().uuidString),business=root.appendingPathComponent("business")
    try FileManager.default.createDirectory(at:business,withIntermediateDirectories:true)
    return Fixture(root:root,directory:root.appendingPathComponent("retained"),business:business,owner:M4HealthArtifactOwner(installationID:"12345678-1234-4234-8234-123456789ABC",namespace:"fixture-original",scope:try scope(space:space)))
  }
  private func open(_ h:Fixture) throws -> M4RetainedHealthArtifactStore {try M4RetainedHealthArtifactStore(directory:h.directory,owner:h.owner,removableRoots:[h.business])}
  private func scope(space:String="space",epoch:Int64=1) throws -> CloudScopeV1 {try CloudScopeV1(accountID:"account",cloudSpaceID:space,zoneID:"zone",activationEpoch:epoch)}
  private func reservation(parentID:String="parent-delete",createdAt:Int64=10,token:String="intent/capture/start",scope value:CloudScopeV1?=nil) throws -> M4HealthRawReservation {
    let binding=try CaptureBinding(matchID:"match",recordingDeviceID:"fixture-watch"),date=Date(timeIntervalSince1970:10),workout=UUID(uuidString:"12345678-1234-4234-8234-123456789abc")!
    let op=try CaptureOperation(id:token,binding:binding,associatedCommandID:"start",action:.start,requestedAt:date,externalToken:token)
    let window=try CaptureWindow(start:date,end:date.addingTimeInterval(1)),observation=try WorkoutObservation(operationID:op.id,binding:binding,externalToken:token,observedAt:date,outcome:.linked(workoutID:workout.uuidString),window:window)
    let segment=try CaptureSegment(id:"opaque-segment",binding:binding,workoutID:workout.uuidString,window:window),metadata=try CaptureMetadata(binding:binding,segments:[segment],gaps:[])
    let revision=try CaptureRevision(id:"revision",binding:binding,parentID:nil,revision:1,observedAt:date,metadata:metadata)
    return try M4HealthRawReservation(parentID:parentID,scope:value ?? scope(),cloud:.keep,local:.delete,health:.delete,healthConfirmed:true,createdAt:createdAt,confirmedAt:createdAt+1,facts:[M4HealthCaptureFacts(binding:binding,revisions:[revision],operations:[CaptureOperationRecord(operation:op,state:.settled,observation:observation)])],sources:[M4HealthSourceEvidence(recordingDeviceID:binding.recordingDeviceID,bundleID:"app.fixture.watch",platform:.watchOS,origin:.controlledFixture,evidenceID:"fixture-source")])
  }
  private func rejects(_ expected:M4HealthArtifactError,_ body:() async throws->Void) async {
    do {try await body();XCTFail("expected \(expected)")}catch {XCTAssertEqual(error as? M4HealthArtifactError,expected)}
  }
  private func scalar(_ h:Fixture,_ sql:String) throws -> Int {
    var db:OpaquePointer?;guard sqlite3_open_v2(h.directory.appendingPathComponent("health.sqlite").path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};defer{sqlite3_close(db)}
    var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};defer{sqlite3_finalize(statement)}
    guard sqlite3_step(statement)==SQLITE_ROW else {throw M4HealthBridgeError.mappingUnavailable};return Int(sqlite3_column_int64(statement,0))
  }
}
