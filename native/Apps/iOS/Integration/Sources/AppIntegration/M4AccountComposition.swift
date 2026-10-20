import Foundation
import AccountKit
import MatchStore
import MatchSession
import MatchSync
import MatchPresentation
import CloudSync

/// A fresh value supplied by the current Apple/backend and cloud identity boundary.
/// This is not a credential or persisted proof. Production has no enabled provider;
/// controlled hosts inject protocol observations without constructing SDK factories.
struct M4CurrentAccountIdentity: Sendable {
  let accountID, cloudSpaceID, zoneID: String
  let environment: AuthorityEnvironment
}
protocol M4CurrentIdentityObserving: Sendable {
  func currentIdentity() async throws -> M4CurrentAccountIdentity
  func advanceIdentityFence(to generation: Int64) async throws
}
struct M4UnavailableCurrentIdentity: M4CurrentIdentityObserving {
  func currentIdentity() async throws -> M4CurrentAccountIdentity { throw AuthorityError.unavailable }
  func advanceIdentityFence(to generation: Int64) async throws { throw AuthorityError.unavailable }
}
private struct M4UnavailableAuthorityRelay: AuthorityHTTPRelay {
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse { throw AuthorityError.unavailable }
}
private struct M4UnavailableAppleAuthorization: AppleSignInDriver {
  func authorize(nonceSHA256: String) async throws -> AppleAuthorization { throw AuthorityError.unavailable }
}

