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
  private let controlledAdapters: M4ControlledAdapters?
  private var lifetime = UUID()
  private var closed = false
  private var finalClosing: Task<Void, any Error>?
  private let closeBridge: M4CompositionCloseBridge
  private var controlOwners: [ObjectIdentifier: M4WeakControlOwner] = [:]
  private var identityLifecycle: LifecycleService?
  private var identityChanging: Task<Void, any Error>?
  private(set) var lastCloseFailure: (any Error)?
  var namespace: String { prepared.seed.namespace }
  var localDeviceID: String { prepared.seed.installationID }
  private var businessStopped = false
  private var businessLifetime = UUID()
  private struct BusinessOperation: Sendable {
    let cancel: @Sendable () -> Void
    let join: Task<Void, Never>
  }
  private var businessOperations: [UUID: BusinessOperation] = [:]
  private var businessReturnWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var reauthenticationID: String?
  private var quiesced = false
  private var quiescing: Task<Void, any Error>?
  private var identityTasks: [UUID: Task<Void, any Error>] = [:]
  private(set) var admittedScope: CloudScope?
  private var scopeBusy = false
  private var managedPhoneResources: M4ManagedPhoneResources?
  private var managedWatchResources: M4ManagedWatchResources?
  private init(prepared: M4PreparedIdentity, repository: SQLiteSessionRepository, session: MatchSession, context: AccountAppContext, client: AuthorityClient, accountService: AccountService, phoneRegistration: PhoneWatchRegistrationService, watchRegistration: WatchRegistrationService, cloudBridge: CloudSessionBridge, sync: MatchSyncService, identity: any M4CurrentIdentityObserving, cloudSpaceID: String, watchRelay: M4WatchRegistrationRelay, closeBridge: M4CompositionCloseBridge, controlledAdapters: M4ControlledAdapters?) {
    self.prepared = prepared; self.repository = repository; self.session = session; self.context = context; self.client = client
    self.accountService = accountService; self.phoneRegistration = phoneRegistration; self.watchRegistration = watchRegistration; self.cloudBridge = cloudBridge; self.sync = sync; self.identity = identity; self.cloudSpaceID = cloudSpaceID; self.watchRelay = watchRelay; self.closeBridge = closeBridge; self.controlledAdapters = controlledAdapters
  }
  static func make(prepared: M4PreparedIdentity, trust: AuthorityTrustConfiguration, cloudSpaceID: String, identity: any M4CurrentIdentityObserving = M4UnavailableCurrentIdentity(), authorityRelay: (any AuthorityHTTPRelay)? = nil, workout: (any WorkoutGateway)? = nil, controlledAdapters: M4ControlledAdapters? = nil) async throws -> M4AccountComposition {
    try AuthorityWire.identifier(cloudSpaceID)
    let development = trust.environment == .development
    guard development ? prepared.seed.namespace != SQLiteSessionRepository.productionNamespace : prepared.seed.namespace == SQLiteSessionRepository.productionNamespace else { throw AuthorityError.identityChanged }
    #if !DEBUG
    guard !development else { throw AuthorityError.identityChanged }
    #endif
    if authorityRelay != nil || workout != nil || controlledAdapters != nil {
      #if DEBUG
      guard development else { throw AuthorityError.identityChanged }
      #else
      throw AuthorityError.identityChanged
      #endif
    }
    if let controlledAdapters { try await controlledAdapters.claim(namespace: prepared.seed.namespace, trust: trust, cloudSpaceID: cloudSpaceID) }
    let policy: CloudSaveProofPolicy = development ? .development(databaseNamespace: prepared.seed.namespace) : .unavailable
    let repository = try prepared.openRepository(authorityTrust: trust, cloudSavePolicy: policy)
    do {
      try await controlledAdapters?.attach(repository)
      let device = PersistentDeviceIdentityProvider(url: prepared.seed.namespaceDirectory.appendingPathComponent("device.identity"), repository: repository)
      guard try await device.localDeviceID() == prepared.seed.installationID else { throw AuthorityError.identityChanged }
      let relay: any AuthorityHTTPRelay = authorityRelay ?? controlledAdapters ?? M4UnavailableAuthorityRelay()
      let apple: any AppleSignInDriver = controlledAdapters ?? M4UnavailableAppleAuthorization()
      let client = AuthorityClient(relay: relay, vault: prepared.material.vault, signer: prepared.material.signer, trust: trust)
      let permits = AuthorityStartPermitProvider(client: client, repository: repository)
      let session = MatchSession(store: repository, deviceIdentity: device, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: permits, workout: workout ?? UnavailableWorkoutGateway(), environment: development ? .development(databaseNamespace: prepared.seed.namespace) : .production)
      try await permits.attach(session)
      let sync = MatchSyncService(repository: repository, inbound: session)
      let recording = RecordingModel(session: session, repository: repository, development: development, sync: sync)
      let accountService = AccountService(client: client, repository: repository, coordinator: session, deviceID: prepared.seed.installationID, cloudSpaceID: cloudSpaceID, apple: apple)
      let phone = PhoneWatchRegistrationService(client: client, repository: repository, coordinator: session)
      let channel: any M4WatchRegistrationChannel = controlledAdapters ?? M4UnavailableWatchRegistrationChannel()
      let watchRelay = M4WatchRegistrationRelay(channel: channel)
      let watch = WatchRegistrationService(client: client, repository: repository, coordinator: session, deviceID: prepared.seed.installationID, cloudSpaceID: cloudSpaceID, authorizer: watchRelay)
      let bridge = CloudSessionBridge(repository: repository, client: client, policy: policy); try await bridge.attach(session)
      let closeBridge = M4CompositionCloseBridge()
      let account = AccountStatusModel(repository: repository, development: development, action: { try await closeBridge.performAccount($0) })
      let lifecycle = LifecycleStatusModel(repository: repository, development: development, action: { _ in throw AuthorityError.unavailable })
      let context = try await AppBootstrap.accountContext(repository: repository, session: session, recording: recording, account: account, lifecycle: lifecycle, shutdownOwner: { await closeBridge.closeFromContext() }, close: { await closeBridge.closeFromContext() })
      let value = M4AccountComposition(prepared: prepared, repository: repository, session: session, context: context, client: client, accountService: accountService, phoneRegistration: phone, watchRegistration: watch, cloudBridge: bridge, sync: sync, identity: identity, cloudSpaceID: cloudSpaceID, watchRelay: watchRelay, closeBridge: closeBridge, controlledAdapters: controlledAdapters)
      // The public context retains its resource owner until successful final close.
      // Breaking this link only after success also retains failed-close retry state.
      closeBridge.owner = value
      return value
    } catch { try? await prepared.close(); throw error }
  }
  /// Bind the actual retained ledger to its original scope; current observations
  /// never choose or replace the scope of already owned transport data.
  func installIdentityLifecycle(ledger: any CloudLedger, scope: CloudScope) async throws {
    guard identityLifecycle == nil, !closed, finalClosing == nil,
          let binding = try await repository.accountBindingV4(),
          raw(binding.accountID, scope.accountID), raw(binding.cloudSpaceID, scope.cloudSpaceID),
          binding.activationEpoch == scope.activationEpoch, binding.environment == client.trust.environment else { throw AuthorityError.identityChanged }
    guard identityLifecycle == nil, !closed, finalClosing == nil else { throw AuthorityError.identityChanged }
    identityLifecycle = LifecycleService(client: client, repository: repository, coordinator: session, scope: scope, ledger: ledger)
  }
  /// The model callback always reaches this original owner and original services.
  func performAccount(_ action: AccountUserAction) async throws {
    if action == .identityChanged { return try await identityChanged() }
    try requireBusiness(businessLifetime)
    // A new current observation invalidates old UI admission before any await.
    // Failure never leaves recording ready from the prior retained credential.
    admittedScope = nil; context.account.pauseIdentity()
    try await ownBusiness {
      guard !self.scopeBusy else { throw AuthorityError.conflict }
      self.scopeBusy = true; defer { self.scopeBusy = false }
      try await self.accountAction(action)
    }
  }
  /// This control owner is deliberately outside businessOperations: it joins the
  /// original business calls and must never wait on its own registration.
  private func identityChanged() async throws {
    guard !closed, finalClosing == nil else { throw AuthorityError.identityChanged }
    context.account.pauseIdentity(); context.account.requireReload(); context.recording.beginRetirement()
    if let identityChanging { return try await identityChanging.value }
    let task = Task {
      try await self.quiesceBusiness()
      guard let service = self.identityLifecycle else { throw AuthorityError.unavailable }
      // Preserve AccountKit's original SQL/vault/analytics/ledger ordering.
      try await service.identityChanged()
      try await self.identity.advanceIdentityFence(to: self.repository.identityGenerationV4())
      try Task.checkCancellation()
    }
    identityChanging = task
    do { try await task.value }
    catch { identityChanging = nil; throw error }
  }
  /// The whole service call is owned, including a credential write after an
  /// already admitted original Session SQL mutation. Never close its DB early.
  private func ownBusiness<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    let token = businessLifetime; try requireBusiness(token)
    let id = UUID(), task = Task {
      try self.requireBusiness(token)
      let generation = try await self.repository.identityGenerationV4()
      try self.requireBusiness(token)
      let value = try await work()
      let current = try await self.repository.identityGenerationV4()
      try self.requireBusiness(token)
      guard current == generation else { throw AuthorityError.identityChanged }
      return value
    }
    businessOperations[id] = BusinessOperation(cancel: { task.cancel() }, join: Task { _ = await task.result })
    defer { businessOperations[id] = nil; notifyBusinessReturns() }
    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    try requireBusiness(token)
    return result
  }
  private func notifyBusinessReturns() {
    guard businessOperations.isEmpty else { return }
    let waiters = businessReturnWaiters; businessReturnWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
  private func joinBusinessReturns() async {
    guard !businessOperations.isEmpty else { return }
    await withCheckedContinuation { businessReturnWaiters.append($0) }
  }
  func startPhoneInbox() async throws {
    let token = businessLifetime; try requireBusiness(token)
    guard let controlledAdapters else { throw AuthorityError.unavailable }
    try await controlledAdapters.startPhoneInbox(authorizer: phoneAuthorizer)
    try requireBusiness(token)
  }
  var phoneAuthorizer: any WatchRegistrationAuthorizing { M4OriginalPhoneAuthorizer(owner: self) }
  fileprivate func phoneRegistrationContext() async throws -> WatchRegistrationContextV4 {
    try await ownBusiness {
      try await self.admitCurrentIdentity()
      return try await self.phoneRegistration.registrationContext()
    }
  }
  fileprivate func authorizePhoneRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async throws -> Data {
    try await ownBusiness {
      try await self.admitCurrentIdentity()
      return try await self.phoneRegistration.authorizeRegistration(attempt, action: action)
    }
  }
  private func accountAction(_ action: AccountUserAction) async throws {
    // Pending-deletion renewal requires its purpose-specific control service.
    guard action != .renew else { throw AuthorityError.unavailable }
    let retained = try prepared.activePhoneAttachment(), retainedWatch = try prepared.activeWatchAttachment()
    // An existing active reservation already fixes this namespace, even when a
    // capsule/seal response was lost. Never dispatch a new generic auth here.
    guard (retained == nil && retainedWatch == nil) || action == .recover else { throw AuthorityError.identityChanged }
    let observed = try await freshBusinessIdentity(), token = businessLifetime
    if let retained { try requireObservation(observed, scope: retained.scope, environment: retained.binding.environment) }
    if let retainedWatch { try requireObservation(observed, scope: retainedWatch.scope, environment: retainedWatch.binding.environment) }
    let binding = try await repository.accountBindingV4()
    try requireBusiness(token)
    guard binding?.role != .waiting else { throw AuthorityError.unavailable }
    let watchPending = try await repository.pendingWatchRegistrationAttemptsV4()
    try requireBusiness(token)
    if binding == nil && watchPending.isEmpty {
      let generation = try await repository.identityGenerationV4()
      // Absence of binding/pending is insufficient: a retained registration
      // receipt/admission without a current055 marker is not fresh protocol.
      guard try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: generation) == nil else { throw AuthorityError.unavailable }
      try requireBusiness(token)
    }
    let result: AccountAuthentication
    var expectedWatchContext: WatchRegistrationContextV4?
    if binding?.role == .watch || retainedWatch != nil {
      guard action == .recover else { throw AuthorityError.unavailable }
      try await requireNoPhoneProtocolFacts(token: token)
      let generation = try await repository.identityGenerationV4()
      guard let proof = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: generation),
            proof.binding.role == .watch else { throw AuthorityError.unavailable }
      if let retainedWatch { guard try retainedWatch.matches(proof) else { throw AuthorityError.identityChanged } }
      guard watchPending.isEmpty else { throw AuthorityError.conflict }
      let originalContext = try await watchRelay.registrationContext()
      try requireBusiness(token); try requireWatchContext(originalContext, original: proof.admittedContext, observed: observed)
      expectedWatchContext = originalContext
      try await watchRegistration.admitCurrentIdentity(context: originalContext)
      try await checkedWatchProof(proof, businessToken: token)
      result = try await watchRegistration.recover(requestID: proof.currentWatchRequestID)
    } else if action == .registerWatch || (action == .recover && !watchPending.isEmpty) {
      try prepared.requireUnboundResources()
      try await requireUnboundProtocolState(token: token)
      guard binding == nil else { throw AuthorityError.unavailable }
      guard watchPending.count <= 1 else { throw AuthorityError.conflict }
      let originalContext = try await watchRelay.registrationContext()
      try requireBusiness(token)
      guard raw(originalContext.accountID, observed.accountID), raw(originalContext.cloudSpaceID, observed.cloudSpaceID), originalContext.environment == observed.environment else { throw AuthorityError.identityChanged }
      if let pending = watchPending.first { try requireWatchContext(originalContext, original: pending.context, observed: observed) }
      expectedWatchContext = originalContext
      try await watchRegistration.admitCurrentIdentity(context: originalContext)
      try requireBusiness(token)
      let pending = watchPending
      try requireBusiness(token)
      if let original = pending.first { result = try await watchRegistration.recover(requestID: original.requestID) }
      else {
        guard action != .recover else { throw LifecycleClientError.unknownOriginal }
        result = try await watchRegistration.register(requestID: UUID().uuidString, challengeRequestID: UUID().uuidString)
      }
    } else {
      guard watchPending.isEmpty else { throw AuthorityError.unavailable }
      try await accountService.admitCurrentIdentity(accountID: observed.accountID)
      try requireBusiness(token)
      let pending = try await repository.pendingAuthAttemptsV4()
      try requireBusiness(token)
      guard pending.count <= 1 else { throw AuthorityError.conflict }
      if let original = pending.first {
        guard retained == nil || retained?.currentAuthRequestID == original.requestID else { throw AuthorityError.identityChanged }
        result = try authenticated(await accountService.recover(authRequestID: original.requestID))
      }
      else if let original = try await repository.currentAuthRequestIDV4() {
        guard retained == nil || retained?.currentAuthRequestID == original else { throw AuthorityError.identityChanged }
        try requireBusiness(token)
        result = try authenticated(await accountService.recover(authRequestID: original))
      } else {
        guard action != .recover else { throw LifecycleClientError.unknownOriginal }
        // A nil current witness alone cannot choose a new protocol. Original
        // pointers, attempts and unfinished controls must all be absent.
        try prepared.requireUnboundResources()
        try await requireUnboundProtocolState(token: token)
        result = try await accountService.signIn(requestID: UUID().uuidString, challengeRequestID: UUID().uuidString)
      }
    }
    try requireBusiness(token)
    guard raw(result.binding.accountID, observed.accountID), raw(result.binding.cloudSpaceID, observed.cloudSpaceID),
          raw(result.binding.deviceID, prepared.seed.installationID), result.binding.environment == observed.environment else { throw AuthorityError.identityChanged }
    // A retained credential/configured subject never substitutes for this second
    // independent current observation and the existing checked038 projection.
    try await observeAndAdmitIdentity(expectedIdentity: observed, expectedWatchContext: expectedWatchContext)
    try requireBusiness(token)
    reauthenticationID = result.reauthenticationID
  }
  private func requireUnboundProtocolState(token: UUID) async throws {
    let generation = try await repository.identityGenerationV4()
    let attempts = try await repository.authAttemptsV4(), current = try await repository.currentAuthRequestIDV4()
    let controls = try await repository.pendingControlsV4(), sagas = try await repository.deletionSagasV4()
    let migration = try await repository.latestMigrationV4()
    try requireBusiness(token)
    guard attempts.isEmpty, current == nil, controls.isEmpty, sagas.isEmpty, migration == nil else { throw AuthorityError.unavailable }
    // nil is only one checked fact, never a freshness decision on its own.
    let proof = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
    let binding = try await repository.accountBindingV4()
    guard proof == nil, binding == nil, try await repository.identityGenerationV4() == generation else { throw AuthorityError.unavailable }
    try requireBusiness(token); try prepared.requireUnboundResources()
  }
  private func authenticated(_ recovery: AuthenticationRecovery) throws -> AccountAuthentication {
    switch recovery {
    case .authenticated(let value): return value
    case .knownRevoked, .knownExpired: throw AuthorityError.staleAttestation
    case .knownNotFound, .knownAbandoned, .unresolved: throw AuthorityError.unavailable
    }
  }
  /// Unbound authentication may be admitted to the original service, but cannot
  /// project recording readiness until the signed result and a fresh observation.
  private func freshBusinessIdentity() async throws -> M4CurrentAccountIdentity {
    let token = businessLifetime; try requireBusiness(token)
    let generation = try await repository.identityGenerationV4(), binding = try await repository.accountBindingV4()
    try requireBusiness(token)
    try await identity.advanceIdentityFence(to: generation)
    let observed = try await identity.currentIdentity()
    for value in [observed.accountID, observed.cloudSpaceID, observed.zoneID] { try AuthorityWire.identifier(value) }
    guard raw(observed.cloudSpaceID, cloudSpaceID), observed.environment == client.trust.environment else { throw AuthorityError.identityChanged }
    if let binding {
      guard raw(binding.accountID, observed.accountID), raw(binding.cloudSpaceID, observed.cloudSpaceID),
            raw(binding.deviceID, prepared.seed.installationID), binding.environment == observed.environment else { throw AuthorityError.identityChanged }
    }
    let currentGeneration = try await repository.identityGenerationV4(), currentBinding = try await repository.accountBindingV4()
    try requireBusiness(token)
    guard currentGeneration == generation, try AuthorityWire.encode(currentBinding) == AuthorityWire.encode(binding) else { throw AuthorityError.identityChanged }
    return observed
  }
  private func requireBusiness(_ token: UUID) throws {
    guard !closed, !businessStopped, businessLifetime == token else { throw AuthorityError.identityChanged }
    try Task.checkCancellation()
  }
  /// The provider must observe the current dual identity again. A retained vault
  /// credential by itself never calls this method or admits the presentation.
  func admitCurrentIdentity() async throws {
    guard !closed, !businessStopped else { throw AuthorityError.identityChanged }
    admittedScope = nil; context.account.pauseIdentity()
    let id = UUID(), task = Task {
      guard !self.scopeBusy else { throw AuthorityError.conflict }
      self.scopeBusy = true; defer { self.scopeBusy = false }
      try await self.observeAndAdmitIdentity()
    }
    identityTasks[id] = task
    defer { identityTasks[id] = nil }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
  private func sameProof(_ lhs: VerifiedLocalAuthenticationEvidenceV4, _ rhs: VerifiedLocalAuthenticationEvidenceV4) throws -> Bool {
    let bindingMatches = try AuthorityWire.encode(lhs.binding) == AuthorityWire.encode(rhs.binding)
    let attemptMatches = try AuthorityWire.encode(lhs.attempt) == AuthorityWire.encode(rhs.attempt)
    return lhs.identityGeneration == rhs.identityGeneration && lhs.admissionGeneration == rhs.admissionGeneration &&
      raw(lhs.currentAuthRequestID, rhs.currentAuthRequestID) && lhs.receipt.raw == rhs.receipt.raw && bindingMatches && attemptMatches
  }
  private func requireIdentityLifetime(_ token: UUID) throws {
    guard !closed, !businessStopped, finalClosing == nil, lifetime == token else { throw AuthorityError.identityChanged }
    try Task.checkCancellation()
  }
  private func checkedProof(_ original: VerifiedLocalAuthenticationEvidenceV4, token: UUID) async throws {
    try requireIdentityLifetime(token)
    guard let current = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: original.identityGeneration),
          try sameProof(original, current) else { throw AuthorityError.identityChanged }
    try requireIdentityLifetime(token)
  }
  private func requireCredential(_ credential: DeviceCredential, binding: AccountBindingV4) throws {
    guard raw(credential.accountID, binding.accountID), raw(credential.deviceID, prepared.seed.installationID),
          raw(credential.deviceID, binding.deviceID), credential.activationEpoch == binding.activationEpoch,
          raw(credential.keyID, try AuthorityWire.deviceKeyID(publicKey: prepared.material.signer.publicKey)),
          Double(credential.expiresAt) > Date().timeIntervalSince1970 else { throw AuthorityError.staleAttestation }
  }
  private func requireObservation(_ observed: M4CurrentAccountIdentity, scope: CloudScope, environment: AuthorityEnvironment) throws {
    guard raw(observed.accountID, scope.accountID), raw(observed.cloudSpaceID, scope.cloudSpaceID),
          raw(observed.cloudSpaceID, cloudSpaceID), raw(observed.zoneID, scope.zoneID),
          observed.environment == environment, observed.environment == client.trust.environment else { throw AuthorityError.identityChanged }
  }
  private func observeAndAdmitIdentity(expectedIdentity: M4CurrentAccountIdentity? = nil, expectedWatchContext: WatchRegistrationContextV4? = nil) async throws {
    guard !closed, !businessStopped else { throw AuthorityError.identityChanged }
    let token = UUID(); lifetime = token; admittedScope = nil; context.account.pauseIdentity()
    do {
      _ = try prepared.activePhoneAttachment() // no unmanaged/binding-only bypass
      let generation = try await repository.identityGenerationV4()
      if try await repository.accountBindingV4()?.role == .watch {
        try await observeAndAdmitWatch(generation: generation, token: token, expectedIdentity: expectedIdentity, expectedContext: expectedWatchContext)
        return
      }
      guard let proof = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation),
            proof.binding.role == .phone, !proof.binding.suspended else { throw AuthorityError.unavailable }
      try requireIdentityLifetime(token)
      try await identity.advanceIdentityFence(to: generation)
      let observed = try await identity.currentIdentity()
      for value in [observed.accountID, observed.cloudSpaceID, observed.zoneID] { try AuthorityWire.identifier(value) }
      guard raw(observed.accountID, proof.binding.accountID), raw(observed.cloudSpaceID, proof.binding.cloudSpaceID),
            raw(observed.cloudSpaceID, cloudSpaceID), raw(proof.binding.deviceID, prepared.seed.installationID),
            raw(proof.attempt.publicKey, prepared.material.signer.publicKey),
            observed.environment == proof.binding.environment, observed.environment == client.trust.environment else { throw AuthorityError.identityChanged }
      if let expectedIdentity {
        guard raw(observed.accountID, expectedIdentity.accountID), raw(observed.cloudSpaceID, expectedIdentity.cloudSpaceID),
              raw(observed.zoneID, expectedIdentity.zoneID), observed.environment == expectedIdentity.environment else { throw AuthorityError.identityChanged }
      }
      try await checkedProof(proof, token: token)
      let handle = try await prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: generation, observed: observed)
      try await checkedProof(proof, token: token)
      try validateOriginalStoreCapsule(handle.storeCapsule, scope: handle.scope)
      let credential = try await prepared.material.vault.credential()
      try requireIdentityLifetime(token); try requireCredential(credential, binding: proof.binding)
      try await accountService.admitCurrentIdentity(accountID: observed.accountID)
      try await phoneRegistration.admitCurrentIdentity(accountID: observed.accountID)
      if let prior = managedPhoneResources {
        guard prior.ledger === handle.ledger, try prior.attachment.digest() == handle.attachment.digest() else { throw AuthorityError.identityChanged }
      } else {
        guard identityLifecycle == nil else { throw AuthorityError.identityChanged }
        try await installIdentityLifecycle(ledger: handle.ledger, scope: handle.scope)
        managedPhoneResources = handle
      }
      try await context.lifecycle.projectCloudScope(handle.scope, expectedIdentityGeneration: generation)
      try await checkedProof(proof, token: token)
      // Last independent source observation, after owner/credential/service
      // tails. Subsequent SQL/model reads are not a global identity lease.
      try await identity.advanceIdentityFence(to: generation)
      let finalObserved = try await identity.currentIdentity()
      try requireObservation(finalObserved, scope: handle.scope, environment: proof.binding.environment)
      try await checkedProof(proof, token: token)
      guard try await handle.ledger.scopeState(scope: handle.scope).issue != .accountChanged else { throw AuthorityError.identityChanged }
      try await checkedProof(proof, token: token)
      let finalCheck = finalPhoneAdmissionCheck(handle, credential: credential)
      // Accepted056 executes this veto after model SQL awaits and rechecks its
      // own stopped/token after callback reentry, immediately before ready.
      try await context.account.admitIdentity(proof.binding, expectedIdentityGeneration: generation, finalCheck: finalCheck)
      try finalCheck() // no new vault await before the scope publication
      admittedScope = handle.scope
    } catch {
      if lifetime == token { admittedScope = nil; context.account.pauseIdentity() }
      throw error
    }
  }
  private func requireNoPhoneProtocolFacts(token: UUID) async throws {
    let attempts = try await repository.authAttemptsV4(), current = try await repository.currentAuthRequestIDV4()
    let controls = try await repository.pendingControlsV4(), deletions = try await repository.deletionSagasV4()
    try requireBusiness(token)
    guard attempts.isEmpty, current == nil, controls.isEmpty, deletions.isEmpty,
          try prepared.activePhoneAttachment() == nil else { throw AuthorityError.unavailable }
  }
  private func requireWatchContext(_ current: WatchRegistrationContextV4, original: WatchRegistrationContextV4, observed: M4CurrentAccountIdentity) throws {
    guard try AuthorityWire.encode(current) == AuthorityWire.encode(original), !raw(current.phoneID, prepared.seed.installationID),
          raw(current.accountID, observed.accountID), raw(current.cloudSpaceID, observed.cloudSpaceID),
          raw(current.cloudSpaceID, cloudSpaceID), current.environment == observed.environment, current.environment == client.trust.environment else { throw AuthorityError.identityChanged }
  }
  private func sameWatchProof(_ lhs: VerifiedLocalWatchRegistrationEvidenceV4, _ rhs: VerifiedLocalWatchRegistrationEvidenceV4) throws -> Bool {
    let binding = try AuthorityWire.encode(lhs.binding) == AuthorityWire.encode(rhs.binding)
    let attempt = try AuthorityWire.encode(lhs.attempt) == AuthorityWire.encode(rhs.attempt)
    let context = try AuthorityWire.encode(lhs.admittedContext) == AuthorityWire.encode(rhs.admittedContext)
    let migration = try AuthorityWire.encode(lhs.latestMigration) == AuthorityWire.encode(rhs.latestMigration)
    return lhs.identityGeneration == rhs.identityGeneration && lhs.acceptedGeneration == rhs.acceptedGeneration &&
      raw(lhs.currentWatchRequestID, rhs.currentWatchRequestID) && raw(lhs.watchDeviceKeyID, rhs.watchDeviceKeyID) &&
      lhs.receipt.raw == rhs.receipt.raw && binding && attempt && context && migration
  }
  private func checkedWatchProof(_ original: VerifiedLocalWatchRegistrationEvidenceV4, businessToken: UUID) async throws {
    try requireBusiness(businessToken)
    guard let current = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: original.identityGeneration),
          try sameWatchProof(original, current) else { throw AuthorityError.identityChanged }
    try requireBusiness(businessToken)
  }
  private func checkedWatchIdentity(_ original: VerifiedLocalWatchRegistrationEvidenceV4, token: UUID) async throws {
    try requireIdentityLifetime(token)
    guard let current = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: original.identityGeneration),
          try sameWatchProof(original, current) else { throw AuthorityError.identityChanged }
    try requireIdentityLifetime(token)
  }
  private func observeAndAdmitWatch(generation: Int64, token: UUID, expectedIdentity: M4CurrentAccountIdentity?, expectedContext: WatchRegistrationContextV4?) async throws {
    try await requireNoPhoneProtocolFacts(token: businessLifetime)
    guard let proof = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: generation),
          proof.binding.role == .watch, !proof.binding.suspended else { throw AuthorityError.unavailable }
    try requireIdentityLifetime(token)
    try await identity.advanceIdentityFence(to: generation)
    let observed = try await identity.currentIdentity()
    for value in [observed.accountID, observed.cloudSpaceID, observed.zoneID] { try AuthorityWire.identifier(value) }
    guard raw(observed.accountID, proof.binding.accountID), raw(observed.cloudSpaceID, proof.binding.cloudSpaceID),
          raw(observed.cloudSpaceID, cloudSpaceID), raw(proof.binding.deviceID, prepared.seed.installationID),
          raw(proof.attempt.payload.watchPublicKey, prepared.material.signer.publicKey),
          raw(proof.watchDeviceKeyID, try AuthorityWire.deviceKeyID(publicKey: prepared.material.signer.publicKey)),
          observed.environment == proof.binding.environment, observed.environment == client.trust.environment else { throw AuthorityError.identityChanged }
    if let expectedIdentity {
      guard raw(observed.accountID, expectedIdentity.accountID), raw(observed.cloudSpaceID, expectedIdentity.cloudSpaceID),
            raw(observed.zoneID, expectedIdentity.zoneID), observed.environment == expectedIdentity.environment else { throw AuthorityError.identityChanged }
    }
    try await checkedWatchIdentity(proof, token: token)
    let initialContext = try await watchRelay.registrationContext()
    try requireWatchContext(initialContext, original: proof.admittedContext, observed: observed)
    if let expectedContext { try requireWatchContext(initialContext, original: expectedContext, observed: observed) }
    try await checkedWatchIdentity(proof, token: token)
    let handle = try await prepared.prepareCurrentWatchResources(expectedIdentityGeneration: generation, observed: observed, phoneContext: initialContext)
    try await checkedWatchIdentity(proof, token: token)
    try validateOriginalStoreCapsule(handle.storeCapsule, scope: handle.scope)
    let credential = try await prepared.material.vault.credential()
    try requireIdentityLifetime(token); try requireCredential(credential, binding: proof.binding)
    try await watchRegistration.admitCurrentIdentity(context: initialContext)
    try await checkedWatchIdentity(proof, token: token)
    if let prior = managedWatchResources {
      guard prior.ledger === handle.ledger, try prior.attachment.digest() == handle.attachment.digest() else { throw AuthorityError.identityChanged }
    } else {
      guard identityLifecycle == nil, managedPhoneResources == nil else { throw AuthorityError.identityChanged }
      try await installIdentityLifecycle(ledger: handle.ledger, scope: handle.scope); managedWatchResources = handle
    }
    try await context.lifecycle.projectCloudScope(handle.scope, expectedIdentityGeneration: generation)
    try await checkedWatchIdentity(proof, token: token)
    // Both external sources have explicit final observation checkpoints after
    // owner/credential/service/lifecycle tails; these are not a future lease.
    let finalContext = try await watchRelay.registrationContext()
    try requireWatchContext(finalContext, original: proof.admittedContext, observed: observed)
    try await checkedWatchIdentity(proof, token: token)
    try await identity.advanceIdentityFence(to: generation)
    let finalObserved = try await identity.currentIdentity()
    try requireObservation(finalObserved, scope: handle.scope, environment: proof.binding.environment)
    try await checkedWatchIdentity(proof, token: token)
    guard try await handle.ledger.scopeState(scope: handle.scope).issue != .accountChanged else { throw AuthorityError.identityChanged }
    try await checkedWatchIdentity(proof, token: token)
    let finalCheck = finalWatchAdmissionCheck(handle, credential: credential)
    try await context.account.admitIdentity(proof.binding, expectedIdentityGeneration: generation, finalCheck: finalCheck)
    try finalCheck(); admittedScope = handle.scope
  }
  /// Synchronous veto only, shared by the actual Watch common gate and its
  /// real056 model-read tail integration test. It never authenticates a caller.
  func finalWatchAdmissionCheck(_ handle: M4ManagedWatchResources, credential: DeviceCredential) -> @MainActor () throws -> Void {
    let token = lifetime
    return {
      try self.requireIdentityLifetime(token); try self.prepared.requireWatchResources(handle)
      try self.requireCredential(credential, binding: handle.attachment.binding)
    }
  }
  /// A veto only, never an admission or a substitute for the checked current
  /// proof and independent source observations in the common gate.
  func finalPhoneAdmissionCheck(_ handle: M4ManagedPhoneResources, credential: DeviceCredential) -> @MainActor () throws -> Void {
    let token = lifetime
    return {
      try self.requireIdentityLifetime(token)
      try self.prepared.requirePhoneResources(handle)
      try self.requireCredential(credential, binding: handle.attachment.binding)
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
    businessStopped = true; businessLifetime = UUID(); lifetime = UUID(); admittedScope = nil
    context.account.pauseIdentity(); context.recording.beginRetirement()
    let session = session, recording = context.recording, observations = Array(identityTasks.values), controlledAdapters = controlledAdapters
    let services = Array(businessOperations.values)
    observations.forEach { $0.cancel() }; services.forEach { $0.cancel() }
    let task = Task {
      // Establish the original Session's permanent business gate before any
      // cancellation-insensitive identity observer can delay this drain.
      let retirement: Result<Void, any Error>
      do { try await Self.retireBusiness(session: session, recording: recording); retirement = .success(()) }
      catch { retirement = .failure(error) }
      await controlledAdapters?.quiesceBusiness()
      // A failed durable retirement still joins every cancelled identity task;
      // preserve the original failure and facade for the owner's SQL-only retry.
      for service in services { await service.join.value }
      await self.joinBusinessReturns()
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
    businessStopped = true; businessLifetime = UUID(); lifetime = UUID(); admittedScope = nil
    context.account.stop(); context.lifecycle.stop(); context.recording.beginRetirement()
    let owners = controlOwners.values.compactMap(\.value), identityChange = identityChanging
    identityChange?.cancel()
    let task = Task {
      try await self.quiesceBusiness()
      _ = await identityChange?.result
      for owner in owners { await owner.stopAndJoin() }
      await self.watchRelay.close()
      try await self.controlledAdapters?.finalClose()
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
  /// Complete point-in-time046 facts from this one original facade, only after
  /// every original Session/capture writer has joined. No subset matchIDs query.
  func captureHealthReservationFacts() async throws -> [M4HealthCaptureFacts] {
    try await quiesceBusiness()
    guard await session.syncRepositoryIdentity() == repository.syncRepositoryIdentity() else { throw AuthorityError.identityChanged }
    return try await repository.captureInventoryV4().map {
      M4HealthCaptureFacts(binding: $0.binding, revisions: $0.captureRevisions, operations: $0.captureOperations)
    }
  }
  func validateHealthReservationFacts(_ raw: M4HealthRawReservation) async throws {
    let actual = try await captureHealthReservationFacts()
    guard try Self.comparableCaptureFacts(actual) == Self.comparableCaptureFacts(raw.facts) else { throw M4HealthBridgeError.identityConflict }
  }
  private static func comparableCaptureFacts(_ facts: [M4HealthCaptureFacts]) throws -> Data {
    // Sort copies by raw keys, preserving every record's original encoded bytes.
    // Never normalize/mutate the retained artifact, its IDs or first mapping.
    var bindings = Set<Data>()
    let ordered = try facts.map { fact -> (Data, M4HealthCaptureFacts) in
      let key = M4HealthBytes.frame([Data(fact.binding.matchID.utf8), Data(fact.binding.recordingDeviceID.utf8)])
      guard bindings.insert(key).inserted,
            Set(fact.revisions.map { Data($0.id.utf8) }).count == fact.revisions.count,
            Set(fact.operations.map { Data($0.operation.id.utf8) }).count == fact.operations.count else { throw M4HealthBridgeError.identityConflict }
      return (key, M4HealthCaptureFacts(binding: fact.binding,
        revisions: fact.revisions.sorted { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) },
        operations: fact.operations.sorted { Data($0.operation.id.utf8).lexicographicallyPrecedes(Data($1.operation.id.utf8)) }))
    }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
    return try M4HealthBytes.encode(ordered)
  }
  func validateOriginalStoreCapsule(_ capsule: M4OwnershipCapsule, scope: CloudScope) throws {
    guard capsule.kind == .businessStore, !capsule.root.directory, capsule.scope == scope,
          try M4CatalogIO.encode(capsule.root) == M4CatalogIO.encode(M4CatalogIO.anchor(prepared.seed.businessDatabaseURL)) else { throw M4CatalogError.identityChanged }
    try capsule.verifyCurrent()
  }
  private func raw(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
}

@MainActor private final class M4CompositionCloseBridge {
  var owner: M4AccountComposition?
  func closeFromContext() async { await owner?.closeFromContext() }
  func performAccount(_ value: AccountUserAction) async throws {
    guard let owner else { throw AuthorityError.identityChanged }; try await owner.performAccount(value)
  }
}
@MainActor private final class M4WeakControlOwner {
  weak var value: M4DeletionResumeController?
  init(_ value: M4DeletionResumeController) { self.value = value }
}

/// Weak forwarding only: the existing Phone service and040 endpoint remain the
/// authority; the inbox cannot manufacture admission from retained/config data.
private struct M4OriginalPhoneAuthorizer: WatchRegistrationAuthorizing {
  weak var owner: M4AccountComposition?
  func registrationContext() async throws -> WatchRegistrationContextV4 {
    guard let owner else { throw AuthorityError.identityChanged }
    return try await owner.phoneRegistrationContext()
  }
  func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async throws -> Data {
    guard let owner else { throw AuthorityError.identityChanged }
    return try await owner.authorizePhoneRegistration(attempt, action: action)
  }
}
