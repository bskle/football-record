import Foundation
import XCTest
import SQLite3
@testable import HealthKitDeletion
final class HealthDeletionLedgerTests: XCTestCase, @unchecked Sendable {
 func testCanonicalSelectionIsCompleteAndOrderIndependent() throws {
  let id=UUID(), first=try target(), second=try target("00000000-0000-0000-0000-000000000002",match:"match-b")
  let a=try request(id,targets:[first,second]), b=try request(id,targets:[second,first])
  XCTAssertFalse(try a.canonicalBytes().isEmpty)
  XCTAssertEqual(try a.canonicalBytes(),try b.canonicalBytes())
  XCTAssertEqual(try a.selectionDigest().count,64)
  for changed in [try target(match:"other"),try target(recorder:"other"),try target(segment:"other"),try target(source:"test.other")] {
   XCTAssertNotEqual(try request(id).selectionDigest(),try request(id,targets:[changed]).selectionDigest())
  }
 }
 func testEmptyDuplicateAndMalformedSelectionIsRejected() throws {
  XCTAssertThrowsError(try request(targets:[]))
  XCTAssertThrowsError(try request(targets:[target(),target()]))
  XCTAssertThrowsError(try request(targets:[target(),target(match:"other")]))
  XCTAssertThrowsError(try target(match:""))
  XCTAssertThrowsError(try target(segment:"bad value"))
  XCTAssertThrowsError(try target(source:""))
  XCTAssertThrowsError(try WorkoutDeletionRequestV1(requestID:UUID(),createdAt:-1,targets:[target()]))
 }

