import Foundation
import MatchCore
import MatchStore
import MatchSession
import MatchSync

/// Integration-only composition. All four objects share one repository actor/connection;
/// callers inject adapters rather than opening another repository or Session.
@MainActor public struct AppComposition {
  public let repository: SQLiteSessionRepository
  public let session: MatchSession
  public let sync: MatchSyncService
  public let model: RecordingModel
}

public enum AppBootstrap {
  @MainActor public static func composition(databaseNamespace: String = SQLiteSessionRepository.productionNamespace, development: Bool = false, workout: any WorkoutGateway = UnavailableWorkoutGateway(), transport: any SyncTransport = UnavailableSyncTransport(), trust: any PeerTrustProvider = UnavailablePeerTrustProvider(), rootDirectory: URL? = nil) throws -> AppComposition {
    guard development ? databaseNamespace != SQLiteSessionRepository.productionNamespace : databaseNamespace == SQLiteSessionRepository.productionNamespace else { throw SessionError.invalidRequest }
    #if !DEBUG
    guard !development else { throw SessionError.invalidRequest }
    #endif
    return try build(namespace: databaseNamespace, development: development, workout: workout, transport: transport, trust: trust, rootDirectory: rootDirectory)
  }
  @MainActor public static func production(workout: any WorkoutGateway = UnavailableWorkoutGateway()) throws -> RecordingModel {
    try make(namespace: SQLiteSessionRepository.productionNamespace, development: false, workout: workout)
  }
  @MainActor static func make(namespace: String, development: Bool, failFirstScore: Bool = false, fixedClock: Bool = false, workout: any WorkoutGateway = UnavailableWorkoutGateway(), rootDirectory: URL? = nil) throws -> RecordingModel {
    try build(namespace: namespace, development: development, failFirstScore: failFirstScore, fixedClock: fixedClock, workout: workout, rootDirectory: rootDirectory).model
  }
  @MainActor private static func build(namespace: String, development: Bool, failFirstScore: Bool = false, fixedClock: Bool = false, workout: any WorkoutGateway = UnavailableWorkoutGateway(), transport: any SyncTransport = UnavailableSyncTransport(), trust: any PeerTrustProvider = UnavailablePeerTrustProvider(), rootDirectory: URL? = nil) throws -> AppComposition {
    let support = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record", isDirectory: true)
    let repository = try SQLiteSessionRepository(rootDirectory: support, databaseNamespace: namespace)
    let identity = PersistentDeviceIdentityProvider(url: support.appendingPathComponent(namespace).appendingPathComponent("device.identity"), repository: repository)
    var store: any SessionRepository = repository
    var permits: any StartPermitProvider = UnavailableStartPermitProvider()
    var environment: SessionEnvironment = .production
    #if DEBUG
    if development {
      permits = DevelopmentStartPermitProvider()
      environment = .development(databaseNamespace: namespace)
      if failFirstScore { store = DebugFailureRepository(repository) }
    }
    #endif
    var clock: any SessionClock = SystemSessionClock()
    #if DEBUG
    if development && fixedClock { clock = DebugFrozenClock(value: Date()) }
    #endif
    let session = MatchSession(store: store, deviceIdentity: identity, clock: clock, ids: UUIDSessionIDFactory(), permits: permits, workout: workout, environment: environment)
    // A caller-supplied transport does not establish production trust.
    let effectiveTrust: any PeerTrustProvider = development ? trust : UnavailablePeerTrustProvider()
    let sync = MatchSyncService(repository: store, inbound: session, transport: transport, trust: effectiveTrust)
    let model = RecordingModel(session: session, repository: store, development: development, sync: sync)
    return AppComposition(repository: repository, session: session, sync: sync, model: model)
  }
  #if DEBUG
  @MainActor public static func development(dataset: String, failFirstScore: Bool = false, fixedClock: Bool = false, workout: any WorkoutGateway = UnavailableWorkoutGateway()) throws -> RecordingModel {
    let canonical = String(dataset.lowercased().utf8.filter { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }.map { Character(UnicodeScalar($0)) }.prefix(80))
    guard !canonical.isEmpty else { throw SessionError.invalidRequest }
    return try make(namespace: "ui-simulation-" + canonical, development: true, failFirstScore: failFirstScore, fixedClock: fixedClock, workout: workout)
  }
  #endif
}

