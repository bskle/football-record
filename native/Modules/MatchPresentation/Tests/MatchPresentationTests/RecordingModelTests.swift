import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
@testable import MatchPresentation
actor FaultRepository: SessionRepository {
  let underlying: SQLiteSessionRepository
  var nextFault: String?
  var failRead = false
  init(_ r: SQLiteSessionRepository) { underlying = r }
  func fault(_ name: String) { nextFault = name }
  func failNextRead() { failRead = true }
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await underlying.syncRepositoryIdentity() }
  func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await underlying.unroutedBusinessOutboxV3(matchID: matchID) }
  func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await underlying.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
  func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await underlying.pendingPacketsV2(matchID: matchID) }
  func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await underlying.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
  func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await underlying.acknowledgeV2(bytes, peer: peer, now: now) }
  func syncStateV3(matchID: String) async throws -> SyncState { try await underlying.syncStateV3(matchID: matchID) }
  func ensureSyncDeliveriesV3(matchID: String) async throws { try await underlying.ensureSyncDeliveriesV3(matchID: matchID) }
  func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await underlying.dueSyncDeliveriesV3(now: now, limit: limit) }
  func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await underlying.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
  func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await underlying.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
  func reactivateSyncACKsV3() async throws { try await underlying.reactivateSyncACKsV3() }
  func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await underlying.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
  func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await underlying.pendingSyncAssembliesV3(peer: peer, now: now) }
  func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await underlying.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
  func expireSyncAssembliesV3(now: Date) async throws { try await underlying.expireSyncAssembliesV3(now: now) }
  func databaseNamespace() async -> String { await underlying.databaseNamespace() }
  func matchIDs() async throws -> [String] {
    if failRead { failRead = false; throw StoreError.injectedFailure }
    return try await underlying.matchIDs()
  }
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

actor StaleOnceClient: SessionCommanding {
  let underlying: MatchSession
  var invalidated = false
  init(_ s: MatchSession) { underlying = s }
  func prepareStart(starter: Bool) async throws -> SessionRequest { try await underlying.prepareStart(starter: starter) }
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest { try await underlying.prepare(action, matchID: matchID) }
  func execute(_ request: SessionRequest) async throws -> SessionReceipt {
    if request.action == .quick(.myAssist), !invalidated { invalidated = true; throw StoreError.staleGeneration }
    return try await underlying.execute(request)
  }
  func recover() async throws -> RecoverySelection { try await underlying.recover() }
  func snapshot(matchID: String) async throws -> SessionSnapshot { try await underlying.snapshot(matchID: matchID) }
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot> { await underlying.updates(matchID: matchID) }
}
extension RecordingModelTests {
  func testStaleRefreshThenDebouncedDoesNotLeavePendingRequestBlockingRecording() async throws {
    let f = try Fixture(); let client = StaleOnceClient(f.session)
    let m = RecordingModel(session: client, repository: f.repository, development: true)
    await m.start(starter: true); try await Task.sleep(for: .milliseconds(40)); f.clock.advance(2)
    await m.perform(.quick(.myGoal)); await m.perform(.quick(.myAssist))
    XCTAssertNil(m.pendingRequest); XCTAssertTrue(m.canRecord)
    XCTAssertEqual(m.snapshot?.replay.score.forTeam, 1); XCTAssertEqual(m.feedbackCount, 2)
    await m.perform(.undoLastQuick); XCTAssertEqual(m.snapshot?.replay.score.forTeam, 0)
  }
}

struct OtherIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "another-device" } }
extension RecordingModelTests {
  func testOtherDeviceRecoveryDisplaysUniqueSnapshotReadOnly() async throws {
    let f = try Fixture(); let started = try await f.start()
    let other = MatchSession(store: f.repository, deviceIdentity: OtherIdentity(), clock: f.clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "presentation-test"))
    let m = RecordingModel(session: other, repository: f.repository, development: true)
    await m.load(); await m.load(); XCTAssertTrue(m.readOnly); XCTAssertFalse(m.canRecord)
    XCTAssertEqual(m.snapshot?.replay.matchID, started.replay.matchID)
    await m.perform(.quick(.myGoal)); XCTAssertEqual(m.snapshot?.replay.score.forTeam, 0)
    XCTAssertTrue(m.issue?.contains("另一台设备") == true)
  }
  func testUnavailableProductionPermitKeepsSingleOriginalIntentOnRetry() async throws {
    let repository = try SQLiteSessionRepository(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), databaseNamespace: "production")
    let s = MatchSession(store: repository, deviceIdentity: Identity(), clock: Clock(), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .production)
    let m = RecordingModel(session: s, repository: repository, development: false)
    await m.start(starter: true); let original = try XCTUnwrap(m.pendingRequest)
    XCTAssertEqual(m.feedbackCount, 0); await m.retry()
    XCTAssertEqual(m.pendingRequest, original); XCTAssertEqual(m.feedbackCount, 0)
    let matches = try await repository.matchIDs(); XCTAssertEqual(matches, [original.matchID])
    let stored = try await repository.snapshotV2(matchID: original.matchID)
    XCTAssertTrue(stored.business.events.isEmpty); XCTAssertNil(stored.business.descriptor.startPermit)
  }
}
