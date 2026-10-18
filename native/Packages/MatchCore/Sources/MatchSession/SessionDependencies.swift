import Foundation
import MatchCore
import MatchStore

public protocol SessionRepository: SyncRepository {
  func matchIDs() async throws -> [String]
  func databaseNamespace() async -> String
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2?
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord]
}
public protocol DeviceIdentityProvider: Sendable { func localDeviceID() async throws -> String }
public protocol SessionClock: Sendable { func now() -> Date }
public protocol SessionIDFactory: Sendable { func nextID() -> String }
public protocol StartPermitProvider: Sendable {
  func acquire(for intent: StartIntent) async throws -> TrustedStartPermit
}
public protocol WorkoutGateway: Sendable {
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation
}
public struct SystemSessionClock: SessionClock {
  public init() {}
  public func now() -> Date { Date() }
}
public struct UUIDSessionIDFactory: SessionIDFactory {
  public init() {}
  public func nextID() -> String { UUID().uuidString }
}
public struct UnavailableStartPermitProvider: StartPermitProvider {
  public init() {}
  public func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    throw SessionError.permitUnavailable
  }
}
/// Must only be injected into a separate development database. MatchSession verifies that boundary.
public struct DevelopmentStartPermitProvider: StartPermitProvider {
  public init() {}
  public func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    DevelopmentStartFixture.permit(for: intent)
  }
}
public struct UnavailableWorkoutGateway: WorkoutGateway {
  public init() {}
  private func observation(_ operation: CaptureOperation) -> WorkoutObservation {
    try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: Date(),
      outcome: operation.action == .start ? .notCreated(.unavailable) : .unknown,
      window: CaptureWindow(start: nil, end: nil), failure: .unavailable)
  }
  public func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    observation(operation)
  }
  public func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    // An unavailable adapter cannot prove that an earlier cross-system action did not create a Workout.
    try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: Date(), outcome: .unknown, window: CaptureWindow(start: nil, end: nil),
      failure: .unavailable)
  }
}
/// Namespace selects the actual database path; callers cannot relabel an already-open production store.
public actor SQLiteSessionRepository: SessionRepository {
  public static let productionNamespace = "production"
  let store: MatchStore
  private let syncIdentity: SyncRepositoryIdentity
  private let namespace: String
  public let databaseURL: URL
  static func isCanonicalNamespace(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { byte in
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
      }
  }
  public init(rootDirectory: URL, databaseNamespace: String, authorityTrust: AuthorityTrustConfiguration? = nil) throws {
    // APFS may fold case and Unicode. Only canonical ASCII names reach the path factory.
    guard Self.isCanonicalNamespace(databaseNamespace) else { throw SessionError.invalidRequest }
    namespace = databaseNamespace
    syncIdentity = try SyncRepositoryIdentity(instanceID: UUID().uuidString, databaseNamespace: databaseNamespace)
    let directory = rootDirectory.appendingPathComponent(databaseNamespace, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appendingPathComponent("matches.sqlite")
    store = try MatchStore(url: databaseURL, syncEnvironment: databaseNamespace == Self.productionNamespace ? .production : .development(databaseNamespace: databaseNamespace), authorityTrust: authorityTrust)
  }
  public func databaseNamespace() async -> String { namespace }
  public func matchIDs() async throws -> [String] { try await store.matchIDs() }
  public func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 {
    try await store.snapshotV2(matchID: matchID)
  }
  public func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? {
    try await store.committedCommandV2(commandID: commandID)
  }
  public func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    try await store.commitV2(request)
  }
  public func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] {
    try await store.pendingCaptureOperations(matchID: matchID)
  }
  public func syncRepositoryIdentity() async -> SyncRepositoryIdentity { syncIdentity }
  public func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await store.unroutedBusinessOutboxV3(matchID: matchID) }
  public func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await store.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
  public func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await store.pendingPacketsV2(matchID: matchID) }
  public func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await store.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
  public func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await store.acknowledgeV2(bytes, peer: peer, now: now) }
  public func syncStateV3(matchID: String) async throws -> SyncState { try await store.syncStateV3(matchID: matchID) }
  public func ensureSyncDeliveriesV3(matchID: String) async throws { try await store.ensureSyncDeliveriesV3(matchID: matchID) }
  public func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await store.dueSyncDeliveriesV3(now: now, limit: limit) }
  public func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await store.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
  public func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await store.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
  public func reactivateSyncACKsV3() async throws { try await store.reactivateSyncACKsV3() }
  public func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await store.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
  public func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await store.pendingSyncAssembliesV3(peer: peer, now: now) }
  public func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await store.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
  public func expireSyncAssembliesV3(now: Date) async throws { try await store.expireSyncAssembliesV3(now: now) }
  public func close() async throws { try await store.close() }
}
/// One durable installation identity. Missing/corrupt identity with existing matches fails closed.
public actor PersistentDeviceIdentityProvider: DeviceIdentityProvider {
  private let url: URL
  private let repository: any SessionRepository
  private var load: Task<String, Error>?
  public init(url: URL, repository: any SessionRepository) {
    self.url = url
    self.repository = repository
  }
  public func localDeviceID() async throws -> String {
    if let load { return try await load.value }
    let url = url
    let repository = repository
    let task = Task<String, Error> {
      func read() throws -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
          raw.hasPrefix("football-record.identity.v1:"),
          let uuid = UUID(uuidString: String(raw.dropFirst("football-record.identity.v1:".count)))
        else { throw SessionError.identityUnavailable }
        return uuid.uuidString
      }
      if FileManager.default.fileExists(atPath: url.path) { return try read() }
      guard try await repository.matchIDs().isEmpty else { throw SessionError.identityUnavailable }
      let value = UUID().uuidString
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("football-record.identity.v1:" + value).utf8).write(
          to: url, options: .withoutOverwriting)
      } catch {
        if FileManager.default.fileExists(atPath: url.path) { return try read() }
        throw SessionError.identityUnavailable
      }
      return value
    }
    load = task
    return try await task.value
  }
}


extension SQLiteSessionRepository: AuthorityRepository {
  public func bindAccountV4(_ binding: AccountBindingV4) async throws { try await store.bindAccountV4(binding) }
  public func accountBindingV4() async throws -> AccountBindingV4? { try await store.accountBindingV4() }
  public func suspendAccountV4() async throws { try await store.suspendAccountV4() }
  public func prepareControlV4(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4 { try await store.prepareControlV4(intent) }
  public func pendingControlsV4() async throws -> [ControlIntentV1] { try await store.pendingControlsV4() }
  public func recordAuthorityResultV4(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4 { try await store.recordAuthorityResultV4(receipt) }
  public func recordLiveLockV4(_ proof: VerifiedLiveLockV1, now: Date) async throws { try await store.recordLiveLockV4(proof,now:now) }
  public func authorityStateV4(matchID: String, now: Date) async throws -> AuthorityStateV4 { try await store.authorityStateV4(matchID:matchID,now:now) }
  public func validateAuthorityStartV4(_ intent: StartIntent, now: Date) async throws { try await store.validateAuthorityStartV4(intent,now:now) }
}
