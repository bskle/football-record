import Foundation
import XCTest
import SQLite3
@testable import HealthKitDeletion
final class HealthDeletionServiceTests: XCTestCase, @unchecked Sendable {
 func testUnconfirmedRequestNeverCallsDriver() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business),driver=ControlledDeletionDriver()
  _=try await ledger.submit(r);let service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  await expectIssue(.unconfirmed) { _=try await service.resume(r.requestID,timeout:.milliseconds(1)) }
  XCTAssertTrue(driver.calls.isEmpty);try await service.close()
 }
 func testAttemptIsCommittedBeforeDriverAndZeroIsScopedReceipt() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r)
  let observed=DeletionFaultSwitch()
  let driver=ControlledDeletionDriver(onCall:{ attempt in
   var db: OpaquePointer?;let opened=sqlite3_open_v2(paths.control.path,&db,SQLITE_OPEN_READONLY,nil)
   defer { sqlite3_close(db) };var statement: OpaquePointer?
   let prepared=sqlite3_prepare_v2(db,"SELECT phase,attempt_id,digest FROM health_deletion_requests",-1,&statement,nil)
   defer { sqlite3_finalize(statement) }
   if opened == SQLITE_OK,prepared == SQLITE_OK,sqlite3_step(statement) == SQLITE_ROW,
      String(cString:sqlite3_column_text(statement,0)) == "executing",
      String(cString:sqlite3_column_text(statement,1)) == attempt.attemptID.uuidString.lowercased(),
      String(cString:sqlite3_column_text(statement,2)) == attempt.selectionDigest { observed.arm(.finish,.afterCommitResponseLost) }
  })
  let service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  let result=Task { try await service.resume(r.requestID,timeout:.seconds(1)) }
  try await driver.waitForCalls(1);driver.answer(.success(deletedObjectCount:0))
  let entry=try await result.value;XCTAssertEqual(entry.phase,.succeededLocally);XCTAssertTrue(entry.receipt?.noMatchingObjectsInScope == true)
  XCTAssertNotNil(observed.take(.finish));XCTAssertEqual(entry.attemptCount,1);try await service.close()
 }
 func testTimeoutAndConcurrentResumeDoNotIssueDuplicateAttempt() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),driver=ControlledDeletionDriver()
  let service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  let first=Task { try await service.resume(r.requestID,timeout:.milliseconds(10)) };try await driver.waitForCalls(1)
  let concurrent=try await service.resume(r.requestID,timeout:.milliseconds(1));XCTAssertTrue([HealthDeletionPhase.executing,.awaitingOutcome].contains(concurrent.phase))
  let timed=try await first.value;XCTAssertEqual(timed.phase,.awaitingOutcome)
  _=try await service.resume(r.requestID,timeout:.milliseconds(1));XCTAssertEqual(driver.calls.count,1)
  driver.answer(.success(deletedObjectCount:1));try await eventually { try await ledger.entry(r.requestID).phase == .succeededLocally }
  driver.answer(.failure(.authorizationDenied));let final=try await ledger.entry(r.requestID);XCTAssertEqual(final.receipt?.deletedObjectCount,1)
  try await service.close()
 }
 func testReopenRetriesSameScopeAndIgnoresOldCallback() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),old=ControlledDeletionDriver()
  let service=HealthDeletionService(ledger:ledger,driver:old,clock:{deletionTime})
  _=try await service.resume(r.requestID,timeout:.milliseconds(1));try await service.close()
  let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
  let interrupted=try await reopened.entry(r.requestID);XCTAssertEqual(interrupted.phase,.interrupted)
  let next=ControlledDeletionDriver(),replacement=HealthDeletionService(ledger:reopened,driver:next,clock:{deletionTime})
  let result=Task { try await replacement.resume(r.requestID,timeout:.seconds(1)) };try await next.waitForCalls(1)
  old.answer(.success(deletedObjectCount:1));next.answer(.success(deletedObjectCount:0))
  let final=try await result.value;XCTAssertEqual(final.receipt?.deletedObjectCount,0);XCTAssertEqual(final.attemptCount,2)
  XCTAssertEqual(try old.calls[0].request.canonicalBytes(),try next.calls[0].request.canonicalBytes())
  XCTAssertNotEqual(old.calls[0].attemptID,next.calls[0].attemptID);try await replacement.close()
 }
 func testInvalidCountsAndPermissionFailuresRemainHealthOnly() async throws {
  for outcome in [HealthDeletionDriverOutcome.success(deletedObjectCount:-1),.success(deletedObjectCount:2),.failure(.authorizationDenied),.failure(.authorizationNotDetermined)] {
   let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),driver=ControlledDeletionDriver()
   let service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
   let result=Task { try await service.resume(r.requestID,timeout:.seconds(1)) };try await driver.waitForCalls(1);driver.answer(outcome)
   let entry=try await result.value;XCTAssertEqual(entry.phase,.failed);XCTAssertNil(entry.receipt)
   if case .failure(let issue)=outcome { XCTAssertEqual(entry.issue,issue) } else { XCTAssertEqual(entry.issue,.invalidResponse) }
   try await service.close()
  }
 }
 func testDefaultDriverIsUnavailable() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r)
  let service=HealthDeletionService(ledger:ledger,clock:{deletionTime})
  let entry=try await service.resume(r.requestID,timeout:.seconds(1));XCTAssertEqual(entry.phase,.failed);XCTAssertEqual(entry.issue,.unavailable)
  try await service.close()
 }
 func testCallbackCommitFailureReopensUnknownAndRetryZeroDoesNotInventCount() async throws {
  let paths=try deletionPaths(),r=try request(),fault=DeletionFaultSwitch()
  let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business,fault:{fault.take($0)})
  _=try await ledger.submit(r);_=try await ledger.confirm(confirmation(r),now:deletionTime)
  let driver=ControlledDeletionDriver(),service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  let first=Task { try await service.resume(r.requestID,timeout:.seconds(1)) };try await driver.waitForCalls(1)
  fault.arm(.finish,.beforeCommit);driver.answer(.success(deletedObjectCount:1));_=try await first.value;try await service.close()
  let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business),next=ControlledDeletionDriver()
  let replacement=HealthDeletionService(ledger:reopened,driver:next,clock:{deletionTime})
  let second=Task { try await replacement.resume(r.requestID,timeout:.seconds(1)) };try await next.waitForCalls(1);next.answer(.success(deletedObjectCount:0))
  let result=try await second.value;XCTAssertEqual(result.receipt?.deletedObjectCount,0);XCTAssertEqual(result.attemptCount,2);try await replacement.close()
 }

 func testBeginCommitFaultNeverCallsSDKAndReopensOriginalScope() async throws {
  for point in [DeletionFault.beforeCommit,.afterCommitResponseLost] {
   let paths=try deletionPaths(),r=try request(),fault=DeletionFaultSwitch()
   let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business,fault:{fault.take($0)})
   _=try await ledger.submit(r);_=try await ledger.confirm(confirmation(r),now:deletionTime)
   let driver=ControlledDeletionDriver(),service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
   fault.arm(.beginAttempt,point)
   await expectIssue(.storageUnavailable) { _=try await service.resume(r.requestID,timeout:.milliseconds(1)) }
   XCTAssertTrue(driver.calls.isEmpty);try await service.close()
   let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business),next=ControlledDeletionDriver()
   let replacement=HealthDeletionService(ledger:reopened,driver:next,clock:{deletionTime})
   let done=Task { try await replacement.resume(r.requestID,timeout:.seconds(1)) };try await next.waitForCalls(1);next.answer(.success(deletedObjectCount:0))
   let entry=try await done.value;XCTAssertEqual(entry.phase,.succeededLocally);XCTAssertEqual(try entry.request.canonicalBytes(),try r.canonicalBytes());try await replacement.close()
  }
 }
 func testCallbackCommitResponseLossPreservesFirstReceiptAfterReopen() async throws {
  let paths=try deletionPaths(),r=try request(),fault=DeletionFaultSwitch()
  let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business,fault:{fault.take($0)})
  _=try await ledger.submit(r);_=try await ledger.confirm(confirmation(r),now:deletionTime)
  let driver=ControlledDeletionDriver(),service=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  let done=Task { try await service.resume(r.requestID,timeout:.seconds(1)) };try await driver.waitForCalls(1)
  fault.arm(.finish,.afterCommitResponseLost);driver.answer(.success(deletedObjectCount:1))
  let first=try await done.value;XCTAssertEqual(first.receipt?.deletedObjectCount,1);try await service.close()
  let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business),next=ControlledDeletionDriver()
  let replacement=HealthDeletionService(ledger:reopened,driver:next,clock:{deletionTime})
  let second=try await replacement.resume(r.requestID);XCTAssertEqual(first.receipt,second.receipt);XCTAssertTrue(next.calls.isEmpty);try await replacement.close()
 }
 func testTwoServicesSharingOneLedgerIssueOnlyOneAttempt() async throws {
  let paths=try deletionPaths(),r=try request(),ledger=try await confirmedLedger(paths,r),driver=ControlledDeletionDriver()
  let a=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime}),b=HealthDeletionService(ledger:ledger,driver:driver,clock:{deletionTime})
  let x=Task { try await a.resume(r.requestID,timeout:.seconds(1)) },y=Task { try await b.resume(r.requestID,timeout:.seconds(1)) }
  try await driver.waitForCalls(1);driver.answer(.success(deletedObjectCount:1));_=try await x.value;_=try await y.value
  XCTAssertEqual(driver.calls.count,1);let entry=try await ledger.entry(r.requestID);XCTAssertEqual(entry.attemptCount,1);try await a.close()
 }
}
