import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
import MatchPresentation
import WorkoutCapture
@testable import AppIntegration

@MainActor final class IntegrationTests: XCTestCase {
  func testEnvironmentPreferenceReopensSameDatasetAndInvalidDataNeverFallsBack() throws {
    let defaults = UserDefaults(suiteName: "football-record-integration-test-" + UUID().uuidString)!
    let preferences = EnvironmentPreferences(defaults: defaults)
    XCTAssertEqual(try preferences.load(), .production)
    try preferences.save(.deviceAcceptance)
    XCTAssertEqual(try EnvironmentPreferences(defaults: defaults).load(), .deviceAcceptance)
    XCTAssertEqual(IntegrationMode.deviceAcceptance.dataset, "device-acceptance-v1")
    try preferences.save(.uiSimulation(dataset: "stable-ui-test"))
    XCTAssertEqual(try preferences.load(), .uiSimulation(dataset: "stable-ui-test"))
    defaults.set(Data("unrecognised".utf8), forKey: EnvironmentPreferences.key)
    XCTAssertThrowsError(try preferences.load())
    defaults.set("wrong-type", forKey: EnvironmentPreferences.key)
    XCTAssertThrowsError(try preferences.load())
    XCTAssertThrowsError(try preferences.save(.uiSimulation(dataset: "device-acceptance-v1")))
    defaults.removeObject(forKey: EnvironmentPreferences.key)
  }
  func testRealSQLiteActiveAndEndedHeldRecordsBlockLeavingEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: DeviceDatasetGate.namespace)
    let gate = DeviceDatasetGate(rootDirectory: root)
    let initiallySafe = try await gate.isSafeToLeave(); XCTAssertTrue(initiallySafe)
    let session = MatchSession(store: repo, deviceIdentity: TestIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: DeviceDatasetGate.namespace))
    let request = try await session.prepareStart(starter: true)
    _ = try await session.execute(request)
    let activeSafe = try await gate.isSafeToLeave(); XCTAssertFalse(activeSafe)
    let end = try await session.prepare(.end, matchID: request.matchID)
    _ = try await session.execute(end)
    let endedSafe = try await gate.isSafeToLeave(); XCTAssertFalse(endedSafe, "Ended with held backend lock is not safe to abandon")
  }
  func testCaptureUncertaintyAndPendingLinkAlwaysBlockSwitching() {
    XCTAssertFalse(IntegrationSafety.permitsLeaving(lockReleased: true, active: false, capture: .needsReconciliation, pendingOperations: false))
    XCTAssertFalse(IntegrationSafety.permitsLeaving(lockReleased: true, active: false, capture: .savedAwaitingLink, pendingOperations: false))
    XCTAssertFalse(IntegrationSafety.permitsLeaving(lockReleased: true, active: false, capture: .finished, pendingOperations: true))
    XCTAssertFalse(IntegrationSafety.permitsLeaving(lockReleased: false, active: false, capture: .notRecorded(.unavailable), pendingOperations: false))
    XCTAssertTrue(IntegrationSafety.permitsLeaving(lockReleased: true, active: false, capture: .notRecorded(.unavailable), pendingOperations: false))
  }
  func testMetricsConvertUnitsPreservingUnknownUnsupportedAndRealZero() {
    var value = LiveWorkoutMetrics()
    value.heartRate = .unsupported; value.distanceMeters = .available(1250); value.speedMetersPerSecond = .available(2); value.location = .available(0)
    let result = MetricsMapping.presentation(value)
    XCTAssertEqual(result.heartRate, .unsupported); XCTAssertEqual(result.distance, .available(1.25)); XCTAssertEqual(result.speed, .available(7.2)); XCTAssertTrue(result.gps.contains("0"))
    value.distanceMeters = .available(0); value.speedMetersPerSecond = .available(.nan); value.location = .notRecorded
    let zero = MetricsMapping.presentation(value)
    XCTAssertEqual(zero.distance, .available(0)); XCTAssertEqual(zero.speed, .notRecorded); XCTAssertEqual(zero.gps, "未记录")
  }
  func testRecoveryBeforeAttachAndWhileBusyIsRetainedAndCoalesced() async throws {
    let inbox = RecoveryInbox()
    var ready = false; var calls = 0
    inbox.request(); inbox.request()
    inbox.attach(isReady: { ready }, recover: { calls += 1 })
    try await Task.sleep(for: .milliseconds(30)); XCTAssertEqual(calls, 0)
    ready = true
    try await Task.sleep(for: .milliseconds(150)); XCTAssertEqual(calls, 1)
    inbox.request(); try await Task.sleep(for: .milliseconds(30)); XCTAssertEqual(calls, 2)
  }
  func testRecoveryDuringAnInFlightLoadIsNotDropped() async throws {
    let inbox = RecoveryInbox(); var calls = 0
    inbox.attach(isReady: { true }, recover: {
      calls += 1
      if calls == 1 { inbox.request(); await Task.yield() }
    })
    inbox.request(); try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(calls, 2)
  }
}

private struct TestIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "integration-test-device" } }
