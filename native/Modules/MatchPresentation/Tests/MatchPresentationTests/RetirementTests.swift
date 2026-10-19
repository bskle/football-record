import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
import MatchSync
@testable import MatchPresentation

@MainActor final class RetirementTests: XCTestCase {
  func testShutdownJoinsHeldPrepareAndCannotExecuteItsLateRequest() async throws {
    let f = try Fixture(), client = RetirementClient(try Fixture().session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    await client.hold(.prepare)
    let starting = Task { await model.start(starter: true) }
    await client.waitForEntry()
    model.beginRetirement()
    var finished = false
    let shutting = Task { await model.shutdown(); finished = true }
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(finished, "shutdown must join the direct prepare operation")
    await client.release()
    await starting.value; await shutting.value
    let calls = await client.executions
    XCTAssertEqual(calls, 0)
    XCTAssertNil(model.pendingRequest); XCTAssertNil(model.snapshot); XCTAssertFalse(model.busy)
    await model.start(starter: true); await model.load()
    XCTAssertNil(model.snapshot); XCTAssertFalse(model.canRecord)
  }

  func testHeldHistoryCannotStartRecoveryOrRestoreSensitiveProjection() async throws {
    let f = try Fixture(); _ = try await f.start()
    let client = RetirementClient(f.session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    await client.hold(.snapshot)
    let loading = Task { await model.load() }
    await client.waitForEntry()
    model.metrics.heartRate = .available(123)
    model.beginRetirement()
    var finished = false
    let shutting = Task { await model.shutdown(); finished = true }
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(finished)
    await client.release()
    await loading.value; await shutting.value
    let recoveries = await client.recoveries
    XCTAssertEqual(recoveries, 0)
    XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.snapshot)
    XCTAssertNil(model.pendingRequest); XCTAssertNil(model.issue); XCTAssertNil(model.authorityStatus)
    XCTAssertEqual(model.metrics, LiveMetrics()); XCTAssertEqual(model.feedbackCount, 0)
    XCTAssertTrue(model.readOnly)
  }

  func testShutdownClearsExistingFactsAndDoesNotCloseOriginalRepository() async throws {
    let f = try Fixture()
    let model = RecordingModel(session: f.session, repository: f.repository, development: true)
    await model.start(starter: true); await model.load()
    let id = try XCTUnwrap(model.snapshot?.replay.matchID)
    XCTAssertFalse(model.history.isEmpty)
    model.metrics.distance = .available(456)
    model.beginRetirement()
    try await f.session.retireBusiness()
    async let a: Void = model.shutdown()
    async let b: Void = model.shutdown()
    await a; await b
    XCTAssertNil(model.snapshot); XCTAssertTrue(model.history.isEmpty)
    XCTAssertEqual(model.feedbackCount, 0); XCTAssertEqual(model.metrics, LiveMetrics())
    let persisted = try await f.repository.snapshotV2(matchID: id)
    XCTAssertFalse(persisted.business.events.isEmpty)
  }

  func testSyncShutdownJoinsHeldObservationRegistrationAndCanRestart() async throws {
    let source = RetirementSyncSource()
    let model = SyncStatusModel(service: source)
    model.observe(matchID: "old")
    await source.waitForEntry()
    var finished = false
    let closing = Task { await model.shutdown(); finished = true }
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(finished)
    await source.release()
    await closing.value
    XCTAssertNil(model.matchID); XCTAssertNil(model.state)
    await model.start(); model.observe(matchID: "new")
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(model.matchID, "new")
    await model.shutdown()
  }
}

private actor RetirementClient: SessionCommanding {
  enum Held { case prepare, snapshot }
  let underlying: MatchSession
  var point: Held?
  var entered = false
  var waiter: CheckedContinuation<Void, Never>?
  var blocked: CheckedContinuation<Void, Never>?
  var executions = 0
  var recoveries = 0
  init(_ session: MatchSession) { underlying = session }
  func hold(_ point: Held) { self.point = point; entered = false }
  func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
  func release() { blocked?.resume(); blocked = nil; point = nil }
  func pause(_ point: Held) async {
    guard self.point == point else { return }
    entered = true; waiter?.resume(); waiter = nil
    await withCheckedContinuation { blocked = $0 }
  }
  func prepareStart(starter: Bool) async throws -> SessionRequest {
    await pause(.prepare); return try await underlying.prepareStart(starter: starter)
  }
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest { try await underlying.prepare(action, matchID: matchID) }
  func execute(_ request: SessionRequest) async throws -> SessionReceipt { executions += 1; return try await underlying.execute(request) }
  func recover() async throws -> RecoverySelection { recoveries += 1; return try await underlying.recover() }
  func snapshot(matchID: String) async throws -> SessionSnapshot { await pause(.snapshot); return try await underlying.snapshot(matchID: matchID) }
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot> { await underlying.updates(matchID: matchID) }
}
private actor RetirementSyncSource: SyncStatusServing {
  var entered = false
  var waiter: CheckedContinuation<Void, Never>?
  var blocked: CheckedContinuation<Void, Never>?
  var released = false
  func start() async throws {}
  func stop() async {}
  func wake() async {}
  func retry() async {}
  func state(matchID: String) async throws -> SyncState { try SyncState(matchID: matchID, unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: nil, issue: nil) }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> {
    if !released {
      entered = true; waiter?.resume(); waiter = nil
      await withCheckedContinuation { blocked = $0 }
    }
    return AsyncStream { $0.finish() }
  }
  func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
  func release() { released = true; blocked?.resume(); blocked = nil }
}
