import Foundation
import XCTest
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
    await context.shutdown()
    let reopened = try await IntegrationContext.make(root: root, namespace: namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    XCTAssertFalse(reopened.model === oldModel)
    await reopened.model.load()
    XCTAssertEqual(reopened.model.snapshot?.store.business.descriptor.matchID, id)
    XCTAssertFalse(reopened.model.readOnly)
    XCTAssertTrue(reopened.model.canRecord, "state=\(String(describing: reopened.model.snapshot?.replay.state)) issue=\(String(describing: reopened.model.issue)) pending=\(String(describing: reopened.model.pendingRequest))")
    await reopened.model.perform(.leaveField)
    XCTAssertEqual(reopened.model.feedbackCount, 1, "issue=\(String(describing: reopened.model.issue)) pending=\(String(describing: reopened.model.pendingRequest))")
    XCTAssertEqual(oldModel.feedbackCount, 2)
    await reopened.shutdown()
  }
  func testThrowingTransportFactoryCannotBlockExistingLocalRecord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lifecycle = IntegrationLifecycle()
    var original: IntegrationContext? = try await lifecycle.replace {
      try await IntegrationContext.make(root: root, namespace: DeviceDatasetGate.namespace, development: true, transport: ContextTransport(), trust: UnavailableRevocableTrust())
    }
    await original?.model.load(); await original?.model.start(starter: true)
    let prior = try XCTUnwrap(original?.model), match = try XCTUnwrap(prior.snapshot?.replay.matchID)
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
    XCTAssertEqual(prior.feedbackCount, 1)
    let state = try await next.coordinator?.state(matchID: match)
    XCTAssertNil(state?.lastPeerACKAt)
    XCTAssertGreaterThan(state?.unroutedCount ?? 0, 0)
    await next.shutdown()
  }

}
private actor ContextTransport: SyncTransport, DeviceSyncEventSource {
  func activate() async {}
  func send(_ bytes: Data, deliveryID: String) async throws { throw StoreError.syncTransportUnavailable }
  func deliveries() async -> AsyncStream<SyncDelivery> { AsyncStream { $0.finish() } }
  func events() async -> AsyncStream<DeviceSyncEvent> { AsyncStream { $0.finish() } }
}
