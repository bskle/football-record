import Foundation
import XCTest
@testable import CloudSync

final class CloudLocalTransportErasureTests: XCTestCase, @unchecked Sendable {
 private func installFence(_ url:URL,scope:CloudScope) throws {
  let sql = try CloudSQL(url:url)
  try sql.execute("CREATE TABLE IF NOT EXISTS cloud_local_erase_fences(stable_zone TEXT PRIMARY KEY) STRICT")
  try sql.execute("INSERT INTO cloud_local_erase_fences(stable_zone) VALUES(?)",[.text(scope.stableZoneKey)])
  try sql.close()
 }
 func testPersistentStableFenceBlocksPreviouslyUnseenEpoch() async throws {
  let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),scope = try cloudScope()
  try installFence(url,scope:scope)
  let current = try await ledger.scopeState(scope:scope),future = try await ledger.scopeState(scope:cloudScope(epoch:100))
  XCTAssertEqual(current.issue,.accountChanged); XCTAssertEqual(future.issue,.accountChanged)
  await expectCloudError(.accountChanged) { try await ledger.clearScopeIssue(scope:scope) }
  try await ledger.close()
 }
 func testPersistentFenceGuardsCanonicalInsertTransactions() async throws {
  let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),upload = try cloudUpload()
  let remote = try CloudRecord(scope:upload.scope,payload:.matchFacts(cloudFacts(match:"remote")))
  let conflict = try CloudConflict(upload:upload,remote:remote,changeTag:"remote-tag")
  try installFence(url,scope:upload.scope)
  await expectCloudError(.accountChanged) { try await ledger.enqueue(upload) }
  await expectCloudError(.accountChanged) { try await ledger.retainConflict(conflict) }
  await expectCloudError(.accountChanged) { try await ledger.stage(cloudBatch()) }
  let uploads = try await ledger.uploads(scope:upload.scope),conflicts = try await ledger.conflicts(scope:upload.scope),batches = try await ledger.batches(scope:upload.scope)
  XCTAssertTrue(uploads.isEmpty); XCTAssertTrue(conflicts.isEmpty); XCTAssertTrue(batches.isEmpty)
  try await ledger.close()
 }
}
