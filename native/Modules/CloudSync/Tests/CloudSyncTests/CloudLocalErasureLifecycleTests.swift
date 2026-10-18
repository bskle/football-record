import Foundation
import XCTest
@testable import CloudSync

let eraseTables = ["cloud_uploads","cloud_batches","cloud_conflicts","cloud_save_evidence"]
func eraseUpload(_ scope:CloudScope,match:String = "erased-match") throws -> CloudUpload {
 try CloudUpload(scope:scope,record:CloudRecord(scope:scope,payload:.matchFacts(cloudFacts(match:match))))
}
func eraseEvidence(_ upload:CloudUpload) throws -> DevelopmentCloudSaveEvidence {
 let readback = try completeCloudSave(upload)
 return try DevelopmentCloudSaveEvidence(upload:upload,readback:readback,manifest:CloudCodec.decode(CloudSaveManifest.self,readback.manifestBytes))
}
func canonicalSnapshot(_ url:URL,scope:CloudScope? = nil) throws -> [String:[[String]]] {
 let sql = try CloudSQL(url:url); defer { try? sql.close() }
 return try Dictionary(uniqueKeysWithValues:eraseTables.map { table in
  let rows = try sql.rows("SELECT * FROM " + table + (scope == nil ? "" : " WHERE scope=?") + " ORDER BY rowid",try scope.map { [.text(try $0.key)] } ?? [])
  return (table,rows.map { $0.map { value in
   switch value { case .text(let s):return "text:"+s; case .blob(let d):return "blob:"+d.base64EncodedString(); case .integer(let n):return "int:"+String(n); case .null:return "null" }
  } })
 })
}
func seedErasurePhases(_ ledger:SQLiteCloudLedger,scope:CloudScope) async throws {
 let upload = try eraseUpload(scope),blocked = try eraseUpload(scope,match:"blocked"),remote = blocked.record
 try await ledger.enqueue(upload); try await ledger.confirmUpload(eraseEvidence(upload))
 try await ledger.enqueue(blocked); try await ledger.retainConflict(CloudConflict(upload:blocked,remote:remote,changeTag:"remote-tag"))
 try await ledger.failUpload(id:blocked.id,issue:.conflict,at:cloudTime,nextAttemptAt:nil)
 let tombstone = try CloudRecord(scope:scope,payload:.deletion(CloudDeletion(matchID:"deleted",deletionID:"deletion",deletedAt:cloudTime)))
 try await ledger.enqueue(CloudUpload(scope:scope,record:tombstone))
 for (id,state) in [("pending",0),("blocked",1),("confirmed",2)] {
  let batch = try cloudBatch(id:id,records:[upload.record,tombstone],scope:scope)
  try await ledger.stage(batch)
  if state == 1 { try await ledger.failBatch(scope:scope,id:id,issue:.invalidPayload,at:cloudTime,nextAttemptAt:nil) }
  if state == 2 { try await ledger.acknowledge(CloudImportAcknowledgement(batch:batch)) }
 }
 try await ledger.recordScopeIssue(scope:scope,issue:.quotaExceeded,at:cloudTime,nextAttemptAt:nil)
}

