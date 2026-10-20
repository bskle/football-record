import Foundation
import AccountKit
import CloudSync
import MatchStore
import MatchSession
import MatchPresentation

/// Explicit local protocol fixtures only. Configuration/credential retention is
/// never a fresh Apple/cloud identity observation or recording admission.
actor M4ControlledAdapters: AppleSignInDriver, AuthorityHTTPRelay, CloudDriver, M4WatchRegistrationChannel, M4LocalCopyDrainChecking {
  nonisolated let namespace: String
  private let trust: AuthorityTrustConfiguration
  private let cloudSpaceID: String
  #if DEBUG
  private let clients: DevelopmentAuthorityProtocolClients
  private let generationReplyGate: (@Sendable () async -> Void)?
  private init(configuration: DevelopmentAuthorityConfiguration, clients: DevelopmentAuthorityProtocolClients, generationReplyGate: (@Sendable () async -> Void)?) throws {
    namespace = configuration.namespace; cloudSpaceID = configuration.cloudSpaceID
    trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: [configuration.keyID: configuration.publicKey])
    self.clients = clients; self.generationReplyGate = generationReplyGate
  }
  static func make(configuration: DevelopmentAuthorityConfiguration, rootDirectory: URL, generationReplyGate: (@Sendable () async -> Void)? = nil) throws -> M4ControlledAdapters {
    let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration, rootDirectory: rootDirectory)
    return try M4ControlledAdapters(configuration: configuration, clients: clients, generationReplyGate: generationReplyGate)
  }
  #else
  private init(namespace: String, trust: AuthorityTrustConfiguration, cloudSpaceID: String) {
    self.namespace = namespace; self.trust = trust; self.cloudSpaceID = cloudSpaceID
  }
  #endif
  private var claimed = false
  private var repository: SQLiteSessionRepository?
  private var originalIdentity: SyncRepositoryIdentity?
  private var businessStopped = false
  private var businessLifetime = UUID()
  var businessAdmissionClosed: Bool { businessStopped }
  private var finalStopped = false
  private struct Pending: Sendable {
    let cancel: @Sendable () -> Void
    let join: Task<Void, Never>
  }
  private var business: [UUID: Pending] = [:]
  private var exchanges: [UUID: Task<M4WatchRegistrationResponse, any Error>] = [:]
  private var quiescing: Task<Void, Never>?
  private var finalClosing: Task<Void, any Error>?
  private var businessDrainers: [CheckedContinuation<Void, Never>] = []
  /// Claim once before any business DB is opened, never attach to a second facade.
  func claim(namespace: String, trust: AuthorityTrustConfiguration, cloudSpaceID: String) throws {
    guard !claimed, !finalStopped, trust.environment == .development, self.trust == trust,
          M4CatalogIO.raw(namespace, self.namespace), M4CatalogIO.raw(cloudSpaceID, self.cloudSpaceID),
          namespace != SQLiteSessionRepository.productionNamespace else { throw AuthorityError.identityChanged }
    claimed = true
  }
  func attach(_ repository: SQLiteSessionRepository) async throws {
    guard claimed, !finalStopped, self.repository == nil,
          M4CatalogIO.raw(await repository.databaseNamespace(), namespace) else { throw AuthorityError.identityChanged }
    self.repository = repository; originalIdentity = await repository.syncRepositoryIdentity()
  }
  private func original() async throws -> SQLiteSessionRepository {
    guard claimed, !finalStopped, let repository, let originalIdentity,
          await repository.syncRepositoryIdentity() == originalIdentity,
          M4CatalogIO.raw(await repository.databaseNamespace(), namespace) else { throw AuthorityError.identityChanged }
    return repository
  }
  private func ownedBusiness<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    guard !businessStopped, !finalStopped else { throw AuthorityError.identityChanged }
    let lifetime = businessLifetime
    let repository = try await original(), generation = try await originalGenerationReply(repository)
    guard !businessStopped, !finalStopped, businessLifetime == lifetime else { throw AuthorityError.identityChanged }
    try Task.checkCancellation()
    let id = UUID(), task = Task { try await work() }
    business[id] = Pending(cancel: { task.cancel() }, join: Task { _ = await task.result })
    defer { business[id] = nil; notifyBusinessDrainers() }
    let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    let currentGeneration = try await originalGenerationReply(repository)
    guard !businessStopped, !finalStopped, businessLifetime == lifetime, currentGeneration == generation else { throw AuthorityError.identityChanged }
    try Task.checkCancellation(); return value
  }
  private func originalGenerationReply(_ repository: SQLiteSessionRepository) async throws -> Int64 {
    let original = try await repository.identityGenerationV4()
    #if DEBUG
    await generationReplyGate?()
    #endif
    return original
  }
  func startPhoneInbox(authorizer: any WatchRegistrationAuthorizing) async throws {
    guard !businessStopped, !finalStopped else { throw AuthorityError.identityChanged }
    _ = try await original()
    #if DEBUG
    try await clients.startInbox(authorizer: authorizer)
    guard !businessStopped, !finalStopped else { await clients.stopInbox(); throw AuthorityError.identityChanged }
    #else
    throw AuthorityError.unavailable
    #endif
  }
  func authorize(nonceSHA256: String) async throws -> AppleAuthorization {
    #if DEBUG
    let clients = clients; return try await ownedBusiness { try await clients.authorize(nonceSHA256: nonceSHA256) }
    #else
    throw AuthorityError.unavailable
    #endif
  }
  /// The original HTTP client remains open throughout Saga control/recovery.
  /// Its owning UI/control operations are separately gated and joined by026.
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    _ = try await original()
    #if DEBUG
    return try await clients.send(request)
    #else
    throw AuthorityError.unavailable
    #endif
  }
  func fetch(scope: CloudScope, cursor: CloudCursor) async throws -> CloudFetchBatch {
    #if DEBUG
    let clients = clients; return try await ownedBusiness { try await clients.fetch(scope: scope, cursor: cursor) }
    #else
    throw CloudError(.accountUnavailable)
    #endif
  }
  func save(_ upload: CloudUpload) async throws -> CloudSaveResult {
    #if DEBUG
    let clients = clients; return try await ownedBusiness { try await clients.save(upload) }
    #else
    throw CloudError(.accountUnavailable)
    #endif
  }
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    guard !businessStopped, !finalStopped, exchanges[request.correlationID] == nil else { throw M4WatchRegistrationRelayError.closed }
    #if DEBUG
    let clients = clients, id = request.correlationID
    let task = Task { try await self.ownedBusiness {
      switch request {
      case .context(let id): return M4WatchRegistrationResponse.context(id, try await clients.registrationContext())
      case let .authorize(id, attempt, action):
        let bytes = try await clients.authorizeRegistration(attempt, action: action)
        return M4WatchRegistrationResponse.authorized(id, attempt.requestID, attempt.requestDigest, action, bytes)
      }
    } }
    exchanges[id] = task; defer { exchanges[id] = nil; notifyBusinessDrainers() }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    #else
    throw M4WatchRegistrationRelayError.unavailable
    #endif
  }
  func cancel(_ correlationID: UUID) async {
    guard let task = exchanges[correlationID] else { return }; task.cancel(); _ = await task.result
  }
  /// Channel close is business-only. It must not close the original Saga HTTP.
  func close() async { await quiesceBusiness() }
  func quiesceBusiness() async {
    if let quiescing { await quiescing.value; return }
    businessStopped = true; businessLifetime = UUID()
    let pending = Array(business.values), rpc = Array(exchanges.values)
    pending.forEach { $0.cancel() }; rpc.forEach { $0.cancel() }
    let task = Task {
      #if DEBUG
      // Business retirement joins the original typed Phone inbox without closing
      // the same original HTTP/Cloud clients needed by retained Saga controls.
      await self.clients.stopInbox()
      #endif
      for call in pending { await call.join.value }; for call in rpc { _ = await call.result }
      await self.waitForBusinessReturns()
    }
    quiescing = task; await task.value
  }
  private func waitForBusinessReturns() async {
    guard !business.isEmpty || !exchanges.isEmpty else { return }
    await withCheckedContinuation { businessDrainers.append($0) }
  }
  private func notifyBusinessDrainers() {
    guard business.isEmpty, exchanges.isEmpty else { return }
    let waiting = businessDrainers; businessDrainers.removeAll(); waiting.forEach { $0.resume() }
  }
  private func originalParent(scope: CloudScope, requestID: String, digest: String) async throws -> DeletionSagaV4 {
    let repository = try await original()
    guard let saga = try await repository.deletionSagaV4(requestID: requestID), M4CatalogIO.raw(saga.intent.requestID, requestID),
          saga.intent.digest == digest, saga.originalScope == (try CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)) else { throw M4LocalErasureError.intentMismatch }
    return saga
  }
  func assertDrained(scope: CloudScope, requestID: String, parentIntentDigest: String) async throws {
    guard businessStopped, !finalStopped else { throw M4LocalErasureError.unavailable }
    _ = try await originalParent(scope: scope, requestID: requestID, digest: parentIntentDigest)
    #if DEBUG
    guard await clients.drainState() == .drained else { throw M4LocalErasureError.pendingTransfer }
    _ = try await originalParent(scope: scope, requestID: requestID, digest: parentIntentDigest)
    #else
    throw M4LocalErasureError.unavailable
    #endif
  }
  nonisolated func deletionDriver(parentID: String, parentIntentDigest: String, scope: CloudScope) -> any CloudAccountDeletionDriver {
    M4ControlledParentCloudDeletion(owner: self, parentID: parentID, digest: parentIntentDigest, scope: scope)
  }
  fileprivate func deleteOriginalParent(scope: CloudScope, parentID: String, digest: String) async throws {
    let saga = try await originalParent(scope: scope, requestID: parentID, digest: digest)
    guard saga.backendDeleted, saga.cloudChoice == .delete else { throw M4LocalErasureError.intentMismatch }
    #if DEBUG
    try await clients.deletePrivateZone(scope: scope)
    #else
    throw CloudError(.accountUnavailable)
    #endif
  }
  /// Only the composition's final close calls this after all original controls join.
  func finalClose() async throws {
    if let finalClosing { return try await finalClosing.value }
    finalStopped = true; businessLifetime = UUID()
    let task = Task<Void, any Error> {
      await self.quiesceBusiness()
      #if DEBUG
      guard await self.clients.close() == .drained else { throw M4LocalErasureError.pendingTransfer }
      #else
      throw M4LocalErasureError.unavailable
      #endif
    }
    finalClosing = task
    do { try await task.value } catch { finalClosing = nil; throw error }
  }
}
private struct M4ControlledParentCloudDeletion: CloudAccountDeletionDriver {
  let owner: M4ControlledAdapters
  let parentID, digest: String
  let scope: CloudScope
  func deletePrivateZone(scope: CloudScope) async throws {
    guard scope == self.scope else { throw M4LocalErasureError.intentMismatch }
    try await owner.deleteOriginalParent(scope: scope, parentID: parentID, digest: digest)
  }
}
