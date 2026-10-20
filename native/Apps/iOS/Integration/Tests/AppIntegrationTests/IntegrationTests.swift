import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
import MatchPresentation
import WorkoutCapture
@testable import AppIntegration

@MainActor final class IntegrationTests: XCTestCase {
  func testM4ProductionBootstrapIgnoresDevelopmentInputsWithoutOpeningOrAdoptingDB() async throws {
    for existing in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-production-unavailable-" + UUID().uuidString)
      let privateConfig = root.appendingPathComponent("development/m4-fixture.json")
      try FileManager.default.createDirectory(at: privateConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
      let configBytes = Data("private development configuration must not be read by production".utf8); try configBytes.write(to: privateConfig)
      let database = root.appendingPathComponent("production/matches.sqlite"), original = Data([0,255,17,0,42])
      if existing { try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true); try original.write(to: database) }
      let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
      let arguments = ["--m4-development", "--m4-auto-signin", "--ui-testing", "--ui-dataset", "production", "--device-acceptance"]
      do { _ = try await M4ApplicationBootstrap.production(arguments: arguments, rootDirectory: root); XCTFail("unconfigured production provider cannot create an M4 context") }
      catch { XCTAssertEqual(error as? M4ApplicationBootstrapError, .unavailable) }
      XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
      XCTAssertEqual(try Data(contentsOf: privateConfig), configBytes)
      if existing { XCTAssertEqual(try Data(contentsOf: database), original) }
      else { XCTAssertFalse(FileManager.default.fileExists(atPath: database.path)) }
    }
  }
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
    let initiallySafe = try await gate.isSafeToLeave(activeRepository: repo); XCTAssertTrue(initiallySafe)
    let session = MatchSession(store: repo, deviceIdentity: TestIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: DeviceDatasetGate.namespace))
    let request = try await session.prepareStart(starter: true)
    _ = try await session.execute(request)
    let activeSafe = try await gate.isSafeToLeave(activeRepository: repo); XCTAssertFalse(activeSafe)
    // This fixture tests the held-lock environment gate. Observe the initial
    // unavailable capture result before preparing a versioned end command.
    // A concurrent capture commit must still produce staleGeneration in Session.
    let deadline = ContinuousClock.now.advanced(by: .seconds(3)); var observed = false
    while ContinuousClock.now < deadline {
      let snapshot = try await repo.snapshotV2(matchID: request.matchID)
      if snapshot.captureOperations.contains(where: { $0.operation.action == .start && $0.state == .failed && $0.observation?.outcome == .notCreated(.unavailable) }) { observed = true; break }
      await Task.yield()
    }
    _ = try XCTUnwrap(observed ? true : nil, "initial unavailable capture observation did not commit")
    let end = try await session.prepare(.end, matchID: request.matchID)
    _ = try await session.execute(end)
    let endedSafe = try await gate.isSafeToLeave(activeRepository: repo); XCTAssertFalse(endedSafe, "Ended with held backend lock is not safe to abandon")
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
