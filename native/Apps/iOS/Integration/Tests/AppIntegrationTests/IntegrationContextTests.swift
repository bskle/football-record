import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import MatchSync
import MatchPresentation
import DeviceSync
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
