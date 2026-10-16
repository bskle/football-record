import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSync
import MatchPresentation
import DeviceSync
@testable import AppIntegration

@MainActor final class DevicePairIntegrationTests: XCTestCase {
  func testTwoRealSQLiteInstallationsThroughDeviceTransportACKAndRevocation() async throws {
    let a = UUID().uuidString, b = UUID().uuidString
    let ra = try root(identity: a), rb = try root(identity: b)
    let da = PairDriver(), db = PairDriver(); await da.connect(db); await db.connect(da)
    let ta = try transport(root: ra, driver: da), tb = try transport(root: rb, driver: db)
    let pa = try provider(root: ra, local: a, remote: b), pb = try provider(root: rb, local: b, remote: a)
    let ca = try await IntegrationContext.make(root: ra, namespace: DeviceDatasetGate.namespace, development: true, transport: ta, trust: pa)
    let cb = try await IntegrationContext.make(root: rb, namespace: DeviceDatasetGate.namespace, development: true, transport: tb, trust: pb)
    try await ca.coordinator?.start(); try await cb.coordinator?.start()
    await ca.model.load(); await ca.model.start(starter: true); await ca.model.perform(.quick(.myGoal))
    let match = try XCTUnwrap(ca.model.snapshot?.replay.matchID)
    try await settle {
      guard let state = try? await ca.coordinator?.state(matchID: match) else { return false }
      return state.unroutedCount == 0 && state.pendingACKCount == 0 && state.receivedGapCount == 0 && state.lastPeerACKAt != nil
    }
    await cb.model.load()
    XCTAssertEqual(cb.model.snapshot?.replay.matchID, match)
    XCTAssertTrue(cb.model.readOnly); XCTAssertEqual(cb.model.feedbackCount, 0)
    XCTAssertEqual(ca.model.feedbackCount, 2)
    await ca.model.perform(.end)
    try await settle { (try? await cb.repository?.snapshotV2(matchID: match).business.events.contains(where: { $0.type == .matchEnded })) == true }
    let terminal = try await ca.repository?.snapshotV2(matchID: match)
    XCTAssertNotEqual(terminal?.business.descriptor.backendLockState, .releasedConfirmed)
    XCTAssertEqual(ca.model.snapshot?.replay.state, .endedPendingSync)
    await da.invalidate()
    try await settle { (try? await ca.coordinator?.state(matchID: match).issue) == .trustUnavailable }
    await ca.coordinator?.retry()
    do { _ = try await pa.authorize(.send, remoteDeviceID: b); XCTFail() } catch {}
    XCTAssertEqual(cb.model.feedbackCount, 0)
    await ca.shutdown(); await cb.shutdown()
    let reopened = try DevicePeerTrustProvider(directory: directory(ra), namespace: DeviceDatasetGate.namespace, requested: nil)
    do { _ = try await reopened.authorize(.route, remoteDeviceID: nil); XCTFail() } catch {}
    XCTAssertEqual(try String(contentsOf: directory(ra).appendingPathComponent("device.identity"), encoding: .utf8), "football-record.identity.v1:" + a)
  }
  private func directory(_ root: URL) -> URL { root.appendingPathComponent(DeviceDatasetGate.namespace) }
  private func root(identity: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory(root), withIntermediateDirectories: true)
    try Data(("football-record.identity.v1:" + identity).utf8).write(to: directory(root).appendingPathComponent("device.identity"))
    return root
  }
  private func provider(root: URL, local: String, remote: String) throws -> DevicePeerTrustProvider {
    try DevicePeerTrustProvider(directory: directory(root), namespace: DeviceDatasetGate.namespace, requested: DevicePeerConfiguration(localDeviceID: local, remoteDeviceID: remote, accountSubject: "development-account", pairingID: "explicit-two-installations", trustEpoch: "epoch-1"))
  }
  private func transport(root: URL, driver: PairDriver) throws -> WCSessionTransport {
    let files = directory(root).appendingPathComponent("DeviceSync")
    return try WCSessionTransport(driver: driver, inbox: DurableFileInbox(directory: files.appendingPathComponent("inbox")), outboxDirectory: files.appendingPathComponent("outbox"))
  }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline { if try await predicate() { return }; await Task.yield() }
    XCTFail("device composition condition did not settle")
  }
}
private actor PairDriver: WCSessionDriving {
  weak var peer: PairDriver?
  var callbacks: DriverCallbacks?
  var installed = 0
  func connect(_ peer: PairDriver) { self.peer = peer }
  func install(_ callbacks: DriverCallbacks) async { installed += 1; self.callbacks = callbacks }
  func activate() async { callbacks?.event(.activationCompleted(await snapshot(), nil)) }
  func snapshot() async -> DriverSnapshot { DriverSnapshot(activated: true, reachable: true, counterpartAvailable: true) }
  func sendMessage(_ bytes: Data) async throws -> TransportReply {
    guard let peer else { throw DeviceSyncError.unavailable }
    return await peer.receive(bytes)
  }
  func receive(_ bytes: Data) -> TransportReply { callbacks?.message(bytes) ?? .unavailable }
  func outstandingFiles() async -> [DriverFileTransfer] { [] }
  func enqueueFile(_ transfer: DriverFileTransfer) async throws { throw DeviceSyncError.unavailable }
  func invalidate() { callbacks?.event(.inactive) }
}
