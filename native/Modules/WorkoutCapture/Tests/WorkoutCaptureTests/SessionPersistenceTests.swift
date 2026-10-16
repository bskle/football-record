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
  var cancellationFault: String?
  init(_ inner: SQLiteSessionRepository) { self.inner = inner }
  func inject(_ mode: String, outcome: WorkoutOutcome? = nil) { self.mode = mode; failed = false; failedAction = outcome }
  func injectCancellation(_ mode: String) { cancellationFault = mode; failed = false }
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
    let cancelsUncertainFinish = request.captureOperationUpdates.contains { $0.expectedState == .needsReconciliation && $0.state == .cancelled }
    let fault = cancelsUncertainFinish ? cancellationFault : (matches ? mode : nil)
    if fault != nil { if cancelsUncertainFinish { cancellationFault = nil } else { mode = nil }; failed = true }
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

  func testHeldAuthorizationCancelsUncertainFinishBeforePermissionReturns() async throws {
    try await exerciseTerminalProof(observationFault: nil, cancellationFault: nil)
  }
  func testHeldAuthorizationNegativeObservationFailureReopensSameSQLite() async throws {
    try await exerciseTerminalProof(observationFault: "before", cancellationFault: nil)
  }
  func testHeldAuthorizationNegativeObservationLostResponseReopensSameSQLite() async throws {
    try await exerciseTerminalProof(observationFault: "after", cancellationFault: nil)
  }
  func testHeldAuthorizationCancellationLostResponseReopensDurableProof() async throws {
    try await exerciseTerminalProof(observationFault: nil, cancellationFault: "after")
  }
  private func exerciseTerminalProof(observationFault: String?, cancellationFault: String?) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NATIVE008-terminal-" + UUID().uuidString)
    let sql = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let fault = FaultRepository(sql); let factory = FakeFactory(); factory.holdAuthorization = true
    defer { factory.releaseAuthorization() }
    let gateway = AppleWorkoutGateway(factory: factory, timeout: .milliseconds(10)); let probe = GatewayProbe(gateway); let clock = IntegrationClock()
    let original = session(fault, probe, clock)
    let request = try await original.prepareStart(starter: true); let startReceipt = try await original.execute(request)
    try await wait("actual gateway start timeout must be persisted while authorization hangs") {
      try await sql.snapshotV2(matchID: request.matchID).captureOperations.contains { $0.operation.action == .start && $0.state == .needsReconciliation && $0.observation?.outcome == .unknown }
    }
    XCTAssertNotNil(factory.authorizationContinuation); XCTAssertEqual(factory.creations, 0)
    clock.advance(); let endRequest = try await original.prepare(.end, matchID: request.matchID)
    let endReceipt = try await original.execute(endRequest)
    try await wait("finish must already be uncertain before the local start proof is persisted") {
      try await sql.snapshotV2(matchID: request.matchID).captureOperations.contains { $0.operation.action == .finish && $0.state == .needsReconciliation && $0.observation?.outcome == .unknown }
    }
    XCTAssertNotNil(factory.authorizationContinuation); XCTAssertEqual(factory.creations, 0)
    if let observationFault { await fault.inject(observationFault, outcome: .notCreated(.unavailable)) }
    if let cancellationFault { await fault.injectCancellation(cancellationFault) }
    _ = try await original.recover()
    if observationFault != nil || cancellationFault != nil {
      try await wait("configured observation/cancellation failure must execute") { await fault.failed }
    }
    // Reopen the same actual SQLite file. Local gateway ownership is deliberately retained;
    // a new gateway cannot inherit unpersisted negative proof (separate regression below).
    let reopenedSQL = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let reopened = session(reopenedSQL, probe, clock); _ = try await reopened.recover()
    try await wait("negative start must commit, then uncertain finish must cancel before authorization resolves") {
      let snapshot = try await reopenedSQL.snapshotV2(matchID: request.matchID)
      let pending = try await reopenedSQL.pendingCaptureOperations(matchID: request.matchID)
      return pending.isEmpty && snapshot.captureOperations.contains { $0.operation.action == .start && $0.state == .failed && $0.observation?.outcome == .notCreated(.unavailable) }
        && snapshot.captureOperations.contains { $0.operation.action == .finish && $0.state == .cancelled && $0.observation == nil }
    }
    XCTAssertNotNil(factory.authorizationContinuation, "Permission must remain suspended until cancellation is durable")
    let finalized = try await reopened.snapshot(matchID: request.matchID)
    XCTAssertEqual(finalized.capturePhase, .notRecorded(.unavailable)); XCTAssertEqual(finalized.replay.state, .endedPendingSync)
    XCTAssertEqual(finalized.replay.backendLockState, .held); XCTAssertTrue(finalized.store.captureRevisions.isEmpty)
    XCTAssertEqual(finalized.store.captureOperations.count, 2); XCTAssertEqual(factory.creations, 0); XCTAssertTrue(factory.driver.calls.isEmpty)
    XCTAssertEqual(Set(finalized.store.captureOperations.map(\.operation.externalToken)), [request.captureOperationID!])
    let originalEvents = finalized.store.business.events
    factory.releaseAuthorization(); for _ in 0..<20 { await Task.yield() }
    let startAgain = try await reopened.execute(request); let endAgain = try await reopened.execute(endRequest)
    XCTAssertEqual(startAgain.receipt, startReceipt.receipt); XCTAssertEqual(endAgain.receipt, endReceipt.receipt)
    let afterLate = try await reopened.snapshot(matchID: request.matchID)
    XCTAssertEqual(afterLate.store.business.events, originalEvents); XCTAssertEqual(afterLate.capturePhase, .notRecorded(.unavailable))
    XCTAssertEqual(afterLate.store.captureOperations.count, 2); XCTAssertEqual(factory.creations, 0); XCTAssertTrue(factory.driver.calls.isEmpty)
    XCTAssertTrue(afterLate.store.captureRevisions.isEmpty)
    let performed = await probe.performed; let reconciled = await probe.reconciled
    XCTAssertEqual(performed.filter { $0.action == .start }.count, 1)
    XCTAssertTrue(reconciled.contains { $0.action == .start && $0.id == request.captureOperationID })
    XCTAssertEqual(Set((performed + reconciled).map(\.externalToken)), [request.captureOperationID!])
    // Durable proof survives another connection with an entirely new gateway and no local evidence.
    let thirdSQL = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let noEvidenceFactory = FakeFactory(); let noEvidence = session(thirdSQL, AppleWorkoutGateway(factory: noEvidenceFactory), clock)
    _ = try await noEvidence.recover()
    let persisted = try await noEvidence.snapshot(matchID: request.matchID)
    XCTAssertEqual(persisted.capturePhase, .notRecorded(.unavailable)); XCTAssertEqual(noEvidenceFactory.creations, 0)
    XCTAssertEqual(noEvidenceFactory.recoveryCalls, 0)
    try await sql.close(); try await reopenedSQL.close(); try await thirdSQL.close()
  }
  func testRestartedGatewayWithoutPersistedAbsenceKeepsUnknownFinishUncancelled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NATIVE008-no-proof-" + UUID().uuidString)
    let sql = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let oldFactory = FakeFactory(); oldFactory.holdAuthorization = true; defer { oldFactory.releaseAuthorization() }
    let oldProbe = GatewayProbe(AppleWorkoutGateway(factory: oldFactory, timeout: .milliseconds(10))); let clock = IntegrationClock()
    let old = session(sql, oldProbe, clock); let request = try await old.prepareStart(starter: true); _ = try await old.execute(request)
    try await wait("unknown start must be durable") {
      try await sql.snapshotV2(matchID: request.matchID).captureOperations.contains { $0.operation.action == .start && $0.observation?.outcome == .unknown }
    }
    clock.advance(); _ = try await old.execute(old.prepare(.end, matchID: request.matchID))
    try await wait("unknown finish must exist before simulated process loss") {
      try await sql.snapshotV2(matchID: request.matchID).captureOperations.contains { $0.operation.action == .finish && $0.state == .needsReconciliation && $0.observation?.outcome == .unknown }
    }
    let reopenedSQL = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "capture-integration")
    let newFactory = FakeFactory(); let probe = GatewayProbe(AppleWorkoutGateway(factory: newFactory, timeout: .milliseconds(10)))
    let reopened = session(reopenedSQL, probe, clock); _ = try await reopened.recover()
    try await wait("fresh process must reconcile original operations without absence evidence") { await probe.reconciled.count >= 2 }
    let unknown = try await reopened.snapshot(matchID: request.matchID)
    XCTAssertEqual(unknown.capturePhase, .needsReconciliation); XCTAssertEqual(unknown.replay.state, .endedPendingSync); XCTAssertEqual(unknown.replay.backendLockState, .held)
    XCTAssertTrue(unknown.store.captureOperations.allSatisfy { $0.state == .needsReconciliation })
    XCTAssertFalse(unknown.store.captureOperations.contains { $0.state == .cancelled || $0.state == .failed })
    XCTAssertTrue(unknown.store.captureRevisions.isEmpty); XCTAssertEqual(newFactory.creations, 0); XCTAssertTrue(newFactory.driver.calls.isEmpty)
    let performed = await probe.performed; XCTAssertTrue(performed.isEmpty)
    oldFactory.releaseAuthorization(); for _ in 0..<20 { await Task.yield() }
    _ = try await reopened.recover()
    let stillUnknown = try await reopened.snapshot(matchID: request.matchID)
    XCTAssertEqual(stillUnknown.capturePhase, .needsReconciliation); XCTAssertFalse(stillUnknown.store.captureOperations.contains { $0.state == .cancelled })
    XCTAssertEqual(newFactory.creations, 0)
    try await sql.close(); try await reopenedSQL.close()
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
