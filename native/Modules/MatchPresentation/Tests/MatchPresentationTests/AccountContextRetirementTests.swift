import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import MatchPresentation

@MainActor final class AccountContextRetirementTests: XCTestCase {
 private func eventually(_ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
  while ContinuousClock.now < deadline { if await condition() { return true }; await Task.yield() }
  return false
 }
 private func heldReply(_ mode: ContextRetirementReply) async throws {
  let f = try ContextRetirementFixture(reply: mode), context = try await f.context()
  let starting = Task { await f.model.start(starter: true) }
  await f.replyGate.waitForEntry()
  let persistedIntent = await f.proxy.intent(), original = try XCTUnwrap(persistedIntent)
  XCTAssertTrue(context.repository === f.repository); XCTAssertTrue(context.session === f.session)
  let closed = ContextRetirementFlag()
  let closing = Task { await context.shutdown(); await closed.set() }
  let stopped = await eventually { f.model.readOnly }; XCTAssertTrue(stopped)
  let retired = await eventually {
   do { _ = try await f.session.prepareStart(starter: false); return false }
   catch { return error as? SessionError == .retired }
  }
  XCTAssertTrue(retired, "public shutdown must enter the original Session retirement before Model.join")
  let premature = await closed.value; XCTAssertFalse(premature)
  await f.replyGate.release(); await starting.value; await closing.value
  let permits = await f.permits.calls, gateway = await f.gateway.calls
  XCTAssertEqual(permits, 0, "no first permit may dispatch after early retirement")
  XCTAssertEqual(gateway, 0); XCTAssertEqual(f.owner.fallbacks, 0)
  XCTAssertEqual(f.owner.resourceCloses, 1)
  let snapshot = try XCTUnwrap(f.owner.beforeClose)
  XCTAssertTrue(snapshot.business.events.isEmpty); XCTAssertNil(snapshot.business.descriptor.startPermit)
  XCTAssertEqual(snapshot.business.descriptor.startIntent, original.descriptor.startIntent)
  XCTAssertEqual(f.owner.originalCommand, original)
  XCTAssertNil(f.model.snapshot); XCTAssertNil(f.model.pendingRequest); XCTAssertTrue(f.model.readOnly)
  await f.cleanup()
 }
 func testPublicOwnerRetiresBeforeOriginalIntentCommitReply() async throws { try await heldReply(.intent) }
 func testPublicOwnerRetiresBeforeOriginalPostIntentSnapshotReply() async throws { try await heldReply(.snapshot) }
 func testNilOwnerKeepsModelDrainBeforeOriginalResourceClose() async throws {
  let f = try ContextRetirementFixture(reply: .intent, permitAvailable: false), context = try await f.context(owner: false)
  let starting = Task { await f.model.start(starter: true) }; await f.replyGate.waitForEntry()
  let closing = Task { await context.shutdown() }
  let stopped = await eventually { f.model.readOnly }; XCTAssertTrue(stopped)
  XCTAssertEqual(f.owner.fallbacks, 0); XCTAssertEqual(f.owner.resourceCloses, 0)
  await f.replyGate.release(); await starting.value; await closing.value
  XCTAssertEqual(f.owner.calls, 0); XCTAssertEqual(f.owner.fallbacks, 1); XCTAssertEqual(f.owner.resourceCloses, 1)
  XCTAssertFalse(f.owner.resourceClosedWhileBusy)
  let permits = await f.permits.calls; XCTAssertEqual(permits, 1, "nil owner preserves the existing fallback order")
  let gateway = await f.gateway.calls; XCTAssertEqual(gateway, 0)
  await f.cleanup()
 }
 func testLegacyTrailingCloseCallStillUsesDefaultResourcePath() async throws {
  let f = try ContextRetirementFixture()
  var closes = 0
  let context = try await AppBootstrap.accountContext(repository: f.repository, session: f.session, recording: f.model,
   account: f.account, lifecycle: f.lifecycle) {
    closes += 1; await f.owner.closeResource()
   }
  await context.shutdown(); await context.shutdown()
  XCTAssertEqual(closes, 1); XCTAssertEqual(f.owner.calls, 0); XCTAssertEqual(f.owner.resourceCloses, 1)
  XCTAssertFalse(f.owner.resourceClosedWhileBusy); await f.cleanup()
 }
 func testConcurrentPublicShutdownJoinsOneCompleteOwnerWithoutFallback() async throws {
  let f = try ContextRetirementFixture(), context = try await f.context(), held = ContextRetirementGate()
  f.owner.beforeRetirement = held
  let firstDone = ContextRetirementFlag(), secondDone = ContextRetirementFlag()
  let first = Task { await context.shutdown(); await firstDone.set() }; await held.waitForEntry()
  let second = Task { await context.shutdown(); await secondDone.set() }
  for _ in 0..<30 { await Task.yield() }
  let firstEarly = await firstDone.value, secondEarly = await secondDone.value
  XCTAssertFalse(firstEarly); XCTAssertFalse(secondEarly, "all concurrent public callers must join the same owner")
  XCTAssertEqual(f.owner.calls, 1); XCTAssertEqual(f.owner.resourceCloses, 0)
  await held.release(); await first.value; await second.value; await context.shutdown()
  XCTAssertEqual(f.owner.calls, 1); XCTAssertEqual(f.owner.resourceCloses, 1); XCTAssertEqual(f.owner.fallbacks, 0)
  await f.cleanup()
 }
 func testPublicOwnerJoinsOriginalPositiveCaptureBeforeClosingDatabase() async throws {
  let f = try ContextRetirementFixture(heldCapture: true), context = try await f.context()
  await f.model.start(starter: true); await f.gateway.gate.waitForEntry()
  let finished = ContextRetirementFlag(), closing = Task { await context.shutdown(); await finished.set() }
  let retired = await eventually {
   do { _ = try await f.session.prepareStart(starter: false); return false }
   catch { return error as? SessionError == .retired }
  }; XCTAssertTrue(retired)
  let premature = await finished.value; XCTAssertFalse(premature); XCTAssertEqual(f.owner.resourceCloses, 0)
  _ = try await f.repository.matchIDs()
  await f.gateway.gate.release(); await closing.value
  XCTAssertNil(f.owner.failure); XCTAssertEqual(f.owner.resourceCloses, 1); XCTAssertEqual(f.owner.fallbacks, 0)
  XCTAssertEqual(f.owner.beforeClose?.captureOperations.first?.observation?.outcome, .running)
  XCTAssertEqual(f.owner.beforeClose?.captureOperations.first?.state, .settled)
  let gateway = await f.gateway.calls, reconciled = await f.gateway.reconciled
  XCTAssertEqual(gateway, 1); XCTAssertEqual(reconciled, 0)
  await f.cleanup()
 }
 func testFailedOwnerDoesNotFallBackAndRetainsOriginalSQLOnlyRetry() async throws {
  let f = try ContextRetirementFixture(heldCapture: true), context = try await f.context()
  await f.model.start(starter: true); await f.gateway.gate.waitForEntry(); await f.proxy.failNextObservation()
  let closing = Task { await context.shutdown() }
  let stopped = await eventually { f.model.readOnly }; XCTAssertTrue(stopped)
  await f.gateway.gate.release(); await closing.value
  XCTAssertEqual(f.owner.failure as? StoreError, .injectedFailure)
  XCTAssertEqual(f.owner.resourceCloses, 0); XCTAssertEqual(f.owner.fallbacks, 0)
  let retained = try await f.repository.matchIDs(); XCTAssertFalse(retained.isEmpty, "failed owner keeps the original facade open")
  await f.owner.shutdown() // Explicit owner retry, not another public context success proof.
  XCTAssertNil(f.owner.failure); XCTAssertEqual(f.owner.resourceCloses, 1)
  XCTAssertEqual(f.owner.beforeClose?.captureOperations.first?.observation?.outcome, .running)
  let calls = await f.gateway.calls, reconciled = await f.gateway.reconciled
  XCTAssertEqual(calls, 1); XCTAssertEqual(reconciled, 0)
  await f.cleanup()
 }
 func testWrongCheckedAssemblyNeverInvokesEitherOwnerOrResourceCallback() async throws {
  let f = try ContextRetirementFixture()
  let other = try SQLiteSessionRepository(rootDirectory: f.root, databaseNamespace: "other-context")
  var callbacks = 0
  do {
   _ = try await AppBootstrap.accountContext(repository: f.repository, session: f.session, recording: f.model,
     account: AccountStatusModel(repository: other), lifecycle: f.lifecycle,
     shutdownOwner: { callbacks += 1 }, close: { callbacks += 1 })
   XCTFail("checked original facade mismatch")
  } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
  XCTAssertEqual(callbacks, 0); try await other.close(); await f.cleanup()
 }
}