 func testRequestConfirmationAndRawSelectionSurviveBusinessErasure() async throws {
  let paths=try deletionPaths(), r=try request(), c=try confirmation(r)
  try FileManager.default.createDirectory(at: paths.business,withIntermediateDirectories:true)
  try Data("business".utf8).write(to:paths.business.appendingPathComponent("facts"))
  let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  let first=try await ledger.submit(r); XCTAssertEqual(first.phase,.awaitingConfirmation)
  let confirmed=try await ledger.confirm(c,now:deletionTime); XCTAssertEqual(confirmed.phase,.pending)
  try await ledger.close(); try FileManager.default.removeItem(at:paths.business)
  let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  let entry=try await reopened.entry(r.requestID)
  XCTAssertEqual(try entry.request.canonicalBytes(),try r.canonicalBytes()); XCTAssertEqual(entry.confirmation,c)
  XCTAssertEqual(entry.selectionDigest,try r.selectionDigest()); try await reopened.close()
 }
 func testConflictingRequestAndConfirmationNeverReplaceOriginal() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  _=try await ledger.submit(r)
  await expectIssue(.identityConflict) { _=try await ledger.submit(request(r.requestID,targets:[target(match:"other")])) }
  let other=try request(),wrong=try WorkoutDeletionConfirmationV1(confirmationID:UUID(),requestID:r.requestID,selectionDigest:other.selectionDigest(),confirmedAt:deletionTime,explicitHealthDeletion:true)
  await expectIssue(.identityConflict) { _=try await ledger.confirm(wrong,now:deletionTime) }
  let c=try confirmation(r); _=try await ledger.confirm(c,now:deletionTime)
  await expectIssue(.identityConflict) { _=try await ledger.confirm(confirmation(r),now:deletionTime) }
  let entry=try await ledger.entry(r.requestID); XCTAssertEqual(entry.confirmation,c); try await ledger.close()
 }
 func testIndependentDirectoryAndSingleOwnerAreRequired() async throws {
  let paths=try deletionPaths()
  XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.business.appendingPathComponent("control.sqlite"),businessDataDirectory:paths.business))
  let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business))
  try await ledger.close()
  let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business);try await reopened.close()
 }
 func testBeforeCommitRollbackAndLostResponseRecoverFirstRequest() async throws {
  for point in [DeletionFault.beforeCommit,.afterCommitResponseLost] {
   let paths=try deletionPaths(),r=try request()
   let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business,fault:{ _ in point })
   await expectIssue(.storageUnavailable) { _=try await ledger.submit(r) };try await ledger.close()
   let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
   let pending=try await reopened.pendingRequests();XCTAssertEqual(pending.count,point == .beforeCommit ? 0:1)
   let restored=try await reopened.submit(r);XCTAssertEqual(restored.selectionDigest,try r.selectionDigest());try await reopened.close()
  }
 }
 func testFutureSchemaAndCorruptDatabaseArePreserved() throws {
  for corrupt in [false,true] {
   let paths=try deletionPaths();try FileManager.default.createDirectory(at:paths.control.deletingLastPathComponent(),withIntermediateDirectories:true)
   if corrupt { try Data("not sqlite".utf8).write(to:paths.control) } else {
    var db: OpaquePointer?;XCTAssertEqual(sqlite3_open(paths.control.path,&db),SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db,"PRAGMA user_version=999",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
   }
   let before=try Data(contentsOf:paths.control)
   XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business))
   XCTAssertEqual(try Data(contentsOf:paths.control),before)
  }
 }
 func testConfirmationMustBeExplicitAndTimeBound() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  _=try await ledger.submit(r)
  XCTAssertThrowsError(try WorkoutDeletionConfirmationV1(confirmationID:UUID(),requestID:r.requestID,selectionDigest:r.selectionDigest(),confirmedAt:deletionTime,explicitHealthDeletion:false))
  let future=try WorkoutDeletionConfirmationV1(confirmationID:UUID(),requestID:r.requestID,selectionDigest:r.selectionDigest(),confirmedAt:deletionTime+61,explicitHealthDeletion:true)
  await expectIssue(.invalidRequest) { _=try await ledger.confirm(future,now:deletionTime) };try await ledger.close()
 }

 func testSelectionBoundsAndCompleteRequestDomain() throws {
  let targets=try (0..<WorkoutDeletionRequestV1.maximumTargets).map { _ in try WorkoutDeletionTargetV1(workoutUUID:UUID(),matchID:"m",recordingDeviceID:"d",segmentToken:"s",expectedSourceBundleID:"test.football.phone") }
  XCTAssertNoThrow(try request(targets:targets))
  XCTAssertThrowsError(try request(targets:targets+[target()]))
  XCTAssertThrowsError(try target(match:String(repeating:"a",count:129)))
  XCTAssertThrowsError(try target(source:"test..phone"))
  XCTAssertThrowsError(try WorkoutDeletionRequestV1(requestID:UUID(),createdAt:Int64.max,targets:[target()]))
  let a=try request(),b=try WorkoutDeletionRequestV1(requestID:a.requestID,createdAt:deletionTime+1,targets:a.targets)
  XCTAssertNotEqual(try a.selectionDigest(),try b.selectionDigest())
  XCTAssertNotEqual(try a.selectionDigest(),try request().selectionDigest())
 }
 func testUnknownConfirmationFieldsAreRejectedWithoutRewritingFile() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r);try await ledger.close()
  try editControlDB(paths.control,"UPDATE health_deletion_requests SET confirmation=CAST(json_set(confirmation,'$.readAuthorized',1) AS BLOB)")
  let before=try Data(contentsOf:paths.control)
  XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business))
  XCTAssertEqual(try Data(contentsOf:paths.control),before)
 }
 func testInconsistentExecutingIssueIsNotResetToRetryable() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r)
  _=try await ledger.beginAttempt(r.requestID,attemptID:UUID());try await ledger.close()
  try editControlDB(paths.control,"UPDATE health_deletion_requests SET issue='authorizationDenied'")
  let before=try Data(contentsOf:paths.control)
  XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business))
  XCTAssertEqual(try Data(contentsOf:paths.control),before)
 }
 func testReceiptTimeCannotPrecedeConfirmedSelection() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),attempt=UUID()
  _=try await ledger.beginAttempt(r.requestID,attemptID:attempt)
  try await ledger.finish(r.requestID,digest:r.selectionDigest(),attemptID:attempt,outcome:.success(deletedObjectCount:1),now:deletionTime)
  try await ledger.close();try editControlDB(paths.control,"UPDATE health_deletion_requests SET receipt=CAST(json_set(receipt,'$.completedAt',0) AS BLOB)")
  let before=try Data(contentsOf:paths.control)
  XCTAssertThrowsError(try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business))
  XCTAssertEqual(try Data(contentsOf:paths.control),before)
 }
 func testWrongDigestAndOldAttemptCannotAdvanceCurrentAttempt() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),old=UUID(),next=UUID()
  _=try await ledger.beginAttempt(r.requestID,attemptID:old)
  await expectIssue(.identityConflict) { try await ledger.finish(r.requestID,digest:String(repeating:"a",count:64),attemptID:old,outcome:.success(deletedObjectCount:1),now:deletionTime) }
  try await ledger.finish(r.requestID,digest:r.selectionDigest(),attemptID:old,outcome:.failure(.authorizationDenied),now:deletionTime)
  _=try await ledger.beginAttempt(r.requestID,attemptID:next)
  await expectIssue(.identityConflict) { try await ledger.finish(r.requestID,digest:r.selectionDigest(),attemptID:old,outcome:.success(deletedObjectCount:1),now:deletionTime) }
  let entry=try await ledger.entry(r.requestID);XCTAssertEqual(entry.phase,.executing);XCTAssertEqual(entry.attemptID,next);XCTAssertNil(entry.receipt);try await ledger.close()
 }

 func testLiveCallbackTimeBeforeConfirmationCannotCreateReceipt() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business),attempt=UUID()
  _=try await ledger.submit(r)
  let later=try WorkoutDeletionConfirmationV1(confirmationID:UUID(),requestID:r.requestID,selectionDigest:r.selectionDigest(),confirmedAt:deletionTime+10,explicitHealthDeletion:true)
  _=try await ledger.confirm(later,now:deletionTime+10);_=try await ledger.beginAttempt(r.requestID,attemptID:attempt)
  await expectIssue(.invalidResponse) { try await ledger.finish(r.requestID,digest:r.selectionDigest(),attemptID:attempt,outcome:.success(deletedObjectCount:1),now:deletionTime+5) }
  let entry=try await ledger.entry(r.requestID);XCTAssertNil(entry.receipt);XCTAssertEqual(entry.phase,.executing);try await ledger.close()
 }
}
