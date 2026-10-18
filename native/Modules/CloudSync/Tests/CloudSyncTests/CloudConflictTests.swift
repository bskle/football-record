import Foundation
import XCTest
import MatchCore
@testable import CloudSync

final class CloudConflictTests:XCTestCase,@unchecked Sendable {
 func testConflictPreservesBothOriginalFactsAndChangeTagsAcrossReopen() async throws {
  let url = try tempCloudURL(),upload = try cloudUpload(),remote = try cloudRecord(match:"remote")
  let ledger = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
  try await ledger.enqueue(upload)
  await driver.configureSave(response:.conflict(recordID:upload.record.recordID,remote:remote,changeTag:"remote-tag"))
  let service = CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,clock:{cloudTime})
  let result = try await service.synchronize(); XCTAssertEqual(result.issue,.conflict)
  try await ledger.close(); let reopened = try SQLiteCloudLedger(url:url)
  let conflicts = try await reopened.conflicts(scope:cloudScope()),rows = try await reopened.uploads(scope:cloudScope())
  XCTAssertEqual(conflicts.count,1); XCTAssertEqual(conflicts.first?.localBytes,upload.record.canonicalBytes)
  XCTAssertEqual(conflicts.first?.remoteBytes,remote.canonicalBytes); XCTAssertEqual(conflicts.first?.remoteChangeTag,"remote-tag")
  XCTAssertEqual(rows.first?.state,.blocked); XCTAssertEqual(rows.first?.upload,upload)
  let evidence = try await reopened.saveEvidence(scope:cloudScope()); XCTAssertTrue(evidence.isEmpty); try await reopened.close()
 }
 func testPartialSaveNeverConfirmsOrCreatesEvidence() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver()
  try await ledger.enqueue(upload); await driver.configureSave(response:.partial([]))
  let result = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,clock:{cloudTime}).synchronize()
  XCTAssertEqual(result.issue,.partialSave)
  let rows = try await ledger.uploads(scope:cloudScope()),evidence = try await ledger.saveEvidence(scope:cloudScope())
  XCTAssertEqual(rows.first?.state,.pending); XCTAssertEqual(rows.first?.attemptCount,1); XCTAssertTrue(evidence.isEmpty); try await ledger.close()
 }
 func testQuotaBackoffPersistsAndDoesNotRetryBeforeDueAfterReopen() async throws {
  let url = try tempCloudURL(),upload = try cloudUpload(),driver = ControlledCloudDriver()
  await driver.configureSave(issue:.quotaExceeded)
  let ledger = try SQLiteCloudLedger(url:url); try await ledger.enqueue(upload)
  _ = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,clock:{cloudTime}).synchronize()
  try await ledger.close(); let reopened = try SQLiteCloudLedger(url:url),rows = try await reopened.uploads(scope:cloudScope())
  XCTAssertEqual(rows.first?.issue,.quotaExceeded); XCTAssertEqual(rows.first?.nextAttemptAt,cloudTime.addingTimeInterval(60))
  _ = try await CloudSyncService(scope:try cloudScope(),ledger:reopened,driver:driver,clock:{cloudTime.addingTimeInterval(1)}).synchronize()
  let countBefore = await driver.savedAttempts(); XCTAssertEqual(countBefore,1)
  _ = try await CloudSyncService(scope:try cloudScope(),ledger:reopened,driver:driver,clock:{cloudTime.addingTimeInterval(61)}).synchronize()
  let countAfter = await driver.savedAttempts(); XCTAssertEqual(countAfter,2); try await reopened.close()
 }
 func testAccountChangedPersistentlyStopsBothUploadAndFetch() async throws {
  let url = try tempCloudURL(),driver = ControlledCloudDriver(),ledger = try SQLiteCloudLedger(url:url)
  try await ledger.enqueue(cloudUpload()); await driver.configureSave(issue:.accountChanged)
  let first = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize(); XCTAssertEqual(first.issue,.accountChanged)
  try await ledger.close(); let reopened = try SQLiteCloudLedger(url:url)
  let second = try await CloudSyncService(scope:try cloudScope(),ledger:reopened,driver:driver).synchronize(); XCTAssertEqual(second.issue,.accountChanged)
  let saves = await driver.savedAttempts(),fetches = await driver.fetchRequests(); XCTAssertEqual(saves,1); XCTAssertTrue(fetches.isEmpty)
  try await reopened.close()
 }
 func testTokenExpiredResetPreservesPendingUploadAndExplicitTombstone() async throws {
  let sink = try FixtureCloudSink(url:tempCloudURL()),scope = try cloudScope()
  let deletion = try CloudRecord(scope:scope,payload:.deletion(CloudDeletion(matchID:"deleted",deletionID:"delete",deletedAt:cloudTime)))
  _ = try await sink.importBatch(cloudBatch(id:"deletion",next:Data([9]),records:[deletion]))
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload()
  try await ledger.enqueue(upload); try await ledger.failUpload(id:upload.id,issue:.quotaExceeded,at:cloudTime,nextAttemptAt:cloudTime.addingTimeInterval(100))
  let old = try cloudBatch(id:"old",parent:Data([9]),records:[]); try await ledger.stage(old)
  try await ledger.failBatch(scope:scope,id:old.batchID,issue:.staleGeneration,at:cloudTime,nextAttemptAt:nil)
  let driver = ControlledCloudDriver(fetchIssue:.changeTokenExpired)
  let result = try await CloudSyncService(scope:scope,ledger:ledger,driver:driver,sink:sink,clock:{cloudTime}).synchronize()
  XCTAssertEqual(result.issue,.changeTokenExpired)
  let cursor = try await sink.appliedCursor(scope:scope); XCTAssertNil(cursor.appliedToken); XCTAssertEqual(cursor.fetchGeneration,1)
  await expectCloudError(.staleGeneration) { _ = try await sink.importBatch(old) }
  let uploads = try await ledger.uploads(scope:scope),batches = try await ledger.batches(scope:scope),count = try await sink.factCount()
  XCTAssertEqual(uploads.first?.upload,upload); XCTAssertEqual(batches.count,1); XCTAssertEqual(count,1)
  try await ledger.close(); try await sink.close()
 }
 func testRemoteAbsenceNeverDeletesAndExplicitTombstoneNeverResurrects() async throws {
  let sink = try FixtureCloudSink(url:tempCloudURL()),scope = try cloudScope(),record = try cloudRecord()
  _ = try await sink.importBatch(cloudBatch(id:"original",next:Data([1]),records:[record]))
  _ = try await sink.importBatch(cloudBatch(id:"empty-full-scan",parent:Data([1]),next:Data([2]),records:[]))
  let visible = try await sink.visibleMatchCount(); XCTAssertEqual(visible,1)
  let deletion = try CloudRecord(scope:scope,payload:.deletion(CloudDeletion(matchID:"match",deletionID:"delete",deletedAt:cloudTime)))
  _ = try await sink.importBatch(cloudBatch(id:"tombstone",parent:Data([2]),next:Data([3]),records:[deletion]))
  _ = try await sink.importBatch(cloudBatch(id:"late-original",parent:Data([3]),next:Data([4]),records:[record]))
  let final = try await sink.visibleMatchCount(); XCTAssertEqual(final,0); try await sink.close()
 }
 func testCompleteReadbackEvidenceIsDevelopmentOnlyAndBoundToExactSnapshot() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver()
  try await ledger.enqueue(upload)
  let result = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize(); XCTAssertNil(result.issue)
  let rows = try await ledger.uploads(scope:cloudScope()),evidence = try await ledger.saveEvidence(scope:cloudScope())
  XCTAssertEqual(rows.first?.state,.confirmed); XCTAssertEqual(evidence.count,1)
  XCTAssertEqual(evidence.first?.boundary,"controlledDevelopmentTransport")
  XCTAssertEqual(evidence.first?.terminalEventID,"end-match"); XCTAssertTrue(try XCTUnwrap(evidence.first).matches(upload))
  XCTAssertFalse(try XCTUnwrap(evidence.first).matches(cloudUpload(match:"changed")))
  try await ledger.close()
 }
 func testWrongReadbackOrSavePolicyDoesNotCreateEvidence() async throws {
  for wrongPolicy in [false,true] {
   let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver()
   try await ledger.enqueue(upload)
   let readback = try completeCloudSave(upload,condition:wrongPolicy ? .unconditional:.ifServerRecordUnchanged,readBack:wrongPolicy ? nil:Data([8,7]))
   await driver.configureSave(response:.complete(readback))
   let result = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize(); XCTAssertEqual(result.issue,.invalidPayload)
   let evidence = try await ledger.saveEvidence(scope:cloudScope()); XCTAssertTrue(evidence.isEmpty); try await ledger.close()
  }
 }
 func testUnknownFetchFailureIsDurableAndNeverMeansEmptySynchronizedLibrary() async throws {
  let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),sink = try FixtureCloudSink(url:tempCloudURL())
  let driver = ControlledCloudDriver(fetchIssue:.unknown)
  let result = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,sink:sink,clock:{cloudTime}).synchronize()
  XCTAssertEqual(result.issue,.unknown); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),state = try await reopened.scopeState(scope:cloudScope())
  XCTAssertEqual(state.issue,.unknown); XCTAssertEqual(state.attemptCount,1)
  let cursor = try await sink.appliedCursor(scope:cloudScope()); XCTAssertNil(cursor.appliedToken)
  try await reopened.close(); try await sink.close()
 }
 func testLogicalRecordAlsoRequiresConditionalSaveAndNonemptyChangeTag() async throws {
  for field in ["recordCondition","recordChangeTag"] {
   let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver()
   try await ledger.enqueue(upload)
   let good = try completeCloudSave(upload)
   var object = try XCTUnwrap(JSONSerialization.jsonObject(with:CloudCodec.encode(good)) as? [String:Any])
   object[field] = field == "recordCondition" ? "unconditional":""
   let malformed = try JSONDecoder().decode(CloudSaveReadback.self,from:JSONSerialization.data(withJSONObject:object))
   await driver.configureSave(response:.complete(malformed))
   let result = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize()
   XCTAssertEqual(result.issue,.invalidPayload)
   let evidence = try await ledger.saveEvidence(scope:cloudScope()); XCTAssertTrue(evidence.isEmpty); try await ledger.close()
  }
 }
 func testPauseBetweenServiceCheckAndSQLProgressCannotConfirmLateResponse() async throws {
  for point in [PauseProgressPoint.stage,.acknowledge,.confirm] {
   let base = try SQLiteCloudLedger(url:tempCloudURL()),scope = try cloudScope(),sink = try FixtureCloudSink(url:tempCloudURL())
   if point == .confirm { try await base.enqueue(cloudUpload()) }
   let ledger = PausingCloudLedger(base:base,point:point),driver = ControlledCloudDriver(batches:[try cloudBatch()])
   let result = try await CloudSyncService(scope:scope,ledger:ledger,driver:driver,sink:sink,clock:{cloudTime}).synchronize()
   XCTAssertEqual(result.issue,.accountChanged)
   let batches = try await base.batches(scope:scope),uploads = try await base.uploads(scope:scope),evidence = try await base.saveEvidence(scope:scope)
   XCTAssertTrue(batches.allSatisfy { $0.state != .confirmed }); XCTAssertTrue(uploads.allSatisfy { $0.state != .confirmed }); XCTAssertTrue(evidence.isEmpty)
   try await base.close(); try await sink.close()
  }
 }
 func testCurrentSameMatchCaptureRevisionInvalidatesEarlierSaveEvidence() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver(),facts = try cloudFacts()
  try await ledger.enqueue(upload); _ = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize()
  let binding = try CaptureBinding(matchID:"match",recordingDeviceID:"watch")
  let revision = try CaptureRevision(id:"capture-1",binding:binding,parentID:nil,revision:1,observedAt:cloudTime,metadata:CaptureMetadata(binding:binding,segments:[],gaps:[]))
  let revised = try CloudMatchFacts(startIntent:facts.startIntent,starter:true,events:facts.events,captureRevisions:[revision])
  let changed = try CloudUpload(scope:cloudScope(),record:CloudRecord(scope:cloudScope(),payload:.matchFacts(revised)))
  let evidence = try await ledger.saveEvidence(scope:cloudScope())
  XCTAssertFalse(try XCTUnwrap(evidence.first).matches(changed)); XCTAssertNotEqual(upload.record.recordID,changed.record.recordID)
  try await ledger.enqueue(changed); let rows = try await ledger.uploads(scope:cloudScope()); XCTAssertEqual(rows.filter { $0.state == .pending }.count,1)
  try await ledger.close()
 }
 func testMissingReferencesWrongManifestAndCrossSnapshotReadbackNeverConfirm() async throws {
  for field in ["parts","recordID","manifestRecordID","manifestChangeTag","confirmationID","manifest-version","manifest-captureDigest","manifest-checkpointID"] {
   let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload(),driver = ControlledCloudDriver(),good = try completeCloudSave(cloudUpload())
   try await ledger.enqueue(upload)
   var object = try XCTUnwrap(JSONSerialization.jsonObject(with:CloudCodec.encode(good)) as? [String:Any])
   if field.hasPrefix("manifest-") {
    var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:good.manifestBytes) as? [String:Any])
    let key = String(field.dropFirst(9)); manifest[key] = key == "version" ? 99:"wrong"
    object["manifestBytes"] = try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.withoutEscapingSlashes]).base64EncodedString()
   } else if field == "parts" { object[field] = [] as [Any] }
   else { object[field] = field.hasSuffix("Tag") || field == "confirmationID" ? "":"wrong" }
   let invalid = try JSONDecoder().decode(CloudSaveReadback.self,from:JSONSerialization.data(withJSONObject:object))
   await driver.configureSave(response:.complete(invalid))
   let outcome = try await CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver).synchronize()
   XCTAssertEqual(outcome.issue,.invalidPayload,field)
   let evidence = try await ledger.saveEvidence(scope:cloudScope()); XCTAssertTrue(evidence.isEmpty,field); try await ledger.close()
  }
 }
 func testSaveConfirmationRollbackAndLostResponseRecoverFirstEvidence() async throws {
  for fault in [CloudLedgerFault.beforeCommit,.afterCommitResponseLost] {
   let url = try tempCloudURL(),upload = try cloudUpload(),initial = try SQLiteCloudLedger(url:url)
   try await initial.enqueue(upload); try await initial.close()
   let readback = try completeCloudSave(upload),manifest = try CloudCodec.decode(CloudSaveManifest.self,readback.manifestBytes)
   let evidence = DevelopmentCloudSaveEvidence(upload:upload,readback:readback,manifest:manifest)
   let failing = try SQLiteCloudLedger(url:url,fault:fault)
   await expectCloudError(.storageUnavailable) { try await failing.confirmUpload(evidence) }; try await failing.close()
   let reopened = try SQLiteCloudLedger(url:url),before = try await reopened.saveEvidence(scope:cloudScope())
   XCTAssertEqual(before.count,fault == .beforeCommit ? 0:1)
   try await reopened.confirmUpload(evidence); try await reopened.confirmUpload(evidence)
   let after = try await reopened.saveEvidence(scope:cloudScope()),rows = try await reopened.uploads(scope:cloudScope())
   XCTAssertEqual(after,[evidence]); XCTAssertEqual(rows.first?.attemptCount,1); XCTAssertEqual(rows.first?.state,.confirmed)
   try await reopened.close()
  }
 }
 func testAccountFenceAlsoGuardsAtomicStageAndSaveConfirmation() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),upload = try cloudUpload()
  try await ledger.enqueue(upload)
  let alreadyStaged = try cloudBatch(id:"already-staged")
  try await ledger.stage(alreadyStaged)
  let readback = try completeCloudSave(upload),manifest = try CloudCodec.decode(CloudSaveManifest.self,readback.manifestBytes)
  let evidence = DevelopmentCloudSaveEvidence(upload:upload,readback:readback,manifest:manifest)
  try await ledger.recordScopeIssue(scope:cloudScope(),issue:.accountChanged,at:cloudTime,nextAttemptAt:nil)
  await expectCloudError(.accountChanged) { try await ledger.stage(cloudBatch()) }
  await expectCloudError(.accountChanged) { try await ledger.confirmUpload(evidence) }
  await expectCloudError(.accountChanged) { try await ledger.acknowledge(CloudImportAcknowledgement(batch:alreadyStaged)) }
  let stages = try await ledger.batches(scope:cloudScope()),proofs = try await ledger.saveEvidence(scope:cloudScope())
  XCTAssertEqual(stages.count,1); XCTAssertEqual(stages.first?.state,.pending); XCTAssertTrue(proofs.isEmpty); try await ledger.close()
 }
 func testAccountChangeWhileFetchAwaitsDiscardsResponseWithoutImport() async throws {
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),sink = try FixtureCloudSink(url:tempCloudURL()),driver = SuspendedCloudDriver()
  let service = CloudSyncService(scope:try cloudScope(),ledger:ledger,driver:driver,sink:sink)
  let work = Task { try await service.synchronize() }
  await driver.waitUntilFetching()
  try await service.suspendForAccountChange()
  await driver.finish(try cloudBatch())
  let result = try await work.value; XCTAssertEqual(result.issue,.accountChanged)
  let rows = try await ledger.batches(scope:cloudScope()),count = try await sink.factCount()
  XCTAssertTrue(rows.isEmpty); XCTAssertEqual(count,0)
  try await ledger.close(); try await sink.close()
 }
}

private actor SuspendedCloudDriver: CloudDriver {
 private var started = false
 private var waiters:[CheckedContinuation<Void,Never>] = []
 private var response:CheckedContinuation<CloudFetchBatch,Never>?
 func fetch(scope:CloudScope,cursor:CloudCursor) async throws -> CloudFetchBatch {
  started = true; waiters.forEach { $0.resume() }; waiters.removeAll()
  return await withCheckedContinuation { response = $0 }
 }
 func waitUntilFetching() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
 func finish(_ batch:CloudFetchBatch) { response?.resume(returning:batch); response = nil }
}
