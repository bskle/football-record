import XCTest
import MatchCore
@testable import WorkoutCapture

@MainActor final class FakeDriver: WorkoutDriver {
  var calls: [String] = []
  var state = DriverState(outcome: .unknown)
  var saveResult = DriverState(outcome: .linked(workoutID: "REAL-UUID"))
  var suspendedStart: CheckedContinuation<DriverState, Never>?
  var hangStart = false
  var suspendedSave: CheckedContinuation<DriverState, Never>?
  var hangSave = false
  var stopFailures = 0
  func start() async -> DriverState {
    calls.append("start")
    if hangStart { return await withCheckedContinuation { suspendedStart = $0 } }
    state = DriverState(outcome: .running, start: Date(timeIntervalSince1970: 200)); return state
  }
  func pause() async -> DriverState { calls.append("pause"); state.outcome = .paused; return state }
  func resume() async -> DriverState { calls.append("resume"); state.outcome = .running; return state }
  func requestStop() { calls.append("requestStop") }
  func stop() async -> DriverState { calls.append("stopped"); if stopFailures > 0 { stopFailures -= 1; state.failure = .captureFailed; return state }; state.outcome = .stopped; return state }
  func endCollection() async -> Bool { calls.append("endCollection"); return true }
  func save() async -> DriverState { calls.append("save"); if hangSave { state = await withCheckedContinuation { suspendedSave = $0 }; return state }; state = saveResult; return state }
  func endSession() { calls.append("endSession") }
  func currentState() -> DriverState { state }
}
@MainActor final class FakeFactory: WorkoutDriverFactory {
  let driver = FakeDriver()
  var authorization = HealthAuthorization(available: true, write: .allowed, location: .allowed)
  var lookup = RecoveryLookup.unknown
  var creations = 0
  var holdAuthorization = false
  var authorizationStarted = false
  var authorizationContinuation: CheckedContinuation<HealthAuthorization, Never>?
  func requestAuthorization() async -> HealthAuthorization {
    authorizationStarted = true
    if holdAuthorization { return await withCheckedContinuation { authorizationContinuation = $0 } }
    return authorization
  }
  func releaseAuthorization() { holdAuthorization = false; authorizationContinuation?.resume(returning: authorization); authorizationContinuation = nil }
  func makeDriver(context: WorkoutContext) throws -> any WorkoutDriver { creations += 1; return driver }
  func recover(context: WorkoutContext) async -> RecoveryLookup { lookup }
}
@MainActor final class WorkoutLifecycleTests: XCTestCase {
  func operation(_ action: CaptureAction, id: String? = nil, token: String = "start") throws -> CaptureOperation {
    try CaptureOperation(id: id ?? (action == .start ? token : action.rawValue), binding: CaptureBinding(matchID: "match", recordingDeviceID: "watch"), associatedCommandID: "command", action: action, requestedAt: Date(timeIntervalSince1970: 1), externalToken: token)
  }
  func testActualStartWindowDoesNotBackfillBusinessTime() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    let result = await g.perform(try operation(.start))
    XCTAssertEqual(result.outcome, .running); XCTAssertEqual(result.window.start, Date(timeIntervalSince1970: 200))
    XCTAssertEqual(f.creations, 1)
  }
  func testFinishOrderAndSavedTokenNeverFinishesAgain() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    _ = await g.perform(try operation(.start)); let result = await g.perform(try operation(.finish))
    XCTAssertEqual(result.outcome, .linked(workoutID: "REAL-UUID"))
    XCTAssertEqual(f.driver.calls, ["start", "requestStop", "stopped", "endCollection", "save", "endSession"])
    _ = await g.perform(try operation(.finish, id: "finish-retry")); _ = await g.perform(try operation(.pause))
    XCTAssertEqual(f.driver.calls.filter { $0 == "save" }.count, 1)
  }
  func testNilNilSaveWaitsForLookupWithoutRepeatedFinish() async throws {
    let f = FakeFactory(); f.driver.saveResult = DriverState(outcome: .savedAwaitingLink)
    let g = AppleWorkoutGateway(factory: f); _ = await g.perform(try operation(.start))
    let saved = await g.perform(try operation(.finish)); XCTAssertEqual(saved.outcome, .savedAwaitingLink)
    f.lookup = .saved(DriverState(outcome: .linked(workoutID: "UNLOCKED-UUID")))
    let linked = await g.reconcile(try operation(.finish)); XCTAssertEqual(linked.outcome, .linked(workoutID: "UNLOCKED-UUID"))
    XCTAssertEqual(f.driver.calls.filter { $0 == "save" }.count, 1)
  }
  func testWriteDeniedCreatesNoWorkoutAndDoesNotInferReadDenial() async throws {
    let f = FakeFactory(); f.authorization = HealthAuthorization(available: true, write: .denied, location: .unknown)
    let result = await AppleWorkoutGateway(factory: f).perform(try operation(.start))
    XCTAssertEqual(result.outcome, .notCreated(.writeDenied)); XCTAssertEqual(f.creations, 0)
    XCTAssertEqual(HealthReadState.fromEmptyQuery, .notRecorded)
  }
  func testUnknownReconciliationDoesNotCreateAnotherWorkout() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    let result = await g.reconcile(try operation(.start))
    XCTAssertEqual(result.outcome, .unknown); XCTAssertEqual(f.creations, 0)
  }
  func testReattachesRecoveredDriverWithoutStart() async throws {
    let f = FakeFactory(); f.driver.state = DriverState(outcome: .paused); f.lookup = .active(f.driver)
    let g = AppleWorkoutGateway(factory: f); let result = await g.reconcile(try operation(.recover))
    XCTAssertEqual(result.outcome, .paused); XCTAssertTrue(f.driver.calls.isEmpty); XCTAssertEqual(f.creations, 0)
  }
  func testSavedRecoveryClosesOldSegmentWithoutInventingUUID() async throws {
    let f = FakeFactory(); f.lookup = .saved(DriverState(outcome: .linked(workoutID: "QUERY-UUID")))
    let result = await AppleWorkoutGateway(factory: f).reconcile(try operation(.recover))
    XCTAssertEqual(result.outcome, .linked(workoutID: "QUERY-UUID")); XCTAssertEqual(result.failure, .recoveryUnavailable)
  }
  func testTimeoutDoesNotHoldDriverAndLateStartOnlyFinishesOriginalToken() async throws {
    let f = FakeFactory(); f.driver.hangStart = true
    let g = AppleWorkoutGateway(factory: f, timeout: .milliseconds(20))
    let result = await g.perform(try operation(.start)); XCTAssertEqual(result.outcome, .unknown)
    let finished = await g.perform(try operation(.finish)); XCTAssertEqual(finished.outcome, .linked(workoutID: "REAL-UUID"))
    f.driver.suspendedStart?.resume(returning: DriverState(outcome: .running)); f.driver.suspendedStart = nil
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(f.creations, 1); XCTAssertEqual(f.driver.calls.filter { $0 == "save" }.count, 1)
    let current = await g.reconcile(try operation(.start)); XCTAssertEqual(current.outcome, .linked(workoutID: "REAL-UUID"))
  }
  func testCrossBindingTokenRejectedBeforeSideEffect() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    _ = await g.perform(try operation(.start))
    let wrong = try CaptureOperation(id: "bad-pause", binding: CaptureBinding(matchID: "other", recordingDeviceID: "watch"), associatedCommandID: "c", action: .pause, requestedAt: Date(), externalToken: "start")
    let result = await g.perform(wrong); XCTAssertEqual(result.outcome, .unknown); XCTAssertFalse(f.driver.calls.contains("pause"))
  }
  func testTimeoutThenLateNilNilThenQueryUUIDKeepsFirstSave() async throws {
    let f = FakeFactory(); f.driver.hangSave = true
    let g = AppleWorkoutGateway(factory: f, timeout: .milliseconds(10))
    _ = await g.perform(try operation(.start)); let first = await g.perform(try operation(.finish))
    XCTAssertEqual(first.outcome, .unknown)
    f.driver.suspendedSave?.resume(returning: DriverState(outcome: .savedAwaitingLink)); f.driver.suspendedSave = nil
    for _ in 0..<5 { await Task.yield() }
    let locked = await g.reconcile(try operation(.finish)); XCTAssertEqual(locked.outcome, .savedAwaitingLink)
    f.lookup = .saved(DriverState(outcome: .linked(workoutID: "REAL-LATE-UUID")))
    let linked = await g.reconcile(try operation(.finish)); XCTAssertEqual(linked.outcome, .linked(workoutID: "REAL-LATE-UUID"))
    f.driver.state = DriverState(outcome: .running)
    let old = await g.reconcile(try operation(.start)); XCTAssertEqual(old.outcome, .linked(workoutID: "REAL-LATE-UUID"))
    XCTAssertEqual(f.driver.calls.filter { $0 == "save" }.count, 1)
  }
  func testReconcileRejectsMutatedOriginalOperation() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    _ = await g.perform(try operation(.start))
    let original = try operation(.start)
    let changed = try CaptureOperation(id: original.id, binding: original.binding, associatedCommandID: "different", action: .start, requestedAt: original.requestedAt, externalToken: original.externalToken)
    let result = await g.reconcile(changed); XCTAssertEqual(result.outcome, .unknown)
  }
  func testReconcileAdvancesKnownStoppedSameBuilderWithoutRepeatingSave() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    _ = await g.perform(try operation(.start)); f.driver.state = DriverState(outcome: .stopped, failure: .captureFailed)
    let result = await g.reconcile(try operation(.finish))
    XCTAssertEqual(result.outcome, .linked(workoutID: "REAL-UUID")); XCTAssertEqual(f.creations, 1)
  }

  func testFailedStopCanRetryOriginalTokenOnNewTerminalOperation() async throws {
    let f = FakeFactory(); f.driver.stopFailures = 1; let g = AppleWorkoutGateway(factory: f)
    _ = await g.perform(try operation(.start)); let failed = await g.perform(try operation(.finish))
    XCTAssertEqual(failed.outcome, .running); XCTAssertEqual(failed.failure, .captureFailed)
    let saved = await g.perform(try operation(.finish, id: "finish-second"))
    XCTAssertEqual(saved.outcome, .linked(workoutID: "REAL-UUID")); XCTAssertEqual(f.creations, 1)
    XCTAssertEqual(f.driver.calls.filter { $0 == "stopped" }.count, 2); XCTAssertEqual(f.driver.calls.filter { $0 == "save" }.count, 1)
  }

  func testEndDuringFreshAuthorizationProvesOnlyOriginalStartNeverCreated() async throws {
    let f = FakeFactory(); f.holdAuthorization = true; let g = AppleWorkoutGateway(factory: f)
    let start = try operation(.start); let finish = try operation(.finish)
    let starting = Task { await g.perform(start) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !f.authorizationStarted && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(f.authorizationStarted)
    let ending = await g.perform(finish); XCTAssertEqual(ending.outcome, .unknown)
    f.releaseAuthorization(); let endedStart = await starting.value
    XCTAssertEqual(endedStart.outcome, .notCreated(.unavailable)); XCTAssertEqual(f.creations, 0)
    let original = await g.reconcile(start); XCTAssertEqual(original.outcome, .notCreated(.unavailable))
    let notStart = await g.reconcile(finish); XCTAssertEqual(notStart.outcome, .unknown); XCTAssertEqual(f.creations, 0)
    _ = await g.perform(finish) // Previously cached unknown finish response must not erase proven start absence.
    let stillAbsent = await g.reconcile(start); XCTAssertEqual(stillAbsent.outcome, .notCreated(.unavailable))
  }
  func testTimedOutFreshAuthorizationStillNeverCreatesAfterTerminal() async throws {
    let f = FakeFactory(); f.holdAuthorization = true; let g = AppleWorkoutGateway(factory: f, timeout: .milliseconds(5))
    let start = try operation(.start); let first = await g.perform(start); XCTAssertEqual(first.outcome, .unknown)
    _ = await g.perform(try operation(.finish)); f.releaseAuthorization()
    for _ in 0..<10 { await Task.yield() }
    let original = await g.reconcile(start); XCTAssertEqual(original.outcome, .notCreated(.unavailable)); XCTAssertEqual(f.creations, 0)
  }
  func testRestartOrPriorRecoveryCannotProveFreshNegativeCreation() async throws {
    let f = FakeFactory(); let g = AppleWorkoutGateway(factory: f)
    let start = try operation(.start); _ = await g.reconcile(start); _ = await g.perform(try operation(.finish))
    let result = await g.perform(start); XCTAssertEqual(result.outcome, .unknown); XCTAssertEqual(f.creations, 0)
    let restarted = AppleWorkoutGateway(factory: f); let afterRestart = await restarted.reconcile(start)
    XCTAssertEqual(afterRestart.outcome, .unknown)
  }
  func testConstructedDriverCannotTurnUncertainStartIntoNegativeProof() async throws {
    let f = FakeFactory(); f.driver.hangStart = true
    let g = AppleWorkoutGateway(factory: f, timeout: .milliseconds(5)); let start = try operation(.start)
    let first = await g.perform(start); XCTAssertEqual(first.outcome, .unknown); XCTAssertEqual(f.creations, 1)
    _ = await g.perform(try operation(.finish)); f.driver.suspendedStart?.resume(returning: DriverState(outcome: .unknown)); f.driver.suspendedStart = nil
    for _ in 0..<10 { await Task.yield() }
    let result = await g.reconcile(start); XCTAssertNotEqual(result.outcome, .notCreated(.unavailable)); XCTAssertEqual(f.creations, 1)
  }

}