/// One original identity lease, one business facade, and the original Session.
/// Account admission is explicit and independent of opening a retained credential.
/// App entry and lifecycle/erasure routing are integrated in later 026 slices.
@MainActor final class M4AccountComposition {
  let repository: SQLiteSessionRepository
  let session: MatchSession
  let context: AccountAppContext
  let client: AuthorityClient
  let accountService: AccountService
  let phoneRegistration: PhoneWatchRegistrationService
  let watchRegistration: WatchRegistrationService
  let cloudBridge: CloudSessionBridge
  let sync: MatchSyncService
  private let prepared: M4PreparedIdentity
  private let identity: any M4CurrentIdentityObserving
  private let cloudSpaceID: String
  private let watchRelay: M4WatchRegistrationRelay
  private var lifetime = UUID()
  private var closed = false
  private var finalClosing: Task<Void, any Error>?
  private let closeBridge: M4CompositionCloseBridge
  private var controlOwners: [ObjectIdentifier: M4WeakControlOwner] = [:]
  private(set) var lastCloseFailure: (any Error)?
  var namespace: String { prepared.seed.namespace }
  var localDeviceID: String { prepared.seed.installationID }
  private var businessStopped = false
  private var quiesced = false
  private var quiescing: Task<Void, any Error>?
  private var identityTasks: [UUID: Task<Void, any Error>] = [:]
  private(set) var admittedScope: CloudScope?
  private init(prepared: M4PreparedIdentity, repository: SQLiteSessionRepository, session: MatchSession, context: AccountAppContext, client: AuthorityClient, accountService: AccountService, phoneRegistration: PhoneWatchRegistrationService, watchRegistration: WatchRegistrationService, cloudBridge: CloudSessionBridge, sync: MatchSyncService, identity: any M4CurrentIdentityObserving, cloudSpaceID: String, watchRelay: M4WatchRegistrationRelay, closeBridge: M4CompositionCloseBridge) {
    self.prepared = prepared; self.repository = repository; self.session = session; self.context = context; self.client = client
    self.accountService = accountService; self.phoneRegistration = phoneRegistration; self.watchRegistration = watchRegistration; self.cloudBridge = cloudBridge; self.sync = sync; self.identity = identity; self.cloudSpaceID = cloudSpaceID; self.watchRelay = watchRelay; self.closeBridge = closeBridge
  }
  static func make(prepared: M4PreparedIdentity, trust: AuthorityTrustConfiguration, cloudSpaceID: String, identity: any M4CurrentIdentityObserving = M4UnavailableCurrentIdentity(), authorityRelay: (any AuthorityHTTPRelay)? = nil, workout: (any WorkoutGateway)? = nil) async throws -> M4AccountComposition {
    try AuthorityWire.identifier(cloudSpaceID)
    let development = trust.environment == .development
    guard development ? prepared.seed.namespace != SQLiteSessionRepository.productionNamespace : prepared.seed.namespace == SQLiteSessionRepository.productionNamespace else { throw AuthorityError.identityChanged }
    #if !DEBUG
    guard !development else { throw AuthorityError.identityChanged }
    #endif
    if authorityRelay != nil || workout != nil {
      #if DEBUG
      guard development else { throw AuthorityError.identityChanged }
      #else
      throw AuthorityError.identityChanged
      #endif
    }
    let policy: CloudSaveProofPolicy = development ? .development(databaseNamespace: prepared.seed.namespace) : .unavailable
    let repository = try prepared.openRepository(authorityTrust: trust, cloudSavePolicy: policy)
    do {
      let device = PersistentDeviceIdentityProvider(url: prepared.seed.namespaceDirectory.appendingPathComponent("device.identity"), repository: repository)
      guard try await device.localDeviceID() == prepared.seed.installationID else { throw AuthorityError.identityChanged }
      let client = AuthorityClient(relay: authorityRelay ?? M4UnavailableAuthorityRelay(), vault: prepared.material.vault, signer: prepared.material.signer, trust: trust)
      let permits = AuthorityStartPermitProvider(client: client, repository: repository)
      let session = MatchSession(store: repository, deviceIdentity: device, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: permits, workout: workout ?? UnavailableWorkoutGateway(), environment: development ? .development(databaseNamespace: prepared.seed.namespace) : .production)
      try await permits.attach(session)
      let sync = MatchSyncService(repository: repository, inbound: session)
      let recording = RecordingModel(session: session, repository: repository, development: development, sync: sync)
      let accountService = AccountService(client: client, repository: repository, coordinator: session, deviceID: prepared.seed.installationID, cloudSpaceID: cloudSpaceID, apple: M4UnavailableAppleAuthorization())
      let phone = PhoneWatchRegistrationService(client: client, repository: repository, coordinator: session)
      let watchRelay = M4WatchRegistrationRelay()
      let watch = WatchRegistrationService(client: client, repository: repository, coordinator: session, deviceID: prepared.seed.installationID, cloudSpaceID: cloudSpaceID, authorizer: watchRelay)
      let bridge = CloudSessionBridge(repository: repository, client: client, policy: policy); try await bridge.attach(session)
      let account = AccountStatusModel(repository: repository, development: development, action: { _ in throw AuthorityError.unavailable })
      let lifecycle = LifecycleStatusModel(repository: repository, development: development, action: { _ in throw AuthorityError.unavailable })
      let closeBridge = M4CompositionCloseBridge()
      let context = try await AppBootstrap.accountContext(repository: repository, session: session, recording: recording, account: account, lifecycle: lifecycle, close: { await closeBridge.closeFromContext() })
      let value = M4AccountComposition(prepared: prepared, repository: repository, session: session, context: context, client: client, accountService: accountService, phoneRegistration: phone, watchRegistration: watch, cloudBridge: bridge, sync: sync, identity: identity, cloudSpaceID: cloudSpaceID, watchRelay: watchRelay, closeBridge: closeBridge)
      // The public context retains its resource owner until successful final close.
      // Breaking this link only after success also retains failed-close retry state.
      closeBridge.owner = value
      return value
    } catch { try? await prepared.close(); throw error }
  }
  /// The provider must observe the current dual identity again. A retained vault
  /// credential by itself never calls this method or admits the presentation.
  func admitCurrentIdentity() async throws {
    guard !closed, !businessStopped else { throw AuthorityError.identityChanged }
    let id = UUID(), task = Task { try await self.observeAndAdmitIdentity() }
    identityTasks[id] = task
    defer { identityTasks[id] = nil }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
  private func observeAndAdmitIdentity() async throws {
    guard !closed, !businessStopped else { throw AuthorityError.identityChanged }
    let token = UUID(); lifetime = token; admittedScope = nil; context.account.pauseIdentity()
    do {
      let generation = try await repository.identityGenerationV4()
      guard let binding = try await repository.accountBindingV4(), !binding.suspended else { throw AuthorityError.identityChanged }
      try await identity.advanceIdentityFence(to: generation)
      let observed = try await identity.currentIdentity()
      try await unchanged(binding, generation: generation, token: token)
      for value in [observed.accountID, observed.cloudSpaceID, observed.zoneID] { try AuthorityWire.identifier(value) }
      guard raw(observed.accountID, binding.accountID), raw(observed.cloudSpaceID, binding.cloudSpaceID), raw(observed.cloudSpaceID, cloudSpaceID),
            raw(binding.deviceID, prepared.seed.installationID), observed.environment == binding.environment, observed.environment == client.trust.environment else { throw AuthorityError.identityChanged }
      let credential = try await prepared.material.vault.credential()
      guard raw(credential.accountID, binding.accountID), raw(credential.deviceID, binding.deviceID), credential.activationEpoch == binding.activationEpoch,
            raw(credential.keyID, try AuthorityWire.deviceKeyID(publicKey: prepared.material.signer.publicKey)), Double(credential.expiresAt) > Date().timeIntervalSince1970 else { throw AuthorityError.identityChanged }
      if binding.role == .watch {
        let context = try await watchRelay.registrationContext()
        guard raw(context.accountID, observed.accountID), raw(context.cloudSpaceID, observed.cloudSpaceID), context.activationEpoch == binding.activationEpoch, context.environment == observed.environment else { throw AuthorityError.identityChanged }
        try await watchRegistration.admitCurrentIdentity(context: context)
      } else {
        try await accountService.admitCurrentIdentity(accountID: observed.accountID)
        if binding.role == .phone { try await phoneRegistration.admitCurrentIdentity(accountID: observed.accountID) }
      }
      try await unchanged(binding, generation: generation, token: token)
      let scope = try CloudScope(accountID: observed.accountID, cloudSpaceID: observed.cloudSpaceID, zoneID: observed.zoneID, activationEpoch: binding.activationEpoch)
      try await context.lifecycle.projectCloudScope(scope, expectedIdentityGeneration: generation)
      try await unchanged(binding, generation: generation, token: token)
      try await context.account.admitIdentity(binding, expectedIdentityGeneration: generation)
      try await unchanged(binding, generation: generation, token: token)
      admittedScope = scope
    } catch {
      if lifetime == token { admittedScope = nil; context.account.pauseIdentity() }
      throw error
    }
  }
  /// The owner closes business entry synchronously, then joins the original
  /// Session's real capture observations before clearing borrowed UI references.
  /// A failed durable drain throws and retains the original facade for retry.
  static func retireBusiness(session: MatchSession, recording: RecordingModel) async throws {
    recording.beginRetirement()
    try await session.retireBusiness()
    await recording.shutdown()
  }
  func quiesceBusiness() async throws {
    guard !closed else { throw AuthorityError.identityChanged }
    if quiesced { return }
    if let quiescing { return try await quiescing.value }
    businessStopped = true; lifetime = UUID(); admittedScope = nil
    context.account.pauseIdentity(); context.recording.beginRetirement()
    let session = session, recording = context.recording, observations = Array(identityTasks.values)
    observations.forEach { $0.cancel() }
    let task = Task {
      // Establish the original Session's permanent business gate before any
      // cancellation-insensitive identity observer can delay this drain.
      let retirement: Result<Void, any Error>
      do { try await Self.retireBusiness(session: session, recording: recording); retirement = .success(()) }
      catch { retirement = .failure(error) }
      // A failed durable retirement still joins every cancelled identity task;
      // preserve the original failure and facade for the owner's SQL-only retry.
      for observation in observations { _ = await observation.result }
      try retirement.get()
    }
    quiescing = task
    do { try await task.value; quiesced = true; quiescing = nil }
    catch { quiescing = nil; throw error }
  }
  func registerControlOwner(_ owner: M4DeletionResumeController) -> Bool {
    guard !closed, finalClosing == nil else { return false }
    controlOwners = controlOwners.filter { $0.value.value != nil }
    controlOwners[ObjectIdentifier(owner)] = M4WeakControlOwner(owner)
    return true
  }
  /// The one throwing final-close boundary. It never invokes context.shutdown:
  /// that public Void callback may already be awaiting this same close task.
  func close() async throws {
    guard !closed else { return }
    if let finalClosing { return try await finalClosing.value }
    businessStopped = true; lifetime = UUID(); admittedScope = nil
    context.account.stop(); context.lifecycle.stop(); context.recording.beginRetirement()
    let owners = controlOwners.values.compactMap(\.value)
    let task = Task {
      try await self.quiesceBusiness()
      for owner in owners { await owner.stopAndJoin() }
      await self.watchRelay.close()
      // close() verifies the original lease and throws before releasing that
      // lease or closing its DB when original identity provenance has changed.
      try await self.prepared.close()
    }
    finalClosing = task
    do {
      try await task.value
      closed = true; lastCloseFailure = nil; finalClosing = nil
      context.account.stop(); context.lifecycle.stop(); controlOwners.removeAll()
      closeBridge.owner = nil
    } catch {
      lastCloseFailure = error; finalClosing = nil
      context.account.stop(); context.lifecycle.stop()
      throw error
    }
  }
  fileprivate func closeFromContext() async {
    do { try await close() }
    catch { lastCloseFailure = error }
  }

  /// A stable component receipt is derived only from this original facade's
  /// fresh045 SQL snapshot. Mutable Saga progress/revision is never frozen into it.
  func localStoreEvidence(capsule: M4OwnershipCapsule, parentID: String, parentIntentDigest: String, scope: CloudScope) async throws -> M4StoreCompletionEvidence {
    try validateOriginalStoreCapsule(capsule, scope: scope)
    try await quiesceBusiness()
    try capsule.verifyCurrent()
    guard await session.syncRepositoryIdentity() == repository.syncRepositoryIdentity() else { throw AuthorityError.identityChanged }
    let rawScope = try CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)
    let witness = try await repository.validateLocalBusinessErasedV4(requestID: parentID, requestDigest: parentIntentDigest, scope: rawScope)
    guard M4CatalogIO.raw(witness.requestID, parentID), witness.requestDigest == parentIntentDigest, witness.originalScope == rawScope else { throw M4LocalErasureError.intentMismatch }
    try capsule.verifyCurrent()
    return M4StoreCompletionEvidence(requestID: parentID, parentIntentDigest: parentIntentDigest, backendReceiptDigest: witness.backendReceiptDigest,
      scope: scope, database: capsule.root, localProgress: .completed)
  }
  func validateOriginalStoreCapsule(_ capsule: M4OwnershipCapsule, scope: CloudScope) throws {
    guard capsule.kind == .businessStore, !capsule.root.directory, capsule.scope == scope,
          try M4CatalogIO.encode(capsule.root) == M4CatalogIO.encode(M4CatalogIO.anchor(prepared.seed.businessDatabaseURL)) else { throw M4CatalogError.identityChanged }
    try capsule.verifyCurrent()
  }
  private func unchanged(_ binding: AccountBindingV4, generation: Int64, token: UUID) async throws {
    guard !closed, !businessStopped, lifetime == token, try await repository.identityGenerationV4() == generation,
          let current = try await repository.accountBindingV4(), try AuthorityWire.encode(current) == AuthorityWire.encode(binding), !closed, lifetime == token,
          try await repository.identityGenerationV4() == generation,
          !closed, !businessStopped, lifetime == token else { throw AuthorityError.identityChanged }
  }
  private func raw(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
}

@MainActor private final class M4CompositionCloseBridge {
  var owner: M4AccountComposition?
  func closeFromContext() async { await owner?.closeFromContext() }
}
@MainActor private final class M4WeakControlOwner {
  weak var value: M4DeletionResumeController?
  init(_ value: M4DeletionResumeController) { self.value = value }
}
