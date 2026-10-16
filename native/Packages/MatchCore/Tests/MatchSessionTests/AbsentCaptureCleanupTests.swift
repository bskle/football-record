import Foundation
import MatchCore
import MatchStore
import XCTest

@testable import MatchSession

actor AuthorizationStillPendingGateway: WorkoutGateway {
  var authorizationFinished = false
  var externalCreates = 0
  var finishedCalls = 0
  var finishWaiters: [CheckedContinuation<Void, Never>] = []
  func observation(_ operation: CaptureOperation) throws -> WorkoutObservation {
    let outcome: WorkoutOutcome =
      operation.action == .start && authorizationFinished ? .notCreated(.unavailable) : .unknown
    return try WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: operation.requestedAt.addingTimeInterval(authorizationFinished ? 100 : 1),
      outcome: outcome, window: CaptureWindow(start: nil, end: nil))
  }
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    // Outer start timeout returns unknown while the independent authorization remains pending.
    if operation.action == .finish {
      finishedCalls += 1
      finishWaiters.forEach { $0.resume() }
      finishWaiters = []
    }
    return try! observation(operation)
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    try! observation(operation)
  }
  func waitForFinish() async {
    if finishedCalls > 0 { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }
  func completeAuthorizationWithoutCreatingDriver() { authorizationFinished = true }
}
final class AbsentCaptureCleanupSessionTests: XCTestCase, @unchecked Sendable {
  func testOuterTimeoutEndThenFreshNegativeProofCancelsUncertainFinishWithoutCreatingWorkout()
    async throws
  {
    let h = try Harness()
    let gateway = AuthorizationStillPendingGateway()
    let session = MatchSession(
      store: h.repo, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
    let start = try await session.prepareStart(starter: true)
    _ = try await session.execute(start)
    await h.repo.waitForObservation()
    h.clock.advance(10)
    _ = try await session.execute(session.prepare(.end, matchID: start.matchID))
    await gateway.waitForFinish()
    try await eventually("finish must already be durably uncertain before authorization resolves") {
      let s = try await h.repo.snapshotV2(matchID: start.matchID)
      return s.captureOperations.contains {
        $0.operation.action == .finish && $0.state == .needsReconciliation && $0.observation != nil
      }
    }
    let before = await gateway.authorizationFinished
    XCTAssertFalse(before)
    await gateway.completeAuthorizationWithoutCreatingDriver()
    _ = try await session.recover()
    try await eventually("durable fresh absence must remove only the uncertain finish") {
      try await h.repo.pendingCaptureOperations(matchID: start.matchID).isEmpty
    }
    let result = try await session.snapshot(matchID: start.matchID)
    XCTAssertEqual(result.replay.state, .endedPendingSync)
    XCTAssertEqual(result.replay.backendLockState, .held)
    XCTAssertEqual(result.capturePhase, .notRecorded(.unavailable))
    XCTAssertTrue(result.store.captureRevisions.isEmpty)
    XCTAssertEqual(result.store.captureOperations.last?.state, .cancelled)
    let creates = await gateway.externalCreates
    XCTAssertEqual(creates, 0)
  }
  func testSessionDoesNotSilentlyDropLatePositiveAfterAbsentStartWasFinalized() async throws {
    let h = try Harness()
    await h.gateway.configure(outcome: .notCreated(.unavailable))
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    let snapshot = try await h.repo.snapshotV2(matchID: r.matchID)
    let operation = try XCTUnwrap(snapshot.captureOperations.first?.operation)
    let observation = try WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: h.clock.now().addingTimeInterval(10), outcome: .running,
      window: CaptureWindow(start: h.clock.now(), end: nil))
    do {
      try await h.session.saveObservation(observation, operation: operation)
      XCTFail("late positive must reach quarantine")
    } catch let e as StoreError { XCTAssertEqual(e, .captureConflict) }
    let diagnostics = try await h.repo.store.diagnostics(matchID: r.matchID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    XCTAssertTrue(
      diagnostics.contains {
        $0.rawBytes == (try? encoder.encode(observation)) && $0.severity == .blocking
      })
    do {
      _ = try await h.session.snapshot(matchID: r.matchID)
      XCTFail("cannot show successful absence through a blocking diagnosis")
    } catch {}
  }

  func testExistingSameBindingSegmentKeepsUncertainFinishReconciling() async throws {
    let h = try Harness()
    await h.gateway.configure(outcome: .notCreated(.unavailable))
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    try await h.waitCaptureSettled(start.matchID)
    var snapshot = try await h.repo.snapshotV2(matchID: start.matchID)
    let original = try XCTUnwrap(snapshot.captureOperations.first?.operation)
    let segment = try CaptureSegment(
      id: "unattributed-existing-segment", binding: original.binding,
      workoutID: "real-workout", window: CaptureWindow(start: nil, end: nil))
    let metadata = try CaptureMetadata(binding: original.binding, segments: [segment], gaps: [])
    let revision = try CaptureRevision(
      id: "existing", binding: original.binding, parentID: nil,
      revision: 1, observedAt: h.clock.now(), metadata: metadata)
    let finish = try CaptureOperation(
      id: "uncertain-finish", binding: original.binding,
      associatedCommandID: "prepare-finish", action: .finish, requestedAt: h.clock.now(),
      externalToken: original.id)
    _ = try await h.repo.commitV2(
      h.session.makeCommit(
        command: "prepare-finish", generation: snapshot.business.generation,
        descriptor: snapshot.business.descriptor, revisions: [revision], operations: [finish],
        outboxID: "existing-outbox"))
    snapshot = try await h.repo.snapshotV2(matchID: start.matchID)
    let marker = try CaptureOperationUpdate(
      operationID: finish.id, expectedState: .pending, state: .needsReconciliation, observation: nil
    )
    _ = try await h.repo.commitV2(
      h.session.makeCommit(
        command: "mark-finish", generation: snapshot.business.generation,
        descriptor: snapshot.business.descriptor, updates: [marker]))
    let dispatch = try await h.session.planDispatch(finish, match: start.matchID)
    XCTAssertEqual(dispatch?.operation, finish)
    XCTAssertEqual(dispatch?.perform, false)
    let pending = try await h.repo.pendingCaptureOperations(matchID: start.matchID)
    XCTAssertEqual(pending.last?.state, .needsReconciliation)
    let diagnostics = try await h.repo.store.diagnostics(matchID: start.matchID)
    XCTAssertFalse(diagnostics.contains { $0.severity == .blocking })
  }

}
