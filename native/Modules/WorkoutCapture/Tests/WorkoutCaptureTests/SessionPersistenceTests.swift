import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import WorkoutCapture

private struct IntegrationIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "watch" } }
private final class IntegrationClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock(); private var date = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { date } }
  func advance() { lock.withLock { date.addTimeInterval(10) } }
}
private actor FaultRepository: SessionRepository {
  let inner: SQLiteSessionRepository
  var mode: String?
  var failed = false
  var failedAction: WorkoutOutcome?
  init(_ inner: SQLiteSessionRepository) { self.inner = inner }
  func inject(_ mode: String, outcome: WorkoutOutcome? = nil) { self.mode = mode; failed = false; failedAction = outcome }
  func databaseNamespace() async -> String { await inner.databaseNamespace() }
  func matchIDs() async throws -> [String] { try await inner.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await inner.snapshotV2(matchID: matchID) }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await inner.committedCommandV2(commandID: commandID) }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await inner.pendingCaptureOperations(matchID: matchID) }
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    let matches = request.captureOperationUpdates.contains { update in
      guard let observation = update.observation else { return false }
      return failedAction == nil || observation.outcome == failedAction
    }
    let fault = matches ? mode : nil
    if fault != nil { mode = nil; failed = true }
    if fault == "before" { throw StoreError.injectedFailure }
    let receipt = try await inner.commitV2(request)
    if fault == "after" { throw StoreError.responseLost }
    return receipt
  }
}
private actor GatewayProbe: WorkoutGateway {
  let actual: AppleWorkoutGateway
  var performed: [CaptureOperation] = []
  var reconciled: [CaptureOperation] = []
  init(_ actual: AppleWorkoutGateway) { self.actual = actual }
  func perform(_ op: CaptureOperation) async -> WorkoutObservation { performed.append(op); return await actual.perform(op) }
  func reconcile(_ op: CaptureOperation) async -> WorkoutObservation { reconciled.append(op); return await actual.reconcile(op) }
}
@MainActor final class SessionPersistenceTests: XCTestCase {
  private func wait(_ description: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    XCTFail(description); throw StoreError.injectedFailure
  }
  private func session(_ repo: any SessionRepository, _ gateway: any WorkoutGateway, _ clock: IntegrationClock) -> MatchSession {
    MatchSession(store: repo, deviceIdentity: IntegrationIdentity(), clock: clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: gateway, environment: .development(databaseNamespace: "capture-integration"))
  }
  func testActualGatewayStartSuccessThenSQLiteFailureReconcilesOriginalToken() async throws {
    try await exercise(saveFault: "before")
  }
  func testActualGatewaySavedAwaitingLinkThenLostSQLiteResponseNeverFinishesAgain() async throws {
    try await exercise(saveFault: "after")
  }
  private func exercise(saveFault: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NATIVE008-integration-" + UUID().uuidString)
    let sql = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let fault = FaultRepository(sql); let factory = FakeFactory(); factory.driver.saveResult = DriverState(outcome: .savedAwaitingLink)
    let gateway = AppleWorkoutGateway(factory: factory); let probe = GatewayProbe(gateway); let clock = IntegrationClock()
    let original = session(fault, probe, clock)
    await fault.inject("before")
    let request = try await original.prepareStart(starter: true); _ = try await original.execute(request)
    try await wait("start observation DB write must fail") { await fault.failed }
    let uncertain = try await sql.snapshotV2(matchID: request.matchID)
    XCTAssertEqual(uncertain.captureOperations.first?.state, .needsReconciliation)
    XCTAssertEqual(factory.creations, 1)
    // A second real connection reopens exactly the same durable database; it is not an in-memory repository.
    let reopenedSQL = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let reopenedFault = FaultRepository(reopenedSQL); let reopened = session(reopenedFault, probe, clock)
    _ = try await reopened.recover()
    try await wait("original start token should reconcile") {
      try await reopenedSQL.snapshotV2(matchID: request.matchID).captureOperations.allSatisfy { $0.state == .settled }
    }
    XCTAssertEqual(factory.creations, 1)
    let reconciliations = await probe.reconciled; XCTAssertTrue(reconciliations.contains { $0.id == request.captureOperationID && $0.externalToken == request.captureOperationID })
    await reopenedFault.inject(saveFault, outcome: .savedAwaitingLink)
    clock.advance(); _ = try await reopened.execute(reopened.prepare(.end, matchID: request.matchID))
    try await wait("save observation failure must be injected") { await reopenedFault.failed }
    let afterSave = try await reopenedSQL.snapshotV2(matchID: request.matchID)
    XCTAssertTrue(afterSave.captureRevisions.flatMap(\.metadata.segments).isEmpty)
    let thirdSQL = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let third = session(thirdSQL, probe, clock); _ = try await third.recover()
    try await wait("saved nil,nil should remain awaiting real UUID") {
      try await thirdSQL.snapshotV2(matchID: request.matchID).captureOperations.contains { $0.operation.action == .finish && $0.observation?.outcome == .savedAwaitingLink }
    }
    XCTAssertEqual(factory.driver.calls.filter { $0 == "save" }.count, 1)
    let awaitingUUID = try await thirdSQL.snapshotV2(matchID: request.matchID)
    XCTAssertTrue(awaitingUUID.captureRevisions.flatMap(\.metadata.segments).isEmpty)
    factory.lookup = .saved(DriverState(outcome: .linked(workoutID: "REAL-QUERY-UUID"), start: Date(timeIntervalSince1970: 200), end: Date(timeIntervalSince1970: 201)))
    _ = try await third.recover()
    try await wait("real query UUID must persist once") {
      try await thirdSQL.snapshotV2(matchID: request.matchID).captureRevisions.last?.metadata.segments.count == 1
    }
    let final = try await thirdSQL.snapshotV2(matchID: request.matchID)
    XCTAssertEqual(final.captureRevisions.last?.metadata.segments.first?.workoutID, "REAL-QUERY-UUID")
    XCTAssertEqual(factory.creations, 1); XCTAssertEqual(factory.driver.calls.filter { $0 == "save" }.count, 1)
    let all = await probe.performed + probe.reconciled
    XCTAssertEqual(Set(all.map(\.externalToken)), [request.captureOperationID!])
    XCTAssertEqual(all.filter { $0.action == .start && $0.id == request.captureOperationID }.map(\.externalToken).first, request.captureOperationID)
    try await sql.close(); try await reopenedSQL.close(); try await thirdSQL.close()
  }
}
