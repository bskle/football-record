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

  private struct Fixture {let root,directory,business:URL;let owner:M4HealthArtifactOwner}
  private func fixture(space:String="space") throws -> Fixture {
    let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("NATIVE041-"+UUID().uuidString),business=root.appendingPathComponent("business")
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
