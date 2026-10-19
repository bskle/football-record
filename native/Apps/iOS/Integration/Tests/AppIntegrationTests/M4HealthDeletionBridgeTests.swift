import Foundation
import CryptoKit
import SQLite3
import XCTest
import MatchCore
import MatchStore
import MatchSession
import AccountKit
import HealthKitDeletion
@testable import AppIntegration

@MainActor final class M4HealthDeletionBridgeTests: XCTestCase {
  func testRealSessionFirstCaptureTokenIsFrozenWithoutSegmentSuffix() async throws {
    let root = location(), repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "health-bridge-fixture")
    let session = MatchSession(store: repo, deviceIdentity: HealthFixtureIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: HealthCaptureGateway(), environment: .development(databaseNamespace: "health-bridge-fixture"))
    let start = try await session.prepareStart(starter: true); _ = try await session.execute(start)
    try await settled(repo, start.matchID)
    _ = try await session.execute(session.prepare(.end, matchID: start.matchID))
    try await settled(repo, start.matchID)
    let snapshot = try await repo.snapshotV2(matchID: start.matchID)
    let raw = try reservation(facts: [M4HealthCaptureFacts(snapshot: snapshot)])
    let target = try XCTUnwrap(raw.targets().first)
    let original = try XCTUnwrap(snapshot.captureOperations.first { $0.operation.action == .start })
    XCTAssertEqual(target.workoutUUID, HealthCaptureGateway.workout)
    XCTAssertEqual(Data(target.segmentToken.utf8), Data(original.operation.externalToken.utf8))
    XCTAssertTrue(original.operation.externalToken.hasSuffix("/capture/start"))
    XCTAssertFalse(target.segmentToken.hasSuffix("/segment"))
    XCTAssertEqual(try raw.targets().count, 1)
    XCTAssertEqual(try raw.canonicalBytes(), try JSONDecoder().decode(M4HealthRawReservation.self, from: raw.canonicalBytes()).canonicalBytes())
  }
  func testActualCoreRecoveryGapAndOldRunningSiblingKeepBothOriginalWorkouts() async throws {
    let root=location(), repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"health-recovery-fixture")
    func session() -> MatchSession { MatchSession(store:repo,deviceIdentity:HealthFixtureIdentity(),clock:SystemSessionClock(),ids:UUIDSessionIDFactory(),permits:DevelopmentStartPermitProvider(),workout:HealthRecoveryGateway(),environment:.development(databaseNamespace:"health-recovery-fixture")) }
    let initial=session(), request=try await initial.prepareStart(starter:true); _=try await initial.execute(request); try await settled(repo,request.matchID)
    let restored=session(); _=try await restored.recover()
    let deadline=ContinuousClock.now.advanced(by:.seconds(3)); var restarted=false
    while ContinuousClock.now < deadline {
      let facts=try await repo.snapshotV2(matchID:request.matchID)
      if facts.captureOperations.filter({$0.operation.action == .start && $0.state == .settled}).count == 2 { restarted=true;break }; await Task.yield()
    }
    XCTAssertTrue(restarted)
    _=try await restored.execute(restored.prepare(.end,matchID:request.matchID)); try await settled(repo,request.matchID)
    let snapshot=try await repo.snapshotV2(matchID:request.matchID)
    XCTAssertTrue(snapshot.captureRevisions.contains {!$0.metadata.gaps.isEmpty})
    let raw=try reservation(facts:[M4HealthCaptureFacts(snapshot:snapshot)]), targets=try raw.targets()
    XCTAssertEqual(targets.count,2)
    let recovery=try XCTUnwrap(snapshot.captureOperations.first {$0.operation.action == .recover})
    XCTAssertTrue(targets.contains {Data($0.segmentToken.utf8)==Data(recovery.operation.externalToken.utf8)})
    XCTAssertTrue(targets.contains {Data($0.segmentToken.utf8)==Data((recovery.operation.id+"/restart/start").utf8)})
  }
  func testOriginalOpaqueSegmentIDCannotReplaceLinkedOperationToken() throws {
    let facts = try capture(token: "intent/é/capture/start", segmentID: "opaque-import-id-not-a-token")
    let raw = try reservation(facts: [facts]); let target = try XCTUnwrap(raw.targets().first)
    XCTAssertEqual(Data(target.segmentToken.utf8), Data("intent/é/capture/start".utf8))
    XCTAssertEqual(target.expectedSourceBundleID, "app.fixture.watch")
  }
  func testRecoverAndRestartUseOriginalOperationTokensAndDeduplicateHistory() throws {
    let original = try capture(token: "start/capture/start")
    let restart = try capture(token: "recover/operation/restart/start", workout: UUID(), revisionID: "revision-b")
    let facts = M4HealthCaptureFacts(binding: original.binding, revisions: original.revisions + restart.revisions + original.revisions, operations: original.operations + restart.operations)
    let raw = try reservation(facts: [facts]); let tokens = try raw.targets().map { Data($0.segmentToken.utf8) }
    XCTAssertEqual(tokens.count, 2)
    XCTAssertTrue(tokens.contains(Data("start/capture/start".utf8)))
    XCTAssertTrue(tokens.contains(Data("recover/operation/restart/start".utf8)))
  }
  func testSameWorkoutConflictingRawTupleAndUnicodeBindingFailClosed() throws {
    let a = try capture(token: "capture/start")
    let b = try capture(token: "other/start", workout: a.revisions[0].metadata.segments[0].workoutIDUUID, revisionID: "other")
    let mixed = M4HealthCaptureFacts(binding: a.binding, revisions: a.revisions + b.revisions, operations: a.operations + b.operations)
    XCTAssertThrowsError(try reservation(facts: [mixed])) { XCTAssertEqual($0 as? M4HealthBridgeError, .missingMapping) }
    let different = try CaptureBinding(matchID: "match-e\u{301}", recordingDeviceID: "health-fixture-watch")
    let raw = try capture(token: "start", matchID: "match-é")
    let mismatched = M4HealthCaptureFacts(binding: different, revisions: raw.revisions, operations: raw.operations)
    XCTAssertThrowsError(try reservation(facts: [mismatched])) { XCTAssertEqual($0 as? M4HealthBridgeError, .missingMapping) }
  }
  func testMissingSourceMissingOperationAndPendingCoverageAreNotSubsetSuccess() throws {
    let a = try capture(token: "start")
    XCTAssertThrowsError(try reservation(facts: [a], sources: [])) { XCTAssertEqual($0 as? M4HealthBridgeError, .sourceUnavailable) }
    let absent = M4HealthCaptureFacts(binding: a.binding, revisions: a.revisions, operations: [])
    XCTAssertThrowsError(try reservation(facts: [absent])) { XCTAssertEqual($0 as? M4HealthBridgeError, .missingMapping) }
    let operation = try CaptureOperation(id: "pending/start", binding: a.binding, associatedCommandID: "pending", action: .start, requestedAt: Date(timeIntervalSince1970: 10), externalToken: "pending/start")
    let pending = try CaptureOperationRecord(operation: operation, state: .pending, observation: nil)
    let unknown = M4HealthCaptureFacts(binding: a.binding, revisions: a.revisions, operations: a.operations + [pending])
    XCTAssertThrowsError(try reservation(facts: [unknown])) { XCTAssertEqual($0 as? M4HealthBridgeError, .missingMapping) }
  }
  func testMixedPlatformSourceAndOverflowDoNotTruncateTargets() throws {
    let a = try capture(token: "watch/start")
    let b = try capture(token: "phone/start", workout: UUID(), matchID: "phone-match", recorder: "phone-device")
    let sources = [source(), M4HealthSourceEvidence(recordingDeviceID: "phone-device", bundleID: "app.fixture.phone", platform: .iOS, origin: .controlledFixture, evidenceID: "phone-source-fixture")]
    XCTAssertThrowsError(try reservation(facts: [a,b], sources: sources)) { XCTAssertEqual($0 as? M4HealthBridgeError, .unsupportedSelection) }
    let all = try (0...256).map { try capture(token: "start-" + String($0), workout: UUID(), matchID: "match-" + String($0)) }
    XCTAssertThrowsError(try reservation(facts: all)) { XCTAssertEqual($0 as? M4HealthBridgeError, .unsupportedSelection) }
  }
  func testRawSourceEvidenceTimesAndIndependentHealthConfirmationAreFrozen() throws {
    let a = try reservation(facts: [capture(token: "start")])
    let b = try reservation(facts: [capture(token: "start")], parentID: "parent-other")
    XCTAssertNotEqual(try a.digest(), try b.digest())
    XCTAssertThrowsError(try M4HealthRawReservation(parentID: "parent", scope: scope(), cloud: .keep, local: .delete, health: .delete, healthConfirmed: false, createdAt: 10, confirmedAt: 11, facts: [capture(token: "start")], sources: [source()]))
    XCTAssertThrowsError(try M4HealthRawReservation(parentID: "parent", scope: scope(), cloud: .keep, local: .delete, health: .delete, healthConfirmed: true, createdAt: 11, confirmedAt: 10, facts: [capture(token: "start")], sources: [source()]))
  }

  private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("m4-health-bridge-" + UUID().uuidString) }
  private func settled(_ repo: SQLiteSessionRepository, _ matchID: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      let value = try await repo.snapshotV2(matchID: matchID)
      if !value.captureOperations.isEmpty && value.captureOperations.allSatisfy({ [.settled,.failed,.cancelled].contains($0.state) }) { return }
      await Task.yield()
    }
    XCTFail("capture did not settle")
  }
  private func scope() throws -> CloudScopeV1 { try CloudScopeV1(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", zoneID: "zone-fixture", activationEpoch: 1) }
  private func source() -> M4HealthSourceEvidence { M4HealthSourceEvidence(recordingDeviceID: "health-fixture-watch", bundleID: "app.fixture.watch", platform: .watchOS, origin: .controlledFixture, evidenceID: "source-fixture-v1") }
  private func reservation(facts: [M4HealthCaptureFacts], sources: [M4HealthSourceEvidence]? = nil, parentID: String = "parent-delete") throws -> M4HealthRawReservation {
    try M4HealthRawReservation(parentID: parentID, scope: scope(), cloud: .keep, local: .delete, health: .delete, healthConfirmed: true, createdAt: 10, confirmedAt: 11, facts: facts, sources: sources ?? [source()])
  }
  private func capture(token: String, workout: UUID = HealthCaptureGateway.workout, matchID: String = "match", recorder: String = "health-fixture-watch", segmentID: String = "opaque-segment", revisionID: String = "revision") throws -> M4HealthCaptureFacts {
    let binding = try CaptureBinding(matchID: matchID, recordingDeviceID: recorder), date = Date(timeIntervalSince1970: 10)
    let op = try CaptureOperation(id: token, binding: binding, associatedCommandID: "command", action: .start, requestedAt: date, externalToken: token)
    let window = try CaptureWindow(start: date, end: date.addingTimeInterval(1))
    let observation = try WorkoutObservation(operationID: op.id, binding: binding, externalToken: token, observedAt: date, outcome: .linked(workoutID: workout.uuidString), window: window)
    let segment = try CaptureSegment(id: segmentID, binding: binding, workoutID: workout.uuidString, window: window)
    let metadata = try CaptureMetadata(binding: binding, segments: [segment], gaps: [])
    let revision = try CaptureRevision(id: revisionID, binding: binding, parentID: nil, revision: 1, observedAt: date, metadata: metadata)
    return M4HealthCaptureFacts(binding: binding, revisions: [revision], operations: [try CaptureOperationRecord(operation: op, state: .settled, observation: observation)])
  }
}
private extension CaptureSegment { var workoutIDUUID: UUID { UUID(uuidString: workoutID)! } }
private struct HealthFixtureIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "health-fixture-watch" } }
private struct HealthCaptureGateway: WorkoutGateway {
  static let workout = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    let date = Date()
    return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: date, outcome: operation.action == .finish ? .linked(workoutID: Self.workout.uuidString) : .running, window: CaptureWindow(start: date, end: operation.action == .finish ? date : nil))
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
}

