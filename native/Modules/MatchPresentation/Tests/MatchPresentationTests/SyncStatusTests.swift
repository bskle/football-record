import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
import MatchSync
import SQLite3
@testable import MatchPresentation

@MainActor final class SyncStatusTests: XCTestCase {
  func testZeroCountsWithoutACKNeverClaimsPeerSaved() throws {
    let state = try SyncState(matchID: "m", unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: nil, issue: nil)
    let projection = SyncStatusProjection(state: state, unavailable: nil, terminal: false)
    XCTAssertFalse(projection.peerPersisted)
    XCTAssertEqual(projection.peer, "尚无对端保存确认")
    XCTAssertEqual(projection.cloud, "云同步尚未接通")
  }
  func testACKRequiresEveryPendingDomainClearAndUnknownClearsOldSuccess() throws {
    let ack = Date()
    for counts in [(1,0,0), (0,1,0), (0,0,1)] {
      let state = try SyncState(matchID: "m", unroutedCount: counts.0, pendingACKCount: counts.1, receivedGapCount: counts.2, lastPeerACKAt: ack, issue: nil)
      XCTAssertFalse(SyncStatusProjection(state: state, unavailable: nil, terminal: true).peerPersisted)
    }
    let state = try SyncState(matchID: "m", unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: ack, issue: nil)
    XCTAssertTrue(SyncStatusProjection(state: state, unavailable: nil, terminal: true).peerPersisted)
    let unknown = SyncStatusProjection(state: state, unavailable: .blockedIntegrity, terminal: true)
    XCTAssertFalse(unknown.peerPersisted)
    XCTAssertNil(unknown.pendingCount)
    XCTAssertEqual(unknown.backend, "后台待终结")
  }
  func testTwoRealStoresKeepPendingUntilACKThenReopenOriginalIdentities() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let syncClock = ControlledSyncClock()
    let pair = try await DevelopmentSyncPair.make(dataset: "sync-test", rootDirectory: root, mode: .queued, syncClock: syncClock)
    let model = pair.model
    await model.load(); await model.start(starter: true)
    let id = try XCTUnwrap(model.snapshot?.replay.matchID)
    await pair.settle()
    let pending = try await pair.localRepository.syncStateV3(matchID: id)
    XCTAssertGreaterThan(pending.pendingACKCount, 0)
    XCTAssertNil(pending.lastPeerACKAt)
    let localURL = await pair.localRepository.databaseURL, remoteURL = await pair.remoteRepository.databaseURL
    XCTAssertNotEqual(localURL, remoteURL)
    let ids = (pair.localDeviceID, pair.remoteDeviceID)
    let feedback = model.feedbackCount
    syncClock.advance(301) // Host-only control of persistent retry deadlines.
    await model.syncStatus.retry(); await pair.settle()
    let saved = try await pair.localRepository.syncStateV3(matchID: id)
    XCTAssertNotNil(saved.lastPeerACKAt)
    XCTAssertEqual(saved.pendingACKCount + saved.unroutedCount + saved.receivedGapCount, 0)
    XCTAssertEqual(model.feedbackCount, feedback)
    let remote = try await pair.remoteRepository.snapshotV2(matchID: id)
    XCTAssertEqual(remote.business.events, model.snapshot?.store.business.events)
    await model.shutdown()
    try await pair.localRepository.close(); try await pair.remoteRepository.close()
    let reopened = try await DevelopmentSyncPair.make(dataset: "sync-test", rootDirectory: root, mode: .queued)
    XCTAssertEqual(reopened.localDeviceID, ids.0); XCTAssertEqual(reopened.remoteDeviceID, ids.1)
    await reopened.model.load()
    let restored = try await reopened.localRepository.syncStateV3(matchID: id)
    XCTAssertNotNil(restored.lastPeerACKAt)
    XCTAssertEqual(reopened.model.feedbackCount, 0)
    await reopened.model.shutdown()
  }
  func testUnavailableReadClearsSuccessAndLateMatchUpdateCannotRestoreIt() throws {
    let model = SyncStatusModel(service: nil)
    model.observe(matchID: "m")
    let saved = try SyncState(matchID: "m", unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: Date(), issue: nil)
    model.accept(.state(saved), expectedMatchID: "m")
    XCTAssertTrue(model.projection(terminal: false).peerPersisted)
    model.accept(.unavailable(matchID: "m", issue: .blockedIntegrity), expectedMatchID: "m")
    XCTAssertNil(model.state); XCTAssertFalse(model.projection(terminal: false).peerPersisted)
    model.observe(matchID: "new")
    model.accept(.state(saved), expectedMatchID: "m")
    XCTAssertNil(model.state)
  }
  func testRealSQLiteReadFailurePublishesUnknownThenRestoredFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pair = try await DevelopmentSyncPair.make(dataset: "read-fault", rootDirectory: root, mode: .online)
    await pair.model.load(); await pair.model.start(starter: true); await pair.settle()
    let id = try XCTUnwrap(pair.model.snapshot?.replay.matchID)
    await pair.model.syncStatus.retry(); await pair.settle()
    XCTAssertTrue(pair.model.syncStatus.projection(terminal: false).peerPersisted)
    let original = try await pair.localRepository.snapshotV2(matchID: id)
    let path = await pair.localRepository.databaseURL.path
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    // Counts being stable does not stop the pair's asynchronous SQLite writers.
    // Hold a real competing writer until the injector has observed SQLITE_BUSY.
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
    defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); sqlite3_close(writer) }
    let acquired = await executeFaultSQL(writer, "BEGIN IMMEDIATE")
    XCTAssertEqual(acquired, SQLITE_OK, "The controlled writer must acquire its real transaction")
    guard acquired == SQLITE_OK else { await pair.model.shutdown(); return }
    let rename = "ALTER TABLE sync_routes_v3 RENAME TO held_routes"
    let immediate = sqlite3_exec(db, rename, nil, nil, nil)
    XCTAssertEqual(immediate, SQLITE_BUSY, "The original single-attempt injector cannot acquire the held writer")
    print("NATIVE-035 controlled writer: original injector returned \(immediate)")
    let blocked = expectation(description: "Fault injector encounters the held SQLite writer")
    let injecting = Task { await executeFaultSQL(db, rename, onBusy: { blocked.fulfill() }) }
    await fulfillment(of: [blocked], timeout: 2)
    XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
    let injected = await injecting.value
    XCTAssertEqual(injected, SQLITE_OK, "Real schema fault must be injected: \(String(cString: sqlite3_errmsg(db)))")
    guard injected == SQLITE_OK else { await pair.model.shutdown(); return }
    await pair.lifecycle.wake()
    for _ in 0..<100 { if pair.model.syncStatus.unavailable != nil { break }; await Task.yield() }
    XCTAssertNil(pair.model.syncStatus.state)
    XCTAssertEqual(pair.model.syncStatus.unavailable, .blockedIntegrity)
    XCTAssertFalse(pair.model.syncStatus.projection(terminal: false).peerPersisted)
    XCTAssertNil(pair.model.syncStatus.projection(terminal: false).pendingCount)
    let restored = await executeFaultSQL(db, "ALTER TABLE held_routes RENAME TO sync_routes_v3")
    XCTAssertEqual(restored, SQLITE_OK, "Original schema must be restored: \(String(cString: sqlite3_errmsg(db)))")
    guard restored == SQLITE_OK else { await pair.model.shutdown(); return }
    let restoredFacts = try await pair.localRepository.snapshotV2(matchID: id)
    XCTAssertEqual(restoredFacts.business.events, original.business.events)
    // A legitimate later local commit and its real peer ACK recover the notification.
    await pair.model.perform(.leaveField)
    await pair.model.syncStatus.retry(); await pair.settle()
    let state = try await pair.localRepository.syncStateV3(matchID: id)
    XCTAssertEqual(state.pendingACKCount, 0)
    XCTAssertNil(pair.model.syncStatus.unavailable)
    XCTAssertNotNil(pair.model.syncStatus.state)
    XCTAssertTrue(pair.model.syncStatus.projection(terminal: false).peerPersisted)
    let peer = try await pair.remoteRepository.snapshotV2(matchID: id)
    XCTAssertEqual(peer.business.events, pair.model.snapshot?.store.business.events)
    await pair.model.shutdown()
  }
  /// This external injector has no busy handler. Yield only for a real competing
  /// writer, with a monotonic deadline; schema/IO errors still fail immediately.
  private func executeFaultSQL(_ db: OpaquePointer?, _ sql: String, onBusy: (() -> Void)? = nil) async -> Int32 {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    var reportedBusy = false
    while true {
      let result = sqlite3_exec(db, sql, nil, nil, nil)
      guard result == SQLITE_BUSY, clock.now < deadline else { return result }
      if !reportedBusy { reportedBusy = true; onBusy?() }
      await Task.yield()
    }
  }
  func testTransportFailureDoesNotBlockRecordingOrProduceExtraFeedback() async throws {
    let syncClock = ControlledSyncClock()
    let pair = try await DevelopmentSyncPair.make(dataset: "retry-test", rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), mode: .failed, syncClock: syncClock)
    await pair.model.load(); await pair.model.start(starter: true); await pair.settle()
    XCTAssertTrue(pair.model.canRecord)
    XCTAssertEqual(pair.model.syncStatus.state?.issue, .transportUnavailable)
    XCTAssertNil(pair.model.issue)
    let before = pair.model.feedbackCount
    await pair.model.perform(.leaveField); await pair.settle()
    XCTAssertEqual(pair.model.feedbackCount, before + 1)
    XCTAssertTrue(pair.model.canRecord)
    let feedback = pair.model.feedbackCount
    syncClock.advance(301)
    await pair.model.syncStatus.retry(); await pair.settle()
    XCTAssertEqual(pair.model.feedbackCount, feedback)
    XCTAssertTrue(pair.model.syncStatus.projection(terminal: false).peerPersisted)
    await pair.model.perform(.end); await pair.model.syncStatus.retry(); await pair.settle()
    XCTAssertEqual(pair.model.snapshot?.replay.state, .endedPendingSync)
    XCTAssertNotEqual(pair.model.snapshot?.store.business.descriptor.backendLockState, .releasedConfirmed)
    XCTAssertEqual(pair.model.syncStatus.projection(terminal: true).backend, "后台待终结")
    XCTAssertFalse(pair.model.canRecord)
    await pair.model.shutdown()
  }
  func testMissingPersistentIdentityWithRecordsDoesNotInventReplacementPair() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pair = try await DevelopmentSyncPair.make(dataset: "missing-id", rootDirectory: root, mode: .online)
    await pair.model.load(); await pair.model.start(starter: true); await pair.settle()
    await pair.model.shutdown(); try await pair.localRepository.close(); try await pair.remoteRepository.close()
    let identity = root.appendingPathComponent("ui-simulation-missing-id-local/device.identity")
    try FileManager.default.removeItem(at: identity)
    do { _ = try await DevelopmentSyncPair.make(dataset: "missing-id", rootDirectory: root, mode: .online); XCTFail("Missing identity must fail closed") }
    catch { XCTAssertEqual(error as? SessionError, .identityUnavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
  }
  func testSyncRetryDoesNotJumpSessionTimeOrRewriteEvents() async throws {
    let pair = try await DevelopmentSyncPair.make(dataset: "no-time-jump", rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), mode: .failed)
    await pair.model.load(); await pair.model.start(starter: true); await pair.settle()
    let before = try XCTUnwrap(pair.model.snapshot)
    let wall = Date()
    await pair.model.syncStatus.retry()
    await pair.model.perform(.leaveField)
    let after = try XCTUnwrap(pair.model.snapshot)
    XCTAssertEqual(Array(after.store.business.events.prefix(before.store.business.events.count)), before.store.business.events)
    let event = try XCTUnwrap(after.store.business.events.first(where: { $0.type == .leftField }))
    XCTAssertLessThan(abs(event.createdAt.timeIntervalSince(wall)), 10)
    XCTAssertLessThan(event.matchElapsed ?? 1000, 10)
    XCTAssertEqual(after.replay.state, .running)
    await pair.model.shutdown()
  }
  func testSuspendedSyncStartupCannotDelayLocalRecoveryOrRecording() async throws {
    let fixture = try Fixture(); let original = try await fixture.start()
    let source = SuspendedStartupSource()
    let model = RecordingModel(session: fixture.session, repository: fixture.repository, development: true, sync: source)
    let loaded = expectation(description: "Local recovery completes while sync is suspended")
    let loading = Task { await model.load(); loaded.fulfill() }
    await source.waitForStart()
    await fulfillment(of: [loaded], timeout: 2)
    await source.releaseStart()
    await loading.value
    XCTAssertEqual(model.snapshot?.replay.matchID, original.replay.matchID)
    XCTAssertTrue(model.canRecord)
    let feedback = model.feedbackCount
    fixture.clock.advance(2); await model.perform(.quick(.myGoal))
    XCTAssertEqual(model.snapshot?.replay.score.forTeam, 1)
    XCTAssertEqual(model.feedbackCount, feedback + 1)
    await model.shutdown()
    let active = await source.active, stopped = await source.stopCount
    XCTAssertFalse(active); XCTAssertGreaterThanOrEqual(stopped, 1)
  }
  func testShutdownCancelsSuspendedStartupWithoutLateActivation() async throws {
    let source = SuspendedStartupSource()
    let status = SyncStatusModel(service: source)
    await status.start(); await source.waitForStart()
    await status.shutdown()
    let active = await source.active, stopped = await source.stopCount
    XCTAssertFalse(active); XCTAssertEqual(stopped, 1)
    XCTAssertNil(status.matchID); XCTAssertNil(status.state)
  }
  func testLateRetrySuccessCannotCrossSameMatchRestart() async throws {
    let source = HeldRetrySource()
    let status = SyncStatusModel(service: source)
    await status.start(); status.observe(matchID: "m")
    for _ in 0..<100 { if status.unavailable != nil { break }; await Task.yield() }
    for _ in 0..<100 { if await source.reads > 0 { break }; await Task.yield() }
    await source.holdNextState()
    let retrying = Task { await status.retry() }
    await source.waitForHeldState()
    await status.shutdown()
    await status.start(); status.observe(matchID: "m")
    for _ in 0..<100 { if status.unavailable != nil { break }; await Task.yield() }
    XCTAssertNil(status.state)
    await source.releaseState(); await retrying.value
    XCTAssertNil(status.state, "Old lifecycle success must not overwrite new unavailable")
    XCTAssertFalse(status.projection(terminal: false).peerPersisted)
    await status.shutdown()
  }
  func testShutdownDuringLocalRecoveryCannotReinstallOldObservers() async throws {
    let fixture = try Fixture(); _ = try await fixture.start()
    let client = RecoveryFaultClient(fixture.session)
    let model = RecordingModel(session: client, repository: fixture.repository, development: true)
    await client.holdNextRecovery()
    let loading = Task { await model.load() }
    await client.waitForRecovery()
    await model.shutdown()
    await client.releaseRecovery(); await loading.value
    XCTAssertNil(model.syncStatus.matchID)
    XCTAssertFalse(model.canRecord)
    XCTAssertNil(model.snapshot)
  }
  func testLateStartupReadCannotCrossMatchRoundTrip() async throws {
    for lateError in [false, true] {
      let source = HeldRetrySource()
      let status = SyncStatusModel(service: source)
      await source.holdNextState(fail: lateError)
      status.observe(matchID: "a"); await status.start()
      await source.waitForHeldState()
      if lateError { await source.useSavedStreams() }
      status.observe(matchID: "b"); status.observe(matchID: "a")
      for _ in 0..<100 {
        if lateError ? status.state != nil : status.unavailable != nil { break }
        await Task.yield()
      }
      await source.releaseState()
      for _ in 0..<100 { await Task.yield() }
      if lateError {
        XCTAssertTrue(status.projection(terminal: false).peerPersisted, "Stale startup failure must not clear the current stream receipt")
      } else {
        XCTAssertNil(status.state, "Stale startup success must not overwrite current unavailable")
        XCTAssertFalse(status.projection(terminal: false).peerPersisted)
      }
      await status.shutdown()
    }
  }
  func testLateStartupIgnoringCancellationIsStoppedBeforeShutdownReturns() async throws {
    let source = LateActivationSource()
    let status = SyncStatusModel(service: source)
    await status.start(); await source.waitForStart()
    await status.shutdown()
    let active = await source.active
    XCTAssertFalse(active, "A late activation after stop must be stopped again before joining startup")
    // The old startup is joined before a new lifecycle may share this service.
    await source.prepareNextStart(); await status.start(); await source.waitForStart()
    await source.finishStart()
    for _ in 0..<100 { await Task.yield() }
    let newActive = await source.active
    XCTAssertTrue(newActive, "Old lifecycle cleanup must not stop the new activation")
    await status.shutdown()
  }
  func testSwitchAndShutdownCancelOldStreamsAndStopService() async throws {
    let source = LifecycleSyncSource()
    let model = SyncStatusModel(service: source)
    await model.start(); model.observe(matchID: "old")
    for _ in 0..<100 { if await source.activeCount() == 1 { break }; await Task.yield() }
    model.observe(matchID: "new")
    for _ in 0..<100 { if await source.onlyNew() { break }; await Task.yield() }
    let onlyNew = await source.onlyNew(); XCTAssertTrue(onlyNew)
    let value = try SyncState(matchID: "old", unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: Date(), issue: nil)
    await source.emit(.state(value))
    XCTAssertNil(model.state)
    await model.shutdown()
    for _ in 0..<100 { if await source.activeCount() == 0 { break }; await Task.yield() }
    let active = await source.activeCount(), stopped = await source.stopCount
    XCTAssertEqual(active, 0); XCTAssertEqual(stopped, 1)
  }
}

