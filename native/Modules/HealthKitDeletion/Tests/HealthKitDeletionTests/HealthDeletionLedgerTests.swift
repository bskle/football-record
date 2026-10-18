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
}
