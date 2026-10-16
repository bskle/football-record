import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
@testable import MatchPresentation

/// Only recovery delivery is controlled; reads, commands and receipts use the real SQLite session.
actor RecoveryFaultClient: SessionCommanding {
  let underlying: MatchSession
  var failures: [SessionError] = []
  var hold = false
  var entered = false
  var entryWaiter: CheckedContinuation<Void, Never>?
  var releaseWaiter: CheckedContinuation<Void, Never>?
  init(_ session: MatchSession) { underlying = session }
  func failNextRecovery(_ error: SessionError = .identityUnavailable) { failures.append(error) }
  func holdNextRecovery() { hold = true; entered = false }
  func waitForRecovery() async {
    if !entered { await withCheckedContinuation { entryWaiter = $0 } }
  }
  func releaseRecovery() { releaseWaiter?.resume(); releaseWaiter = nil }
  func prepareStart(starter: Bool) async throws -> SessionRequest { try await underlying.prepareStart(starter: starter) }
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest { try await underlying.prepare(action, matchID: matchID) }
  func execute(_ request: SessionRequest) async throws -> SessionReceipt { try await underlying.execute(request) }
  func recover() async throws -> RecoverySelection {
    if hold {
      hold = false; entered = true
      entryWaiter?.resume(); entryWaiter = nil
      await withCheckedContinuation { releaseWaiter = $0 }
    }
    if !failures.isEmpty { throw failures.removeFirst() }
    return try await underlying.recover()
  }
  func snapshot(matchID: String) async throws -> SessionSnapshot { try await underlying.snapshot(matchID: matchID) }
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot> { await underlying.updates(matchID: matchID) }
}

@MainActor final class RecordingRecoveryTests: XCTestCase {
  func testSuccessfulEmptyRecoveryAfterReadFailureAllowsStart() async throws {
    let f = try Fixture(); let repository = FaultRepository(f.repository)
    let model = RecordingModel(session: f.session, repository: repository, development: true)
    await repository.failNextRead(); await model.load()
    XCTAssertTrue(model.readOnly); XCTAssertNotNil(model.issue)
    await model.start(starter: true); XCTAssertNil(model.snapshot)

    await model.load()
    XCTAssertFalse(model.readOnly); XCTAssertNil(model.issue); XCTAssertNil(model.snapshot)
    await model.start(starter: true)
    XCTAssertEqual(model.snapshot?.replay.state, .running)
    XCTAssertEqual(model.feedbackCount, 1)
  }

