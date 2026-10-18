import Foundation
import XCTest
import MatchCore
@testable import CloudSync

let cloudTime = Date(timeIntervalSince1970: 1_700_000_000)
func tempCloudURL(_ name: String = "ledger") throws -> URL {
 let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-022-" + UUID().uuidString)
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 return directory.appendingPathComponent(name + ".sqlite")
}
func cloudScope(epoch: Int64 = 1) throws -> CloudScope { try CloudScope(accountID: "account", cloudSpaceID: "space", zoneID: "zone", activationEpoch: epoch) }
func cloudFacts(match: String = "match", deleted: Bool = false) throws -> CloudMatchFacts {
 let intent = StartIntent(id: "intent-" + match, matchID: match, recordingDeviceID: "watch", requestedAt: cloudTime)
 let start = MatchEvent(eventID: "start-" + match, matchID: match, sequence: 1, occurredAt: cloudTime, matchElapsed: 0, type: .matchStarted, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime)
 let end = MatchEvent(eventID: "end-" + match, matchID: match, sequence: 2, occurredAt: cloudTime.addingTimeInterval(10), matchElapsed: 10, type: .matchEnded, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime)
 let tombstone = MatchEvent(eventID: "deleted-" + match, matchID: match, sequence: 3, occurredAt: cloudTime.addingTimeInterval(10), matchElapsed: 10, type: .matchEnded, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime, status: .deleted, correctionOfEventID: end.eventID, revision: 1, authority: .postMatch)
 return try CloudMatchFacts(startIntent: intent, starter: true, events: deleted ? [start,end,tombstone] : [start,end], captureRevisions: [])
}
func cloudRecord(match: String = "match") throws -> CloudRecord { try CloudRecord(scope: cloudScope(), payload: .matchFacts(cloudFacts(match: match))) }
func cloudUpload(id: String? = nil, match: String = "match") throws -> CloudUpload { try CloudUpload(id: id, scope: cloudScope(), record: cloudRecord(match: match), expectedChangeTag: nil) }
func expectCloudError(_ expected: CloudIssue, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
 do { try await operation(); XCTFail("expected " + expected.rawValue, file: file, line: line) } catch let error as CloudError { XCTAssertEqual(error.issue, expected, file: file, line: line) } catch { XCTFail("unexpected \(error)", file: file, line: line) }
}


