import Foundation
import CloudSync
import DeviceSync
import MatchStore
import MatchSession
import AccountKit
import HealthKitDeletion

/// A component result only. The aggregate must separately establish the original
/// Store proof, full seal and every required component before reporting success.
enum M4LocalErasureError: Error, Equatable {
  case unavailable, intentMismatch, pendingTransfer, unsupportedComponent
}
struct M4LocalTransportLeaves: Sendable {
  let catalog: M4OwnedDataCatalog
  let stagingControls: [String: URL]
  let storeRoutes: [String: M4AccountComposition]
  let deviceDriver: any DeviceSyncErasureDriving
  init(catalog: M4OwnedDataCatalog, stagingControls: [String: URL] = [:], deviceDriver: any DeviceSyncErasureDriving = UnavailableDeviceSyncErasureDriver(), storeRoutes: [String: M4AccountComposition] = [:]) {
    self.catalog = catalog; self.stagingControls = stagingControls; self.deviceDriver = deviceDriver; self.storeRoutes = storeRoutes
  }
  func erase(componentID: String, parentID: String, parentIntentDigest: String) async throws -> M4RetainedLeafReceipt {
    let (plan, capsule, child) = try admitted(componentID, parentID, parentIntentDigest)
    let payload: Data, digest: String
    switch capsule.kind {
    case .cloudStaging:
      guard capsule.root.directory, let control = stagingControls[componentID] else { throw M4LocalErasureError.intentMismatch }
      // Explicit routing only: all three original coordination inodes must be
      // part of this capsule before any constructor could create a file.
      for required in [control, URL(fileURLWithPath: control.path + ".owner"), URL(fileURLWithPath: capsule.root.path + ".owner")] {
        guard capsule.retainedControls.contains(where: { M4CatalogIO.raw($0.path, M4CatalogIO.canonical(required).path) }) else { throw M4LocalErasureError.intentMismatch }
        let anchor = try M4CatalogIO.anchor(required)
        guard try capsule.retainedControls.contains(where: { try M4CatalogIO.encode($0) == M4CatalogIO.encode(anchor) }) else { throw M4LocalErasureError.intentMismatch }
      }
      let staging = try CloudOwnedStaging(rootURL: URL(fileURLWithPath: capsule.root.path), controlURL: control)
      defer { try? staging.close() }
      let receipt = try staging.erase(CloudStagingEraseRequest(requestID: child.requestID, requestDigest: parentIntentDigest, scope: capsule.scope))
      payload = try M4CatalogIO.encode(M4StagingCompletionEvidence(receipt)); digest = receipt.requestDigest
      try staging.close()
    case .deviceSync:
      guard capsule.root.directory else { throw M4LocalErasureError.intentMismatch }
      let root = URL(fileURLWithPath: capsule.root.path)
      for required in [root.appendingPathComponent(".control/.owner"), root.appendingPathComponent(".control/control.sqlite")] {
        guard capsule.retainedControls.contains(where: { M4CatalogIO.raw($0.path, M4CatalogIO.canonical(required).path) }) else { throw M4LocalErasureError.intentMismatch }
        let anchor = try M4CatalogIO.anchor(required)
        guard try capsule.retainedControls.contains(where: { try M4CatalogIO.encode($0) == M4CatalogIO.encode(anchor) }) else { throw M4LocalErasureError.intentMismatch }
      }
      let context = try DeviceSyncStorageContext(root: root)
      // Never bind on erase/reopen. The original capsule must already have been
      // bound while fresh; the leaf checks its retained original owner/request.
      let request = try DeviceSyncLocalEraseRequest(binding: capsule.deviceBinding(), requestID: parentID, requestDigest: parentIntentDigest)
      guard case .completed(let receipt) = try await DeviceSyncErasureService(context: context, driver: deviceDriver).erase(request) else { throw M4LocalErasureError.pendingTransfer }
      payload = try M4CatalogIO.encode(receipt); digest = receipt.intentDigest
    case .cloudLedger:
      guard !capsule.root.directory else { throw M4LocalErasureError.intentMismatch }
      let ledger = try SQLiteCloudLedger(url: URL(fileURLWithPath: capsule.root.path))
      do {
        try capsule.verifyCurrent()
        // Always invoke the concrete leaf, including cached receipt replay. Its
        // current all-epoch canonical inventory is the authority for this read.
        let receipt = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID: child.requestID, scope: capsule.scope))
        payload = try M4CatalogIO.encode(receipt); digest = receipt.requestDigest
        try await ledger.close()
      } catch { try? await ledger.close(); throw error }
    case .businessStore:
      guard let original = storeRoutes[componentID] else { throw M4LocalErasureError.unsupportedComponent }
      let proof = try await original.localStoreEvidence(capsule: capsule, parentID: parentID, parentIntentDigest: parentIntentDigest, scope: plan.scope)
      payload = try M4CatalogIO.encode(proof); digest = M4CatalogIO.hash(payload)
    }
    _ = try admitted(componentID, parentID, parentIntentDigest)
    let receipt = try M4RetainedLeafReceipt.capture(plan: plan, componentID: componentID, leafDigest: digest, canonicalReceipt: payload)
    try catalog.saveReceipt(receipt)
    guard let retained = try catalog.receipts(requestID: parentID).first(where: { M4CatalogIO.raw($0.componentID, componentID) }),
          try M4CatalogIO.encode(retained) == M4CatalogIO.encode(receipt) else { throw M4LocalErasureError.intentMismatch }
    return retained
  }
  private func admitted(_ componentID: String, _ parentID: String, _ digest: String) throws -> (M4FrozenDeletionPlan, M4OwnershipCapsule, M4CatalogChild) {
    guard let plan = try catalog.plan(requestID: parentID), plan.choices.local == .delete, plan.parentIntentDigest == digest,
          let entry = plan.entries.first(where: { M4CatalogIO.raw($0.capsule.componentID, componentID) }),
          let child = plan.children.first(where: { M4CatalogIO.raw($0.componentID, componentID) }) else { throw M4LocalErasureError.intentMismatch }
    try catalog.preflightErasure(requestID: parentID)
    try entry.capsule.verifyCurrent()
    return (plan, entry.capsule, child)
  }

}

