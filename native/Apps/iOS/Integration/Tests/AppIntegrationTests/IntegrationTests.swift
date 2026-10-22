import Foundation
import XCTest
import MatchCore
import MatchSession
import MatchStore
import MatchPresentation
import WorkoutCapture
import AccountKit
import CryptoKit
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

#if DEBUG
extension IntegrationTests {
  func testControlledM4BootstrapRejectsMissingIndependentIdentityBeforeBusinessDB() async throws {
    let (root, configuration) = try controlledApplicationFixture(observations: false)
    do { _ = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root); XCTFail("configuration cannot synthesize independent identity") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(configuration.namespace).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("development/m4-controls").path))
  }
  func testControlledM4BootstrapRetainsActualCatalogPublicationBeforeOriginalFacade() async throws {
    let (root, configuration) = try controlledApplicationFixture()
    let app = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root)
    let controls = root.appendingPathComponent("development/m4-controls/" + configuration.namespace)
    guard FileManager.default.fileExists(atPath: controls.appendingPathComponent("catalog/catalog.json").path) else {
      XCTFail("the formal controlled factory must retain original physical publication before opening its facade")
      try await app.shutdown(); return
    }
    let catalog = try M4OwnedDataCatalog(directory: controls.appendingPathComponent("catalog"))
    let saved = try XCTUnwrap(catalog.physicalBootstrap())
    XCTAssertTrue(saved.resourcesPublished); XCTAssertTrue(saved.businessPublished)
    let original = try M4CatalogIO.anchor(root.appendingPathComponent(configuration.namespace + "/matches.sqlite"))
    XCTAssertTrue(M4CatalogIO.sameInode(original, saved.reservation.businessDatabase))
    XCTAssertTrue(try catalog.index().entries.isEmpty, "physical reservation cannot invent an account scope")
    try catalog.close(); try await app.shutdown()
  }
  func testControlledM4BootstrapUsesOriginalMaterialAndOneFacadeAcrossReopen() async throws {
    for role in ["phone", "watch"] {
      let (root, configuration) = try controlledApplicationFixture(role: role)
      let first = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root)
      try await first.activateControlled()
      let directory = root.appendingPathComponent(configuration.namespace), key = try Data(contentsOf: directory.appendingPathComponent("development.key"))
      let provider = PersistentDeviceIdentityProvider(url: directory.appendingPathComponent("device.identity"), repository: first.context.repository)
      let originalID = try await provider.localDeviceID(), repositoryID = await first.context.repository.syncRepositoryIdentity(), sessionID = await first.context.session.syncRepositoryIdentity()
      XCTAssertEqual(repositoryID, sessionID); XCTAssertEqual(key.count, 32); XCTAssertTrue(first.developmentSimulation)
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("authority.fixture").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("development.vault").path))
      XCTAssertFalse(first.context.account.canEnterRecording, "material/credential opening never admits current identity")
      let binding = try await first.context.repository.accountBindingV4(); XCTAssertNil(binding)
      let apple = root.appendingPathComponent("development/current-identity/apple-account.json"), cloud = root.appendingPathComponent("development/current-identity/cloud-space.json")
      let originalApple = try Data(contentsOf: apple), originalCloud = try Data(contentsOf: cloud)
      try await first.shutdown()
      let reopened = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root)
      try await reopened.activateControlled()
      let nextProvider = PersistentDeviceIdentityProvider(url: directory.appendingPathComponent("device.identity"), repository: reopened.context.repository)
      let nextID = try await nextProvider.localDeviceID(); XCTAssertEqual(nextID, originalID)
      XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("development.key")), key)
      XCTAssertEqual(try Data(contentsOf: apple), originalApple); XCTAssertEqual(try Data(contentsOf: cloud), originalCloud)
      XCTAssertFalse(reopened.context.account.canEnterRecording); try await reopened.shutdown()
    }
  }
  func testControlledM4BootstrapDoesNotRegeneratePartialMaterialBesideOriginalDB() async throws {
    let (root, configuration) = try controlledApplicationFixture()
    let original = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root)
    try await original.shutdown()
    let directory = root.appendingPathComponent(configuration.namespace), database = directory.appendingPathComponent("matches.sqlite"), key = directory.appendingPathComponent("development.key")
    let bytes = try Data(contentsOf: database), identity = try Data(contentsOf: directory.appendingPathComponent("device.identity"))
    try FileManager.default.moveItem(at: key, to: root.appendingPathComponent("saved-original-key"))
    do { _ = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: root); XCTFail("missing original key is not a new installation") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: key.path)); XCTAssertEqual(try Data(contentsOf: database), bytes)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("device.identity")), identity)
  }
  private func controlledApplicationFixture(role: String = "phone", observations: Bool = true) throws -> (URL, DevelopmentAuthorityConfiguration) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-application-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey(), namespace = "m4-ui-assembly-" + role
    let configuration = DevelopmentAuthorityConfiguration(dataset: "assembly", namespace: namespace, baseURL: "http://127.0.0.1:1", keyID: "application-fixture", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation), cloudSpaceID: "independent-cloud", subject: "configured-subject-does-not-admit", role: role)
    if observations {
      let directory = root.appendingPathComponent("development/current-identity")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let observation = UUID().uuidString, common: [String: Any] = ["version": 1, "environment": "development", "namespace": namespace, "observationID": observation]
      for (name, fields) in [("apple-account.json", ["accountID": "independent-account"]), ("cloud-space.json", ["cloudSpaceID": "independent-cloud", "zoneID": "independent-zone"])] {
        let file = directory.appendingPathComponent(name), object = common.merging(fields) { _, new in new }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
    return (root, configuration)
  }
}
#endif
