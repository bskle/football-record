import Foundation
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
