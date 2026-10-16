import Foundation
import MatchCore
import MatchSession
import XCTest

@testable import MatchStore

final class CaptureReconciliationTests: XCTestCase, @unchecked Sendable {
  func testEndCommitsWhileStartSuspendedThenLateRunningOnlyFinishesOriginalToken() async throws {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    await h.gateway.waitForPerform(1)
    h.clock.advance(10)
    let end = try await h.session.execute(h.session.prepare(.end, matchID: start.matchID))
    XCTAssertEqual(end.snapshot.replay.state, .endedPendingSync)
    let before = await h.gateway.performed
    XCTAssertEqual(before.count, 1)
    await h.gateway.release()
    try await h.waitCaptureSettled(start.matchID)
    let after = await h.gateway.performed
    XCTAssertEqual(after.map(\.action), [.start, .finish])
    XCTAssertEqual(Set(after.map(\.externalToken)).count, 1)
    let saved = try await h.session.snapshot(matchID: start.matchID)
    XCTAssertEqual(saved.replay.state, .endedPendingSync)
    XCTAssertEqual(saved.capturePhase, .finished)
    XCTAssertEqual(saved.store.captureRevisions.last?.metadata.segments.count, 1)
    guard case .none = try await h.newSession().recover() else {
      return XCTFail("terminal is never active")
    }
  }
  func testEndCommitsWhileResumeSuspendedAndBenchDoesNotPauseCapture() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    h.clock.advance(2)
    _ = try await h.session.execute(h.session.prepare(.leaveField, matchID: r.matchID))
    let one = await h.gateway.performed
    XCTAssertEqual(one.count, 1)
    h.clock.advance(2)
    _ = try await h.session.execute(h.session.prepare(.pause, matchID: r.matchID))
    try await h.waitCaptureSettled(r.matchID)
    await h.gateway.configure(suspend: true)
    h.clock.advance(2)
    _ = try await h.session.execute(h.session.prepare(.resume, matchID: r.matchID))
    try await eventually("resume capture must be dispatched after its COMMIT") {
      await h.gateway.performed.count >= 3
    }
    h.clock.advance(2)
    let end = try await h.session.execute(h.session.prepare(.end, matchID: r.matchID))
    XCTAssertEqual(end.snapshot.replay.state, .endedPendingSync)
    await h.gateway.release()
    try await h.waitCaptureSettled(r.matchID)
    let all = await h.gateway.performed
    XCTAssertEqual(all.map(\.action), [.start, .pause, .resume, .finish])
    XCTAssertEqual(Set(all.map(\.externalToken)).count, 1)
  }
  func testGatewaySuccessObservationFailureReopenReconcilesSameTokenWithoutPerformingAgain()
    async throws
  {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    await h.repo.failNextObservation("before")
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    await h.gateway.waitForPerform(1)
    await h.gateway.release()
    await h.repo.waitForObservation()
    let before = try await h.repo.snapshotV2(matchID: start.matchID)
    XCTAssertEqual(before.captureOperations.first?.state, .needsReconciliation)
    let repository = TestRepository(try MatchStore(url: h.url))
    let gateway = FakeGateway()
    await gateway.configure(outcome: .linked(workoutID: "actual-reconciled"))
    await gateway.script(.finish, [.linked(workoutID: "actual-reconciled")])
    let reopened = MatchSession(
      store: repository, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
    h.clock.advance(20)
    let end = try await reopened.execute(reopened.prepare(.end, matchID: start.matchID))
    XCTAssertEqual(end.snapshot.replay.state, .endedPendingSync)
    await gateway.waitForReconcile(1)
    for _ in 0..<10000 {
      let s = try await repository.snapshotV2(matchID: start.matchID)
      if s.captureOperations.allSatisfy({ $0.state == .settled || $0.state == .cancelled }) {
        break
      }
      await Task.yield()
    }
    let performed = await gateway.performed
    XCTAssertFalse(performed.contains { $0.action == .start })
    let reconciled = await gateway.reconciled
    XCTAssertEqual(reconciled.first?.externalToken, start.captureOperationID)
    let snapshot = try await repository.snapshotV2(matchID: start.matchID)
    XCTAssertEqual(
      snapshot.captureRevisions.last?.metadata.segments.filter {
        $0.workoutID == "actual-reconciled"
      }.count, 1)
    XCTAssertTrue(
      snapshot.captureOperations.allSatisfy { $0.state == .settled || $0.state == .cancelled })
    XCTAssertTrue(snapshot.business.diagnostics.isEmpty)
  }
  func testUnknownAndSavedAwaitingLinkSurviveRestartWithoutNewWorkout() async throws {
    for outcome in [WorkoutOutcome.unknown, .savedAwaitingLink] {
      let h = try Harness()
      await h.gateway.configure(outcome: outcome)
      let r = try await h.session.prepareStart(starter: true)
      _ = try await h.session.execute(r)
      await h.gateway.waitForPerform(1)
      await h.repo.waitForObservation()
      let gateway = FakeGateway()
      await gateway.configure(outcome: outcome)
      let reopened = MatchSession(
        store: h.repo, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
        permits: DevelopmentStartPermitProvider(), workout: gateway,
        environment: .development(databaseNamespace: "test-development"))
      _ = try await reopened.recover()
      await gateway.waitForReconcile(1)
      for _ in 0..<100 { await Task.yield() }
      let called = await gateway.performed
      XCTAssertTrue(called.isEmpty)
      let pending = try await h.repo.pendingCaptureOperations(matchID: r.matchID)
      XCTAssertEqual(pending.first?.state, .needsReconciliation)
      XCTAssertEqual(pending.first?.observation?.outcome, outcome)
      let s = try await reopened.snapshot(matchID: r.matchID)
      XCTAssertEqual(
        s.capturePhase, outcome == .savedAwaitingLink ? .savedAwaitingLink : .needsReconciliation)
    }
  }
  func testUnavailableCapturePreservesBusinessAndRouteWarningSurvivesUnrelatedSuccess() async throws
  {
    let h = try Harness()
    await h.gateway.configure(outcome: .notCreated(.writeDenied))
    let r = try await h.session.prepareStart(starter: true)
    let saved = try await h.session.execute(r)
    XCTAssertEqual(saved.snapshot.replay.state, .running)
    try await h.waitCaptureSettled(r.matchID)
    let failed = try await h.session.snapshot(matchID: r.matchID)
    XCTAssertEqual(failed.capturePhase, .notRecorded(.writeDenied))
    XCTAssertEqual(failed.captureFailure, .writeDenied)
    let other = try Harness()
    await other.gateway.configure(failure: .routeFailed)
    let start = try await other.session.prepareStart(starter: true)
    _ = try await other.session.execute(start)
    try await other.waitCaptureSettled(start.matchID)
    await other.gateway.configure()
    other.clock.advance(2)
    _ = try await other.session.execute(other.session.prepare(.pause, matchID: start.matchID))
    try await other.waitCaptureSettled(start.matchID)
    let paused = try await other.session.snapshot(matchID: start.matchID)
    XCTAssertEqual(paused.capturePhase, .paused)
    XCTAssertEqual(paused.captureFailure, .routeFailed)
  }
  func testPreparedRequestStalesAfterCaptureCommitAndNewCommandCanSucceed() async throws {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    await h.gateway.waitForPerform(1)
    h.clock.advance(2)
    let original = try await h.session.prepare(.quick(.myGoal), matchID: r.matchID)
    await h.gateway.release()
    try await h.waitCaptureSettled(r.matchID)
    do {
      _ = try await h.session.execute(original)
      XCTFail("original generation advanced")
    } catch let e as StoreError { XCTAssertEqual(e, .staleGeneration) }
    let absent = try await h.repo.committedCommandV2(commandID: original.commandID)
    XCTAssertNil(absent)
    let snapshot = try await h.session.snapshot(matchID: r.matchID)
    XCTAssertEqual(snapshot.replay.score.forTeam, 0)
    let next = try await h.session.prepare(.quick(.myGoal), matchID: r.matchID)
    XCTAssertNotEqual(next.commandID, original.commandID)
    let committed = try await h.session.execute(next)
    XCTAssertEqual(committed.snapshot.replay.score.forTeam, 1)
  }
  func testEndCancelsNeverDispatchedStartAndFinishThenOriginalStartRetryStillWorks() async throws {
    let h = try Harness()
    await h.repo.loseNextStartResponse()
    let start = try await h.session.prepareStart(starter: true)
    do {
      _ = try await h.session.execute(start)
      XCTFail("start response lost after COMMIT")
    } catch let e as StoreError { XCTAssertEqual(e, .responseLost) }
    h.clock.advance(10)
    let end = try await h.session.execute(h.session.prepare(.end, matchID: start.matchID))
    XCTAssertEqual(end.snapshot.replay.state, .endedPendingSync)
    for _ in 0..<1000 {
      let s = try await h.repo.snapshotV2(matchID: start.matchID)
      if s.captureOperations.allSatisfy({ $0.state == .cancelled }) { break }
      await Task.yield()
    }
    let s = try await h.repo.snapshotV2(matchID: start.matchID)
    XCTAssertTrue(s.captureOperations.allSatisfy { $0.state == .cancelled })
    let calls = await h.gateway.performed
    XCTAssertTrue(calls.isEmpty)
    let again = try await h.newSession().execute(start)
    XCTAssertEqual(again.receipt.generation, 2)
    XCTAssertEqual(again.snapshot.replay.state, .endedPendingSync)
  }
  func testLinkedObservationResponseLostReopenDoesNotCreateSecondSegmentOrFinish() async throws {
    let h = try Harness()
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    try await h.waitCaptureSettled(start.matchID)
    await h.repo.failNextObservation("after")
    h.clock.advance(10)
    _ = try await h.session.execute(h.session.prepare(.end, matchID: start.matchID))
    await h.repo.waitForObservation()
    let before = try await h.repo.snapshotV2(matchID: start.matchID)
    XCTAssertEqual(before.captureRevisions.last?.metadata.segments.count, 1)
    let gateway = FakeGateway()
    let repository = TestRepository(try MatchStore(url: h.url))
    let reopened = MatchSession(
      store: repository, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
    guard case .none = try await reopened.recover() else { return XCTFail("ended") }
    for _ in 0..<100 { await Task.yield() }
    let after = try await reopened.snapshot(matchID: start.matchID)
    XCTAssertEqual(after.store.captureRevisions.last?.metadata.segments.count, 1)
    let calls = await gateway.performed
    let checks = await gateway.reconciled
    XCTAssertTrue(calls.isEmpty)
    XCTAssertTrue(checks.isEmpty)
  }

  func testKnownFailedFinishCanRetryOriginalTokenOnTerminalRecovery() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    await h.gateway.script(.finish, [.running])
    await h.gateway.configure(failure: .captureFailed)
    h.clock.advance(10)
    _ = try await h.session.execute(h.session.prepare(.end, matchID: r.matchID))
    try await h.waitCaptureSettled(r.matchID)
    let failed = try await h.session.snapshot(matchID: r.matchID)
    XCTAssertEqual(failed.capturePhase, .needsReconciliation)
    let gateway = FakeGateway()
    let repo = TestRepository(try MatchStore(url: h.url))
    let reopened = MatchSession(
      store: repo, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
    _ = try await reopened.recover()
    try await eventually("failed finish must be retried during terminal recovery") {
      await gateway.performed.count >= 1
    }
    let calls = await gateway.performed
    XCTAssertEqual(calls.map(\.action), [.finish])
    XCTAssertEqual(calls.first?.externalToken, r.captureOperationID)
  }
  func testRecoveryFailureAndGapSuccessorAreAtomicAcrossDatabaseFailure() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    let gateway = FakeGateway()
    await gateway.script(.recover, [.stopped])
    await gateway.configure(failure: .recoveryUnavailable)
    let recovering = MatchSession(
      store: h.repo, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
    await h.repo.failNextRecoverySuccessor()
    _ = try await recovering.recover()
    await gateway.waitForPerform(1)
    await h.repo.waitForSuccessorFailure()
    let failed = await h.repo.successorFailed
    XCTAssertTrue(failed)
    let snapshot = try await h.repo.snapshotV2(matchID: r.matchID)
    XCTAssertEqual(snapshot.captureOperations.last?.state, .needsReconciliation)
    XCTAssertEqual(snapshot.captureOperations.filter { $0.operation.action == .start }.count, 1)
    XCTAssertTrue(snapshot.captureRevisions.isEmpty)
  }

  func testNewCaptureWorkDuringAnEmptyScanCannotLoseDriverWakeup() async throws {
    let h = try Harness()
    await h.repo.holdSecondSnapshotAfterObservation()
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    await h.repo.waitForHeldTail()
    h.clock.advance(2)
    _ = try await h.session.execute(h.session.prepare(.pause, matchID: start.matchID))
    await h.repo.releaseTail()
    try await eventually("new committed pause must wake the existing empty driver") {
      await h.gateway.performed.count >= 2
    }
    let calls = await h.gateway.performed
    XCTAssertEqual(calls.map(\.action), [.start, .pause])
  }

}
