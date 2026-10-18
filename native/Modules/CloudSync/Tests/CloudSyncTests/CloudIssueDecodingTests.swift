import Foundation
import XCTest
@testable import CloudSync

final class CloudIssueDecodingTests: XCTestCase, @unchecked Sendable {
 func testUnknownScopeIssueCannotResumePreviouslyPausedTransport() async throws {
  try await assertUnknownIssueFailsClosed(table: "cloud_scope_state")
 }
 func testUnknownUploadIssueFailsClosedAndPreservesOriginalBytes() async throws {
  try await assertUnknownIssueFailsClosed(table: "cloud_uploads")
 }
 func testUnknownBatchIssueFailsClosedBeforeBusinessImport() async throws {
  try await assertUnknownIssueFailsClosed(table: "cloud_batches")
 }

 private func assertUnknownIssueFailsClosed(table: String) async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),upload = try cloudUpload(),batch = try cloudBatch()
  let initial = try SQLiteCloudLedger(url:url)
  if table == "cloud_batches" {
   try await initial.stage(batch)
   try await initial.failBatch(scope:scope,id:batch.batchID,issue:.storageUnavailable,at:cloudTime,nextAttemptAt:nil)
  } else {
   try await initial.enqueue(upload)
   if table == "cloud_uploads" { try await initial.failUpload(id:upload.id,issue:.quotaExceeded,at:cloudTime,nextAttemptAt:nil) }
   else { try await initial.recordScopeIssue(scope:scope,issue:.accountChanged,at:cloudTime,nextAttemptAt:nil) }
  }
  try await initial.close()
  let raw = try CloudSQL(url:url)
  try raw.execute("UPDATE " + table + " SET issue=?",[.text("future-unknown-issue")])
  XCTAssertEqual(try raw.rows("PRAGMA user_version").first?.first?.number,3)
  XCTAssertEqual(try raw.rows("PRAGMA quick_check(1)").first?.first?.string,"ok")
  let originalUploads = try raw.rows("SELECT original FROM cloud_uploads").compactMap { $0.first?.data }
  let originalBatches = try raw.rows("SELECT original FROM cloud_batches").compactMap { $0.first?.data }
  try raw.close()
  let originalFile = try Data(contentsOf:url)

  let reopened = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver(batches:[batch]),sink = try FixtureCloudSink(url:tempCloudURL())
  let service = CloudSyncService(scope:scope,ledger:reopened,driver:driver,sink:sink,clock:{cloudTime.addingTimeInterval(3600)})
  await expectCloudError(.invalidPayload) { _ = try await service.synchronize() }
  if table == "cloud_scope_state" { await expectCloudError(.invalidPayload) { _ = try await reopened.scopeState(scope:scope) } }
  else if table == "cloud_uploads" { await expectCloudError(.invalidPayload) { _ = try await reopened.uploads(scope:scope) } }
  else { await expectCloudError(.invalidPayload) { _ = try await reopened.batches(scope:scope) } }
  let fetches = await driver.fetchRequests(),saves = await driver.savedAttempts(),facts = try await sink.factCount()
  XCTAssertTrue(fetches.isEmpty); XCTAssertEqual(saves,0); XCTAssertEqual(facts,0)
  try await reopened.close(); try await sink.close()

  XCTAssertEqual(try Data(contentsOf:url),originalFile)
  let inspect = try CloudSQL(url:url)
  XCTAssertEqual(try inspect.rows("SELECT original FROM cloud_uploads").compactMap { $0.first?.data },originalUploads)
  XCTAssertEqual(try inspect.rows("SELECT original FROM cloud_batches").compactMap { $0.first?.data },originalBatches)
  XCTAssertEqual(try inspect.rows("SELECT issue FROM " + table).first?.first?.string,"future-unknown-issue")
  XCTAssertTrue(try inspect.rows("SELECT original FROM cloud_save_evidence").isEmpty)
  try inspect.close()
 }
}
