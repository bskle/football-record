import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
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


extension BootstrapTests {
  func testCheckedContextRetainsOriginalObjectsAndClosesOnce() async throws {
    let c = try AppBootstrap.composition(databaseNamespace: "checked-context", development: true, rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let account = AccountStatusModel(repository: c.repository), lifecycle = LifecycleStatusModel(repository: c.repository)
    var closes = 0
    let context = try await AppBootstrap.accountContext(repository: c.repository, session: c.session, recording: c.model, account: account, lifecycle: lifecycle, close: { closes += 1; try? await c.repository.close() })
    XCTAssertTrue(context.repository === c.repository); XCTAssertTrue(context.session === c.session)
    XCTAssertTrue(context.recording === c.model); XCTAssertTrue(context.account === account); XCTAssertTrue(context.lifecycle === lifecycle)
    await context.refresh(); XCTAssertFalse(account.canEnterRecording, "assembly does not authenticate")
    await context.shutdown(); await context.shutdown(); XCTAssertEqual(closes, 1)
  }
  func testCheckedContextRejectsWrongFacadeAndSessionWithoutClosingResources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = try AppBootstrap.composition(databaseNamespace: "same-namespace", development: true, rootDirectory: root)
    let b = try AppBootstrap.composition(databaseNamespace: "same-namespace", development: true, rootDirectory: root)
    let secondSession = MatchSession(store: a.repository, deviceIdentity: BootstrapIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "same-namespace"))
    let account = AccountStatusModel(repository: a.repository), lifecycle = LifecycleStatusModel(repository: a.repository)
    let cases: [(SQLiteSessionRepository, MatchSession, RecordingModel, AccountStatusModel, LifecycleStatusModel)] = [
      (b.repository,a.session,a.model,account,lifecycle),
      (a.repository,b.session,a.model,account,lifecycle),
      (a.repository,a.session,b.model,account,lifecycle),
      (a.repository,a.session,RecordingModel(session: secondSession,repository:a.repository,development:true),account,lifecycle),
      (a.repository,a.session,RecordingModel(session:a.session,repository:b.repository,development:true),account,lifecycle),
      (a.repository,a.session,a.model,AccountStatusModel(repository:b.repository),lifecycle),
      (a.repository,a.session,a.model,account,LifecycleStatusModel(repository:b.repository))
    ]
    var closes = 0
    for (repo,session,recording,account,lifecycle) in cases {
      do {
        _ = try await AppBootstrap.accountContext(repository:repo,session:session,recording:recording,account:account,lifecycle:lifecycle,close:{ closes += 1 })
        XCTFail("must reject wrong original facade/Session")
      } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    }
    XCTAssertEqual(closes,0); try await a.repository.close(); try await b.repository.close()
  }
}
private struct BootstrapIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "checked-device" } }
