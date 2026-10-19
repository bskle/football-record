import Foundation
import XCTest
import MatchStore
@testable import AppIntegration

final class DevicePeerTrustTests: XCTestCase, @unchecked Sendable {
  let local = "00000000-0000-0000-0000-000000000001"
  let remote = "00000000-0000-0000-0000-000000000002"
  func fixture() throws -> (URL, DevicePeerConfiguration) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(("football-record.identity.v1:" + local).utf8).write(to: root.appendingPathComponent("device.identity"))
    return (root, try DevicePeerConfiguration(localDeviceID: local.lowercased(), remoteDeviceID: remote.lowercased(), accountSubject: "development-account", pairingID: "explicit-pair", trustEpoch: "epoch-1"))
  }
  func testUnconfiguredNeverInventsRemoteAndConfiguredBindingReopens() async throws {
    let (root, config) = try fixture()
    let empty = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: nil)
    do { _ = try await empty.authorize(.route, remoteDeviceID: nil); XCTFail() } catch {}
    let first = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: config)
    let authorization = try await first.authorize(.route, remoteDeviceID: nil)
    XCTAssertEqual(authorization.localDeviceID, local); XCTAssertEqual(authorization.remoteDeviceID, remote)
    let reopened = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: nil)
    try await reopened.validate(authorization, for: .send)
    do { _ = try await reopened.authorize(.receive, remoteDeviceID: UUID().uuidString); XCTFail() } catch {}
  }
  func testIdentityFileAndConfigurationAreRecheckedAndInvalidationSurvivesRestart() async throws {
    let (root, config) = try fixture()
    let trust = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: config)
    let authorization = try await trust.authorize(.route, remoteDeviceID: nil)
    try Data("invalid-identity".utf8).write(to: root.appendingPathComponent("device.identity"))
    do { try await trust.validate(authorization, for: .send); XCTFail() } catch {}
    try Data(("football-record.identity.v1:" + local).utf8).write(to: root.appendingPathComponent("device.identity"))
    // Once observed, restoring a file must not erase the persisted invalidation.
    let reopened = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: config)
    do { _ = try await reopened.authorize(.route, remoteDeviceID: nil); XCTFail() } catch {}
  }
  func testChangedBindingAndMalformedUUIDFailClosedWithoutReplacingOriginal() async throws {
    let (root, config) = try fixture()
    _ = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: config)
    let original = try Data(contentsOf: root.appendingPathComponent("development-peer.json"))
    let changed = try DevicePeerConfiguration(localDeviceID: local, remoteDeviceID: remote, accountSubject: "different-account", pairingID: "explicit-pair", trustEpoch: "epoch-2")
    XCTAssertThrowsError(try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: changed))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("development-peer.json")), original)
    XCTAssertThrowsError(try DevicePeerConfiguration(localDeviceID: "not-uuid", remoteDeviceID: remote, accountSubject: "a", pairingID: "p", trustEpoch: "e"))
    XCTAssertThrowsError(try DevicePeerTrustProvider(directory: root, namespace: "production", requested: config))
  }
  func testValidateRejectsEveryBindingFieldAndFutureOrExpiredTime() async throws {
    let (root, config) = try fixture()
    let trust = try DevicePeerTrustProvider(directory: root, namespace: DeviceDatasetGate.namespace, requested: config)
    let good = try await trust.authorize(.route, remoteDeviceID: nil)
    for n in 0..<8 {
      let bad = try PeerAuthorization(localDeviceID: n == 0 ? UUID().uuidString : local, remoteDeviceID: n == 1 ? UUID().uuidString : remote, accountSubject: n == 2 ? "other" : good.accountSubject, pairingID: n == 3 ? "other" : good.pairingID, trustEpoch: n == 4 ? "other" : good.trustEpoch, environment: n == 5 ? .development(databaseNamespace: "other") : good.environment, issuedAt: n == 6 ? Date().addingTimeInterval(600) : Date().addingTimeInterval(-600), expiresAt: n == 7 ? Date().addingTimeInterval(-1) : Date().addingTimeInterval(900))
      do { try await trust.validate(bad, for: .receive); XCTFail("field \(n)") } catch {}
    }
  }
}