/// One original Session/facade. This guard is also used by direct coordinator
/// entrances so bypassing a UI resume helper cannot bypass erasure admission.
@MainActor final class M4DeletionAdmission {
  let composition: M4AccountComposition
  let catalog: M4OwnedDataCatalog
  let scope: CloudScope
  let ledger: any CloudLedger
  let healthArtifacts: M4RetainedHealthArtifactStore?
  let healthLedger: SQLiteHealthDeletionLedger?
  let allowedHealthSourceOrigin: M4HealthSourceEvidence.Origin
  init(composition: M4AccountComposition, catalog: M4OwnedDataCatalog, scope: CloudScope, ledger: any CloudLedger,
       healthArtifacts: M4RetainedHealthArtifactStore? = nil, healthLedger: SQLiteHealthDeletionLedger? = nil,
       allowedHealthSourceOrigin: M4HealthSourceEvidence.Origin = .platformObservation) {
    self.composition = composition; self.catalog = catalog; self.scope = scope; self.ledger = ledger
    self.healthArtifacts = healthArtifacts; self.healthLedger = healthLedger; self.allowedHealthSourceOrigin = allowedHealthSourceOrigin
  }
  func resume(requestID: String) async throws -> DeletionSagaV4 {
    guard let original = try await composition.repository.deletionSagaV4(requestID: requestID) else { throw LifecycleClientError.unknownOriginal }
    let plan = try catalog.requireOriginalParentSeal(saga: original)
    guard plan.scope == scope else { throw AuthorityError.intentMismatch }
    try await composition.quiesceBusiness()
    try await sameFacade()
    _ = try await rawArtifact(plan)
    // requestDeletion's prior-saga return skips these operations. Restore them
    // idempotently on every original resume, including reopen and generic retry.
    try await composition.session.setAnalyticsEnabled(false)
    do { try await ledger.recordScopeIssue(scope: scope, issue: .accountChanged, at: Date(), nextAttemptAt: nil) }
    catch let error as CloudError where error.issue == .accountChanged {
      guard try await ledger.scopeState(scope: scope).issue == .accountChanged else { throw error }
    }
    guard let actual = try await composition.repository.deletionSagaV4(requestID: requestID), actual.intent == original.intent else { throw AuthorityError.intentMismatch }
    _ = try catalog.requireOriginalParentSeal(saga: actual)
    return actual
  }
  func creation(_ saga: DeletionSagaV4) async throws {
    let plan = try catalog.requireOriginalReservation(saga: saga)
    guard plan.scope == scope else { throw AuthorityError.intentMismatch }
    try await composition.quiesceBusiness(); try await sameFacade(); _ = try await rawArtifact(plan)
    _ = try catalog.requireOriginalReservation(saga: saga)
  }
  func localErase(requestID: String) async throws -> DeletionSagaV4 {
    let original = try await resume(requestID: requestID), plan = try catalog.requireOriginalParentSeal(saga: original)
    if plan.choices.health == .keep { return original }
    if let issue = plan.health.issue {
      switch issue {
      case .missingMapping: throw M4HealthBridgeError.missingMapping
      case .sourceUnavailable: throw M4HealthBridgeError.sourceUnavailable
      case .unsupportedSelection: throw M4HealthBridgeError.unsupportedSelection
      }
    }
    guard let artifacts = healthArtifacts, let ledger = healthLedger, let reference = plan.preparedHealth,
          let expectedSeal = plan.fullSeal?.health, let raw = try await rawArtifact(plan),
          let prepared = try await artifacts.readPrepared(parentID: requestID),
          let actualSeal = try await artifacts.readFullSeal(parentID: requestID) else { throw M4HealthBridgeError.unsealed }
    guard try prepared.canonicalBytes() == M4HealthPreparedMapping(reservation: raw, parentDigest: original.intent.digest).canonicalBytes(),
          M4CatalogIO.hash(try prepared.canonicalBytes()) == reference.preparedDigest,
          reference.selection.requestID == prepared.request.requestID,
          reference.selection.confirmationID == prepared.confirmation.confirmationID,
          reference.selection.selectionDigest == prepared.confirmation.selectionDigest,
          try M4CatalogIO.encode(actualSeal) == M4CatalogIO.encode(expectedSeal) else { throw M4HealthBridgeError.identityConflict }
    let entry = try await ledger.entry(prepared.request.requestID)
    guard try entry.request.canonicalBytes() == prepared.request.canonicalBytes(),
          entry.selectionDigest == prepared.confirmation.selectionDigest,
          try entry.confirmation.map(M4CatalogIO.encode) == M4CatalogIO.encode(prepared.confirmation) else { throw M4HealthBridgeError.identityConflict }
    let actual = try await resume(requestID: requestID), after = try catalog.requireOriginalParentSeal(saga: actual)
    guard try M4CatalogIO.encode(after.fullSeal) == M4CatalogIO.encode(plan.fullSeal),
          try M4CatalogIO.encode(after.preparedHealth) == M4CatalogIO.encode(plan.preparedHealth) else { throw M4HealthBridgeError.identityConflict }
    return actual
  }
  func healthCompletion(requestID: String) async throws {
    _ = try await localErase(requestID: requestID)
    guard let ledger = healthLedger, let reference = try catalog.plan(requestID: requestID)?.preparedHealth else { throw M4HealthBridgeError.unsealed }
    let entry = try await ledger.entry(reference.selection.requestID)
    guard entry.phase == .succeededLocally, let receipt = entry.receipt,
          receipt.requestID == reference.selection.requestID, receipt.selectionDigest == reference.selection.selectionDigest,
          receipt.attemptID == entry.attemptID, receipt.deletedObjectCount >= 0,
          receipt.deletedObjectCount <= entry.request.targets.count else { throw M4HealthBridgeError.deletionFailed }
  }
  private func sameFacade() async throws {
    let repository = composition.repository, identity = await repository.syncRepositoryIdentity()
    guard await composition.session.syncRepositoryIdentity() == identity,
          let binding = try await repository.accountBindingV4(), binding.environment == composition.client.trust.environment,
          M4CatalogIO.raw(binding.accountID, scope.accountID), M4CatalogIO.raw(binding.cloudSpaceID, scope.cloudSpaceID),
          binding.activationEpoch == scope.activationEpoch else { throw AuthorityError.identityChanged }
  }
  private func rawArtifact(_ plan: M4FrozenDeletionPlan) async throws -> M4HealthRawReservation? {
    guard let digest = plan.health.rawArtifactDigest else { return nil }
    guard let artifacts = healthArtifacts, let raw = try await artifacts.readReservation(parentID: plan.requestID),
          try raw.digest() == digest, M4CatalogIO.raw(raw.parentID, plan.requestID),
          raw.scope == (try CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)),
          raw.cloud == plan.choices.cloud, raw.local == plan.choices.local, raw.health == plan.choices.health,
          raw.healthConfirmed == plan.choices.healthConfirmed, !raw.sources.isEmpty,
          raw.sources.allSatisfy({ $0.origin == allowedHealthSourceOrigin }) else { throw M4HealthBridgeError.missingMapping }
    return raw
  }
}
struct M4GuardedLifecycleCoordinator: LifecycleInboundCoordinator, ControlQueueInboundCoordinator {
  let original: MatchSession
  let admission: M4DeletionAdmission
  @MainActor init(admission: M4DeletionAdmission) { self.admission = admission; original = admission.composition.session }
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await original.syncRepositoryIdentity() }
  func beginControlAttempt(_ intent: ControlIntentV1, at: Date) async throws {
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    try await original.beginControlAttempt(intent, at: at)
  }
  func failControlAttempt(_ intent: ControlIntentV1, issue: LifecycleIssueV4, retryable: Bool, at: Date) async throws {
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    try await original.failControlAttempt(intent, issue: issue, retryable: retryable, at: at)
  }
  func prepareLifecycleControl(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4 {
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    return try await original.prepareLifecycleControl(intent)
  }
  func acceptMigrationCheckpoint(migrationID: String, proof: VerifiedAccountCheckpointV4) async throws { try await original.acceptMigrationCheckpoint(migrationID: migrationID, proof: proof) }
  func acceptLifecycleResult(intent: ControlIntentV1, receipt: VerifiedAuthorityReceiptV1) async throws {
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    try await original.acceptLifecycleResult(intent: intent, receipt: receipt)
  }
  func suspendAccount() async throws { try await original.suspendAccount() }
  func createDeletionSaga(_ saga: DeletionSagaV4) async throws { try await admission.creation(saga); try await original.createDeletionSaga(saga) }
  func updateDeletionSaga(_ saga: DeletionSagaV4, expectedRevision: Int64) async throws {
    let prior = try await admission.resume(requestID: saga.intent.requestID)
    if saga.localTransportProgress == .completed, prior.localTransportProgress != .completed { throw M4LocalErasureError.unsupportedComponent }
    if saga.healthProgress == .completed, prior.healthProgress != .completed { try await admission.healthCompletion(requestID: saga.intent.requestID) }
    try await original.updateDeletionSaga(saga, expectedRevision: expectedRevision)
  }
  func acceptDeletion(requestID: String, receipt: VerifiedAuthorityReceiptV1, expectedRevision: Int64) async throws -> DeletionSagaV4 { _ = try await admission.resume(requestID: requestID); return try await original.acceptDeletion(requestID: requestID, receipt: receipt, expectedRevision: expectedRevision) }
  func eraseLocalBusiness(requestID: String, expectedRevision: Int64) async throws -> DeletionSagaV4 { _ = try await admission.localErase(requestID: requestID); return try await original.eraseLocalBusiness(requestID: requestID, expectedRevision: expectedRevision) }
  func setAnalyticsEnabled(_ enabled: Bool) async throws { try await original.setAnalyticsEnabled(enabled) }
  func enqueueAnalytics(_ event: AnalyticsEventV4) async throws { try await original.enqueueAnalytics(event) }
  func acknowledgeAnalytics(requestID: String) async throws { try await original.acknowledgeAnalytics(requestID: requestID) }
}
struct M4GuardedLocalTransportDeletion: LocalTransportDeletionDriver {
  let admission: M4DeletionAdmission
  func purgeBusinessCopies(_ request: LocalTransportDeletionRequest) async throws {
    let saga = try await admission.localErase(requestID: request.requestID)
    guard saga.intent.digest == request.requestDigest, request.scope == admission.scope else { throw AuthorityError.intentMismatch }
    // 044/045 current-zero aggregate dependencies are not accepted yet.
    throw M4LocalErasureError.unsupportedComponent
  }
}

