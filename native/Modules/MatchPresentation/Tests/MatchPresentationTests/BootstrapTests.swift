import Foundation
import XCTest
import MatchCore
import MatchSession
@testable import MatchPresentation
actor ProbeGateway: WorkoutGateway {
  var calls = 0
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    calls += 1
    return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: Date(), outcome: .notCreated(.unavailable), window: CaptureWindow(start: nil, end: nil))
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: Date(), outcome: .unknown, window: CaptureWindow(start: nil, end: nil))
  }
}
@MainActor final class BootstrapTests: XCTestCase {
  func testGatewaySeamKeepsFixedDevelopmentBoundaryAndUsesInjectedAdapter() async throws {
    let gateway = ProbeGateway()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try AppBootstrap.make(namespace: "bootstrap-test", development: true, workout: gateway, rootDirectory: root)
    await model.start(starter: true)
    for _ in 0..<100 { if await gateway.calls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    let calls = await gateway.calls; XCTAssertEqual(calls, 1); XCTAssertTrue(model.development)
    let namespace = await model.repository.databaseNamespace(); XCTAssertEqual(namespace, "bootstrap-test")
    XCTAssertEqual(model.snapshot?.store.business.descriptor.startPermit?.evidence, .developmentSimulation)
  }
  func testGatewayInjectionCannotBypassUnavailableProductionPermit() async throws {
    let gateway = ProbeGateway()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try AppBootstrap.make(namespace: "production", development: false, workout: gateway, rootDirectory: root)
    await model.start(starter: true)
    let calls = await gateway.calls; XCTAssertEqual(calls, 0); XCTAssertFalse(model.development)
    XCTAssertEqual(model.feedbackCount, 0); XCTAssertNotNil(model.pendingRequest)
  }
}
