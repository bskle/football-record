import Foundation
import XCTest
@testable import CloudSync

final class CloudAccountCheckpointTests: XCTestCase, @unchecked Sendable {
 private let controlID = UUID(uuidString:"00000000-0000-0000-0000-000000000031")!
 private func accountCheckpoint(_ scope:CloudScope,refs:[String] = []) throws -> CloudCheckpoint {
  try CloudCheckpoint.account(scope:scope,checkpointID:controlID,recordIDs:refs)
 }

 func testEmptyAccountCheckpointSavesAndReopensWithoutBusinessFacts() async throws {
  let scope = try cloudScope(),checkpoint = try accountCheckpoint(scope),url = try tempCloudURL("empty-account")
  let record = try CloudRecord(scope:scope,payload:.checkpoint(checkpoint)),upload = try CloudUpload(scope:scope,record:record)
  let original = try upload.canonicalBytes(),ledger = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
  try await ledger.enqueue(upload)
  let result = try await CloudSyncService(scope:scope,ledger:ledger,driver:driver).synchronize(); XCTAssertNil(result.issue)
  try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url); try await reopened.enqueue(upload)
  let entries = try await reopened.uploads(scope:scope),evidence = try await reopened.saveEvidence(scope:scope)
  XCTAssertEqual(entries.count,1); XCTAssertEqual(entries.first?.state,.confirmed)
  XCTAssertEqual(entries.first?.originalBytes,original); XCTAssertEqual(entries.first?.upload.record,record)
  guard case .checkpoint(let restored) = try XCTUnwrap(entries.first).upload.record.payload else { return XCTFail("only a control checkpoint is allowed") }
  XCTAssertTrue(restored.recordIDs.isEmpty); XCTAssertEqual(restored,checkpoint)
  XCTAssertEqual(evidence.count,1); XCTAssertNil(evidence.first?.terminalEventID)
  XCTAssertNotEqual(upload.checkpointID,checkpoint.checkpointID); XCTAssertNotEqual(upload.checkpointID,record.recordID)
  let calls = await driver.savedAttempts(),fetches = await driver.fetchRequests()
  XCTAssertEqual(calls,1); XCTAssertTrue(fetches.isEmpty)
  let batches = try await reopened.batches(scope:scope); XCTAssertTrue(batches.isEmpty)
  try await reopened.close()
 }

 func testAccountCheckpointReferencesConfirmedFactsWithoutRewritingThem() async throws {
  let scope = try cloudScope(),url = try tempCloudURL("populated-account"),ledger = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
  let service = CloudSyncService(scope:scope,ledger:ledger,driver:driver)
  let facts = try [cloudUpload(match:"first"),cloudUpload(match:"second")]
  for upload in facts { try await ledger.enqueue(upload); _ = try await service.synchronize() }
  let confirmed = try await ledger.uploads(scope:scope); XCTAssertEqual(confirmed.filter { $0.state == .confirmed }.count,2)
  let refs = confirmed.map { $0.upload.record.recordID }.sorted(),checkpoint = try accountCheckpoint(scope,refs:refs.reversed())
  XCTAssertEqual(checkpoint.recordIDs,refs)
  let control = try CloudUpload(scope:scope,record:CloudRecord(scope:scope,payload:.checkpoint(checkpoint)))
  try await ledger.enqueue(control); _ = try await service.synchronize(); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),after = try await reopened.uploads(scope:scope)
  XCTAssertEqual(after.count,3)
  for original in facts { XCTAssertEqual(after.first { $0.upload.id == original.id }?.originalBytes,try original.canonicalBytes()) }
  let restored = try XCTUnwrap(after.first { $0.upload.id == control.id }); XCTAssertEqual(restored.upload.record.digest,control.record.digest)
  guard case .checkpoint(let decoded) = try restored.upload.record.payload else { return XCTFail("checkpoint expected") }
  XCTAssertEqual(decoded.recordIDs,refs); try await reopened.close()
 }

 func testAccountAnchorRejectsWrongHashAndOtherStableScopes() throws {
  let scope = try cloudScope(),checkpoint = try accountCheckpoint(scope,refs:["known-record"])
  let wrong = try CloudCheckpoint(matchID:"account-checkpoint:"+String(repeating:"0",count:64),checkpointID:controlID.uuidString.lowercased(),recordIDs:["known-record"])
  XCTAssertThrowsError(try CloudRecord(scope:scope,payload:.checkpoint(wrong)))
  for foreign in [try CloudScope(accountID:"other",cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:1),try CloudScope(accountID:scope.accountID,cloudSpaceID:"other",zoneID:scope.zoneID,activationEpoch:1),try CloudScope(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:"other",activationEpoch:1)] {
   XCTAssertThrowsError(try CloudRecord(scope:foreign,payload:.checkpoint(checkpoint)))
  }
  let nextEpoch = try cloudScope(epoch:2)
  XCTAssertNoThrow(try CloudRecord(scope:nextEpoch,payload:.checkpoint(checkpoint)))
 }

 func testRawRecordAndBatchDecodingRejectForeignAccountAnchor() throws {
  let scope = try cloudScope(),checkpoint = try accountCheckpoint(scope,refs:["known-record"])
  let record = try CloudRecord(scope:scope,payload:.checkpoint(checkpoint)),foreign = try CloudScope(accountID:"foreign",cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:1)
  XCTAssertThrowsError(try CloudRecord(scope:foreign,canonicalBytes:record.canonicalBytes))
  // Recompute the outer identity for the foreign scope so checksum failure cannot mask anchor validation.
  var rawRecord = try XCTUnwrap(JSONSerialization.jsonObject(with:CloudCodec.encode(record)) as? [String:Any])
  rawRecord["scope"] = try JSONSerialization.jsonObject(with:CloudCodec.encode(foreign))
  rawRecord["recordID"] = try CloudCodec.hash([foreign.stableZoneKey,"CheckpointV1",checkpoint.matchID,record.digest],domain:"record-id")
  XCTAssertThrowsError(try JSONDecoder().decode(CloudRecord.self,from:JSONSerialization.data(withJSONObject:rawRecord)))
  let batch = try cloudBatch(records:[record],scope:scope)
  var rawBatch = try XCTUnwrap(JSONSerialization.jsonObject(with:batch.canonicalBytes()) as? [String:Any])
  rawBatch["scope"] = try JSONSerialization.jsonObject(with:CloudCodec.encode(foreign)); rawBatch["records"] = [rawRecord]
  XCTAssertThrowsError(try JSONDecoder().decode(CloudFetchBatch.self,from:JSONSerialization.data(withJSONObject:rawBatch)))
 }

 func testOrdinaryMatchStillRequiresReferencesAndAccountControlUUIDIsValidated() throws {
  let scope = try cloudScope(),anchor = CloudCheckpoint.accountMatchID(for:scope)
  XCTAssertThrowsError(try CloudCheckpoint(matchID:"ordinary-match",checkpointID:"legacy-checkpoint",recordIDs:[]))
  XCTAssertThrowsError(try accountCheckpoint(scope,refs:["same","same"]))
  XCTAssertThrowsError(try CloudCheckpoint(matchID:anchor,checkpointID:"not-a-control-uuid",recordIDs:["known-record"]))
  XCTAssertThrowsError(try CloudCheckpoint(matchID:"account-checkpoint:wrong-hash",checkpointID:controlID.uuidString.lowercased(),recordIDs:["known-record"]))
 }

 func testLegacyMatchCheckpointKeepsCanonicalBytesIdentityAndDigest() async throws {
  let scope = try cloudScope(),checkpoint = try CloudCheckpoint(matchID:"legacy-match",checkpointID:"legacy-checkpoint",recordIDs:["record-b","record-a"])
  let record = try CloudRecord(scope:scope,payload:.checkpoint(checkpoint))
  let expected = Data(#"{"checkpoint":{"_0":{"checkpointID":"legacy-checkpoint","matchID":"legacy-match","recordIDs":["record-a","record-b"]}}}"#.utf8)
  XCTAssertEqual(record.canonicalBytes,expected)
  let upload = try CloudUpload(scope:scope,record:record),url = try tempCloudURL("legacy-checkpoint"),ledger = try SQLiteCloudLedger(url:url)
  try await ledger.enqueue(upload); try await ledger.enqueue(upload); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),entries = try await reopened.uploads(scope:scope)
  XCTAssertEqual(entries.count,1); XCTAssertEqual(entries.first?.originalBytes,try upload.canonicalBytes())
  XCTAssertEqual(entries.first?.upload.record.canonicalBytes,expected)
  XCTAssertEqual(entries.first?.upload.record.recordID,record.recordID); XCTAssertEqual(entries.first?.upload.record.digest,record.digest)
  try await reopened.close()
 }
}