private struct HealthRecoveryGateway: WorkoutGateway {
  func perform(_ operation:CaptureOperation) async -> WorkoutObservation {
    let date=Date(), old=HealthCaptureGateway.workout, next=UUID(uuidString:"22345678-1234-4234-8234-123456789abc")!
    let outcome:WorkoutOutcome = operation.action == .recover ? .linked(workoutID:old.uuidString) : operation.action == .finish ? .linked(workoutID:next.uuidString) : .running
    return try! WorkoutObservation(operationID:operation.id,binding:operation.binding,externalToken:operation.externalToken,observedAt:date,outcome:outcome,window:CaptureWindow(start:nil,end:nil),failure:operation.action == .recover ? .recoveryUnavailable:nil)
  }
  func reconcile(_ operation:CaptureOperation) async -> WorkoutObservation { await perform(operation) }
}

extension M4HealthDeletionBridgeTests {
  func testPrepareReadsPersistedParentAndOriginal028SelectionBeforeSeal() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"parent/capture/start")])
    try await h.bridge.reserve(raw)
    let value=try await h.bridge.prepare(parentID:raw.parentID), entry=try await h.ledger.entry(value.request.requestID)
    XCTAssertEqual(value.parentDigest,h.saga.intent.digest); XCTAssertFalse(h.saga.backendDeleted)
    XCTAssertEqual(try entry.request.canonicalBytes(),try value.request.canonicalBytes())
    XCTAssertEqual(entry.confirmation,value.confirmation); XCTAssertEqual(entry.phase,.pending)
    XCTAssertEqual(entry.attemptCount,0)
    let seal=try await h.mapping.readFullSeal(parentID:raw.parentID); XCTAssertNil(seal)
    try await h.bridge.close(); try await h.mapping.close(); try await h.repo.close()
  }
  func testPreparedUUIDAndOriginalCanonicalBytesSurviveBothLedgersReopen() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"parent/capture/start")])
    try await h.bridge.reserve(raw); let first=try await h.bridge.prepare(parentID:raw.parentID)
    let bytes=try first.canonicalBytes(), selection=try first.request.canonicalBytes(), confirmation=first.confirmation
    XCTAssertEqual(first.request.requestID.uuidString.lowercased().split(separator:"-")[2].first,"8")
    XCTAssertTrue(["8","9","a","b"].contains(String(first.request.requestID.uuidString.lowercased().split(separator:"-")[3].first!)))
    try await h.bridge.close(); try await h.mapping.close()
    let reopened=try healthStores(root:h.root,repo:h.repo)
    let again=try await reopened.bridge.prepare(parentID:raw.parentID)
    XCTAssertEqual(try again.canonicalBytes(),bytes); XCTAssertEqual(try again.request.canonicalBytes(),selection)
    XCTAssertEqual(again.confirmation,confirmation)
    XCTAssertNotEqual(again.request.requestID,again.confirmation.confirmationID)
    try await reopened.bridge.close(); try await reopened.mapping.close(); try await h.repo.close()
  }
  func testPreparedBeforeCommitFailureLeavesOriginalReservationAndNo028Request() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")])
    try await h.bridge.reserve(raw); await h.mapping.setFault(.beforePrepared)
    do {_=try await h.bridge.prepare(parentID:raw.parentID);XCTFail()}catch{}
    let pending=try await h.ledger.pendingRequests(), prepared=try await h.mapping.readPrepared(parentID:raw.parentID)
    XCTAssertTrue(pending.isEmpty); XCTAssertNil(prepared)
    let saved=try await h.mapping.readReservation(parentID:raw.parentID); XCTAssertEqual(try saved?.canonicalBytes(),try raw.canonicalBytes())
    try await h.bridge.close();try await h.mapping.close()
    let next=try healthStores(root:h.root,repo:h.repo), value=try await next.bridge.prepare(parentID:raw.parentID)
    XCTAssertEqual(value.request.createdAt,raw.createdAt);XCTAssertEqual(value.confirmation.confirmedAt,raw.confirmedAt)
    try await next.bridge.close();try await next.mapping.close();try await h.repo.close()
  }
  func testPreparedCommitLostResponseReopensOriginalMappingWithoutRegeneratingIDs() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")])
    try await h.bridge.reserve(raw);await h.mapping.setFault(.afterPrepared)
    do {_=try await h.bridge.prepare(parentID:raw.parentID);XCTFail()}catch{}
    let value=try await h.mapping.readPrepared(parentID:raw.parentID), first=try XCTUnwrap(value)
    let count=try await h.ledger.pendingRequests().count;XCTAssertEqual(count,0)
    try await h.bridge.close();try await h.mapping.close()
    let next=try healthStores(root:h.root,repo:h.repo), restored=try await next.bridge.prepare(parentID:raw.parentID)
    XCTAssertEqual(try first.canonicalBytes(),try restored.canonicalBytes())
    let entries=try await next.ledger.pendingRequests();XCTAssertEqual(entries.count,1)
    try await next.bridge.close();try await next.mapping.close();try await h.repo.close()
  }
  func test028SubmitAndConfirmationLostResponsesKeepFirstSelectionOnRetry() async throws {
    for fault in [HealthLedgerResponseLoss.Point.submit,.confirm] {
      let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")])
      let losing=HealthLedgerResponseLoss(h.ledger,point:fault)
      let bridge=M4HealthDeletionBridge(mapping:h.mapping,parents:h.repo,ledger:losing,allowedSourceOrigin:.controlledFixture,clock:{100})
      try await bridge.reserve(raw)
      do {_=try await bridge.prepare(parentID:raw.parentID);XCTFail()}catch{}
      let value=try await h.mapping.readPrepared(parentID:raw.parentID), first=try XCTUnwrap(value)
      let original=try await h.ledger.entry(first.request.requestID)
      XCTAssertEqual(try original.request.canonicalBytes(),try first.request.canonicalBytes())
      let restored=try await bridge.prepare(parentID:raw.parentID), entry=try await h.ledger.entry(first.request.requestID)
      XCTAssertEqual(try restored.canonicalBytes(),try first.canonicalBytes());XCTAssertEqual(entry.confirmation,first.confirmation)
      XCTAssertEqual(entry.attemptCount,0);try await bridge.close();try await h.mapping.close();try await h.repo.close()
    }
  }
  func testSameParentDifferentRawReservationCannotReplaceDurableMapping() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")])
    try await h.bridge.reserve(raw);let first=try await h.bridge.prepare(parentID:raw.parentID)
    let changed=try reservation(facts:[capture(token:"different/start")])
    do {try await h.bridge.reserve(changed);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.identityConflict)}
    let saved=try await h.mapping.readPrepared(parentID:raw.parentID);XCTAssertEqual(try saved?.canonicalBytes(),try first.canonicalBytes())
    try await h.bridge.close();try await h.mapping.close();try await h.repo.close()
  }
  func testMissingPersistedParentWrongScopeAndDefaultFixtureAdmissionDoNotSubmit() async throws {
    for mode in [0,1,2] {
      let h=try await healthHarness(), facts=try [capture(token:"start")]
      let wrong=try CloudScopeV1(accountID:"other-account",cloudSpaceID:"cloud-fixture",zoneID:"zone-fixture",activationEpoch:1)
      let raw=try M4HealthRawReservation(parentID:mode == 0 ? "unknown-parent":"parent-delete",scope:mode == 1 ? wrong:scope(),cloud:.keep,local:.delete,health:.delete,healthConfirmed:true,createdAt:10,confirmedAt:11,facts:facts,sources:[source()])
      let bridge=mode == 2 ? M4HealthDeletionBridge(mapping:h.mapping,parents:h.repo,ledger:h.ledger,clock:{100}):h.bridge
      do {try await bridge.reserve(raw);_=try await bridge.prepare(parentID:raw.parentID);XCTFail()}catch{}
      let entries=try await h.ledger.pendingRequests();XCTAssertTrue(entries.isEmpty)
      try await bridge.close();try await h.mapping.close();try await h.repo.close()
    }
  }
  func testInvalidDecodedReservationCannotBecomePreparedMapping() async throws {
    let h=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")])
    var object=try XCTUnwrap(JSONSerialization.jsonObject(with:raw.canonicalBytes()) as? [String:Any]);object["version"]=2
    let bad=try JSONDecoder().decode(M4HealthRawReservation.self,from:JSONSerialization.data(withJSONObject:object))
    do {try await h.bridge.reserve(bad);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.invalidReservation)}
    let entries=try await h.ledger.pendingRequests();XCTAssertTrue(entries.isEmpty)
    try await h.bridge.close();try await h.mapping.close();try await h.repo.close()
  }

  private struct HealthHarness {let root:URL;let repo:SQLiteSessionRepository;let saga:DeletionSagaV4;let key:Curve25519.Signing.PrivateKey;let mapping:HealthSQLiteMapping;let ledger:SQLiteHealthDeletionLedger;let bridge:M4HealthDeletionBridge}
  private func healthHarness() async throws -> HealthHarness {
    let root=location(), key=Curve25519.Signing.PrivateKey(), trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:["health-fixture":AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let repo=try SQLiteSessionRepository(rootDirectory:root.appendingPathComponent("business"),databaseNamespace:"health-fixture",authorityTrust:trust,cloudSavePolicy:.development(databaseNamespace:"health-fixture"))
    let binding=try AccountBindingV4(accountID:"account-fixture",cloudSpaceID:"cloud-fixture",deviceID:"phone",activationEpoch:1,role:.phone,environment:.development);try await repo.bindAccountV4(binding)
    let cap=AuthorityWire.base64URL(Data(repeating:41,count:32));var fields=AuthorityFields();fields.reauthenticationID="fresh-fixture";fields.recoveryCapabilityDigest=AuthorityWire.hash(Data(cap.utf8))
    let saga=try DeletionSagaV4(intent:ControlIntentV1(requestID:"parent-delete",operation:.deleteAccount,fields:fields),accountID:binding.accountID,activationEpoch:1,recoveryCapability:cap,cloudChoice:.keep,localChoice:.delete,healthChoice:.delete,healthConfirmed:true,originalScope:scope())
    try await repo.createDeletionSagaV4(saga)
    let stores=try healthStores(root:root,repo:repo)
    return HealthHarness(root:root,repo:repo,saga:saga,key:key,mapping:stores.mapping,ledger:stores.ledger,bridge:stores.bridge)
  }
  private func healthStores(root:URL,repo:SQLiteSessionRepository) throws -> (mapping:HealthSQLiteMapping,ledger:SQLiteHealthDeletionLedger,bridge:M4HealthDeletionBridge) {
    let mapping=try HealthSQLiteMapping(url:root.appendingPathComponent("retained/mapping.sqlite"))
    let ledger=try SQLiteHealthDeletionLedger(url:root.appendingPathComponent("retained/health.sqlite"),businessDataDirectory:root.appendingPathComponent("business"))
    return (mapping,ledger,M4HealthDeletionBridge(mapping:mapping,parents:repo,ledger:ledger,allowedSourceOrigin:.controlledFixture,clock:{100}))
  }
}

