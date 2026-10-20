import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import MatchSync
import MatchPresentation
import DeviceSync
import AccountKit
@testable import AppIntegration

@MainActor final class IntegrationContextTests: XCTestCase {
  func testSingleFacadeLocalCommitsSurviveSyncFailureAndReopenUsesFreshModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let namespace = DeviceDatasetGate.namespace
    let context = try await IntegrationContext.make(root: root, namespace: namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    let repository = try XCTUnwrap(context.repository), session = try XCTUnwrap(context.session)
    let storeID = await repository.syncRepositoryIdentity(), sessionID = await session.syncRepositoryIdentity()
    XCTAssertEqual(storeID, sessionID)
    await context.model.load(); await context.model.start(starter: true)
    let id = try XCTUnwrap(context.model.snapshot?.store.business.descriptor.matchID)
    await context.model.perform(.quick(.myGoal))
    XCTAssertEqual(context.model.feedbackCount, 2)
    let oldModel = context.model
    try await context.shutdown()
    let reopened = try await IntegrationContext.make(root: root, namespace: namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    XCTAssertFalse(reopened.model === oldModel)
    await reopened.model.load()
    XCTAssertEqual(reopened.model.snapshot?.store.business.descriptor.matchID, id)
    XCTAssertFalse(reopened.model.readOnly)
    XCTAssertTrue(reopened.model.canRecord, "state=\(String(describing: reopened.model.snapshot?.replay.state)) issue=\(String(describing: reopened.model.issue)) pending=\(String(describing: reopened.model.pendingRequest))")
    await reopened.model.perform(.leaveField)
    XCTAssertEqual(reopened.model.feedbackCount, 1, "issue=\(String(describing: reopened.model.issue)) pending=\(String(describing: reopened.model.pendingRequest))")
    XCTAssertEqual(oldModel.feedbackCount, 0, "retired model stays cleared while the fresh model changes")
    XCTAssertNil(oldModel.snapshot); XCTAssertTrue(oldModel.history.isEmpty)
    try await reopened.shutdown()
  }
  func testThrowingTransportFactoryCannotBlockExistingLocalRecord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lifecycle = IntegrationLifecycle()
    var original: IntegrationContext? = try await lifecycle.replace {
      try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    }
    await original?.model.load(); await original?.model.start(starter: true)
    let prior = try XCTUnwrap(original?.model), match = try XCTUnwrap(prior.snapshot?.replay.matchID)
    XCTAssertEqual(prior.feedbackCount, 1, "original successful feedback is visible before retirement")
    let oldRepo = try XCTUnwrap(original?.repository)
    original = nil
    let next = try await lifecycle.replace {
      XCTAssertTrue(prior.readOnly, "old model must be stopped before constructing replacement")
      do { _ = try await oldRepo.matchIDs(); XCTFail("old facade must be closed before factory") } catch {}
      return try await IntegrationContext.makeWithTransportFactory(root: root, namespace: DeviceDatasetGate.namespace, development: true, trust: UnavailableRevocableTrust()) { throw DeviceSyncError.corruptFile }
    }
    XCTAssertTrue(next.transportUnavailable)
    await next.model.load()
    XCTAssertEqual(next.model.snapshot?.replay.matchID, match)
    XCTAssertFalse(next.model.readOnly)
    await next.model.perform(.leaveField)
    XCTAssertEqual(next.model.feedbackCount, 1)
    XCTAssertEqual(prior.feedbackCount, 0, "replacement operations cannot repopulate retired feedback")
    XCTAssertNil(prior.snapshot); XCTAssertTrue(prior.history.isEmpty)
    let state = try await next.coordinator?.state(matchID: match)
    XCTAssertNil(state?.lastPeerACKAt)
    XCTAssertGreaterThan(state?.unroutedCount ?? 0, 0)
    try await next.shutdown()
  }

