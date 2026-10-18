import Foundation
import XCTest
@testable import CloudSync

final class CloudServiceTests: XCTestCase, @unchecked Sendable {
 func testTokenWaitsForAtomicBusinessImport() async throws {
  let ledgerURL = try tempCloudURL(), sinkURL = try tempCloudURL("fixture-business"), batch = try cloudBatch()
  let ledger = try SQLiteCloudLedger(url: ledgerURL), sink = try FixtureCloudSink(url: sinkURL,fault: .beforeToken)
  let driver = ControlledCloudDriver(batches: [batch])
  let service = CloudSyncService(scope: try cloudScope(),ledger: ledger,driver: driver,sink: sink,clock: { cloudTime })
  let outcome = try await service.synchronize(); XCTAssertEqual(outcome.issue,.storageUnavailable)
  let before = try await sink.appliedCursor(scope: cloudScope()), count = try await sink.factCount()
  XCTAssertNil(before.appliedToken); XCTAssertEqual(count,0)
  try await ledger.close(); try await sink.close()
  let reopened = try SQLiteCloudLedger(url: ledgerURL), recoveredSink = try FixtureCloudSink(url: sinkURL)
  let retained = try await reopened.batches(scope: cloudScope()); XCTAssertEqual(retained.first?.originalBytes,try batch.canonicalBytes())
  let resumed = CloudSyncService(scope: try cloudScope(),ledger: reopened,driver: driver,sink: recoveredSink,clock: { cloudTime.addingTimeInterval(3600) })
  _ = try await resumed.synchronize()
  let after = try await recoveredSink.appliedCursor(scope: cloudScope()), finalCount = try await recoveredSink.factCount()
  XCTAssertEqual(after.appliedToken,batch.nextToken); XCTAssertEqual(finalCount,2)
  let rows = try await reopened.batches(scope: cloudScope()); XCTAssertEqual(rows.first?.state,.confirmed)
  try await reopened.close(); try await recoveredSink.close()
 }
 func testLostImportAcknowledgementReplaysBeforeCursorCASAfterNewerBatch() async throws {
  let url = try tempCloudURL(), first = try cloudBatch(id:"first",next: Data([2,0,255]))
  let lost = try FixtureCloudSink(url:url,fault:.afterCommit)
  await expectCloudError(.storageUnavailable) { _ = try await lost.importBatch(first) }; try await lost.close()
  let sink = try FixtureCloudSink(url:url)
  let second = try cloudBatch(id:"second",parent:first.nextToken,next:Data([1,0]),records:[])
  _ = try await sink.importBatch(second)
  let replay = try await sink.importBatch(first); XCTAssertEqual(replay,try CloudImportAcknowledgement(batch:first))
  let cursor = try await sink.appliedCursor(scope:cloudScope()); XCTAssertEqual(cursor.appliedToken,second.nextToken)
  let count = try await sink.factCount(); XCTAssertEqual(count,2); try await sink.close()
 }
 func testDifferentBatchCannotRegressOpaqueParentToken() async throws {
  let sink = try FixtureCloudSink(url:tempCloudURL()), first = try cloudBatch(id:"first",next:Data([255]))
  _ = try await sink.importBatch(first)
  let stale = try cloudBatch(id:"different",next:Data([0]),records:[])
  await expectCloudError(.cursorMismatch) { _ = try await sink.importBatch(stale) }
  let cursor = try await sink.appliedCursor(scope:cloudScope()); XCTAssertEqual(cursor.appliedToken,Data([255])); try await sink.close()
 }
 func testResetGenerationCASRejectsDelayedBatchAndSurvivesReopen() async throws {
  let url = try tempCloudURL(), sink = try FixtureCloudSink(url:url), old = try cloudBatch()
  let reset = try await sink.resetCursor(scope:cloudScope(),expectedGeneration:0)
  XCTAssertEqual(reset.fetchGeneration,1); XCTAssertNil(reset.appliedToken)
  await expectCloudError(.staleGeneration) { _ = try await sink.resetCursor(scope:cloudScope(),expectedGeneration:0) }
  try await sink.close(); let reopened = try FixtureCloudSink(url:url)
  await expectCloudError(.staleGeneration) { _ = try await reopened.importBatch(old) }
  let current = try await reopened.appliedCursor(scope:cloudScope()); XCTAssertEqual(current,reset); try await reopened.close()
 }
 func testFetchUsesOnlyAtomicBusinessCursorAndRetainsRawOpaqueArchive() async throws {
  let sink = try FixtureCloudSink(url:tempCloudURL()), seed = try cloudBatch(id:"seed",next:Data([0,128,255,0]),records:[])
  _ = try await sink.importBatch(seed)
  let response = try cloudBatch(id:"next",parent:seed.nextToken,next:Data([8,3]),records:[])
  let driver = ControlledCloudDriver(batches:[response]), ledger = try SQLiteCloudLedger(url:tempCloudURL())
  let service = CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,sink:sink)
  _ = try await service.synchronize(); let calls = await driver.fetchRequests()
  XCTAssertEqual(calls,[try CloudCursor(appliedToken:seed.nextToken,fetchGeneration:0)])
  let batches = try await ledger.batches(scope:cloudScope()); XCTAssertEqual(batches.first?.batch,response)
  try await ledger.close(); try await sink.close()
 }
 func testDefaultSinkRetainsStagedBatchAndReportsAwaitingBusinessImport() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()), batch = try cloudBatch(), driver = ControlledCloudDriver()
  try await ledger.stage(batch)
  let service = CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver)
  let outcome = try await service.synchronize(); XCTAssertEqual(outcome.issue,.awaitingBusinessImport)
  let rows = try await ledger.batches(scope:cloudScope()), calls = await driver.fetchRequests()
  XCTAssertEqual(rows.first?.state,.pending); XCTAssertEqual(rows.first?.issue,.awaitingBusinessImport); XCTAssertTrue(calls.isEmpty)
  try await ledger.close()
 }
 func testStagedSameBatchIDChangedBytesIsRejectedAndReopenRetainsOriginal() async throws {
  let url = try tempCloudURL(), ledger = try SQLiteCloudLedger(url:url), batch = try cloudBatch()
  try await ledger.stage(batch)
  await expectCloudError(.identityConflict) { try await ledger.stage(cloudBatch(next:Data([99]))) }
  try await ledger.close(); let reopened = try SQLiteCloudLedger(url:url)
  let rows = try await reopened.batches(scope:cloudScope()); XCTAssertEqual(rows.first?.batch,batch); try await reopened.close()
 }
 func testStableZoneAllowsOldEpochReadButNeverRebindsPendingUpload() async throws {
  let current = try cloudScope(epoch:2), old = try cloudRecord()
  let batch = try cloudBatch(records:[old],scope:current)
  let sink = try FixtureCloudSink(url:tempCloudURL()),ledger = try SQLiteCloudLedger(url:tempCloudURL())
  let service = CloudSyncService(scope:current,ledger:ledger,driver:ControlledCloudDriver(batches:[batch]),sink:sink)
  let result = try await service.synchronize(); XCTAssertNil(result.issue)
  let count = try await sink.factCount(); XCTAssertEqual(count,1)
  XCTAssertEqual(current.stableZoneKey,old.scope.stableZoneKey)
  XCTAssertThrowsError(try CloudUpload(scope:current,record:old))
  let foreign = try CloudScope(accountID:"other",cloudSpaceID:"space",zoneID:"zone",activationEpoch:2)
  XCTAssertThrowsError(try cloudBatch(records:[old],scope:foreign))
  try await sink.close(); try await ledger.close()
 }
 func testStageFaultsRollbackOrRetainExactlyOriginalBatchAfterCommit() async throws {
  for fault in [CloudLedgerFault.beforeCommit,.afterCommitResponseLost] {
   let url = try tempCloudURL(),batch = try cloudBatch(),ledger = try SQLiteCloudLedger(url:url,fault:fault)
   await expectCloudError(.storageUnavailable) { try await ledger.stage(batch) }; try await ledger.close()
   let reopened = try SQLiteCloudLedger(url:url),rows = try await reopened.batches(scope:cloudScope())
   XCTAssertEqual(rows.count,fault == .beforeCommit ? 0:1)
   try await reopened.stage(batch); let retried = try await reopened.batches(scope:cloudScope())
   XCTAssertEqual(retried.first?.originalBytes,try batch.canonicalBytes()); try await reopened.close()
  }
 }
 func testMismatchedAcknowledgementCannotConfirmStagedBatch() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),batch = try cloudBatch()
  let sink = WrongAcknowledgementSink(ack:try CloudImportAcknowledgement(batch:cloudBatch(id:"other")))
  let service = CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:ControlledCloudDriver(batches:[batch]),sink:sink)
  let result = try await service.synchronize(); XCTAssertEqual(result.issue,.invalidPayload)
  let rows = try await ledger.batches(scope:cloudScope()); XCTAssertEqual(rows.first?.state,.blocked)
  XCTAssertEqual(rows.first?.originalBytes,try batch.canonicalBytes()); try await ledger.close()
 }
 func testSameBatchIDChangedDigestCannotReplayFirstBusinessReceipt() async throws {
  let sink = try FixtureCloudSink(url:tempCloudURL()),batch = try cloudBatch()
  _ = try await sink.importBatch(batch)
  await expectCloudError(.identityConflict) { _ = try await sink.importBatch(cloudBatch(next:Data([123]))) }
  let cursor = try await sink.appliedCursor(scope:cloudScope()); XCTAssertEqual(cursor.appliedToken,batch.nextToken); try await sink.close()
 }
 func testTwoFileConnectionsHaveOneParentTokenCASWinner() async throws {
  let url = try tempCloudURL(),a = try FixtureCloudSink(url:url),b = try FixtureCloudSink(url:url)
  let first = try cloudBatch(id:"a",next:Data([1]),records:[]),second = try cloudBatch(id:"b",next:Data([2]),records:[])
  let results = await withTaskGroup(of:Bool.self,returning:[Bool].self) { group in
   group.addTask { do { _ = try await a.importBatch(first); return true } catch { return false } }
   group.addTask { do { _ = try await b.importBatch(second); return true } catch { return false } }
   var values:[Bool] = []; for await value in group { values.append(value) }; return values
  }
  XCTAssertEqual(results.filter { $0 }.count,1)
  let cursor = try await a.appliedCursor(scope:cloudScope()); XCTAssertTrue([first.nextToken,second.nextToken].contains(cursor.appliedToken))
  try await a.close(); try await b.close()
 }

}


private struct WrongAcknowledgementSink: CloudCommitSink {
 let ack: CloudImportAcknowledgement
 func appliedCursor(scope:CloudScope) async throws -> CloudCursor { try CloudCursor(appliedToken:nil,fetchGeneration:0) }
 func resetCursor(scope:CloudScope,expectedGeneration:Int64) async throws -> CloudCursor { throw CloudError(.awaitingBusinessImport) }
 func importBatch(_ batch:CloudFetchBatch) async throws -> CloudImportAcknowledgement { ack }
}
