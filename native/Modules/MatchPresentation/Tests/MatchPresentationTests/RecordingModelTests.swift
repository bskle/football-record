import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
@testable import MatchPresentation
actor FaultRepository: SessionRepository {
  let underlying: SQLiteSessionRepository
  var nextFault: String?
  init(_ r: SQLiteSessionRepository) { underlying = r }
  func fault(_ name: String) { nextFault = name }
  func databaseNamespace() async -> String { await underlying.databaseNamespace() }
  func matchIDs() async throws -> [String] { try await underlying.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await underlying.snapshotV2(matchID: matchID) }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await underlying.committedCommandV2(commandID: commandID) }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await underlying.pendingCaptureOperations(matchID: matchID) }
  func commitV2(_ r: StoreCommitV2) async throws -> CommitReceiptV2 {
    let business = r.events.contains { $0.type == .scoreEvent }
    let fault = business ? nextFault : nil
    if business { nextFault = nil }
    if fault == "before" { throw StoreError.injectedFailure }
    let saved = try await underlying.commitV2(r)
    if fault == "after" { throw StoreError.responseLost }
    return saved
  }
}
@MainActor final class RecordingModelTests: XCTestCase {
  func fixture() throws -> (RecordingModel, FaultRepository, Clock) {
    let f = try Fixture(); let r = FaultRepository(f.repository)
    let s = MatchSession(store: r, deviceIdentity: Identity(), clock: f.clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "presentation-test"))
    return (RecordingModel(session: s, repository: r, development: true), r, f.clock)
  }
  func testSelectingThenCancellingDoesNotCreateMatch() async throws {
    let (m, r, _) = try fixture(); await m.load()
    let ids = try await r.matchIDs(); XCTAssertTrue(ids.isEmpty); XCTAssertNil(m.snapshot)
  }
  func testFailedCommitKeepsSnapshotAndOriginalRequestUntilReceiptRetry() async throws {
    let (m, r, c) = try fixture(); await m.start(starter: false)
    try await Task.sleep(for: .milliseconds(40)); c.advance(2)
    await r.fault("before"); await m.perform(.quick(.myGoal))
    XCTAssertEqual(m.snapshot?.replay.score.forTeam, 0); XCTAssertEqual(m.feedbackCount, 1)
    let pending = try XCTUnwrap(m.pendingRequest)
    await m.retry()
    XCTAssertNil(m.pendingRequest); XCTAssertEqual(m.snapshot?.replay.score.forTeam, 1)
    XCTAssertEqual(m.feedbackCount, 2)
    let saved = try await r.committedCommandV2(commandID: pending.commandID)
    XCTAssertEqual(saved?.request.commandID, pending.commandID)
    XCTAssertEqual(saved?.request.events.first?.createdAt, pending.requestedAt)
  }
  func testLostResponseReplaysOriginalRequestWithoutDoubleScore() async throws {
    let (m, r, c) = try fixture(); await m.start(starter: true)
    try await Task.sleep(for: .milliseconds(40)); c.advance(2)
    await r.fault("after"); await m.perform(.quick(.myAssist))
    let pending = try XCTUnwrap(m.pendingRequest)
    c.advance(10); await m.retry()
    XCTAssertEqual(m.snapshot?.replay.score.forTeam, 1); XCTAssertEqual(m.feedbackCount, 2)
    let saved = try await r.committedCommandV2(commandID: pending.commandID)
    XCTAssertEqual(saved?.request.events.first?.createdAt, pending.requestedAt)
  }
  func testUndoClearsCrossButtonGuardAndEndsRemainLocked() async throws {
    let (m, _, c) = try fixture(); await m.start(starter: true)
    try await Task.sleep(for: .milliseconds(40)); c.advance(2)
    await m.perform(.quick(.myGoal)); await m.perform(.quick(.conceded))
    XCTAssertEqual(m.snapshot?.replay.score.against, 0)
    await m.perform(.undoLastQuick); await m.perform(.quick(.conceded))
    XCTAssertEqual(m.snapshot?.replay.score.forTeam, 0); XCTAssertEqual(m.snapshot?.replay.score.against, 1)
    await m.perform(.end); XCTAssertEqual(m.snapshot?.replay.state, .endedPendingSync)
    await m.start(starter: true); XCTAssertEqual(m.snapshot?.replay.state, .endedPendingSync)
  }
}

actor HeldFailureClient: SessionCommanding {
  let underlying: MatchSession
  let initial: SessionSnapshot
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  var original: SessionRequest?
  init(_ session: MatchSession, initial: SessionSnapshot) { underlying = session; self.initial = initial }
  func prepareStart(starter: Bool) async throws -> SessionRequest { try await underlying.prepareStart(starter: starter) }
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest { try await underlying.prepare(action, matchID: matchID) }
  func execute(_ request: SessionRequest) async throws -> SessionReceipt {
    original = request; entered = true
    await withCheckedContinuation { continuation = $0 }
    throw StoreError.responseLost
  }
  func release() { continuation?.resume(); continuation = nil }
  func recover() async throws -> RecoverySelection { .active(initial) }
  func snapshot(matchID: String) async throws -> SessionSnapshot { try await underlying.snapshot(matchID: matchID) }
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot> { AsyncStream { $0.yield(initial) } }
}
extension RecordingModelTests {
  func testFailureCannotRollBackNewerCommittedCaptureOrBusinessUpdate() async throws {
    let f = try Fixture(); let first = try await f.start()
    try await Task.sleep(for: .milliseconds(40)); f.clock.advance(2)
    let newer = try await f.act(.pause, first.replay.matchID)
    let client = HeldFailureClient(f.session, initial: first)
    let m = RecordingModel(session: client, repository: f.repository, development: true)
    await m.load()
    let task = Task { await m.perform(.quick(.myGoal)) }
    while !(await client.entered) { await Task.yield() }
    // Same delivery entry used by the live AsyncStream, after the click and before its failure.
    m.accept(newer)
    await client.release(); await task.value
    XCTAssertEqual(m.snapshot?.store.business.generation, newer.store.business.generation)
    XCTAssertEqual(m.snapshot?.replay.state, .paused)
    let original = await client.original
    XCTAssertEqual(m.pendingRequest, original); XCTAssertEqual(m.feedbackCount, 0)
    m.accept(first)
    XCTAssertEqual(m.snapshot?.store.business.generation, newer.store.business.generation)
  }
}