  func testShutdownJoinsOriginalCaptureBeforeClosingFacade() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gateway = ContextHeldGateway()
    let context = try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    await context.model.start(starter: true); let original = await gateway.waitForEntry()
    var began = false, done = false
    let stopping = Task { began = true; try await context.shutdown(); done = true }
    while !began { await Task.yield() }; try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(done, "facade must stay open until the original positive capture observation is durable")
    await gateway.release(); try await stopping.value
    let reopened = try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    let snapshot = try await XCTUnwrap(reopened.repository).snapshotV2(matchID: original.binding.matchID)
    XCTAssertEqual(snapshot.captureOperations.first(where: { $0.operation.id == original.id })?.observation?.outcome, .running)
    try await reopened.shutdown()
  }
  func testReplacementFailureKeepsOriginalRetiredContextAndNeverCallsFactory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gateway = ContextHeldGateway(), lifecycle = IntegrationLifecycle()
    let original = try await lifecycle.replace { try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust()) }
    await original.model.start(starter: true); _ = await gateway.waitForEntry()
    // A controlled closed repository forces the real positive-observation durable
    // drain to fail; this is not represented as a successful production shutdown.
    try await XCTUnwrap(original.repository).close()
    var factoryCalled = false
    let replacing = Task {
      try await lifecycle.replace { factoryCalled = true; throw ContextReplacementProbe.reached }
    }
    try await Task.sleep(for: .milliseconds(30)); await gateway.release()
    do { _ = try await replacing.value; XCTFail("drain failure cannot publish a replacement") } catch {}
    XCTAssertFalse(factoryCalled)
    XCTAssertTrue(lifecycle.current === original)
    XCTAssertTrue(original.model.readOnly)
  }

  func testOverlappingReplacementWaitsForOriginalDrainAndThenClosesFirstReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gateway = ContextHeldGateway(), lifecycle = IntegrationLifecycle()
    let original = try await lifecycle.replace { try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust()) }
    await original.model.start(starter: true); _ = await gateway.waitForEntry()
    var firstBegan = false, secondBegan = false, order: [String] = [], firstBuilt: IntegrationContext?, secondSawClosedFirst = false
    let first = Task {
      firstBegan = true
      return try await lifecycle.replace {
        order.append("first")
        let value = try await IntegrationContext.make(root: root, namespace: "overlap-first", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
        firstBuilt = value; return value
      }
    }
    while !firstBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    let second = Task {
      secondBegan = true
      return try await lifecycle.replace {
        order.append("second")
        if let firstBuilt {
          XCTAssertTrue(firstBuilt.model.readOnly)
          do { _ = try await XCTUnwrap(firstBuilt.repository).matchIDs(); XCTFail("first replacement facade must close before the second factory") }
          catch { secondSawClosedFirst = true }
        } else { XCTFail("a queued replacement cannot pass the first factory") }
        return try await IntegrationContext.make(root: root, namespace: "overlap-second", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
      }
    }
    while !secondBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(order.isEmpty, "neither factory may start while the original capture drain is held")
    await gateway.release()
    let firstResult = try await first.value, secondResult = try await second.value
    XCTAssertEqual(order, ["first", "second"]); XCTAssertTrue(secondSawClosedFirst)
    XCTAssertTrue(lifecycle.current === secondResult); XCTAssertFalse(firstResult === secondResult)
    XCTAssertTrue(firstResult.model.readOnly)
    try await firstResult.shutdown(); try await secondResult.shutdown()
  }
  func testCancelledReplacementJoinsOriginalDrainWithoutBuildingAndReleasesQueuedCaller() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gateway = ContextHeldGateway(), lifecycle = IntegrationLifecycle()
    let original = try await lifecycle.replace { try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust()) }
    await original.model.start(starter: true); _ = await gateway.waitForEntry()
    var firstBegan = false, cancelledFactoryCalls = 0, queuedFactoryCalls = 0, cancelledReturned = false
    let cancelled = Task {
      firstBegan = true
      defer { cancelledReturned = true }
      return try await lifecycle.replace {
        cancelledFactoryCalls += 1
        return try await IntegrationContext.make(root: root, namespace: "cancelled-overlap", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
      }
    }
    while !firstBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
    let queued = Task {
      try await lifecycle.replace {
        queuedFactoryCalls += 1
        return try await IntegrationContext.make(root: root, namespace: "valid-after-cancel", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
      }
    }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(cancelledReturned, "cancellation still joins the original positive fact before releasing replacement ownership")
    XCTAssertEqual(cancelledFactoryCalls, 0); XCTAssertEqual(queuedFactoryCalls, 0)
    await gateway.release()
    var escaped: IntegrationContext?
    do { escaped = try await cancelled.value; XCTFail("cancelled caller cannot build after its awaited shutdown") }
    catch { XCTAssertTrue(error is CancellationError) }
    let next = try await queued.value
    XCTAssertEqual(cancelledFactoryCalls, 0); XCTAssertEqual(queuedFactoryCalls, 1); XCTAssertTrue(lifecycle.current === next)
    XCTAssertTrue(original.model.readOnly)
    do { _ = try await XCTUnwrap(original.repository).matchIDs(); XCTFail("original facade must close after its joined positive observation") } catch {}
    try await escaped?.shutdown(); try await next.shutdown()
  }
  func testOverlappingReplacementFailureKeepsOriginalAndBlocksBothFactories() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gateway = ContextHeldGateway(), lifecycle = IntegrationLifecycle()
    let original = try await lifecycle.replace { try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust()) }
    await original.model.start(starter: true); _ = await gateway.waitForEntry(); try await XCTUnwrap(original.repository).close()
    var firstBegan = false, secondBegan = false, factories = 0, escaped: IntegrationContext?
    let first = Task {
      firstBegan = true
      return try await lifecycle.replace { factories += 1; throw ContextReplacementProbe.reached }
    }
    while !firstBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    let second = Task {
      secondBegan = true
      return try await lifecycle.replace {
        factories += 1
        let value = try await IntegrationContext.make(root: root, namespace: "failed-overlap-escape", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
        escaped = value; return value
      }
    }
    while !secondBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(factories, 0, "a second call cannot see the temporarily empty current as permission to build")
    await gateway.release()
    do { _ = try await first.value; XCTFail("original durable drain must fail") } catch {}
    do { _ = try await second.value; XCTFail("queued call must retry the same failed original drain") } catch {}
    XCTAssertEqual(factories, 0); XCTAssertTrue(lifecycle.current === original); XCTAssertTrue(original.model.readOnly)
    try await escaped?.shutdown()
  }

}
private actor ContextTransport: SyncTransport, DeviceSyncEventSource {
  func activate() async {}
  func send(_ bytes: Data, deliveryID: String) async throws { throw StoreError.syncTransportUnavailable }
  func deliveries() async -> AsyncStream<SyncDelivery> { AsyncStream { $0.finish() } }
  func events() async -> AsyncStream<DeviceSyncEvent> { AsyncStream { $0.finish() } }
}