private actor LifecycleSyncSource: SyncStatusServing {
  var continuations: [String: AsyncStream<SyncStateUpdate>.Continuation] = [:]
  var stopCount = 0
  func start() async throws {}
  func stop() async { stopCount += 1 }
  func wake() async {}
  func state(matchID: String) async throws -> SyncState { throw StoreError.notFound }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> {
    let (stream, continuation) = AsyncStream<SyncStateUpdate>.makeStream()
    continuations[matchID] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.remove(matchID) } }
    return stream
  }
  func remove(_ matchID: String) { continuations.removeValue(forKey: matchID) }
  func activeCount() -> Int { continuations.count }
  func onlyNew() -> Bool { continuations.count == 1 && continuations["new"] != nil }
  func emit(_ update: SyncStateUpdate) { for c in continuations.values { c.yield(update) } }
}

private final class ControlledSyncClock: SyncClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date().addingTimeInterval(-301)
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor SuspendedStartupSource: SyncStatusServing {
  var active = false
  var stopCount = 0
  var entered = false
  var started: CheckedContinuation<Void, Never>?
  var gate: CheckedContinuation<Void, Never>?
  func start() async throws {
    entered = true; started?.resume(); started = nil
    await withCheckedContinuation { gate = $0 }
    try Task.checkCancellation()
    active = true
  }
  func waitForStart() async { if !entered { await withCheckedContinuation { started = $0 } } }
  func releaseStart() { gate?.resume(); gate = nil }
  func stop() async { stopCount += 1; active = false; releaseStart() }
  func wake() async {}
  func state(matchID: String) async throws -> SyncState { throw StoreError.trustUnavailable }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> { AsyncStream { $0.yield(.unavailable(matchID: matchID, issue: .trustUnavailable)) } }
}

