import Foundation
import MatchCore
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
  private var managedController: M4DeletionResumeController?
  private var managedControlLifetime = UUID()
  private var initialDeletionService: InitialDeletionAuthenticationService?
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
  private var normalCloud: CloudSyncService?
  private var normalControl: AuthorityControlService?
  private var normalOperation: UUID?
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
      let lifecycle = LifecycleStatusModel(repository: repository, development: development, action: { try await closeBridge.performLifecycle($0) })
      let context = try await AppBootstrap.accountContext(repository: repository, session: session, recording: recording, account: account, lifecycle: lifecycle, shutdownOwner: { await closeBridge.closeFromContext() }, close: { await closeBridge.closeFromContext() })
      let value = M4AccountComposition(prepared: prepared, repository: repository, session: session, context: context, client: client, accountService: accountService, phoneRegistration: phone, watchRegistration: watch, cloudBridge: bridge, sync: sync, identity: identity, cloudSpaceID: cloudSpaceID, watchRelay: watchRelay, closeBridge: closeBridge, controlledAdapters: controlledAdapters)
      value.initialDeletionService = InitialDeletionAuthenticationService(client: client, repository: repository,
        coordinator: session, apple: apple, currentScope: { [weak value] in
          guard let value else { throw AuthorityError.identityChanged }
          return try await value.initialDeletionScope()
        })
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
  /// Only the original controlled Phone owner can save/release business data.
  /// Every call owns one service unit; failed/missing evidence never loops into
  /// a replacement upload or a new termination request.
  func performLifecycle(_ action: LifecycleUserAction) async throws {
    switch action { case .saveCloudOnly, .synchronize, .retryControls: break; default: throw AuthorityError.unavailable }
    try await ownBusiness {
      guard !self.scopeBusy, self.normalOperation == nil else { throw AuthorityError.conflict }
      self.scopeBusy = true; self.normalOperation = UUID()
      defer { self.normalOperation = nil; self.scopeBusy = false }
      let handle = try await self.normalCheckpoint()
      if self.normalCloud == nil {
        let coordinator = M4NormalCoordinator(owner: self)
        try await self.cloudBridge.attach(coordinator)
        _ = try await self.normalCheckpoint()
        guard let driver = self.controlledAdapters else { throw AuthorityError.unavailable }
        self.normalCloud = CloudSyncService(scope: handle.scope, ledger: handle.ledger, driver: driver, sink: self.cloudBridge)
        self.normalControl = AuthorityControlService(client: self.client, repository: self.repository, coordinator: coordinator)
      }
      guard let cloud = self.normalCloud, let control = self.normalControl else { throw AuthorityError.unavailable }
      switch action {
      case .saveCloudOnly(let id), .synchronize(let id):
        let snapshot = try await self.session.snapshot(matchID: id)
        _ = try await self.normalCheckpoint()
        if snapshot.replay.state != .completed {
          guard snapshot.replay.state == .endedPendingSync,
                snapshot.store.captureOperations.allSatisfy({ [.settled, .failed, .cancelled].contains($0.state) }) else { throw AuthorityError.unavailable }
          let upload = try await self.cloudBridge.prepareUpload(matchID: id, scope: handle.scope)
          _ = try await self.normalCheckpoint()
          try await handle.ledger.enqueue(upload)
          _ = try await self.normalCheckpoint()
          _ = try await cloud.synchronize() // exactly one service unit per action
          _ = try await self.normalCheckpoint()
          let entries = try await handle.ledger.uploads(scope: handle.scope)
          _ = try await self.normalCheckpoint()
          let receipts = try await handle.ledger.saveEvidence(scope: handle.scope)
          _ = try await self.normalCheckpoint()
          guard entries.contains(where: { $0.upload == upload && $0.state == .confirmed && $0.originalBytes == (try? upload.canonicalBytes()) }),
                let evidence = receipts.first(where: { $0.matches(upload) }) else { throw CloudImportError.proofUnavailable }
          _ = try await self.cloudBridge.acceptDevelopmentSave(upload: upload, evidence: evidence, ledger: handle.ledger)
          _ = try await self.normalCheckpoint()
          if case .synchronize = action {
            let queue = try await self.repository.controlQueueV4()
            _ = try await self.normalCheckpoint()
            let originals = queue.filter { $0.intent.operation == .terminate && $0.intent.matchID == id && $0.intent.fields.mode == "normal" && $0.state != .confirmed }
            guard originals.count <= 1 else { throw AuthorityError.conflict }
            if let original = originals.first { _ = try await control.reconcile(original.intent) }
            else {
              let request = "normal-" + AuthorityWire.hash(try AuthorityWire.encode(["football-record.normal.v1", self.namespace, id]))
              _ = try await control.normal(matchID: id, requestID: request)
            }
          }
        }
      case .retryControls:
        let queue = try await self.repository.controlQueueV4()
        _ = try await self.normalCheckpoint()
        for entry in queue where entry.intent.operation == .terminate && entry.intent.fields.mode == "normal" && [.ready, .inFlight, .retryScheduled].contains(entry.state) && (entry.nextAttemptAt.map { $0 <= Date() } ?? true) {
          _ = try await self.normalCheckpoint()
          _ = try await control.reconcile(entry.intent)
        }
      default: throw AuthorityError.unavailable
      }
      _ = try await self.normalCheckpoint()
      await self.context.recording.refreshAuthority()
      _ = try await self.normalCheckpoint()
    }
  }
  /// Last independent observation checkpoint before a borrowed service forwards
  /// to the original Session. Its SQL generation/retirement checks still apply;
  /// this is not an external-source/SQL atomic lease or a future identity promise.
  fileprivate func normalCheckpoint() async throws -> M4ManagedPhoneResources {
    let token = lifetime, business = businessLifetime
    do {
      try requireBusiness(business); try requireIdentityLifetime(token)
      guard normalOperation != nil, scopeBusy, controlledAdapters != nil, client.trust.environment == .development,
            let handle = managedPhoneResources, admittedScope == handle.scope,
            context.account.canEnterRecording else { throw AuthorityError.unavailable }
      try prepared.requirePhoneResources(handle)
      let generation = try await repository.identityGenerationV4()
      guard let proof = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation),
            proof.binding.role == .phone, try handle.attachment.matches(proof) else { throw AuthorityError.identityChanged }
      try requireIdentityLifetime(token)
      let credential = try await prepared.material.vault.credential()
      try requireIdentityLifetime(token); try requireCredential(credential, binding: proof.binding)
      guard try await handle.ledger.scopeState(scope: handle.scope).issue != .accountChanged else { throw AuthorityError.identityChanged }
      try await checkedProof(proof, token: token)
      let observed = try await freshBusinessIdentity()
      try requireObservation(observed, scope: handle.scope, environment: proof.binding.environment)
      try await checkedProof(proof, token: token)
      try requireBusiness(business); try requireIdentityLifetime(token)
      try prepared.requirePhoneResources(handle); try requireCredential(credential, binding: proof.binding)
      return handle
    } catch {
      admittedScope = nil; context.account.pauseIdentity()
      throw error
    }
  }
  /// This control owner is deliberately outside businessOperations: it joins the
  /// original business calls and must never wait on its own registration.
  private func identityChanged() async throws {
    guard !closed, finalClosing == nil else { throw AuthorityError.identityChanged }
    managedControlLifetime = UUID()
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
    let token = businessLifetime
    var setup: CheckedLocalWatchRegistrationSetupEvidenceV4?
    // Only an explicit, unbound Watch setup can use059. Classify locally before
    // either independent identity observation or actual Phone-context exchange.
    if action == .registerWatch {
      let initialBinding = try await repository.accountBindingV4()
      let initialPending = try await repository.pendingWatchRegistrationAttemptsV4()
      try requireBusiness(token)
      if initialBinding == nil && initialPending.isEmpty {
        let generation = try await repository.identityGenerationV4()
        setup = try await checkedWatchSetup(generation: generation, token: token)
      }
    }
    let observed = try await freshBusinessIdentity()
    if let original = setup?.admittedContext { try requireWatchContext(original, original: original, observed: observed) }
    if let retained { try requireObservation(observed, scope: retained.scope, environment: retained.binding.environment) }
    if let retainedWatch { try requireObservation(observed, scope: retainedWatch.scope, environment: retainedWatch.binding.environment) }
    let binding = try await repository.accountBindingV4()
    try requireBusiness(token)
    guard binding?.role != .waiting else { throw AuthorityError.unavailable }
    let watchPending = try await repository.pendingWatchRegistrationAttemptsV4()
    try requireBusiness(token)
    if setup != nil { guard binding == nil, watchPending.isEmpty else { throw AuthorityError.identityChanged } }
    if binding == nil && watchPending.isEmpty && setup == nil {
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
      if let setup {
        _ = try WatchRegistrationContextV4(accountID: originalContext.accountID, cloudSpaceID: originalContext.cloudSpaceID, phoneID: originalContext.phoneID, activationEpoch: originalContext.activationEpoch, environment: originalContext.environment)
        try requireWatchContext(originalContext, original: setup.admittedContext ?? originalContext, observed: observed)
        let finalObserved = try await freshBusinessIdentity()
        try requireBusiness(token)
        guard raw(finalObserved.accountID, observed.accountID), raw(finalObserved.cloudSpaceID, observed.cloudSpaceID),
              raw(finalObserved.zoneID, observed.zoneID), finalObserved.environment == observed.environment else { throw AuthorityError.identityChanged }
        try requireWatchContext(originalContext, original: setup.admittedContext ?? originalContext, observed: finalObserved)
        let current = try await checkedWatchSetup(generation: setup.identityGeneration, token: token)
        guard try sameWatchSetup(setup, current) else { throw AuthorityError.identityChanged }
        try requireBusiness(token); try prepared.requireUnboundResources()
      }
      expectedWatchContext = originalContext
      try await watchRegistration.admitCurrentIdentity(context: originalContext)
      try requireBusiness(token)
      let pending = watchPending
      try requireBusiness(token)
      if let original = pending.first { result = try await watchRegistration.recover(requestID: original.requestID) }
      else {
        guard action != .recover else { throw LifecycleClientError.unknownOriginal }
        guard setup != nil else { throw AuthorityError.unavailable }
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
  private func checkedWatchSetup(generation: Int64, token: UUID) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
    try requireBusiness(token); try prepared.requireUnboundResources()
    let publicKey = prepared.material.signer.publicKey
    let value = try await repository.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: generation, deviceID: prepared.seed.installationID, publicKey: publicKey)
    try requireBusiness(token); try prepared.requireUnboundResources()
    guard value.identityGeneration == generation, raw(value.watchDeviceID, prepared.seed.installationID),
          raw(value.watchPublicKey, publicKey), raw(value.watchDeviceKeyID, try AuthorityWire.deviceKeyID(publicKey: publicKey)) else { throw AuthorityError.identityChanged }
    switch value.state {
    case .empty: guard value.admittedContext == nil else { throw AuthorityError.unavailable }
    case .admissionOnly: guard value.admittedContext != nil else { throw AuthorityError.unavailable }
    }
    return value
  }
  private func sameWatchSetup(_ lhs: CheckedLocalWatchRegistrationSetupEvidenceV4, _ rhs: CheckedLocalWatchRegistrationSetupEvidenceV4) throws -> Bool {
    let context = try AuthorityWire.encode(lhs.admittedContext) == AuthorityWire.encode(rhs.admittedContext)
    return lhs.state == rhs.state && lhs.identityGeneration == rhs.identityGeneration &&
      raw(lhs.watchDeviceID, rhs.watchDeviceID) && raw(lhs.watchPublicKey, rhs.watchPublicKey) &&
      raw(lhs.watchDeviceKeyID, rhs.watchDeviceKeyID) && context
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
  /// Synchronous ownership is established before a caller can suspend. The
  /// initializer only registers this owner; its first FIFO job binds resources.
  func managedDeletionController() throws -> M4DeletionResumeController {
    guard !closed, finalClosing == nil else { throw AuthorityError.identityChanged }
    if let managedController { return managedController }
    let controller = M4DeletionResumeController(managedComposition: self, controlLifetime: managedControlLifetime)
    managedController = controller
    return controller
  }
  func requireManagedDeletionController(_ controller: M4DeletionResumeController) throws {
    try controller.requireManagedOperationCaller()
    guard !closed, finalClosing == nil, managedController === controller,
          controller.controlLifetime == managedControlLifetime else { throw AuthorityError.identityChanged }
    try Task.checkCancellation()
  }
  func requireManagedDeletionBinding(controller: M4DeletionResumeController, borrow: M4ManagedDeletionBorrow) throws {
    try requireManagedDeletionController(controller)
    guard let handle = managedPhoneResources, handle.ledger === borrow.ledger, handle.scope == borrow.attachment.scope,
          try handle.attachment.digest() == borrow.attachment.digest(),
          try M4CatalogIO.encode(handle.seal) == M4CatalogIO.encode(borrow.seal) else { throw AuthorityError.identityChanged }
    try validateOriginalStoreCapsule(borrow.storeCapsule, scope: handle.scope)
    try borrow.verify()
  }
  /// Original source observations are vetoes, not dedicated deletion authority.
  /// In particular this deliberately permits the already-reserved read branch
  /// after business retirement without readmitting recording or replacing owners.
  private func managedCreationProof(_ controller: M4DeletionResumeController, handle: M4ManagedPhoneResources) async throws -> VerifiedLocalAuthenticationEvidenceV4 {
    try requireManagedDeletionController(controller)
    guard identityChanging == nil, client.trust.environment == .development else { throw AuthorityError.identityChanged }
    try prepared.requirePhoneResources(handle)
    let observed = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: handle.attachment.identityGeneration)
    try requireManagedDeletionController(controller)
    guard let proof = observed, try handle.attachment.matches(proof), proof.binding.role == .phone, !proof.binding.suspended,
          raw(proof.attempt.publicKey, prepared.material.signer.publicKey), raw(proof.binding.deviceID, prepared.seed.installationID) else { throw AuthorityError.identityChanged }
    let credential = try await prepared.material.vault.credential()
    try requireManagedDeletionController(controller); try requireCredential(credential, binding: proof.binding)
    try controller.requireCreationCredential(credentialBytes(credential))
    try await identity.advanceIdentityFence(to: proof.identityGeneration)
    try requireManagedDeletionController(controller)
    let identityValue = try await identity.currentIdentity()
    try requireManagedDeletionController(controller)
    try requireObservation(identityValue, scope: handle.scope, environment: proof.binding.environment)
    let afterCredential = try await prepared.material.vault.credential()
    try requireManagedDeletionController(controller); try requireCredential(afterCredential, binding: proof.binding)
    guard try credentialBytes(credential) == credentialBytes(afterCredential) else { throw AuthorityError.identityChanged }
    try controller.requireCreationCredential(credentialBytes(afterCredential))
    // The last awaited observation is the original SQL source, not an external
    // value that could substitute for its complete signed admission evidence.
    let current = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: proof.identityGeneration)
    try requireManagedDeletionController(controller)
    guard let current, try sameProof(proof, current) else { throw AuthorityError.identityChanged }
    try prepared.requirePhoneResources(handle)
    return current
  }
  private func credentialBytes(_ value: DeviceCredential) throws -> Data {
    try AuthorityWire.encode([value.token, value.sessionID, value.accountID, value.deviceID, value.keyID,
      String(value.activationEpoch), String(value.expiresAt)])
  }
  private func initialDeletionScope() async throws -> CloudScopeV1 {
    guard let controller = managedController, let handle = managedPhoneResources else { throw AuthorityError.unavailable }
    _ = try await managedCreationProof(controller, handle: handle)
    return try CloudScopeV1(accountID: handle.scope.accountID, cloudSpaceID: handle.scope.cloudSpaceID,
      zoneID: handle.scope.zoneID, activationEpoch: handle.scope.activationEpoch)
  }
  private func initialRequest(_ requestID: String, confirmedAt: Int64, scope: CloudScope) throws -> InitialDeletionRequestV1 {
    try InitialDeletionRequestV1(creationID: requestID, originalScope: CloudScopeV1(accountID: scope.accountID,
      cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch),
      cloud: .keep, local: .delete, health: .keep, healthConfirmed: false, confirmedAt: confirmedAt)
  }
  private func descriptorBytes(_ value: InitialDeletionReservationV1) throws -> Data {
    try AuthorityWire.encode([AuthorityWire.encode(value.request).base64EncodedString(), String(value.identityGeneration),
      value.originalAuthRequestID, value.originalAuthReceiptDigest, value.initialAuthRequestID,
      value.initialAuthRequestDigest, value.initialAuthReceiptDigest, value.opaqueReauthenticationID])
  }
  private func creationMetadata(_ descriptor: InitialDeletionReservationV1, scope: CloudScope) throws -> M4DeletionCreationMetadata {
    let request = descriptor.request
    let result = M4DeletionCreationMetadata(version: 1, requestID: request.creationID, scope: scope,
      choices: M4DeletionChoices(cloud: request.cloud, local: request.local, health: request.health, healthConfirmed: request.healthConfirmed),
      firstReauthID: descriptor.opaqueReauthenticationID, authRequestID: descriptor.originalAuthRequestID,
      authReceiptDigest: descriptor.originalAuthReceiptDigest, identityGeneration: descriptor.identityGeneration,
      confirmedAt: request.confirmedAt, dispatch: .reserved)
    try result.validate(); return result
  }
  private func initialContext(controller: M4DeletionResumeController, request: InitialDeletionRequestV1,
    handle: M4ManagedPhoneResources, source: VerifiedLocalAuthenticationEvidenceV4) async throws -> InitialDeletionContextV1? {
    try requireManagedDeletionController(controller); try prepared.requirePhoneResources(handle)
    let context = try await repository.initialDeletionContextV4(creationID: request.creationID, expectedIdentityGeneration: source.identityGeneration)
    try requireManagedDeletionController(controller); try prepared.requirePhoneResources(handle)
    if let context {
      guard try AuthorityWire.encode(context.request) == AuthorityWire.encode(request),
            try sameProof(context.originalAuthentication, source) else { throw AuthorityError.conflict }
    }
    return context
  }
  /// Revalidate already-reserved authority from the original Store snapshot.
  /// This is not the first reservation mutation or a cached service result.
  private func checkedInitialReservation(controller: M4DeletionResumeController, request: InitialDeletionRequestV1,
    handle: M4ManagedPhoneResources) async throws -> InitialDeletionReservationV1 {
    let source = try await managedCreationProof(controller, handle: handle)
    guard let context = try await initialContext(controller: controller, request: request, handle: handle, source: source),
          context.phase == .reserved, let actual = context.reservation,
          try AuthorityWire.encode(actual.request) == AuthorityWire.encode(request),
          actual.identityGeneration == source.identityGeneration, raw(actual.originalAuthRequestID, source.currentAuthRequestID),
          actual.originalAuthReceiptDigest == AuthorityWire.hash(source.receipt.raw) else { throw AuthorityError.intentMismatch }
    // initialContext's original SQL snapshot also verifies the full original
    // authentication and signed selected association; no external await follows.
    try requireManagedDeletionController(controller); try prepared.requirePhoneResources(handle)
    return actual
  }
  private func reservedInitialDeletion(controller: M4DeletionResumeController, request: InitialDeletionRequestV1,
    handle: M4ManagedPhoneResources) async throws -> InitialDeletionReservationV1 {
    try requireManagedDeletionController(controller); try prepared.requirePhoneResources(handle)
    guard let service = initialDeletionService else { throw AuthorityError.unavailable }
    let descriptor = try await service.reserve(creationID: request.creationID, expectedIdentityGeneration: handle.attachment.identityGeneration)
    try requireManagedDeletionController(controller)
    let actual = try await checkedInitialReservation(controller: controller, request: request, handle: handle)
    guard try descriptorBytes(actual) == descriptorBytes(descriptor) else { throw AuthorityError.intentMismatch }
    return actual
  }
  private func requireInitialBusiness(_ controller: M4DeletionResumeController, handle: M4ManagedPhoneResources) throws {
    try requireManagedDeletionController(controller); try requireBusiness(businessLifetime)
    guard context.account.canEnterRecording, admittedScope == handle.scope else { throw AuthorityError.identityChanged }
    try prepared.requirePhoneResources(handle)
  }
  /// A single existing business suboperation owns all fresh/recover/first-reserve
  /// work. Its real return tail exits before the outer create retires business.
  private func authenticateInitialDeletion(controller: M4DeletionResumeController, request: InitialDeletionRequestV1,
    handle: M4ManagedPhoneResources) async throws -> InitialDeletionReservationV1 {
    try requireInitialBusiness(controller, handle: handle)
    guard let service = initialDeletionService else { throw AuthorityError.unavailable }
    let source = try await managedCreationProof(controller, handle: handle)
    let context = try await initialContext(controller: controller, request: request, handle: handle, source: source)
    try requireInitialBusiness(controller, handle: handle)
    var association: InitialDeletionAssociationV1?
    if let context, context.phase == .associated {
      guard context.reservation == nil, let selected = context.association else { throw AuthorityError.intentMismatch }
      association = selected
    } else {
      guard context == nil || context?.phase == .preparing, context?.association == nil, context?.reservation == nil else { throw AuthorityError.intentMismatch }
      let unresolved = context?.attempts.filter { $0.resolution == nil } ?? []
      guard unresolved.count <= 1 else { throw InitialDeletionIssueV1.unresolved }
      let outcome: InitialDeletionAuthenticationOutcomeV1
      if let attempt = unresolved.first {
        if attempt.authentication != nil {
          outcome = try await service.recover(creationID: request.creationID, authRequestID: attempt.authRequestID,
            expectedIdentityGeneration: source.identityGeneration)
        } else {
          outcome = try await service.authenticate(request: request, expectedSource: source,
            authRequestID: attempt.authRequestID, challengeRequestID: attempt.challengeRequestID)
        }
      } else {
        // IDs are chosen only after the actual persistent state was inspected.
        let authID = UUID().uuidString, challengeID = UUID().uuidString
        guard Set([request.creationID, source.currentAuthRequestID, authID, challengeID]).count == 4 else { throw AuthorityError.conflict }
        outcome = try await service.authenticate(request: request, expectedSource: source,
          authRequestID: authID, challengeRequestID: challengeID)
      }
      try requireInitialBusiness(controller, handle: handle)
      switch outcome {
      case .associated(let selected): association = selected
      case .unresolved: throw InitialDeletionIssueV1.unresolved
      case .closed: throw AuthorityError.unavailable
      }
    }
    let after = try await managedCreationProof(controller, handle: handle)
    guard try sameProof(source, after), let association,
          let readback = try await initialContext(controller: controller, request: request, handle: handle, source: after),
          readback.phase == .associated, readback.reservation == nil, let saved = readback.association,
          raw(saved.creationID, request.creationID), raw(saved.authRequestID, association.authRequestID),
          saved.requestDigest == association.requestDigest, saved.receipt.raw == association.receipt.raw,
          saved.opaqueReauthenticationID.map({ Data($0.utf8) }) == association.opaqueReauthenticationID.map({ Data($0.utf8) }) else { throw AuthorityError.intentMismatch }
    try requireInitialBusiness(controller, handle: handle)
    try await controller.observe(.initialAssociated)
    try requireInitialBusiness(controller, handle: handle)
    return try await reservedInitialDeletion(controller: controller, request: request, handle: handle)
  }
  func prepareManagedDeletionCreation(controller: M4DeletionResumeController, requestID: String, confirmedAt: Int64) async throws -> (M4DeletionCreationMetadata, M4ManagedDeletionBorrow) {
    try requireManagedDeletionController(controller)
    guard let handle = managedPhoneResources else { throw AuthorityError.unavailable }
    let request = try initialRequest(requestID, confirmedAt: confirmedAt, scope: handle.scope)
    let source = try await managedCreationProof(controller, handle: handle)
    let originalBorrow = try await prepared.borrowActiveDeletionResources(handle: handle)
    try requireManagedDeletionController(controller); try originalBorrow.verify()
    let prior = try originalBorrow.catalog.deletionCreation()
    if let prior {
      guard raw(prior.requestID, requestID), prior.confirmedAt == confirmedAt else { throw AuthorityError.conflict }
      if prior.dispatch == .started { throw LifecycleClientError.unknownOriginal }
    }
    let context = try await initialContext(controller: controller, request: request, handle: handle, source: source)
    if prior != nil, context?.phase != .reserved { throw AuthorityError.intentMismatch }
    let descriptor: InitialDeletionReservationV1
    if context?.phase == .reserved {
      descriptor = try await reservedInitialDeletion(controller: controller, request: request, handle: handle)
    } else {
      try requireInitialBusiness(controller, handle: handle)
      descriptor = try await ownBusiness {
        try await self.authenticateInitialDeletion(controller: controller, request: request, handle: handle)
      }
    }
    // ownBusiness's defer has now removed its real caller return registration.
    try await controller.observe(.initialReserved)
    let readback = try await checkedInitialReservation(controller: controller, request: request, handle: handle)
    guard try descriptorBytes(descriptor) == descriptorBytes(readback) else { throw AuthorityError.identityChanged }
    let creation = try creationMetadata(readback, scope: handle.scope)
    if let prior { guard try M4CatalogIO.encode(prior) == M4CatalogIO.encode(creation) else { throw AuthorityError.conflict } }
    try await quiesceBusiness()
    try requireManagedDeletionController(controller)
    try await controller.observe(.quiescedBeforeCatalog)
    let borrow = try await prepared.borrowActiveDeletionResources(handle: handle)
    try requireManagedDeletionController(controller); try borrow.verify()
    guard borrow.catalog === originalBorrow.catalog, borrow.ledger === originalBorrow.ledger else { throw AuthorityError.identityChanged }
    let final = try await checkedInitialReservation(controller: controller, request: request, handle: handle)
    guard try descriptorBytes(final) == descriptorBytes(descriptor) else { throw AuthorityError.identityChanged }
    try borrow.verify()
    return (creation, borrow)
  }
  func verifyManagedDeletionCreation(controller: M4DeletionResumeController, proposed: DeletionSagaV4, borrow: M4ManagedDeletionBorrow) async throws {
    try requireManagedDeletionController(controller); try controller.requireBinding(borrow)
    guard controller.isDispatching(proposed.intent.requestID), let handle = managedPhoneResources,
          let creation = try borrow.catalog.deletionCreation(), creation.dispatch == .started,
          raw(creation.requestID, proposed.intent.requestID), proposed.intent.operation == .deleteAccount,
          raw(proposed.intent.fields.reauthenticationID ?? "", creation.firstReauthID),
          proposed.intent.fields.recoveryCapabilityDigest == AuthorityWire.hash(Data(proposed.recoveryCapability.utf8)),
          proposed.cloudChoice == .keep, proposed.localChoice == .delete, proposed.healthChoice == .keep, !proposed.healthConfirmed,
          proposed.originalScope == (try CloudScopeV1(accountID: creation.scope.accountID, cloudSpaceID: creation.scope.cloudSpaceID, zoneID: creation.scope.zoneID, activationEpoch: creation.scope.activationEpoch)),
          raw(proposed.accountID, creation.scope.accountID), proposed.activationEpoch == creation.scope.activationEpoch else { throw AuthorityError.intentMismatch }
    let request = try initialRequest(creation.requestID, confirmedAt: creation.confirmedAt, scope: creation.scope)
    let existing = try await repository.deletionSagaV4(requestID: proposed.intent.requestID)
    try requireManagedDeletionController(controller)
    guard existing == nil else { throw AuthorityError.conflict }
    let descriptor = try await checkedInitialReservation(controller: controller, request: request, handle: handle)
    var expected = try creationMetadata(descriptor, scope: handle.scope); expected.dispatch = .started
    guard try M4CatalogIO.encode(expected) == M4CatalogIO.encode(creation) else { throw AuthorityError.intentMismatch }
    try borrow.verify(); _ = try borrow.catalog.requireOriginalReservation(saga: proposed)
  }
  func revalidateManagedDeletionCreation(controller: M4DeletionResumeController, creation: M4DeletionCreationMetadata, borrow: M4ManagedDeletionBorrow) async throws {
    try requireManagedDeletionBinding(controller: controller, borrow: borrow)
    guard let handle = managedPhoneResources else { throw AuthorityError.identityChanged }
    let request = try initialRequest(creation.requestID, confirmedAt: creation.confirmedAt, scope: creation.scope)
    let descriptor = try await checkedInitialReservation(controller: controller, request: request, handle: handle)
    var expected = try creationMetadata(descriptor, scope: handle.scope); expected.dispatch = creation.dispatch
    guard let actual = try borrow.catalog.deletionCreation(), try M4CatalogIO.encode(actual) == M4CatalogIO.encode(creation),
          try M4CatalogIO.encode(expected) == M4CatalogIO.encode(creation) else { throw AuthorityError.identityChanged }
    try borrow.verify()
  }
  #if DEBUG
  var initialDeletionServiceID: ObjectIdentifier? { initialDeletionService.map(ObjectIdentifier.init) }
  #endif
  /// Actual Store/Session and retained signed provenance, including generation+1
  /// after the original backend acceptance. This never readmits business.
  func verifyManagedDeletionParent(controller: M4DeletionResumeController, saga: DeletionSagaV4, requireFullSeal: Bool = true) async throws -> M4ManagedDeletionBorrow {
    try requireManagedDeletionController(controller)
    let stored = try await repository.deletionSagaV4(requestID: saga.intent.requestID)
    try requireManagedDeletionController(controller)
    guard let stored, try M4CatalogIO.encode(stored) == M4CatalogIO.encode(saga) else { throw AuthorityError.intentMismatch }
    let control = try await repository.lifecycleControlIntentV4(requestID: saga.intent.requestID)
    try requireManagedDeletionController(controller)
    guard control?.canonicalRequest == saga.intent.canonicalRequest else { throw AuthorityError.intentMismatch }
    let identity = await session.syncRepositoryIdentity()
    try requireManagedDeletionController(controller)
    let repositoryIdentity = await repository.syncRepositoryIdentity()
    try requireManagedDeletionController(controller)
    guard identity == repositoryIdentity else { throw AuthorityError.identityChanged }
    let borrow = try await prepared.borrowRetainedDeletionResources(saga: saga)
    try requireManagedDeletionController(controller); try controller.bindManagedBorrow(borrow); try controller.requireBinding(borrow); try borrow.verify()
    let plan = try borrow.catalog.requireOriginalReservation(saga: saga)
    if requireFullSeal {
      guard plan.parentIntentDigest == saga.intent.digest, let seal = plan.fullSeal,
            seal.parentIntentDigest == saga.intent.digest, seal.catalogDigest == plan.catalogDigest,
            seal.health == nil, plan.preparedHealth == nil else { throw AuthorityError.intentMismatch }
    }
    try borrow.verify()
    return borrow
  }
  func managedDeletionCopyDrain(controller: M4DeletionResumeController) throws -> any M4LocalCopyDrainChecking {
    try requireManagedDeletionController(controller)
    guard let controlledAdapters else { throw AuthorityError.unavailable }; return controlledAdapters
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
    var unique = controlOwners
    if let managedController { unique[ObjectIdentifier(managedController)] = M4WeakControlOwner(managedController) }
    let owners = unique.values.compactMap(\.value)
    for owner in owners { try owner.requireExternalCloseCaller() }
    if let finalClosing { return try await finalClosing.value }
    managedControlLifetime = UUID()
    businessStopped = true; businessLifetime = UUID(); lifetime = UUID(); admittedScope = nil
    context.account.stop(); context.lifecycle.stop(); context.recording.beginRetirement()
    let identityChange = identityChanging
    identityChange?.cancel()
    let task = Task {
      try await self.quiesceBusiness()
      _ = await identityChange?.result
      for owner in owners { try await owner.stopAndJoin() }
      try await self.initialDeletionService?.stopAndJoin()
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
      managedController = nil; initialDeletionService = nil
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
  func performLifecycle(_ value: LifecycleUserAction) async throws {
    guard let owner else { throw AuthorityError.identityChanged }; try await owner.performLifecycle(value)
  }
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

/// A narrow service borrower. It never owns/closes a facade, substitutes a
/// receipt, or bypasses the original Session's durable checks/publication.
@MainActor private final class M4NormalCoordinator: AuthorityControlCoordinator, ControlQueueInboundCoordinator, CloudInboundCoordinator {
  weak var owner: M4AccountComposition?
  private let original: MatchSession
  init(owner: M4AccountComposition) { self.owner = owner; original = owner.session }
  private func checked() async throws -> M4AccountComposition {
    guard let owner else { throw AuthorityError.identityChanged }
    _ = try await owner.normalCheckpoint(); return owner
  }
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await original.syncRepositoryIdentity() }
  func prepareAuthorityControl(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4 { try await checked().session.prepareAuthorityControl(intent) }
  func acceptAuthorityResult(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4 { try await checked().session.acceptAuthorityResult(receipt) }
  func acceptLiveLock(_ proof: VerifiedLiveLockV1) async throws { try await checked().session.acceptLiveLock(proof) }
  func prepareNormalTermination(matchID: String, requestID: String) async throws -> ControlIntentV1 { try await checked().session.prepareNormalTermination(matchID: matchID, requestID: requestID) }
  func prepareAbnormalTermination(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4 { throw AuthorityError.unavailable }
  func beginControlAttempt(_ intent: ControlIntentV1, at: Date) async throws { try await checked().session.beginControlAttempt(intent, at: at) }
  func failControlAttempt(_ intent: ControlIntentV1, issue: LifecycleIssueV4, retryable: Bool, at: Date) async throws {
    // Error bookkeeping retains the original pending intent while business close
    // joins this same borrowed service; it cannot create a positive business fact.
    guard let owner else { throw AuthorityError.identityChanged }
    try await owner.session.failControlAttempt(intent, issue: issue, retryable: retryable, at: at)
  }
  func importCloudBatch(_ batch: ValidatedCloudBatchV1) async throws -> CloudImportReceiptV4 { try await checked().session.importCloudBatch(batch) }
  func acceptCloudSave(_ proof: VerifiedCloudSaveV1) async throws -> CloudCheckpointReceiptV4 { try await checked().session.acceptCloudSave(proof) }
  func resetCloudCursor(scope: CloudScopeV1, expectedGeneration: Int64) async throws -> CloudCursorV4 { try await checked().session.resetCloudCursor(scope: scope, expectedGeneration: expectedGeneration) }
  func authorizeCloudHistory(_ grant: VerifiedCloudHistoryGrantV1) async throws { try await checked().session.authorizeCloudHistory(grant) }
}