/// Test-only durable mapping adapter. It is not the production026 catalog.
private actor HealthSQLiteMapping: M4HealthMappingStore {
  enum Fault {case beforePrepared,afterPrepared}
  private var db:OpaquePointer?
  private var fault:Fault?
  init(url:URL) throws {
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    guard sqlite3_open(url.path,&db)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable}
    guard sqlite3_exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS mapping(kind TEXT NOT NULL,id BLOB NOT NULL,payload BLOB NOT NULL,digest BLOB NOT NULL,PRIMARY KEY(kind,id))",nil,nil,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable}
  }
  func setFault(_ value:Fault) {fault=value}
  func reserve(_ value:M4HealthRawReservation) throws {try put("raw",value.parentID,value.canonicalBytes())}
  func readReservation(parentID:String) throws -> M4HealthRawReservation? {try read("raw",parentID,M4HealthRawReservation.self)}
  func putPrepared(_ value:M4HealthPreparedMapping) throws {try put("prepared",value.parentID,value.canonicalBytes())}
  func readPrepared(parentID:String) throws -> M4HealthPreparedMapping? {try read("prepared",parentID,M4HealthPreparedMapping.self)}
  func readFullSeal(parentID:String) throws -> M4HealthFullSeal? {try read("seal",parentID,M4HealthFullSeal.self)}
  func seal(_ value:M4HealthFullSeal) throws {try put("seal",value.parentID,M4HealthBytes.encode(value))}
  func close() throws {guard let db else {return};guard sqlite3_close(db)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};self.db=nil}
  private func execute(_ sql:String) throws {guard db != nil,sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable}}
  private func bytes(_ kind:String,_ id:String) throws -> Data? {
    guard let db else {throw M4HealthBridgeError.mappingUnavailable};var statement:OpaquePointer?
    guard sqlite3_prepare_v2(db,"SELECT payload,digest FROM mapping WHERE kind=? AND id=?",-1,&statement,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};defer {sqlite3_finalize(statement)}
    let destructor=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    sqlite3_bind_text(statement,1,kind,-1,destructor);let key=Data(id.utf8);_=key.withUnsafeBytes {sqlite3_bind_blob(statement,2,$0.baseAddress,Int32($0.count),destructor)}
    let step=sqlite3_step(statement);if step==SQLITE_DONE {return nil};guard step==SQLITE_ROW else {throw M4HealthBridgeError.mappingUnavailable}
    let data=Data(bytes:sqlite3_column_blob(statement,0)!,count:Int(sqlite3_column_bytes(statement,0))),digest=Data(bytes:sqlite3_column_blob(statement,1)!,count:Int(sqlite3_column_bytes(statement,1)))
    guard data.count<=M4HealthBytes.maximumArtifactBytes,digest==Data(M4HealthBytes.hash(data).utf8) else {throw M4HealthBridgeError.identityConflict};return data
  }
  private func read<T:Decodable>(_ kind:String,_ id:String,_ type:T.Type) throws -> T? {guard let bytes=try bytes(kind,id) else {return nil};return try JSONDecoder().decode(type,from:bytes)}
  private func put(_ kind:String,_ id:String,_ bytes:Data) throws {
    guard bytes.count<=M4HealthBytes.maximumArtifactBytes else {throw M4HealthBridgeError.unsupportedSelection}
    try execute("BEGIN IMMEDIATE");var committed=false
    defer {if !committed {try? execute("ROLLBACK")}}
    if let prior=try self.bytes(kind,id) {guard prior==bytes else {throw M4HealthBridgeError.identityConflict};try execute("COMMIT");committed=true;return}
    let current=fault;if kind=="prepared" {fault=nil}
    guard let db else {throw M4HealthBridgeError.mappingUnavailable};var statement:OpaquePointer?
    guard sqlite3_prepare_v2(db,"INSERT INTO mapping VALUES(?,?,?,?)",-1,&statement,nil)==SQLITE_OK else {throw M4HealthBridgeError.mappingUnavailable};defer {sqlite3_finalize(statement)}
    let destructor=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    sqlite3_bind_text(statement,1,kind,-1,destructor)
    for (index,data) in [Data(id.utf8),bytes,Data(M4HealthBytes.hash(bytes).utf8)].enumerated() {_=data.withUnsafeBytes {sqlite3_bind_blob(statement,Int32(index+2),$0.baseAddress,Int32($0.count),destructor)}}
    guard sqlite3_step(statement)==SQLITE_DONE else {throw M4HealthBridgeError.mappingUnavailable}
    if kind=="prepared",current == .beforePrepared {throw M4HealthBridgeError.mappingUnavailable}
    try execute("COMMIT");committed=true
    if kind=="prepared",current == .afterPrepared {throw M4HealthBridgeError.mappingUnavailable}
  }
}
private actor HealthLedgerResponseLoss:HealthDeletionLedger {
  enum Point {case submit,confirm}
  let base:any HealthDeletionLedger;var point:Point?
  init(_ base:any HealthDeletionLedger,point:Point){self.base=base;self.point=point}
  func submit(_ value:WorkoutDeletionRequestV1) async throws -> HealthDeletionEntry {let entry=try await base.submit(value);if point == .submit {point=nil;throw HealthDeletionIssue.storageUnavailable};return entry}
  func confirm(_ value:WorkoutDeletionConfirmationV1,now:Int64) async throws -> HealthDeletionEntry {let entry=try await base.confirm(value,now:now);if point == .confirm {point=nil;throw HealthDeletionIssue.storageUnavailable};return entry}
  func entry(_ id:UUID) async throws -> HealthDeletionEntry {try await base.entry(id)}
  func pendingRequests() async throws -> [HealthDeletionEntry] {try await base.pendingRequests()}
  func beginAttempt(_ id:UUID,attemptID:UUID) async throws -> HealthDeletionEntry {try await base.beginAttempt(id,attemptID:attemptID)}
  func markAwaitingOutcome(_ id:UUID,digest:String,attemptID:UUID) async throws {try await base.markAwaitingOutcome(id,digest:digest,attemptID:attemptID)}
  func finish(_ id:UUID,digest:String,attemptID:UUID,outcome:HealthDeletionDriverOutcome,now:Int64) async throws {try await base.finish(id,digest:digest,attemptID:attemptID,outcome:outcome,now:now)}
  func close() async throws {try await base.close()}
}