enum FixtureImportFault: Sendable { case beforeToken, afterCommit }
/// Test-only business stand-in: actual file SQLite facts, receipts and cursor share one transaction.
/// It is never a MatchStore bridge and is never linked into the product target.
actor FixtureCloudSink: CloudCommitSink {
 let sql: CloudSQL
 let fault: FixtureImportFault?
 init(url: URL, fault: FixtureImportFault? = nil) throws {
  sql = try CloudSQL(url: url); self.fault = fault
  try sql.execute("CREATE TABLE IF NOT EXISTS facts(id TEXT PRIMARY KEY, match_id TEXT NOT NULL,digest TEXT NOT NULL,raw BLOB NOT NULL) STRICT")
  try sql.execute("CREATE TABLE IF NOT EXISTS tombstones(match_id TEXT PRIMARY KEY) STRICT")
  try sql.execute("CREATE TABLE IF NOT EXISTS cursors(scope TEXT PRIMARY KEY,token BLOB,generation INTEGER NOT NULL) STRICT")
  try sql.execute("CREATE TABLE IF NOT EXISTS receipts(scope TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,raw BLOB NOT NULL,PRIMARY KEY(scope,id)) STRICT")
 }
 func close() throws { try sql.close() }
 func current(_ scope: CloudScope) throws -> CloudCursor {
  guard let row = try sql.rows("SELECT token,generation FROM cursors WHERE scope=?",[.text(try scope.key)]).first else { return try CloudCursor(appliedToken: nil,fetchGeneration: 0) }
  return try CloudCursor(appliedToken: row[0].data,fetchGeneration: row[1].number ?? -1)
 }
 func appliedCursor(scope: CloudScope) throws -> CloudCursor { try sql.transaction { try current(scope) } }
 func resetCursor(scope: CloudScope,expectedGeneration: Int64) throws -> CloudCursor {
  try sql.transaction {
   let cursor = try current(scope); guard cursor.fetchGeneration == expectedGeneration, expectedGeneration < Int64.max else { throw CloudError(.staleGeneration) }
   let next = try CloudCursor(appliedToken: nil,fetchGeneration: expectedGeneration+1)
   try sql.execute("INSERT INTO cursors(scope,token,generation) VALUES(?,NULL,?) ON CONFLICT(scope) DO UPDATE SET token=NULL,generation=excluded.generation",[.text(try scope.key),.integer(next.fetchGeneration)])
   return next
  }
 }
 func importBatch(_ batch: CloudFetchBatch) throws -> CloudImportAcknowledgement {
  let result = try sql.transaction {
   let scopeKey = try batch.scope.key
   // Replay precedes CAS: lost-ack retries cannot regress an already advanced cursor.
   if let row = try sql.rows("SELECT digest,raw FROM receipts WHERE scope=? AND id=?",[.text(scopeKey),.text(batch.batchID)]).first {
    guard row[0].string == (try batch.digest), let raw = row[1].data else { throw CloudError(.identityConflict) }
    return try CloudCodec.decode(CloudImportAcknowledgement.self,raw)
   }
   let cursor = try current(batch.scope)
   guard cursor.fetchGeneration == batch.fetchGeneration else { throw CloudError(.staleGeneration) }
   guard cursor.appliedToken == batch.expectedAppliedToken else { throw CloudError(.cursorMismatch) }
   for record in batch.records {
    let payload = try record.payload
    if let existing = try sql.rows("SELECT digest,raw FROM facts WHERE id=?",[.text(record.recordID)]).first {
     guard existing[0].string == record.digest,existing[1].data == record.canonicalBytes else { throw CloudError(.conflict) }
    } else {
     try sql.execute("INSERT INTO facts(id,match_id,digest,raw) VALUES(?,?,?,?)",[.text(record.recordID),.text(payload.matchID),.text(record.digest),.blob(record.canonicalBytes)])
    }
    if case .deletion = payload { try sql.execute("INSERT OR IGNORE INTO tombstones(match_id) VALUES(?)",[.text(payload.matchID)]) }
   }
   if fault == .beforeToken { throw CloudError(.storageUnavailable) }
   try sql.execute("INSERT INTO cursors(scope,token,generation) VALUES(?,?,?) ON CONFLICT(scope) DO UPDATE SET token=excluded.token,generation=excluded.generation",[.text(scopeKey),batch.nextToken.map(CloudSQLValue.blob) ?? .null,.integer(batch.fetchGeneration)])
   let ack = try CloudImportAcknowledgement(batch: batch)
   try sql.execute("INSERT INTO receipts(scope,id,digest,raw) VALUES(?,?,?,?)",[.text(scopeKey),.text(batch.batchID),.text(try batch.digest),.blob(try CloudCodec.encode(ack))])
   return ack
  }
  if fault == .afterCommit { throw CloudError(.storageUnavailable) }; return result
 }
 func factCount() throws -> Int { Int(try sql.rows("SELECT count(*) FROM facts").first?.first?.number ?? -1) }
 func visibleMatchCount() throws -> Int { Int(try sql.rows("SELECT count(DISTINCT match_id) FROM facts WHERE match_id NOT IN (SELECT match_id FROM tombstones)").first?.first?.number ?? -1) }
}
actor ControlledCloudDriver: CloudDriver {
 var batches: [CloudFetchBatch]
 var requests: [CloudCursor] = []
 var fetchIssue: CloudIssue?
 var saveIssue: CloudIssue?
 var saveResponse: CloudSaveResult?
 var saveCount = 0
 init(batches: [CloudFetchBatch] = [],fetchIssue: CloudIssue? = nil) { self.batches = batches; self.fetchIssue = fetchIssue }
 func fetch(scope: CloudScope,cursor: CloudCursor) throws -> CloudFetchBatch {
  requests.append(cursor)
  if let fetchIssue { throw CloudError(fetchIssue) }
  guard !batches.isEmpty else { throw CloudError(.networkUnavailable) }
  return batches.removeFirst()
 }
 func fetchRequests() -> [CloudCursor] { requests }
 func configureSave(issue: CloudIssue? = nil, response: CloudSaveResult? = nil) { saveIssue = issue; saveResponse = response }
 func savedAttempts() -> Int { saveCount }
 func save(_ upload: CloudUpload) throws -> CloudSaveResult {
  saveCount += 1
  if let saveIssue { throw CloudError(saveIssue) }
  return try saveResponse ?? .complete(completeCloudSave(upload))
 }
}
func cloudBatch(id: String = "batch",parent: Data? = nil,next: Data? = Data([0,255,7]),generation: Int64 = 0,records: [CloudRecord]? = nil,scope: CloudScope? = nil) throws -> CloudFetchBatch {
 try CloudFetchBatch(scope: scope ?? cloudScope(), batchID: id, records: records ?? [cloudRecord(match: "one"),cloudRecord(match: "two")], expectedAppliedToken: parent,nextToken: next,fetchGeneration: generation,moreComing: false)
}

