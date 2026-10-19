import Foundation
import XCTest
import MatchCore
import MatchStore
@testable import MatchSession

final class SessionRetirementTests: XCTestCase, @unchecked Sendable {
  func testRetirementJoinsOriginalPositiveObservationWithoutAnotherDispatch() async throws {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    await h.gateway.waitForPerform(1)
    let done = RetirementCompletion()
    let retiring = Task { try await h.session.retireBusiness(); await done.finish() }
    // A rejected entry proves the permanent gate was established, without guessing Task timing.
    try await eventually("retirement did not close entry") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    let premature = await done.finished
    XCTAssertFalse(premature)
    await h.gateway.release()
    try await retiring.value
    let snapshot = try await h.session.snapshot(matchID: request.matchID)
    XCTAssertEqual(snapshot.capturePhase, .recording)
    let calls = await h.gateway.performed
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(snapshot.store.captureOperations.first?.observation?.outcome, .running)
    do { _ = try await h.session.recover(); XCTFail("retired recover") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    do { _ = try await h.session.execute(request); XCTFail("retired command") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    // The original facade remains usable for Saga/pure queries; retirement is not DB close.
    let ids = try await h.repo.matchIDs()
    XCTAssertEqual(ids, [request.matchID])
  }

  func testObservationFailureIsReportedThenDatabaseOnlyRetryRetainsOriginalFact() async throws {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    await h.gateway.waitForPerform(1)
    await h.repo.failNextObservation("before")
    let retiring = Task { try await h.session.retireBusiness() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    await h.gateway.release()
    do { try await retiring.value; XCTFail("must report failed persistence") }
    catch { XCTAssertEqual(error as? StoreError, .injectedFailure) }
    let before = try await h.repo.snapshotV2(matchID: request.matchID)
    XCTAssertNil(before.captureOperations.first?.observation)
    try await h.session.retireBusiness()
    let saved = try await h.session.snapshot(matchID: request.matchID)
    XCTAssertEqual(saved.capturePhase, .recording)
    let calls = await h.gateway.performed
    let reconciled = await h.gateway.reconciled
    XCTAssertEqual(calls.count, 1)
    XCTAssertTrue(reconciled.isEmpty)
  }

  func testCommittedObservationResponseLostIsReadBackBeforeSuccessfulRetirement() async throws {
    let h = try Harness()
    await h.gateway.configure(suspend: true)
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    await h.gateway.waitForPerform(1)
    await h.repo.failNextObservation("after")
    let retiring = Task { try await h.session.retireBusiness() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    await h.gateway.release()
    try await retiring.value
    let snapshot = try await h.session.snapshot(matchID: request.matchID)
    XCTAssertEqual(snapshot.capturePhase, .recording)
    let count = await h.gateway.performed.count
    XCTAssertEqual(count, 1)
  }

  func testRetiredUpdatesFinishAndQueriesRemainAvailable() async throws {
    let h = try Harness()
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    try await h.waitCaptureSettled(request.matchID)
    let stream = await h.session.updates(matchID: request.matchID)
    let consuming = Task { var values = 0; for await _ in stream { values += 1 }; return values }
    async let first: Void = h.session.retireBusiness()
    async let second: Void = h.session.retireBusiness()
    try await first; try await second
    _ = await consuming.value
    let later = await h.session.updates(matchID: request.matchID)
    var iterator = later.makeAsyncIterator()
    let next = await iterator.next()
    XCTAssertNil(next)
    _ = try await h.session.snapshot(matchID: request.matchID)
  }
  func testRetirementJoinsOriginalReconcileAndPersistsItsPositiveResult() async throws {
    let h = try Harness()
    await h.gateway.configure(outcome: .unknown)
    let request = try await h.session.prepareStart(starter: true)
    await h.repo.failNextObservation("after")
    _ = try await h.session.execute(request)
    await h.repo.waitForObservation()
    await h.gateway.configure(outcome: .running)
    await h.gateway.suspendReconciliation()
    _ = try await h.session.recover()
    await h.gateway.waitForReconcile(1)
    let done = RetirementCompletion()
    let retiring = Task { try await h.session.retireBusiness(); await done.finish() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    let premature = await done.finished; XCTAssertFalse(premature)
    await h.gateway.releaseReconciliation()
    try await retiring.value
    let snapshot = try await h.session.snapshot(matchID: request.matchID)
    XCTAssertEqual(snapshot.capturePhase, .recording)
    let performs = await h.gateway.performed.count, reconciles = await h.gateway.reconciled.count
    XCTAssertEqual(performs, 1); XCTAssertEqual(reconciles, 1)
  }

  func testOrdinaryRecoveryMustPersistRetainedObservationBeforeAnyNewGatewayResult() async throws {
    let h = try Harness()
    await h.repo.failNextObservation("before")
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    await h.repo.waitForObservation()
    // A was running; a later reconciliation B would say unknown. It must not overwrite A.
    await h.gateway.configure(outcome: .unknown)
    _ = try await h.session.recover()
    try await eventually("original observation not retried") {
      try await h.repo.snapshotV2(matchID: request.matchID).captureOperations.first?.observation != nil
    }
    let saved = try await h.repo.snapshotV2(matchID: request.matchID)
    XCTAssertEqual(saved.captureOperations.first?.observation?.outcome, .running)
    let reconciles = await h.gateway.reconciled.count
    XCTAssertEqual(reconciles, 0, "SQL-only persistence of A precedes another same-op gateway call")
    try await h.session.retireBusiness()
  }

  func testSettledDifferentObservationCannotPretendRetainedOriginalWasPersisted() async throws {
    let h = try Harness()
    await h.repo.failNextObservation("before")
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    await h.repo.waitForObservation()
    let current = try await h.repo.snapshotV2(matchID: request.matchID)
    let original = try XCTUnwrap(current.captureOperations.first?.operation)
    let different = try WorkoutObservation(operationID: original.id, binding: original.binding,
      externalToken: original.externalToken, observedAt: original.requestedAt.addingTimeInterval(0.3),
      outcome: .paused, window: CaptureWindow(start: nil, end: nil))
    let update = try CaptureOperationUpdate(operationID: original.id, expectedState: .needsReconciliation, state: .settled, observation: different)
    _ = try await h.repo.commitV2(StoreCommitV2(commandID: "independent-positive", expectedGeneration: current.business.generation,
      descriptor: current.business.descriptor, events: [], captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [update], businessOutbox: []))
    do { try await h.session.retireBusiness(); XCTFail("first persistence error must surface") }
    catch { XCTAssertEqual(error as? StoreError, .injectedFailure) }
    do { try await h.session.retireBusiness(); XCTFail("different settled B is not proof that original A persisted") }
    catch { XCTAssertEqual(error as? StoreError, .operationConflict) }
    let after = try await h.repo.snapshotV2(matchID: request.matchID)
    XCTAssertEqual(after.captureOperations.first?.observation, different)
    let calls = await h.gateway.performed.count; XCTAssertEqual(calls, 1)
  }

  func testRetirementBeforeIntentReplyCannotDispatchNewPermitRequest() async throws {
    let permits = CountingRetirementPermit(), h = try Harness(permits: permits)
    await h.repo.holdIntentReplyForRetirement()
    let request = try await h.session.prepareStart(starter: true)
    let executing = Task { try await h.session.execute(request) }
    await h.repo.waitForRetirementIntent()
    let retiring = Task { try await h.session.retireBusiness() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    await h.repo.releaseRetirementIntent()
    do { _ = try await executing.value; XCTFail("retired start") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    try await retiring.value
    let count = await permits.calls; XCTAssertEqual(count, 0, "retirement before dispatch cannot issue a new lock request")
    let stored = try await h.repo.snapshotV2(matchID: request.matchID)
    XCTAssertTrue(stored.business.events.isEmpty); XCTAssertNil(stored.business.descriptor.startPermit)
    let captures = await h.gateway.performed.count; XCTAssertEqual(captures, 0)
  }

  func testLatePermitCannotStartAndRetirementJoinsOriginalExecute() async throws {
    let permits = HeldRetirementPermit(), h = try Harness(permits: permits)
    let request = try await h.session.prepareStart(starter: true)
    let executing = Task { try await h.session.execute(request) }
    await permits.waitForEntry()
    let done = RetirementCompletion()
    let retiring = Task { try await h.session.retireBusiness(); await done.finish() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    let premature = await done.finished; XCTAssertFalse(premature)
    await permits.release()
    do { _ = try await executing.value; XCTFail("late permit must not start") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    try await retiring.value
    let persisted = try await h.repo.snapshotV2(matchID: request.matchID)
    XCTAssertTrue(persisted.business.events.isEmpty)
    XCTAssertNil(persisted.business.descriptor.startPermit)
    let calls = await h.gateway.performed.count; XCTAssertEqual(calls, 0)
  }

  func testRetirementJoinsInitialUpdatesReadAndDoesNotCloseLifecycleFacade() async throws {
    let h = try Harness()
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request); try await h.waitCaptureSettled(request.matchID)
    await h.repo.holdNextSnapshotForRetirement()
    let stream = await h.session.updates(matchID: request.matchID)
    await h.repo.waitForRetirementSnapshot()
    let done = RetirementCompletion()
    let retiring = Task { try await h.session.retireBusiness(); await done.finish() }
    try await eventually("retirement gate") {
      do { _ = try await h.session.prepareStart(starter: false); return false }
      catch { return error as? SessionError == .retired }
    }
    let premature = await done.finished; XCTAssertFalse(premature)
    await h.repo.releaseRetirementSnapshot(); try await retiring.value
    var iterator = stream.makeAsyncIterator(); let next = await iterator.next(); XCTAssertNil(next)
    let repository = try SQLiteSessionRepository(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), databaseNamespace: "retirement-saga")
    let session = MatchSession(store: repository, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids, permits: DevelopmentStartPermitProvider(), workout: h.gateway, environment: .development(databaseNamespace: "retirement-saga"))
    try await session.retireBusiness()
    try await session.setAnalyticsEnabled(false)
    let enabled = try await repository.analyticsEnabledV4()
    XCTAssertFalse(enabled)
  }

}
private actor RetirementCompletion {
  var finished = false
  func finish() { finished = true }
}

private actor HeldRetirementPermit: StartPermitProvider {
  var entered = false
  var waiter: CheckedContinuation<Void, Never>?
  var blocked: CheckedContinuation<Void, Never>?
  func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    entered = true; waiter?.resume(); waiter = nil
    await withCheckedContinuation { blocked = $0 }
    return DevelopmentStartFixture.permit(for: intent)
  }
  func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
  func release() { blocked?.resume(); blocked = nil }
}

private actor CountingRetirementPermit: StartPermitProvider {
  var calls = 0
  func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    calls += 1; return DevelopmentStartFixture.permit(for: intent)
  }
}