extension M4HealthDeletionBridgeTests {
  func testSealedOriginalParentCallbackReturnsOnly028ReceiptAndReplayDoesNotDispatch() async throws {
    let driver=HealthControlledDeletionDriver(outcome:.success(deletedObjectCount:1)), h=try await sealedHarness(driver:driver)
    try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID)
    let first=try await h.base.ledger.entry(h.prepared.request.requestID)
    XCTAssertEqual(first.phase,.succeededLocally);XCTAssertEqual(first.receipt?.requestID,h.prepared.request.requestID)
    XCTAssertEqual(first.receipt?.selectionDigest,h.prepared.confirmation.selectionDigest)
    try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID)
    let again=try await h.base.ledger.entry(h.prepared.request.requestID)
    XCTAssertEqual(first.receipt,again.receipt);XCTAssertEqual(driver.calls,1)
    XCTAssertEqual(driver.attempts.first?.request.requestID,h.prepared.request.requestID)
    XCTAssertNotEqual(h.raw.parentID,h.prepared.confirmation.confirmationID.uuidString)
    try await h.bridge.close();try await h.base.mapping.close();try await h.base.repo.close()
  }
  func testUnsealedWrongParentMissingBackendAndTamperedSealNeverDispatch() async throws {
    for mode in 0...4 {
      let base=try await healthHarness(), raw=try reservation(facts:[capture(token:"start")]), driver=HealthControlledDeletionDriver(outcome:.success(deletedObjectCount:1))
      try await base.bridge.reserve(raw);let prepared=try await base.bridge.prepare(parentID:raw.parentID)
      if mode != 1 {_=try await backend(base)}
      if mode != 0 {
        let correct=try fullSeal(raw:raw,prepared:prepared)
        if mode >= 2 {
          var object=try XCTUnwrap(JSONSerialization.jsonObject(with:M4HealthBytes.encode(correct)) as? [String:Any])
          object[mode == 2 ? "parentDigest":mode == 3 ? "preparedDigest":"healthConfirmed"] = mode == 4 ? false:String(repeating:"b",count:64) as Any
          try await base.mapping.seal(JSONDecoder().decode(M4HealthFullSeal.self,from:JSONSerialization.data(withJSONObject:object)))
        } else {try await base.mapping.seal(correct)}
      }
      let bridge=M4HealthDeletionBridge(mapping:base.mapping,parents:base.repo,ledger:base.ledger,driver:driver,allowedSourceOrigin:.controlledFixture,clock:{100})
      do {try await bridge.deleteAppCreatedWorkouts(confirmationID:raw.parentID);XCTFail("missing original proof") }catch{}
      do {try await bridge.deleteAppCreatedWorkouts(confirmationID:prepared.confirmation.confirmationID.uuidString);XCTFail("must use parent ID") }catch{}
      XCTAssertEqual(driver.calls,0)
      let entry=try await base.ledger.entry(prepared.request.requestID);XCTAssertEqual(entry.attemptCount,0)
      try await bridge.close();try await base.mapping.close();try await base.repo.close()
    }
  }
  func testTimeoutKeepsOriginalAttemptAndLateReceiptCanBeReplayedWithoutRedispatch() async throws {
    let driver=HealthControlledDeletionDriver(),h=try await sealedHarness(driver:driver,timeout:.milliseconds(20))
    do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.outcomeUnknown)}
    let pending=try await h.base.ledger.entry(h.prepared.request.requestID);XCTAssertEqual(pending.phase,.awaitingOutcome)
    do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.outcomeUnknown)}
    XCTAssertEqual(driver.calls,1);driver.finish(0,.success(deletedObjectCount:1))
    try await waitHealth(h.base.ledger,h.prepared.request.requestID,phase:.succeededLocally)
    try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTAssertEqual(driver.calls,1)
    try await h.bridge.close();try await h.base.mapping.close();try await h.base.repo.close()
  }
  func testCloseReopenUnknownDoesNotDispatchAndOldCallbackCannotRewriteNewOwner() async throws {
    let oldDriver=HealthControlledDeletionDriver(),h=try await sealedHarness(driver:oldDriver,timeout:.milliseconds(20))
    do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch{}
    let pending=try await h.base.ledger.entry(h.prepared.request.requestID);XCTAssertEqual(pending.phase,.awaitingOutcome)
    try await h.bridge.close();try await h.base.mapping.close()
    let next=try healthStores(root:h.base.root,repo:h.base.repo),driver=HealthControlledDeletionDriver(outcome:.success(deletedObjectCount:1))
    let bridge=M4HealthDeletionBridge(mapping:next.mapping,parents:h.base.repo,ledger:next.ledger,driver:driver,allowedSourceOrigin:.controlledFixture,clock:{100},timeout:.milliseconds(20))
    let original=try await next.ledger.entry(h.prepared.request.requestID);XCTAssertEqual(original.phase,.interrupted)
    do {try await bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.outcomeUnknown)}
    oldDriver.finish(0,.success(deletedObjectCount:1));for _ in 0..<100 {await Task.yield()}
    let after=try await next.ledger.entry(h.prepared.request.requestID)
    XCTAssertEqual(after,original);XCTAssertEqual(driver.calls,0);XCTAssertEqual(oldDriver.calls,1)
    try await bridge.close();try await next.mapping.close();try await h.base.repo.close()
  }
  func testFailedUnknownNeverRetriesButKnownPermissionFailureUsesSameOriginalRequest() async throws {
    for issue in [HealthDeletionIssue.outcomeUnknown,.authorizationDenied] {
      let driver=HealthControlledDeletionDriver(outcome:.failure(issue)),h=try await sealedHarness(driver:driver)
      do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch{}
      let failed=try await h.base.ledger.entry(h.prepared.request.requestID)
      XCTAssertEqual(failed.phase,.failed);XCTAssertEqual(failed.issue,issue);XCTAssertEqual(driver.calls,1)
      driver.configure(.success(deletedObjectCount:1))
      if issue == .outcomeUnknown {
        do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.outcomeUnknown)}
        XCTAssertEqual(driver.calls,1)
      } else {
        try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTAssertEqual(driver.calls,2)
        XCTAssertEqual(Set(driver.attempts.map { $0.request.requestID }),[h.prepared.request.requestID])
        let completed=try await h.base.ledger.entry(h.prepared.request.requestID);XCTAssertEqual(completed.attemptCount,2);XCTAssertEqual(completed.phase,.succeededLocally)
      }
      try await h.bridge.close();try await h.base.mapping.close();try await h.base.repo.close()
    }
  }
  func testWrong028FirstConfirmationCannotBeBlessedByMatchingFullSeal() async throws {
    let h=try await healthHarness(),raw=try reservation(facts:[capture(token:"start")]),driver=HealthControlledDeletionDriver(outcome:.success(deletedObjectCount:1))
    try await h.bridge.reserve(raw)
    let prepared=try M4HealthPreparedMapping(reservation:raw,parentDigest:h.saga.intent.digest)
    try await h.mapping.putPrepared(prepared);_=try await h.ledger.submit(prepared.request)
    let wrong=try WorkoutDeletionConfirmationV1(confirmationID:UUID(),requestID:prepared.request.requestID,selectionDigest:prepared.confirmation.selectionDigest,confirmedAt:raw.confirmedAt,explicitHealthDeletion:true)
    _=try await h.ledger.confirm(wrong,now:100);_=try await backend(h);try await h.mapping.seal(fullSeal(raw:raw,prepared:prepared))
    let bridge=M4HealthDeletionBridge(mapping:h.mapping,parents:h.repo,ledger:h.ledger,driver:driver,allowedSourceOrigin:.controlledFixture,clock:{100})
    do {try await bridge.deleteAppCreatedWorkouts(confirmationID:raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.identityConflict)}
    let original=try await h.ledger.entry(prepared.request.requestID);XCTAssertEqual(original.confirmation,wrong);XCTAssertEqual(driver.calls,0)
    try await bridge.close();try await h.mapping.close();try await h.repo.close()
  }
  func testConcurrentParentCallbacksHaveOneNativeAttemptAndOneFirstReceipt() async throws {
    let driver=HealthControlledDeletionDriver(),h=try await sealedHarness(driver:driver)
    let first=Task {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID)}
    let deadline=ContinuousClock.now.advanced(by:.seconds(3))
    while driver.calls == 0 && ContinuousClock.now<deadline {await Task.yield()}
    XCTAssertEqual(driver.calls,1)
    do {try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID);XCTFail()}catch {XCTAssertEqual(error as? M4HealthBridgeError,.outcomeUnknown)}
    XCTAssertEqual(driver.calls,1);driver.finish(0,.success(deletedObjectCount:1));try await first.value
    let entry=try await h.base.ledger.entry(h.prepared.request.requestID);XCTAssertEqual(entry.attemptCount,1);XCTAssertEqual(entry.phase,.succeededLocally)
    try await h.bridge.close();try await h.base.mapping.close();try await h.base.repo.close()
  }
  func testZeroMatchingObjectsReceiptRemainsLocalAndDoesNotCompleteOtherParentGroups() async throws {
    let driver=HealthControlledDeletionDriver(outcome:.success(deletedObjectCount:0)),h=try await sealedHarness(driver:driver)
    try await h.bridge.deleteAppCreatedWorkouts(confirmationID:h.raw.parentID)
    let entry=try await h.base.ledger.entry(h.prepared.request.requestID), saga=try await h.base.repo.deletionSagaV4(requestID:h.raw.parentID)
    XCTAssertEqual(entry.receipt?.deletedObjectCount,0);XCTAssertEqual(entry.receipt?.noMatchingObjectsInScope,true)
    XCTAssertEqual(saga?.healthProgress,.pending);XCTAssertEqual(saga?.localProgress,.pending);XCTAssertFalse(saga?.finished ?? true)
    try await h.bridge.close();try await h.base.mapping.close();try await h.base.repo.close()
  }
  func testZeroSelectionAndUnavailableDefaultCannotManufactureLocalHealthSuccess() async throws {
    XCTAssertThrowsError(try reservation(facts:[])) {XCTAssertEqual($0 as? M4HealthBridgeError,.unsupportedSelection)}
    let h=try await healthHarness(),raw=try reservation(facts:[capture(token:"start")])
    let defaultBridge=M4HealthDeletionBridge(parents:h.repo,ledger:h.ledger,clock:{100})
    do {try await defaultBridge.reserve(raw);XCTFail()}catch{}
    let entries=try await h.ledger.pendingRequests();XCTAssertTrue(entries.isEmpty)
    try await defaultBridge.close();try await h.mapping.close();try await h.repo.close()
  }

  private struct SealedHarness {let base:HealthHarness;let raw:M4HealthRawReservation;let prepared:M4HealthPreparedMapping;let bridge:M4HealthDeletionBridge}
  private func sealedHarness(driver:HealthControlledDeletionDriver,timeout:Duration = .seconds(1)) async throws -> SealedHarness {
    let h=try await healthHarness(),raw=try reservation(facts:[capture(token:"start")])
    try await h.bridge.reserve(raw);let prepared=try await h.bridge.prepare(parentID:raw.parentID);_=try await backend(h)
    try await h.mapping.seal(fullSeal(raw:raw,prepared:prepared))
    return SealedHarness(base:h,raw:raw,prepared:prepared,bridge:M4HealthDeletionBridge(mapping:h.mapping,parents:h.repo,ledger:h.ledger,driver:driver,allowedSourceOrigin:.controlledFixture,clock:{100},timeout:timeout))
  }
  private func fullSeal(raw:M4HealthRawReservation,prepared:M4HealthPreparedMapping) throws -> M4HealthFullSeal {
    M4HealthFullSeal(version:1,parentID:raw.parentID,parentDigest:prepared.parentDigest,reservationDigest:try raw.digest(),preparedDigest:try M4HealthBytes.hash(prepared.canonicalBytes()),catalogDigest:String(repeating:"a",count:64),scope:raw.scope,cloud:raw.cloud,local:raw.local,health:raw.health,healthConfirmed:raw.healthConfirmed)
  }
  private func backend(_ h:HealthHarness) async throws -> DeletionSagaV4 {
    let body:[String:Any]=["version":1,"environment":"development","keyID":"health-fixture","receiptID":"parent-delete-receipt","requestID":h.saga.intent.requestID,"requestDigest":h.saga.intent.digest,"operation":"deleteAccount","accountID":h.saga.accountID,"activationEpoch":1,"matchID":"","lockID":"","recordingDeviceID":"","result":"deleted","issuedAt":100,"deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]]
    let raw=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try h.key.signature(for:AuthorityWire.signedInput("football-record.authority.receipt.v1",body:raw))
    let envelope=try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(signature)],options:[.sortedKeys,.withoutEscapingSlashes])
    let trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:["health-fixture":AuthorityWire.base64URL(h.key.publicKey.rawRepresentation)])
    let verified=try VerifiedAuthorityReceiptV1.verify(envelope,expected:AuthorityExpectedIntent(h.saga.intent,accountID:h.saga.accountID,epoch:1),trust:trust)
    return try await h.repo.acceptDeletionV4(requestID:h.saga.intent.requestID,receipt:verified,expectedRevision:0)
  }
  private func waitHealth(_ ledger:SQLiteHealthDeletionLedger,_ id:UUID,phase:HealthDeletionPhase) async throws {
    let deadline=ContinuousClock.now.advanced(by:.seconds(3))
    while ContinuousClock.now<deadline {if try await ledger.entry(id).phase == phase {return};await Task.yield()};XCTFail("Health callback never committed")
  }
}
private final class HealthControlledDeletionDriver:HealthDeletionDriver,@unchecked Sendable {
  private let lock=NSLock()
  private var outcome:HealthDeletionDriverOutcome?
  private var recorded:[HealthDeletionDriverAttempt]=[]
  private var completions:[@Sendable (HealthDeletionDriverOutcome)->Void]=[]
  init(outcome:HealthDeletionDriverOutcome?=nil){self.outcome=outcome}
  var calls:Int {lock.withLock {recorded.count}}
  var attempts:[HealthDeletionDriverAttempt] {lock.withLock {recorded}}
  func configure(_ value:HealthDeletionDriverOutcome?){lock.withLock {outcome=value}}
  func delete(_ attempt:HealthDeletionDriverAttempt,completion:@escaping @Sendable(HealthDeletionDriverOutcome)->Void) {
    let value=lock.withLock {recorded.append(attempt);completions.append(completion);return outcome};if let value {completion(value)}
  }
  func finish(_ index:Int,_ value:HealthDeletionDriverOutcome){let callback=lock.withLock {completions.indices.contains(index) ? completions[index]:nil};callback?(value)}
}