#if DEBUG
/// Explicit UI-test failure injection, reachable only through the separate Debug dataset factory.
private struct DebugFrozenClock: SessionClock { let value: Date; func now() -> Date { value } }
private actor DebugFailureRepository: SessionRepository {
  let repository: SQLiteSessionRepository
  var failed = false
  init(_ repository: SQLiteSessionRepository) { self.repository = repository }
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await repository.syncRepositoryIdentity() }
  func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await repository.unroutedBusinessOutboxV3(matchID: matchID) }
  func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await repository.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
  func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await repository.pendingPacketsV2(matchID: matchID) }
  func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await repository.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
  func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await repository.acknowledgeV2(bytes, peer: peer, now: now) }
  func syncStateV3(matchID: String) async throws -> SyncState { try await repository.syncStateV3(matchID: matchID) }
  func ensureSyncDeliveriesV3(matchID: String) async throws { try await repository.ensureSyncDeliveriesV3(matchID: matchID) }
  func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await repository.dueSyncDeliveriesV3(now: now, limit: limit) }
  func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await repository.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
  func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await repository.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
  func reactivateSyncACKsV3() async throws { try await repository.reactivateSyncACKsV3() }
  func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await repository.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
  func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await repository.pendingSyncAssembliesV3(peer: peer, now: now) }
  func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await repository.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
  func expireSyncAssembliesV3(now: Date) async throws { try await repository.expireSyncAssembliesV3(now: now) }
  func databaseNamespace() async -> String { await repository.databaseNamespace() }
  func matchIDs() async throws -> [String] { try await repository.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await repository.snapshotV2(matchID: matchID) }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await repository.committedCommandV2(commandID: commandID) }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await repository.pendingCaptureOperations(matchID: matchID) }
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    if !failed, request.events.contains(where: { $0.type == .scoreEvent }) { failed = true; throw StoreError.injectedFailure }
    return try await repository.commitV2(request)
  }
}
#endif

/// The account gate and recording model retain the exact same facade and Session.
@MainActor public final class AccountAppContext {
  public let repository: SQLiteSessionRepository
  public let session: MatchSession
  public let recording: RecordingModel
  public let account: AccountStatusModel
  public let lifecycle: LifecycleStatusModel
  private let closeResources: @MainActor () async -> Void
  private var closed = false
  init(repository: SQLiteSessionRepository, session: MatchSession, recording: RecordingModel, account: AccountStatusModel, lifecycle: LifecycleStatusModel, close: @escaping @MainActor () async -> Void) {
    self.repository = repository; self.session = session; self.recording = recording; self.account = account; self.lifecycle = lifecycle; closeResources = close
  }
  public func refresh() async {
    guard !closed else { return }
    await account.refresh()
    if account.canEnterRecording { await recording.load() }
    await lifecycle.refresh(matchID: recording.snapshot?.replay.matchID)
  }
  public func shutdown() async {
    guard !closed else { return }; closed = true
    account.stop(); lifecycle.stop(); await recording.shutdown(); await closeResources()
  }
}
public extension AppBootstrap {
  @MainActor static func accountContext(rootDirectory: URL? = nil) throws -> AccountAppContext {
    let c = try composition(rootDirectory: rootDirectory)
    return AccountAppContext(repository: c.repository, session: c.session, recording: c.model, account: AccountStatusModel(repository: c.repository), lifecycle: LifecycleStatusModel(repository: c.repository), close: { try? await c.repository.close() })
  }
}
