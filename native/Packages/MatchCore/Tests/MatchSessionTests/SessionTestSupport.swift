import Foundation
import MatchCore
import MatchSession
import XCTest

@testable import MatchStore

final class TestClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { date } }
  func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
}
final class TestIDs: SessionIDFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func nextID() -> String {
    lock.withLock {
      count += 1
      return "id-\(count)"
    }
  }
}
struct Identity: DeviceIdentityProvider {
  let value: String
  func localDeviceID() async throws -> String { value }
}
actor TestRepository: SessionRepository {
  let store: MatchStore
  var holdFaultProjection = false
  var holdTail = false
  var snapshotsAfterObservation: Int?
  var tailRead = false
  var heldTail: CheckedContinuation<Void, Never>?
  var tailWaiters: [CheckedContinuation<Void, Never>] = []
  var fail = false
  var lose = false
  var failSuccessor = false
  var successorFailed = false
  var successorWaiters: [CheckedContinuation<Void, Never>] = []
  var loseSuffix: String?
  var observationFault: String?
  var observations = 0
  var observationWaiters: [CheckedContinuation<Void, Never>] = []
  init(_ store: MatchStore) { self.store = store }
  func databaseNamespace() async -> String { "test-development" }
  func matchIDs() async throws -> [String] { try await store.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 {
    let snapshot = try await store.snapshotV2(matchID: matchID)
    if let count = snapshotsAfterObservation {
      snapshotsAfterObservation = count + 1
      if count == 1, holdTail {
        holdTail = false
        tailRead = true
        tailWaiters.forEach { $0.resume() }
        tailWaiters = []
        await withCheckedContinuation { heldTail = $0 }
      }
    }
    return snapshot
  }
  func holdSecondSnapshotAfterObservation() {
    holdTail = true
    snapshotsAfterObservation = nil
    tailRead = false
  }
  func waitForHeldTail() async {
    if tailRead { return }
    await withCheckedContinuation { tailWaiters.append($0) }
  }
  func releaseTail() {
    heldTail?.resume()
    heldTail = nil
  }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? {
    try await store.committedCommandV2(commandID: commandID)
  }
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    if fail {
      fail = false
      throw StoreError.injectedFailure
    }
    if failSuccessor, request.newCaptureOperations.contains(where: { $0.id.contains("/restart/") })
    {
      failSuccessor = false
      successorFailed = true
      successorWaiters.forEach { $0.resume() }
      successorWaiters = []
      throw StoreError.injectedFailure
    }
    let isObservation = request.captureOperationUpdates.contains { $0.observation != nil }
    let fault = isObservation ? observationFault : nil
    if isObservation { observationFault = nil }
    if fault == "before" {
      if holdFaultProjection {
        holdFaultProjection = false
        holdTail = true
        snapshotsAfterObservation = 1
      }
      observations += 1
      observationWaiters.forEach { $0.resume() }
      observationWaiters = []
      throw StoreError.injectedFailure
    }
    let r = try await store.commitV2(request)
    if isObservation {
      if holdTail { snapshotsAfterObservation = 0 }
      observations += 1
      observationWaiters.forEach { $0.resume() }
      observationWaiters = []
    }
    if fault == "after" { throw StoreError.responseLost }
    if let suffix = loseSuffix, request.commandID.hasSuffix(suffix) {
      loseSuffix = nil
      throw StoreError.responseLost
    }
    if lose {
      lose = false
      throw StoreError.responseLost
    }
    return r
  }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] {
    try await store.pendingCaptureOperations(matchID: matchID)
  }
  func holdProjectionAfterObservationFailure() {
    holdFaultProjection = true
    tailRead = false
  }
  func failNextObservation(_ mode: String) {
    observationFault = mode
    observations = 0
  }
  func waitForObservation() async {
    if observations > 0 { return }
    await withCheckedContinuation { observationWaiters.append($0) }
  }
  func waitForSuccessorFailure() async {
    if successorFailed { return }
    await withCheckedContinuation { successorWaiters.append($0) }
  }
  func failNextRecoverySuccessor() {
    failSuccessor = true
    successorFailed = false
  }
  func loseNextStartResponse() { loseSuffix = "/start" }
  func failNextCommit() { fail = true }
  func loseNextResponse() { lose = true }
}
actor FakeGateway: WorkoutGateway {
  var performed: [CaptureOperation] = []
  var reconciled: [CaptureOperation] = []
  var outcome: WorkoutOutcome = .running
  var failure: CaptureFailure?
  var suspend = false
  var scripts: [String: [WorkoutOutcome]] = [:]
  var reconcileTime: Date?
  var reconSuspend = false
  var reconContinuation: CheckedContinuation<Void, Never>?
  var reconWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  var suspended: CheckedContinuation<Void, Never>?
  var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  func waitForPerform(_ count: Int) async {
    if performed.count >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
  func script(_ action: CaptureAction, _ outcomes: [WorkoutOutcome]) {
    scripts[action.rawValue] = outcomes
  }
  func waitForReconcile(_ count: Int) async {
    if reconciled.count >= count { return }
    await withCheckedContinuation { reconWaiters.append((count, $0)) }
  }
  func setReconciliationTime(_ time: Date) { reconcileTime = time }
  func suspendReconciliation() { reconSuspend = true }
  func releaseReconciliation() {
    reconSuspend = false
    reconContinuation?.resume()
    reconContinuation = nil
  }
  func configure(
    outcome: WorkoutOutcome = .running, failure: CaptureFailure? = nil, suspend: Bool = false
  ) {
    self.outcome = outcome
    self.failure = failure
    self.suspend = suspend
  }
  func release() {
    suspend = false
    suspended?.resume()
    suspended = nil
  }
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    performed.append(operation)
    let ready = waiters.filter { $0.0 <= performed.count }
    waiters.removeAll { $0.0 <= performed.count }
    ready.forEach { $0.1.resume() }
    if suspend { await withCheckedContinuation { suspended = $0 } }
    var scripted: WorkoutOutcome?
    if var list = scripts[operation.action.rawValue], !list.isEmpty {
      scripted = list.removeFirst()
      scripts[operation.action.rawValue] = list
    }
    let actual: WorkoutOutcome =
      scripted
      ?? (operation.action == .finish
        ? .linked(workoutID: "actual-workout-" + operation.externalToken)
        : operation.action == .pause ? .paused : outcome)
    return try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: operation.requestedAt.addingTimeInterval(0.1), outcome: actual,
      window: CaptureWindow(start: nil, end: nil), failure: failure)
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    reconciled.append(operation)
    let ready = reconWaiters.filter { $0.0 <= reconciled.count }
    reconWaiters.removeAll { $0.0 <= reconciled.count }
    ready.forEach { $0.1.resume() }
    if reconSuspend { await withCheckedContinuation { reconContinuation = $0 } }
    return try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: reconcileTime ?? operation.requestedAt.addingTimeInterval(0.2), outcome: outcome,
      window: CaptureWindow(start: nil, end: nil), failure: failure)
  }
}
struct Harness: Sendable {
  let url: URL
  let repo: TestRepository
  let gateway: FakeGateway
  let clock: TestClock
  let ids: TestIDs
  let session: MatchSession
  init(permits: any StartPermitProvider = DevelopmentStartPermitProvider()) throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "session-" + UUID().uuidString + ".sqlite")
    repo = TestRepository(try MatchStore(url: url))
    gateway = FakeGateway()
    clock = TestClock()
    ids = TestIDs()
    session = MatchSession(
      store: repo, deviceIdentity: Identity(value: "watch"), clock: clock, ids: ids,
      permits: permits, workout: gateway,
      environment: .development(databaseNamespace: "test-development"))
  }
  func newSession(
    permits: any StartPermitProvider = DevelopmentStartPermitProvider(), device: String = "watch",
    environment: SessionEnvironment = .development(databaseNamespace: "test-development")
  ) -> MatchSession {
    MatchSession(
      store: repo, deviceIdentity: Identity(value: device), clock: clock, ids: ids,
      permits: permits, workout: gateway, environment: environment)
  }
  func waitCaptureSettled(_ match: String) async throws {
    try await eventually("capture did not settle") {
      let s = try await repo.snapshotV2(matchID: match)
      return s.captureOperations.allSatisfy {
        $0.state == .settled || $0.state == .failed || $0.state == .cancelled
      }
    }
  }
}

func eventually(_ message: String, condition: @Sendable () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  XCTFail(message)
}
