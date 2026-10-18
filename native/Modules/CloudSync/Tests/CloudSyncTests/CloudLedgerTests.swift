import Foundation
import XCTest
import SQLite3
import MatchCore
import MatchStore
@testable import CloudSync

final class CloudLedgerTests: XCTestCase, @unchecked Sendable {
 func testStableSnapshotAndRawUploadSurviveReopen() async throws {
  let url = try tempCloudURL(), upload = try cloudUpload()
  XCTAssertEqual(upload, try cloudUpload())
  let ledger = try SQLiteCloudLedger(url: url)
  try await ledger.enqueue(upload); try await ledger.enqueue(upload); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url: url), entries = try await reopened.uploads(scope: cloudScope())
  XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].upload, upload)
  XCTAssertEqual(entries[0].originalBytes, try upload.canonicalBytes()); try await reopened.close()
 }
 func testSameIDWithDifferentBytesIsRejectedWithoutReplacingOriginal() async throws {
  let ledger = try SQLiteCloudLedger(url: tempCloudURL()), original = try cloudUpload(id: "same")
  try await ledger.enqueue(original)
  await expectCloudError(.identityConflict) { try await ledger.enqueue(cloudUpload(id: "same", match: "other")) }
  let entries = try await ledger.uploads(scope: cloudScope()); XCTAssertEqual(entries.map(\.upload), [original]); try await ledger.close()
 }
 func testDeletionTombstonesAndAttemptsSurviveReopen() async throws {
  let url = try tempCloudURL(), scope = try cloudScope()
  let payload = try CloudDeletion(matchID: "match", deletionID: "delete", deletedAt: cloudTime)
  let upload = try CloudUpload(scope: scope, record: CloudRecord(scope: scope, payload: .deletion(payload)), expectedChangeTag: "tag")
  let ledger = try SQLiteCloudLedger(url: url); try await ledger.enqueue(upload)
  try await ledger.failUpload(id: upload.id, issue: .quotaExceeded, at: cloudTime, nextAttemptAt: cloudTime.addingTimeInterval(30))
  try await ledger.close(); let reopened = try SQLiteCloudLedger(url: url)
  let persisted = try await reopened.uploads(scope: scope)
  let row = try XCTUnwrap(persisted.first)
  XCTAssertEqual(row.upload, upload); XCTAssertEqual(row.attemptCount, 1); XCTAssertEqual(row.issue, .quotaExceeded)
  XCTAssertEqual(row.nextAttemptAt, cloudTime.addingTimeInterval(30)); try await reopened.close()
 }
 func testBeforeCommitRollsBackAndAfterCommitResponseLossReplaysOriginal() async throws {
  for point in [CloudLedgerFault.beforeCommit, .afterCommitResponseLost] {
   let url = try tempCloudURL(), upload = try cloudUpload(), ledger = try SQLiteCloudLedger(url: url, fault: point)
   await expectCloudError(.storageUnavailable) { try await ledger.enqueue(upload) }; try await ledger.close()
   let reopened = try SQLiteCloudLedger(url: url), rows = try await reopened.uploads(scope: cloudScope())
   XCTAssertEqual(rows.count, point == .beforeCommit ? 0 : 1)
   try await reopened.enqueue(upload); let retried = try await reopened.uploads(scope: cloudScope())
   XCTAssertEqual(retried.count, 1); try await reopened.close()
  }
 }
 func testUnknownSchemaAndCorruptionPreserveOriginalFile() async throws {
  for corrupt in [false,true] {
   let url = try tempCloudURL()
   if corrupt { try Data("not a SQLite database".utf8).write(to: url) } else {
    var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil,nil,nil), SQLITE_OK); sqlite3_close(db)
   }
   let before = try Data(contentsOf: url)
   XCTAssertThrowsError(try SQLiteCloudLedger(url: url)); XCTAssertEqual(try Data(contentsOf: url), before)
  }
 }
 func testCloudQueueDoesNotDependOnAcknowledgedPeerOutbox() async throws {
  let scope = try cloudScope(), facts = try cloudFacts(), ledger = try SQLiteCloudLedger(url: tempCloudURL())
  let store = try MatchStore(url: tempCloudURL("business"), syncEnvironment: .development(databaseNamespace: "cloud-ledger-test"))
  let initial = MatchDescriptor(startIntent: facts.startIntent, starter: true)
  _ = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: initial, events: [], packets: []))
  let descriptor = MatchDescriptor(startIntent: facts.startIntent, starter: true, startPermit: DevelopmentStartFixture.permit(for: facts.startIntent), backendLockState: .held)
  let outbox = try BusinessOutboxItem(id: "peer-delta", matchID: "match", sourceDeviceID: "watch", payload: BusinessDeltaV2(descriptor: descriptor, events: facts.events, captureRevisions: []))
  _ = try await store.commitV2(StoreCommitV2(commandID: "facts", expectedGeneration: 1, descriptor: descriptor, events: facts.events, captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: [outbox]))
  let peer = try PeerAuthorization(localDeviceID: "watch", remoteDeviceID: "phone", accountSubject: "account", pairingID: "pair", trustEpoch: "epoch", environment: .development(databaseNamespace: "cloud-ledger-test"), issuedAt: cloudTime.addingTimeInterval(-1), expiresAt: cloudTime.addingTimeInterval(100))
  let routed = try await store.routeBusinessOutboxV3(outboxID: "peer-delta", peer: peer, now: cloudTime)
  try await store.acknowledgeV2(DurableACKV2(packet: routed.packet).canonicalBytes(), peer: peer, now: cloudTime)
  let peerPending = try await store.pendingPacketsV2(matchID: "match"); XCTAssertTrue(peerPending.isEmpty)
  try await store.close()
  try await ledger.enqueue(CloudUpload(scope: scope, record: CloudRecord(scope: scope, payload: .matchFacts(facts)), expectedChangeTag: nil))
  let uploads = try await ledger.uploads(scope: scope); XCTAssertEqual(uploads.count, 1); try await ledger.close()
 }
 func testStrictPayloadRejectsUnknownFieldsAndOversize() throws {
  let record = try cloudRecord(); var json = try XCTUnwrap(JSONSerialization.jsonObject(with: record.canonicalBytes) as? [String:Any])
  json["heartRate"] = 150; let bad = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  XCTAssertThrowsError(try CloudRecord(scope: cloudScope(), canonicalBytes: bad))
  XCTAssertThrowsError(try CloudRecord(scope: cloudScope(), canonicalBytes: Data(repeating: 0,count: 8*1024*1024+1)))
 }
 func testNearEightMiBTypedPayloadSurvivesEnvelopeReopen() async throws {
  let facts = try cloudFacts(), scope = try cloudScope(), url = try tempCloudURL()
  let goal = GoalPayload(scoreImpact: .forTeam, scoringTeamSnapshot: "team", note: String(repeating: "x",count: 8*1024*1024-6000))
  let event = MatchEvent(eventID: "large-note", matchID: "match", sequence: 3, occurredAt: cloudTime.addingTimeInterval(3), matchElapsed: 3, type: .scoreEvent, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime, goal: goal)
  let full = try CloudMatchFacts(startIntent: facts.startIntent, starter: true, events: facts.events + [event], captureRevisions: [])
  let record = try CloudRecord(scope: scope, payload: .matchFacts(full))
  XCTAssertGreaterThan(record.canonicalBytes.count, 8*1024*1024-10000)
  let upload = try CloudUpload(scope: scope,record: record), original = try upload.canonicalBytes()
  XCTAssertGreaterThan(original.count, 8*1024*1024)
  let ledger = try SQLiteCloudLedger(url: url); try await ledger.enqueue(upload); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url: url), rows = try await reopened.uploads(scope: scope)
  XCTAssertEqual(rows.first?.originalBytes, original); XCTAssertEqual(rows.first?.upload.record.canonicalBytes, record.canonicalBytes)
  try await reopened.close()
 }
 func testFiniteOutOfRangeRetryDateIsRejectedWithoutChangingRow() async throws {
  let ledger = try SQLiteCloudLedger(url: tempCloudURL()), upload = try cloudUpload()
  try await ledger.enqueue(upload)
  let invalid = Date(timeIntervalSince1970: Double(Int64.max)/1000*2)
  await expectCloudError(.invalidPayload) { try await ledger.failUpload(id: upload.id, issue: .quotaExceeded, at: invalid, nextAttemptAt: nil) }
  await expectCloudError(.invalidPayload) { try await ledger.failUpload(id: upload.id, issue: .quotaExceeded, at: cloudTime, nextAttemptAt: invalid) }
  let rows = try await ledger.uploads(scope: cloudScope()); XCTAssertEqual(rows.first?.attemptCount, 0); XCTAssertNil(rows.first?.issue)
  try await ledger.close()
 }

 func testIncompatibleVersionOneSchemaFailedOpenPreservesFileAndVersion() throws {
  for missingTable in [false,true] {
   let url = try tempCloudURL(),sql = try CloudSQL(url:url)
   if !missingTable { try sql.execute("CREATE TABLE cloud_uploads(id TEXT PRIMARY KEY,scope TEXT NOT NULL,digest TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL,issue TEXT,retry_ms INTEGER,attempted_ms INTEGER) STRICT") }
   try sql.execute("PRAGMA user_version=1"); try sql.close()
   let original = try Data(contentsOf:url)
   XCTAssertThrowsError(try SQLiteCloudLedger(url:url))
   XCTAssertEqual(try Data(contentsOf:url),original)
   let inspect = try CloudSQL(url:url)
   XCTAssertEqual(try inspect.rows("PRAGMA user_version").first?.first?.number,1)
   XCTAssertTrue(try inspect.rows("SELECT name FROM sqlite_master WHERE name IN ('cloud_batches','cloud_scope_state')").isEmpty)
   try inspect.close()
  }
 }

}