private enum ContextReplacementProbe: Error { case reached }
private actor ContextHeldGateway: WorkoutGateway {
  private var operation: CaptureOperation?
  private var entered: CheckedContinuation<CaptureOperation, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func waitForEntry() async -> CaptureOperation {
    if let operation { return operation }; return await withCheckedContinuation { entered = $0 }
  }
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    self.operation = operation
    await withCheckedContinuation { continuation in held = continuation; entered?.resume(returning: operation); entered = nil }
    return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: Date(), outcome: .running, window: CaptureWindow(start: operation.requestedAt, end: nil))
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
  func release() { held?.resume(); held = nil }
}

extension IntegrationContextTests {
  func testCancelledFactoryJoinsUnpublishedOriginalNextBeforeQueuedFactory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-factory-" + UUID().uuidString), gateway = ContextHeldGateway(), gate = ContextFactoryBarrier(), lifecycle = IntegrationLifecycle()
    var candidate: IntegrationContext?, operation: CaptureOperation?, returned = false, factorySawOriginalCancellation = false
    let cancelled = Task {
      defer { returned = true }
      return try await lifecycle.replace {
        let value = try await IntegrationContext.make(root: root, namespace: "cancelled-unpublished", development: true, workout: gateway, transport: ContextTransport(), trust: UnavailableRevocableTrust())
        await value.model.start(starter: true); operation = await gateway.waitForEntry(); candidate = value
        await gate.hold(); factorySawOriginalCancellation = Task.isCancelled
        return value
      }
    }
    await gate.waitForEntry(); let original = try XCTUnwrap(candidate), repository = try XCTUnwrap(original.repository), session = try XCTUnwrap(original.session)
    cancelled.cancel(); var queuedCalls = 0, queuedSawClosedOriginal = false
    let queued = Task {
      try await lifecycle.replace {
        queuedCalls += 1
        do { _ = try await repository.matchIDs(); XCTFail("queued factory cannot see an open abandoned facade") } catch { queuedSawClosedOriginal = true }
        return try await IntegrationContext.make(root: root, namespace: "after-cancelled-factory", development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
      }
    }
    await gate.release()
    let retired = await candidateIsRetired(session); XCTAssertTrue(retired)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while !returned, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertFalse(returned, "cancelled replacement must itself join the original next capture before returning")
    XCTAssertEqual(queuedCalls, 0); XCTAssertTrue(factorySawOriginalCancellation)
    await gateway.release()
    do { _ = try await cancelled.value; XCTFail("cancelled caller cannot receive the late factory result") } catch { XCTAssertTrue(error is CancellationError) }
    let next = try await queued.value
    XCTAssertEqual(queuedCalls, 1); XCTAssertTrue(queuedSawClosedOriginal); XCTAssertTrue(lifecycle.current === next)
    XCTAssertNil(original.model.snapshot); XCTAssertTrue(original.model.history.isEmpty)
    let reopened = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "cancelled-unpublished")
    let snapshot = try await reopened.snapshotV2(matchID: XCTUnwrap(operation).binding.matchID)
    XCTAssertEqual(snapshot.captureOperations.first(where: { $0.operation.id == operation?.id })?.observation?.outcome, .running)
    try await reopened.close(); try await next.shutdown()
  }
  func testCancelledFactoryCloseFailureRetainsOriginalNextAndBlocksQueuedFactory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-factory-lease-" + UUID().uuidString), gate = ContextFactoryBarrier(), lifecycle = IntegrationLifecycle()
    let signer = try DevelopmentDeviceSigner(namespace: "cancelled-candidate", rawRepresentation: Data(repeating: 61, count: 32))
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "cancelled-candidate", controlDirectory: root.appendingPathComponent("retained")) { _ in M4IdentityMaterial(signer: signer, vault: MemoryDeviceCredentialVault()) }
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["candidate-key": signer.publicKey])
    let owner = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "candidate-cloud"), candidate = IntegrationContext.account(owner)
    let cancelled = Task { try await lifecycle.replace { await gate.hold(); return candidate } }
    await gate.waitForEntry()
    let path = prepared.seed.controlDirectory.appendingPathComponent("identity.owner"), retained = root.appendingPathComponent("original-owner-preserved"), foreign = root.appendingPathComponent("foreign-owner-preserved")
    try FileManager.default.moveItem(at: path, to: retained); try Data("foreign identity lease fixture".utf8).write(to: path)
    cancelled.cancel(); var queuedCalls = 0
    let queued = Task { try await lifecycle.replace { queuedCalls += 1; throw ContextReplacementProbe.reached } }
    await gate.release()
    do { _ = try await cancelled.value; XCTFail("original next lease refusal must propagate instead of cancelled success") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    do { _ = try await queued.value; XCTFail("failed original cleanup must block queued factory") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertEqual(queuedCalls, 0); XCTAssertTrue(lifecycle.current === candidate); XCTAssertNotNil(owner.lastCloseFailure)
    let ids = try await owner.repository.matchIDs(); XCTAssertTrue(ids.isEmpty, "original DB remains open on identity-lease preflight refusal")
    try FileManager.default.moveItem(at: path, to: foreign); try FileManager.default.moveItem(at: retained, to: path)
    do { _ = try await lifecycle.replace { queuedCalls += 1; throw ContextReplacementProbe.reached }; XCTFail("fixture factory throws after original cleanup retry") }
    catch { XCTAssertEqual(error as? ContextReplacementProbe, .reached) }
    XCTAssertEqual(queuedCalls, 1); XCTAssertNil(lifecycle.current); XCTAssertNil(owner.lastCloseFailure)
  }
  private func candidateIsRetired(_ session: MatchSession) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      do { _ = try await session.prepareStart(starter: true) } catch SessionError.retired { return true } catch {}
      try? await Task.sleep(for: .milliseconds(2))
    }
    return false
  }
}
private actor ContextFactoryBarrier {
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func hold() async { await withCheckedContinuation { held = $0; entered = true; entry?.resume(); entry = nil } }
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { entry = $0 } }
  func release() { held?.resume(); held = nil }
}