private actor HeldRetrySource: SyncStatusServing {
  var reads = 0
  var heldError = false
  var savedStreams = false
  var holding = false
  var entered = false
  var entry: CheckedContinuation<Void, Never>?
  var release: CheckedContinuation<Void, Never>?
  func start() async throws {}
  func stop() async {}
  func wake() async {}
  func retry() async {}
  func holdNextState(fail: Bool = false) { holding = true; entered = false; heldError = fail }
  func useSavedStreams() { savedStreams = true }
  func waitForHeldState() async { if !entered { await withCheckedContinuation { entry = $0 } } }
  func releaseState() { release?.resume(); release = nil }
  func state(matchID: String) async throws -> SyncState {
    reads += 1
    if holding {
      holding = false; entered = true; entry?.resume(); entry = nil
      await withCheckedContinuation { release = $0 }
      if heldError { throw StoreError.injectedFailure }
      return try SyncState(matchID: matchID, unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: Date(), issue: nil)
    }
    throw StoreError.sqlite(code: SQLITE_ERROR, message: "temporarily unreadable")
  }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> {
    let update: SyncStateUpdate = savedStreams ? .state(try! SyncState(matchID: matchID, unroutedCount: 0, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: Date(), issue: nil)) : .unavailable(matchID: matchID, issue: .blockedIntegrity)
    return AsyncStream { $0.yield(update) }
  }
}

private actor LateActivationSource: SyncStatusServing {
  var active = false
  var entered = false
  var entry: CheckedContinuation<Void, Never>?
  var gate: CheckedContinuation<Void, Never>?
  func start() async throws {
    entered = true; entry?.resume(); entry = nil
    await withCheckedContinuation { gate = $0 }
    active = true // Deliberately emulates an adapter callback that ignores cancellation.
  }
  func waitForStart() async { if !entered { await withCheckedContinuation { entry = $0 } } }
  func prepareNextStart() { entered = false }
  func finishStart() { gate?.resume(); gate = nil }
  func stop() async { active = false; finishStart() }
  func wake() async {}
  func state(matchID: String) async throws -> SyncState { throw StoreError.trustUnavailable }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> { AsyncStream { $0.finish() } }
}