private enum ContextRetirementReply: Sendable { case none, intent, snapshot }
private actor ContextRetirementGate {
 private var entered = false
 private var entrants: [CheckedContinuation<Void, Never>] = []
 private var continuation: CheckedContinuation<Void, Never>?
 func hold() async { entered = true; entrants.forEach { $0.resume() }; entrants.removeAll(); await withCheckedContinuation { continuation = $0 } }
 func waitForEntry() async { if !entered { await withCheckedContinuation { entrants.append($0) } } }
 func release() { continuation?.resume(); continuation = nil }
}
private actor ContextRetirementFlag { var value = false; func set() { value = true } }
private struct ContextRetirementIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "watch" } }
private actor ContextRetirementPermit: StartPermitProvider {
 var calls = 0
 let available: Bool
 init(available: Bool) { self.available = available }
 func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
  calls += 1; guard available else { throw SessionError.permitUnavailable }; return DevelopmentStartFixture.permit(for: intent)
 }
}
private actor ContextRetirementGateway: WorkoutGateway {
 let gate = ContextRetirementGate(), held: Bool
 var calls = 0, reconciled = 0
 init(held: Bool) { self.held = held }
 func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
  calls += 1; if held { await gate.hold() }
  return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
   observedAt: Date(), outcome: held ? .running : .notCreated(.unavailable), window: CaptureWindow(start: nil, end: nil))
 }
 func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { reconciled += 1; return await perform(operation) }
}
@MainActor private final class ContextRetirementFixture {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-retirement-" + UUID().uuidString)
 let repository: SQLiteSessionRepository
 let replyGate = ContextRetirementGate(), proxy: ContextRetirementRepository
 let permits: ContextRetirementPermit, gateway: ContextRetirementGateway
 let session: MatchSession, model: RecordingModel, account: AccountStatusModel, lifecycle: LifecycleStatusModel
 let owner: ContextRetirementOwner
 init(reply: ContextRetirementReply = .none, permitAvailable: Bool = true, heldCapture: Bool = false) throws {
  let repository = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "retirement-context")
  self.repository = repository
  let proxy = ContextRetirementRepository(repository, reply: reply, gate: replyGate); self.proxy = proxy
  let permits = ContextRetirementPermit(available: permitAvailable), gateway = ContextRetirementGateway(held: heldCapture)
  self.permits = permits; self.gateway = gateway
  let session = MatchSession(store: proxy, deviceIdentity: ContextRetirementIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: permits, workout: gateway, environment: .development(databaseNamespace: "retirement-context"))
  self.session = session
  let model = RecordingModel(session: session, repository: repository, development: true); self.model = model
  account = AccountStatusModel(repository: repository); lifecycle = LifecycleStatusModel(repository: repository)
  owner = ContextRetirementOwner(repository: repository, session: session, model: model, proxy: proxy)
 }
 func context(owner useOwner: Bool = true) async throws -> AccountAppContext {
  let owner = owner
  let shutdown: (@MainActor () async -> Void)?
  if useOwner { shutdown = { await owner.shutdown() } } else { shutdown = nil }
  return try await AppBootstrap.accountContext(repository: repository, session: session, recording: model, account: account, lifecycle: lifecycle,
   shutdownOwner: shutdown,
   close: { owner.fallbacks += 1; if useOwner { await owner.shutdown() } else { await owner.closeResource() } })
 }
 func cleanup() async { try? await session.retireBusiness(); await model.shutdown(); try? await repository.close() }
}
@MainActor private final class ContextRetirementOwner {
 let repository: SQLiteSessionRepository, session: MatchSession, model: RecordingModel, proxy: ContextRetirementRepository
 var calls = 0, fallbacks = 0, resourceCloses = 0, resourceClosedWhileBusy = false
 var beforeRetirement: ContextRetirementGate?
 var failure: (any Error)?, beforeClose: StoreSnapshotV2?, originalCommand: StoreCommitV2?
 init(repository: SQLiteSessionRepository, session: MatchSession, model: RecordingModel, proxy: ContextRetirementRepository) {
  self.repository = repository; self.session = session; self.model = model; self.proxy = proxy
 }
 func shutdown() async {
  calls += 1
  do {
   if let beforeRetirement { await beforeRetirement.hold() }
   try await session.retireBusiness(); await model.shutdown()
   await closeResource()
  } catch { failure = error }
 }
 func closeResource() async {
  do {
   resourceClosedWhileBusy = model.busy
   if let intent = await proxy.intent() {
    beforeClose = try await repository.snapshotV2(matchID: intent.descriptor.matchID)
    originalCommand = try await repository.committedCommandV2(commandID: intent.commandID)?.request
   }
   try await repository.close(); resourceCloses += 1; failure = nil
  } catch { failure = error }
 }
}
/// Test-only reply gates forward to one actual original SQLite facade and its identity.
/// No synthetic identity or alternate business DB is used by the checked factory.
private actor ContextRetirementRepository: SessionRepository {
 let repository: SQLiteSessionRepository, gate: ContextRetirementGate, reply: ContextRetirementReply
 private var original: StoreCommitV2?, held = false, failObservation = false
 init(_ repository: SQLiteSessionRepository, reply: ContextRetirementReply, gate: ContextRetirementGate) { self.repository = repository; self.reply = reply; self.gate = gate }
 func intent() -> StoreCommitV2? { original }
 func failNextObservation() { failObservation = true }
 func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await repository.syncRepositoryIdentity() }
 func databaseNamespace() async -> String { await repository.databaseNamespace() }
 func matchIDs() async throws -> [String] { try await repository.matchIDs() }
 func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 {
  let value = try await repository.snapshotV2(matchID: matchID)
  if reply == .snapshot, original != nil, !held { held = true; await gate.hold() }
  return value
 }
 func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await repository.committedCommandV2(commandID: commandID) }
 func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await repository.pendingCaptureOperations(matchID: matchID) }
 func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
  if failObservation, request.captureOperationUpdates.contains(where: { $0.observation != nil }) { failObservation = false; throw StoreError.injectedFailure }
  let receipt = try await repository.commitV2(request)
  if request.commandID.hasSuffix("/intent") { original = request; if reply == .intent, !held { held = true; await gate.hold() } }
  return receipt
 }
 func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await repository.unroutedBusinessOutboxV3(matchID: matchID) }
 func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await repository.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
 func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await repository.pendingPacketsV2(matchID: matchID) }
 func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await repository.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
 func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await repository.acknowledgeV2(bytes, peer: peer, now: now) }
 func syncStateV3(matchID: String) async throws -> SyncState { try await repository.syncStateV3(matchID: matchID) }
 func ensureSyncDeliveriesV3(matchID: String) async throws { try await repository.ensureSyncDeliveriesV3(matchID: matchID) }
 func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await repository.dueSyncDeliveriesV3(now: now, limit: limit) }
 func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await repository.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
 func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await repository.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
 func reactivateSyncACKsV3() async throws { try await repository.reactivateSyncACKsV3() }
 func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await repository.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
 func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await repository.pendingSyncAssembliesV3(peer: peer, now: now) }
 func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await repository.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
 func expireSyncAssembliesV3(now: Date) async throws { try await repository.expireSyncAssembliesV3(now: now) }
}
