#if DEBUG
import Foundation
import MatchCore
import MatchStore
import MatchSession
import MatchSync

/// A development-only protocol fixture. These endpoints are two local SQLite installations,
/// never WatchConnectivity, a production account, or a production start lock.
@MainActor final class DevelopmentSyncPair {
  enum Mode: Sendable { case online, queued, failed }
  let localRepository, remoteRepository: SQLiteSessionRepository
  let localDeviceID, remoteDeviceID: String
  let model: RecordingModel
  let lifecycle: DevelopmentPairService
  private init(local: SQLiteSessionRepository, remote: SQLiteSessionRepository, localID: String, remoteID: String, model: RecordingModel, lifecycle: DevelopmentPairService) {
    localRepository = local; remoteRepository = remote; localDeviceID = localID; remoteDeviceID = remoteID; self.model = model; self.lifecycle = lifecycle
  }
  static func make(dataset: String, rootDirectory: URL? = nil, mode: Mode, syncClock: any SyncClock = SystemSyncClock()) async throws -> DevelopmentSyncPair {
    let canonical = String(dataset.lowercased().utf8.filter { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }.map { Character(UnicodeScalar($0)) }.prefix(60))
    guard !canonical.isEmpty else { throw SessionError.invalidRequest }
    let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record", isDirectory: true)
    let localNamespace = "ui-simulation-" + canonical + "-local", remoteNamespace = "ui-simulation-" + canonical + "-peer"
    let local = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: localNamespace)
    let remote = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: remoteNamespace)
    let localURL = root.appendingPathComponent(localNamespace).appendingPathComponent("device.identity")
    let remoteURL = root.appendingPathComponent(remoteNamespace).appendingPathComponent("device.identity")
    let localIdentity = PersistentDeviceIdentityProvider(url: localURL, repository: local)
    let remoteIdentity = PersistentDeviceIdentityProvider(url: remoteURL, repository: remote)
    // The identity provider refuses to invent a replacement when existing records need one.
    let localID = try await localIdentity.localDeviceID(), remoteID = try await remoteIdentity.localDeviceID()
    let localSession = MatchSession(store: local, deviceIdentity: localIdentity, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: localNamespace))
    let remoteSession = MatchSession(store: remote, deviceIdentity: remoteIdentity, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: remoteNamespace))
    let localTransport = DevelopmentLoopbackTransport(mode: mode), remoteTransport = DevelopmentLoopbackTransport(mode: mode)
    await localTransport.connect(remoteTransport); await remoteTransport.connect(localTransport)
    let localTrust = try DevelopmentPeerTrustProvider(localIdentityURL: localURL, remoteIdentityURL: remoteURL, localDeviceID: localID, remoteDeviceID: remoteID, databaseNamespace: localNamespace, accountSubject: "development-account", pairingID: "development-pair-" + canonical, trustEpoch: "development-epoch-v1", clock: syncClock)
    let remoteTrust = try DevelopmentPeerTrustProvider(localIdentityURL: remoteURL, remoteIdentityURL: localURL, localDeviceID: remoteID, remoteDeviceID: localID, databaseNamespace: remoteNamespace, accountSubject: "development-account", pairingID: "development-pair-" + canonical, trustEpoch: "development-epoch-v1", clock: syncClock)
    let localService = MatchSyncService(repository: local, inbound: localSession, transport: localTransport, trust: localTrust, clock: syncClock)
    let remoteService = MatchSyncService(repository: remote, inbound: remoteSession, transport: remoteTransport, trust: remoteTrust, clock: syncClock)
    let lifecycle = DevelopmentPairService(local: localService, remote: remoteService, first: localTransport, second: remoteTransport)
    let model = RecordingModel(session: localSession, repository: local, development: true, sync: lifecycle, developmentPair: true)
    return DevelopmentSyncPair(local: local, remote: remote, localID: localID, remoteID: remoteID, model: model, lifecycle: lifecycle)
  }
  func settle() async {
    var stable = 0
    for _ in 0..<200 {
      await lifecycle.wake(); await Task.yield()
      guard let id = model.snapshot?.replay.matchID, let state = try? await localRepository.syncStateV3(matchID: id) else { continue }
      if state.unroutedCount == 0 && (state.pendingACKCount == 0 || state.lastPeerACKAt == nil) { stable += 1 } else { stable = 0 }
      if stable >= 8 { break }
    }
  }
}

private actor DevelopmentLoopbackTransport: SyncTransport {
  weak var peer: DevelopmentLoopbackTransport?
  var mode: DevelopmentSyncPair.Mode
  let stream: AsyncStream<SyncDelivery>
  let continuation: AsyncStream<SyncDelivery>.Continuation
  init(mode: DevelopmentSyncPair.Mode) {
    self.mode = mode
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
  }
  func connect(_ peer: DevelopmentLoopbackTransport) { self.peer = peer }
  func setOnline() { mode = .online }
  func activate() async {}
  func deliveries() async -> AsyncStream<SyncDelivery> { stream }
  func send(_ fragmentBytes: Data, deliveryID: String) async throws {
    switch mode {
    case .failed: throw StoreError.syncTransportUnavailable
    case .queued: return // A successful transport callback without a business ACK.
    case .online:
      guard let peer else { throw StoreError.syncTransportUnavailable }
      await peer.accept(try SyncDelivery(bytes: fragmentBytes, transportDeliveryID: deliveryID))
    }
  }
  func accept(_ delivery: SyncDelivery) { continuation.yield(delivery) }
}
actor DevelopmentPairService: SyncStatusServing {
  private let local, remote: MatchSyncService
  private let first, second: DevelopmentLoopbackTransport
  fileprivate init(local: MatchSyncService, remote: MatchSyncService, first: DevelopmentLoopbackTransport, second: DevelopmentLoopbackTransport) {
    self.local = local; self.remote = remote; self.first = first; self.second = second
  }
  func start() async throws { try await remote.start(); try await local.start() }
  func stop() async { await local.stop(); await remote.stop() }
  func wake() async { await local.wake(); await remote.wake() }
  func retry() async {
    await first.setOnline(); await second.setOnline()
    try? await start(); await wake()
  }
  func state(matchID: String) async throws -> SyncState { try await local.state(matchID: matchID) }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> { await local.states(matchID: matchID) }
}
#endif