@MainActor final class M4DeletionResumeController {
  private let admission: M4DeletionAdmission
  private let service: LifecycleService
  private var running: [Data: Task<DeletionSagaV4, any Error>] = [:]
  init(admission: M4DeletionAdmission, cloudDeletion: any CloudAccountDeletionDriver = UnavailableCloudAccountDeletionDriver(), healthDeletion: any AppWorkoutDeletionDriver = UnavailableAppWorkoutDeletionDriver()) {
    self.admission = admission
    service = LifecycleService(client: admission.composition.client, repository: admission.composition.repository,
      coordinator: M4GuardedLifecycleCoordinator(admission: admission), scope: admission.scope, ledger: admission.ledger,
      cloudDeletion: cloudDeletion, healthDeletion: healthDeletion, localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
  }
  func resume(requestID: String) async throws -> DeletionSagaV4 {
    let key = Data(requestID.utf8)
    if let prior = running[key] { return try await prior.value }
    let admission = admission, service = service
    let task = Task {
      _ = try await admission.resume(requestID: requestID); try Task.checkCancellation()
      return try await service.resumeDeletion(requestID: requestID)
    }
    running[key] = task; defer { running[key] = nil }
    return try await task.value
  }
  func recover() async throws -> [DeletionSagaV4] {
    let originals = try await admission.composition.repository.deletionSagasV4()
    var results: [DeletionSagaV4] = []
    for original in originals { results.append(try await resume(requestID: original.intent.requestID)) }
    return results
  }
  func reconcile(_ intent: ControlIntentV1) async throws -> VerifiedAuthorityReceiptV1 {
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    return try await service.reconcileLifecycle(intent)
  }
}