func completeCloudSave(_ upload:CloudUpload, condition:CloudSaveCondition = .ifServerRecordUnchanged, readBack:Data? = nil) throws -> CloudSaveReadback {
 let bytes = upload.record.canonicalBytes
 let reference = try CloudAssetReference(partID:upload.record.recordID+"-part",index:0,byteCount:bytes.count,digest:CloudCodec.hash(bytes))
 let manifest = try CloudSaveManifest(upload:upload,parts:[reference])
 return CloudSaveReadback(scope:upload.scope,recordID:upload.record.recordID,manifestRecordID:upload.checkpointID,manifestBytes:try CloudCodec.encode(manifest),manifestChangeTag:"manifest-tag",manifestCondition:condition,parts:[CloudSavedPart(reference:reference,changeTag:"part-tag",condition:condition,readBackBytes:readBack ?? bytes)],confirmationID:"confirmation-"+upload.id,recordChangeTag:"record-tag",recordCondition:condition)
}

enum PauseProgressPoint: Sendable { case stage, acknowledge, confirm }
/// Deterministically inserts the account change after service checks, before the actual SQL progress write.
struct PausingCloudLedger: CloudLedger {
 let base:SQLiteCloudLedger
 let point:PauseProgressPoint
 func pause(_ scope:CloudScope) async throws { try await base.recordScopeIssue(scope:scope,issue:.accountChanged,at:cloudTime,nextAttemptAt:nil) }
 func enqueue(_ upload:CloudUpload) async throws { try await base.enqueue(upload) }
 func uploads(scope:CloudScope) async throws -> [CloudUploadEntry] { try await base.uploads(scope:scope) }
 func failUpload(id:String,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.failUpload(id:id,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func stage(_ batch:CloudFetchBatch) async throws { if point == .stage { try await pause(batch.scope) }; try await base.stage(batch) }
 func batches(scope:CloudScope) async throws -> [CloudBatchEntry] { try await base.batches(scope:scope) }
 func acknowledge(_ acknowledgement:CloudImportAcknowledgement) async throws { if point == .acknowledge { try await pause(acknowledgement.scope) }; try await base.acknowledge(acknowledgement) }
 func failBatch(scope:CloudScope,id:String,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.failBatch(scope:scope,id:id,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func scopeState(scope:CloudScope) async throws -> CloudScopeState { try await base.scopeState(scope:scope) }
 func recordScopeIssue(scope:CloudScope,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.recordScopeIssue(scope:scope,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func clearScopeIssue(scope:CloudScope) async throws { try await base.clearScopeIssue(scope:scope) }
 func retainConflict(_ conflict:CloudConflict) async throws { try await base.retainConflict(conflict) }
 func conflicts(scope:CloudScope) async throws -> [CloudConflict] { try await base.conflicts(scope:scope) }
 func confirmUpload(_ evidence:DevelopmentCloudSaveEvidence) async throws { if point == .confirm { try await pause(evidence.scope) }; try await base.confirmUpload(evidence) }
 func saveEvidence(scope:CloudScope) async throws -> [DevelopmentCloudSaveEvidence] { try await base.saveEvidence(scope:scope) }
}