final class CloudLocalErasureLifecycleTests: XCTestCase, @unchecked Sendable {
 func testExactStableZoneAcrossEpochsAndPhasesPreservesOtherScopesBytes() async throws {
  let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),scope = try cloudScope()
  let targets = try [cloudScope(),cloudScope(epoch:2),cloudScope(epoch:99)]
  let others = try [CloudScope(accountID:"other",cloudSpaceID:"space",zoneID:"zone",activationEpoch:1),CloudScope(accountID:"account",cloudSpaceID:"other",zoneID:"zone",activationEpoch:1),CloudScope(accountID:"account",cloudSpaceID:"space",zoneID:"other",activationEpoch:1)]
  for s in targets + others { try await seedErasurePhases(ledger,scope:s) }
  let originals = try others.map { try canonicalSnapshot(url,scope:$0) }
  let request = try CloudLocalTransportEraseRequest(requestID:"erase-all-epochs",scope:scope)
  let receipt = try await ledger.eraseLocalTransport(request)
  XCTAssertEqual(receipt.requestID,request.requestID); XCTAssertEqual(receipt.stableZoneKey,scope.stableZoneKey)
  for s in targets { XCTAssertTrue(try canonicalSnapshot(url,scope:s).values.allSatisfy(\.isEmpty)) }
  for (i,s) in others.enumerated() { XCTAssertEqual(try canonicalSnapshot(url,scope:s),originals[i]) }
  let replay = try await ledger.eraseLocalTransport(request); XCTAssertEqual(replay,receipt)
  try await ledger.close()
 }
 func testEmptyEraseReopensFirstReceiptAndRejectsReusedIntentID() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),request = try CloudLocalTransportEraseRequest(requestID:"empty",scope:scope)
  let ledger = try SQLiteCloudLedger(url:url),receipt = try await ledger.eraseLocalTransport(request); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),replay = try await reopened.eraseLocalTransport(request)
  XCTAssertEqual(receipt,replay)
  await expectCloudError(.identityConflict) { _ = try await reopened.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"empty",scope:cloudScope(epoch:2))) }
  let raw = try CloudSQL(url:url)
  XCTAssertEqual(try raw.rows("SELECT count(*) FROM cloud_local_erase_receipts").first?.first?.number,1)
  XCTAssertEqual(try raw.rows("SELECT count(*) FROM cloud_local_erase_fences").first?.first?.number,1)
  XCTAssertFalse(try raw.rows("PRAGMA table_info(cloud_local_erase_receipts)").contains { $0[1].string == "original" })
  try raw.close(); try await reopened.close()
 }
 func testBeforeCommitPreservesEveryCanonicalAndDoesNotFence() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),initial = try SQLiteCloudLedger(url:url)
  try await seedErasurePhases(initial,scope:scope); try await initial.close()
  let before = try canonicalSnapshot(url),file = try Data(contentsOf:url)
  let failing = try SQLiteCloudLedger(url:url,fault:.beforeCommit)
  await expectCloudError(.storageUnavailable) { _ = try await failing.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"rollback",scope:scope)) }
  try await failing.close(); XCTAssertEqual(try canonicalSnapshot(url),before); XCTAssertEqual(try Data(contentsOf:url),file)
  let inspect = try CloudSQL(url:url); XCTAssertTrue(try inspect.rows("SELECT * FROM cloud_local_erase_receipts").isEmpty); XCTAssertTrue(try inspect.rows("SELECT * FROM cloud_local_erase_fences").isEmpty); try inspect.close()
 }
 func testCommitResponseLostReopensAndReplaysSameReceipt() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),initial = try SQLiteCloudLedger(url:url)
  try await seedErasurePhases(initial,scope:scope); try await initial.close()
  let request = try CloudLocalTransportEraseRequest(requestID:"lost-response",scope:scope),lost = try SQLiteCloudLedger(url:url,fault:.afterCommitResponseLost)
  await expectCloudError(.storageUnavailable) { _ = try await lost.eraseLocalTransport(request) }; try await lost.close()
  let reopened = try SQLiteCloudLedger(url:url),first = try await reopened.eraseLocalTransport(request),second = try await reopened.eraseLocalTransport(request)
  XCTAssertEqual(first,second); XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty))
  let state = try await reopened.scopeState(scope:cloudScope(epoch:50)); XCTAssertEqual(state.issue,.accountChanged)
  try await reopened.close()
 }
 func testMalformedCanonicalOrAttributionRollsBackWithoutChangingFile() async throws {
  let edits = eraseTables.map { "UPDATE " + $0 + " SET original=x'0102'" } + [
   "UPDATE cloud_uploads SET scope='wrong-scope'","UPDATE cloud_uploads SET digest='wrong-digest'","UPDATE cloud_uploads SET issue='future-issue'",
   "UPDATE cloud_batches SET ack=x'0102' WHERE ack IS NOT NULL","UPDATE cloud_conflicts SET remote_digest='wrong-digest'","UPDATE cloud_save_evidence SET digest='wrong-digest'","UPDATE cloud_scope_state SET issue='future-issue'"]
  for edit in edits {
   let url = try tempCloudURL(),scope = try cloudScope(),initial = try SQLiteCloudLedger(url:url)
   try await seedErasurePhases(initial,scope:scope); try await initial.close()
   let raw = try CloudSQL(url:url); try raw.execute(edit); try raw.close()
   let before = try canonicalSnapshot(url),file = try Data(contentsOf:url),ledger = try SQLiteCloudLedger(url:url)
   await expectCloudError(.invalidPayload) { _ = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"bad-row",scope:scope)) }
   try await ledger.close(); XCTAssertEqual(try canonicalSnapshot(url),before); XCTAssertEqual(try Data(contentsOf:url),file)
  }
 }
 func testUnknownForeignRowCannotBeGuessedAway() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),other = try CloudScope(accountID:"other",cloudSpaceID:"space",zoneID:"zone",activationEpoch:1),ledger = try SQLiteCloudLedger(url:url)
  try await seedErasurePhases(ledger,scope:scope); try await ledger.enqueue(eraseUpload(other)); try await ledger.close()
  let raw = try CloudSQL(url:url); try raw.execute("UPDATE cloud_uploads SET original=x'0102' WHERE scope=?",[.text(try other.key)]); try raw.close()
  let before = try canonicalSnapshot(url),reopened = try SQLiteCloudLedger(url:url)
  await expectCloudError(.invalidPayload) { _ = try await reopened.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"unclassified",scope:scope)) }
  XCTAssertEqual(try canonicalSnapshot(url),before); try await reopened.close()
 }
 func testNulSuffixedAndInvalidUTF8ControlTextCannotProduceEraseReceipt() async throws {
  for edit in ["UPDATE cloud_uploads SET scope=scope||char(0)||'junk'","UPDATE cloud_uploads SET issue='conflict'||char(0)||'junk'","UPDATE cloud_uploads SET state=state||char(0)||'junk'","UPDATE cloud_uploads SET scope=CAST(CAST(scope AS BLOB)||x'ff' AS TEXT)"] {
   let url = try tempCloudURL(),scope = try cloudScope(),ledger = try SQLiteCloudLedger(url:url)
   try await seedErasurePhases(ledger,scope:scope); try await ledger.close()
   let raw = try CloudSQL(url:url); try raw.execute(edit)
   let before = try raw.rows("SELECT hex(original),hex(CAST(scope AS BLOB)),hex(CAST(issue AS BLOB)),hex(CAST(state AS BLOB)) FROM cloud_uploads").map { $0.map(\.string) }; try raw.close()
   let file = try Data(contentsOf:url),reopened = try SQLiteCloudLedger(url:url)
   await expectCloudError(.invalidPayload) { _ = try await reopened.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"text-corruption",scope:scope)) }
   try await reopened.close(); XCTAssertEqual(try Data(contentsOf:url),file)
   let inspect = try CloudSQL(url:url)
   XCTAssertEqual(try inspect.rows("SELECT hex(original),hex(CAST(scope AS BLOB)),hex(CAST(issue AS BLOB)),hex(CAST(state AS BLOB)) FROM cloud_uploads").map { $0.map(\.string) },before)
   XCTAssertTrue(try inspect.rows("SELECT * FROM cloud_local_erase_receipts").isEmpty); XCTAssertTrue(try inspect.rows("SELECT * FROM cloud_local_erase_fences").isEmpty); try inspect.close()
  }
 }
 func testTwoConnectionsFenceEveryLateMutationAndNeverUnfenceNewEpoch() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),first = try SQLiteCloudLedger(url:url),old = try SQLiteCloudLedger(url:url),upload = try eraseUpload(scope),batch = try cloudBatch(records:[upload.record],scope:scope)
  try await old.enqueue(upload); try await old.stage(batch)
  let evidence = try eraseEvidence(upload),ack = try CloudImportAcknowledgement(batch:batch),conflict = try CloudConflict(upload:upload,remote:upload.record,changeTag:"tag")
  _ = try await first.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"two-connections",scope:scope))
  await expectCloudError(.accountChanged) { try await old.enqueue(upload) }
  await expectCloudError(.accountChanged) { try await old.stage(batch) }
  await expectCloudError(.accountChanged) { try await old.retainConflict(conflict) }
  await expectCloudError(.accountChanged) { try await old.confirmUpload(evidence) }
  await expectCloudError(.accountChanged) { try await old.acknowledge(ack) }
  await expectCloudError(.accountChanged) { try await old.failBatch(scope:scope,id:batch.batchID,issue:.quotaExceeded,at:cloudTime,nextAttemptAt:nil) }
  await expectCloudError(.accountChanged) { try await old.recordScopeIssue(scope:scope,issue:.networkUnavailable,at:cloudTime,nextAttemptAt:nil) }
  await expectCloudError(.accountChanged) { try await old.clearScopeIssue(scope:scope) }
  await expectCloudError(.accountChanged) { try await old.enqueue(eraseUpload(cloudScope(epoch:999))) }
  XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await old.close(); try await first.close()
 }
 func testLateSaveSuccessAndConflictCannotReviveCanonical() async throws {
  for conflict in [false,true] {
   let url = try tempCloudURL(),scope = try cloudScope(),ledger = try SQLiteCloudLedger(url:url),eraser = try SQLiteCloudLedger(url:url),upload = try eraseUpload(scope),driver = ErasureGateDriver()
   try await ledger.enqueue(upload)
   let service = CloudSyncService(scope:scope,ledger:ledger,driver:driver),work = Task { try await service.synchronize() }
   await driver.waitUntilStarted(); _ = try await eraser.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"late-save",scope:scope))
   await driver.finishSave(conflict ? .conflict(recordID:upload.record.recordID,remote:upload.record,changeTag:"tag") : .complete(try completeCloudSave(upload)))
   let result = try await work.value; XCTAssertEqual(result.issue,.accountChanged)
   XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await ledger.close(); try await eraser.close()
  }
 }
 func testLateFetchCannotStageOrImport() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),ledger = try SQLiteCloudLedger(url:url),eraser = try SQLiteCloudLedger(url:url),sink = try FixtureCloudSink(url:tempCloudURL()),driver = ErasureGateDriver()
  let service = CloudSyncService(scope:scope,ledger:ledger,driver:driver,sink:sink),work = Task { try await service.synchronize() }
  await driver.waitUntilStarted(); _ = try await eraser.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"late-fetch",scope:scope))
  await driver.finishFetch(try cloudBatch())
  let result = try await work.value,facts = try await sink.factCount(); XCTAssertEqual(result.issue,.accountChanged); XCTAssertEqual(facts,0)
  XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await ledger.close(); try await eraser.close(); try await sink.close()
 }
 func testSaveAndFetchBeforeEraseAreRemovedThenNetworkRemainsStoppedAfterReopen() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),ledger = try SQLiteCloudLedger(url:url),driver = try ControlledCloudDriver(batches:[cloudBatch()]),sink = try FixtureCloudSink(url:tempCloudURL())
  try await ledger.enqueue(eraseUpload(scope)); let service = CloudSyncService(scope:scope,ledger:ledger,driver:driver,sink:sink)
  _ = try await service.synchronize(); _ = try await service.synchronize()
  XCTAssertFalse(try canonicalSnapshot(url)["cloud_save_evidence"]!.isEmpty); XCTAssertFalse(try canonicalSnapshot(url)["cloud_batches"]!.isEmpty)
  _ = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"callback-first",scope:scope)); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),newDriver = try ControlledCloudDriver(batches:[cloudBatch()])
  for s in [scope,try cloudScope(epoch:2)] { let result = try await CloudSyncService(scope:s,ledger:reopened,driver:newDriver,sink:sink).synchronize(); XCTAssertEqual(result.issue,.accountChanged) }
  let calls = await newDriver.savedAttempts(),fetches = await newDriver.fetchRequests(); XCTAssertEqual(calls,0); XCTAssertTrue(fetches.isEmpty)
  XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await reopened.close(); try await sink.close()
 }
 func testFreshNamespaceIsExplicitAndOldFileFencePersists() async throws {
  let scope = try cloudScope(),old = try SQLiteCloudLedger(url:tempCloudURL()),fresh = try SQLiteCloudLedger(url:tempCloudURL())
  _ = try await old.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"namespace",scope:scope))
  try await fresh.enqueue(eraseUpload(scope)); let rows = try await fresh.uploads(scope:scope); XCTAssertEqual(rows.count,1)
  await expectCloudError(.accountChanged) { try await old.enqueue(eraseUpload(scope)) }; try await old.close(); try await fresh.close()
 }
 func testDefaultOptionalEraserIsUnavailable() async throws {
  await expectCloudError(.storageUnavailable) { _ = try await UnavailableCloudLocalTransportEraser().eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"default",scope:cloudScope())) }
 }
 func testReceiptWithoutItsPersistentFenceCannotReplayOrResumeTransport() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),request = try CloudLocalTransportEraseRequest(requestID:"missing-fence",scope:scope),ledger = try SQLiteCloudLedger(url:url)
  _ = try await ledger.eraseLocalTransport(request); try await ledger.close()
  let raw = try CloudSQL(url:url); try raw.execute("DELETE FROM cloud_local_erase_fences"); try raw.close()
  let file = try Data(contentsOf:url),reopened = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
  await expectCloudError(.invalidPayload) { _ = try await reopened.eraseLocalTransport(request) }
  await expectCloudError(.invalidPayload) { _ = try await CloudSyncService(scope:scope,ledger:reopened,driver:driver).synchronize() }
  await expectCloudError(.invalidPayload) { try await reopened.enqueue(eraseUpload(scope)) }
  try await reopened.close(); XCTAssertEqual(try Data(contentsOf:url),file)
  let saves = await driver.savedAttempts(),fetches = await driver.fetchRequests(); XCTAssertEqual(saves,0); XCTAssertTrue(fetches.isEmpty)
 }
}

private actor ErasureGateDriver: CloudDriver {
 var started = false
 var waiters:[CheckedContinuation<Void,Never>] = []
 var saveResponse:CheckedContinuation<CloudSaveResult,Never>?
 var fetchResponse:CheckedContinuation<CloudFetchBatch,Never>?
 func begin() { started = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
 func waitUntilStarted() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
 func save(_ upload:CloudUpload) async -> CloudSaveResult { begin(); return await withCheckedContinuation { saveResponse = $0 } }
 func fetch(scope:CloudScope,cursor:CloudCursor) async -> CloudFetchBatch { begin(); return await withCheckedContinuation { fetchResponse = $0 } }
 func finishSave(_ result:CloudSaveResult) { saveResponse?.resume(returning:result); saveResponse = nil }
 func finishFetch(_ result:CloudFetchBatch) { fetchResponse?.resume(returning:result); fetchResponse = nil }
}