  func testSuccessfulOwnedRecoveryAfterRecoveryFailureAllowsRecording() async throws {
    let f = try Fixture(); let original = try await f.start()
    let client = RecoveryFaultClient(f.session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    await client.failNextRecovery(); await model.load()
    XCTAssertTrue(model.readOnly); XCTAssertNotNil(model.issue)

    await model.load()
    XCTAssertFalse(model.readOnly); XCTAssertNil(model.issue); XCTAssertTrue(model.canRecord)
    XCTAssertEqual(model.snapshot?.replay.matchID, original.replay.matchID)
    XCTAssertEqual(model.feedbackCount, 0)
    f.clock.advance(2); await model.perform(.quick(.myGoal))
    XCTAssertEqual(model.snapshot?.replay.score.forTeam, 1)
    XCTAssertEqual(model.feedbackCount, 1)
  }

  func testRepeatedMultipleCandidateRecoveryDoesNotChooseOrUnlock() async throws {
    let f = try Fixture(); _ = try await f.start()
    let intent = StartIntent(id: "second", matchID: "second-match", recordingDeviceID: "ui-test", requestedAt: f.clock.now())
    _ = try await f.repository.commitV2(StoreCommitV2(
      commandID: "second/intent", expectedGeneration: 0,
      descriptor: MatchDescriptor(startIntent: intent, starter: false), events: [],
      captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: []))
    let model = RecordingModel(session: f.session, repository: f.repository, development: true)
    for _ in 0..<2 {
      await model.load()
      XCTAssertEqual(model.history.count, 2)
      XCTAssertTrue(model.readOnly); XCTAssertFalse(model.canRecord); XCTAssertNil(model.snapshot)
      XCTAssertEqual(model.issue, RecordingModel.message(SessionError.multipleCandidates))
    }
    await model.start(starter: true)
    let ids = try await f.repository.matchIDs()
    XCTAssertEqual(ids.count, 2); XCTAssertEqual(model.feedbackCount, 0)
  }

  func testSuccessfulHistoryCannotBypassIdentityOrDiagnosticRecoveryFailure() async throws {
    let f = try Fixture(); _ = try await f.start()
    let client = RecoveryFaultClient(f.session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    for failure in [SessionError.identityUnavailable, .blockedDiagnostics] {
      await client.failNextRecovery(failure); await model.load()
      XCTAssertEqual(model.history.count, 1)
      XCTAssertTrue(model.readOnly); XCTAssertFalse(model.canRecord)
      XCTAssertEqual(model.issue, RecordingModel.message(failure))
    }
    await model.perform(.quick(.myGoal))
    XCTAssertNil(model.pendingRequest); XCTAssertEqual(model.feedbackCount, 0)
  }

  func testRecoveryDoesNotUnlockBeforeAwaitedValidationFinishes() async throws {
    let f = try Fixture(); let original = try await f.start()
    let client = RecoveryFaultClient(f.session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    await client.failNextRecovery(); await model.load()
    await client.holdNextRecovery()
    let loading = Task { await model.load() }
    await client.waitForRecovery()
    XCTAssertTrue(model.busy); XCTAssertTrue(model.readOnly); XCTAssertFalse(model.canRecord)
    await model.perform(.quick(.myGoal)); XCTAssertNil(model.pendingRequest)
    await client.releaseRecovery(); await loading.value
    XCTAssertFalse(model.busy); XCTAssertFalse(model.readOnly); XCTAssertTrue(model.canRecord)
    XCTAssertEqual(model.snapshot?.replay.matchID, original.replay.matchID)
  }

  func testRecoveryPreservesUncertainRequestBytesUntilOriginalReceiptRetry() async throws {
    let f = try Fixture(); let repository = FaultRepository(f.repository)
    let session = MatchSession(store: repository, deviceIdentity: Identity(), clock: f.clock,
      ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(),
      workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "presentation-test"))
    let client = RecoveryFaultClient(session)
    let model = RecordingModel(session: client, repository: repository, development: true)
    await model.start(starter: true)
    try await Task.sleep(for: .milliseconds(40)); f.clock.advance(2)
    await repository.fault("after"); await model.perform(.quick(.myAssist))
    let original = try XCTUnwrap(model.pendingRequest)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let originalBytes = try encoder.encode(original)
    await client.failNextRecovery(); await model.load()
    XCTAssertTrue(model.readOnly)
    XCTAssertEqual(model.pendingRequest, original)
    await model.load()
    XCTAssertFalse(model.readOnly); XCTAssertFalse(model.canRecord)
    XCTAssertEqual(try encoder.encode(XCTUnwrap(model.pendingRequest)), originalBytes)
    XCTAssertEqual(model.feedbackCount, 1)
    await model.retry()
    XCTAssertNil(model.pendingRequest); XCTAssertNil(model.issue)
    XCTAssertEqual(model.snapshot?.replay.score.forTeam, 1); XCTAssertEqual(model.feedbackCount, 2)
    let saved = try await repository.committedCommandV2(commandID: original.commandID)
    XCTAssertEqual(saved?.request.commandID, original.commandID)
    XCTAssertEqual(saved?.request.events.first?.createdAt, original.requestedAt)
    await model.retry(); XCTAssertEqual(model.feedbackCount, 2)
  }

  func testRecoveredUnpermittedIntentRetainsIssueAndOriginalRequest() async throws {
    let repository = try SQLiteSessionRepository(
      rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), databaseNamespace: "production")
    let session = MatchSession(store: repository, deviceIdentity: Identity(), clock: Clock(),
      ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(),
      workout: UnavailableWorkoutGateway(), environment: .production)
    let client = RecoveryFaultClient(session)
    let model = RecordingModel(session: client, repository: repository, development: false)
    await model.start(starter: false)
    let original = try XCTUnwrap(model.pendingRequest)
    await client.failNextRecovery(); await model.load(); XCTAssertTrue(model.readOnly)
    await model.load()
    XCTAssertFalse(model.readOnly); XCTAssertFalse(model.canRecord)
    XCTAssertEqual(model.pendingRequest, original)
    XCTAssertEqual(model.issue, RecordingModel.message(SessionError.permitUnavailable))
    await model.retry()
    XCTAssertEqual(model.pendingRequest, original); XCTAssertEqual(model.feedbackCount, 0)
    let ids = try await repository.matchIDs(); XCTAssertEqual(ids, [original.matchID])
  }

  func testSuccessfulHeldTerminalRecoveryDoesNotStartOrReleaseLock() async throws {
    let f = try Fixture(); let started = try await f.start()
    f.clock.advance(3); let ended = try await f.act(.end, started.replay.matchID)
    let client = RecoveryFaultClient(f.session)
    let model = RecordingModel(session: client, repository: f.repository, development: true)
    await client.failNextRecovery(); await model.load(); XCTAssertTrue(model.readOnly)
    await model.load(); await model.load()
    XCTAssertFalse(model.readOnly); XCTAssertNil(model.issue); XCTAssertFalse(model.canRecord)
    XCTAssertEqual(model.snapshot?.replay.matchID, ended.replay.matchID)
    XCTAssertEqual(model.snapshot?.replay.state, .endedPendingSync)
    await model.start(starter: true); await model.perform(.quick(.myGoal))
    let ids = try await f.repository.matchIDs(); XCTAssertEqual(ids, [ended.replay.matchID])
    let stored = try await f.repository.snapshotV2(matchID: ended.replay.matchID)
    XCTAssertEqual(stored.business.descriptor.backendLockState, ended.store.business.descriptor.backendLockState)
    XCTAssertNotEqual(stored.business.descriptor.backendLockState, .releasedConfirmed)
    XCTAssertEqual(model.feedbackCount, 0); XCTAssertNil(model.pendingRequest)
  }
}
