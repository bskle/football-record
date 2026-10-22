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
      let retained = try catalog.receipts(requestID: parentID).first(where: { M4CatalogIO.raw($0.componentID, componentID) })
      if let retained { try retained.validate(plan: plan) }
      // This accepted047 constructor cannot create or migrate a restored DB.
      let ledger = try SQLiteCloudLedger(existingLocalErasureURL: URL(fileURLWithPath: capsule.root.path))
      do {
        try capsule.verifyCurrent()
        let request = try CloudLocalTransportEraseRequest(requestID: child.requestID, scope: capsule.scope)
        let receipt: CloudLocalTransportEraseReceipt
        if let retained {
          let expected: CloudLocalTransportEraseReceipt = try M4CatalogIO.decode(retained.canonicalReceipt)
          // Missing internal proof is an error, never permission to re-erase.
          receipt = try await ledger.replayLocalTransportErasure(request, expectedReceipt: expected)
        } else { receipt = try await ledger.eraseLocalTransport(request) }
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

/// Internal controlled seam only. The production default cannot prove that
/// retained transport/control payload directories have drained.
protocol M4LocalCopyDrainChecking: Sendable {
  func assertDrained(scope: CloudScope, requestID: String, parentIntentDigest: String) async throws
}
struct M4UnavailableLocalCopyDrain: M4LocalCopyDrainChecking {
  func assertDrained(scope: CloudScope, requestID: String, parentIntentDigest: String) async throws { throw M4LocalErasureError.unavailable }
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
  let localLeaves: M4LocalTransportLeaves?
  let copyDrain: any M4LocalCopyDrainChecking
  private weak var managedController: M4DeletionResumeController?
  init(composition: M4AccountComposition, catalog: M4OwnedDataCatalog, scope: CloudScope, ledger: any CloudLedger,
       healthArtifacts: M4RetainedHealthArtifactStore? = nil, healthLedger: SQLiteHealthDeletionLedger? = nil,
       allowedHealthSourceOrigin: M4HealthSourceEvidence.Origin = .platformObservation,
       localLeaves: M4LocalTransportLeaves? = nil, copyDrain: any M4LocalCopyDrainChecking = M4UnavailableLocalCopyDrain(), managedController: M4DeletionResumeController? = nil) {
    self.composition = composition; self.catalog = catalog; self.scope = scope; self.ledger = ledger
    self.healthArtifacts = healthArtifacts; self.healthLedger = healthLedger; self.allowedHealthSourceOrigin = allowedHealthSourceOrigin
    self.localLeaves = localLeaves; self.copyDrain = copyDrain
    self.managedController = managedController
  }
  func positiveGate(requireFullSeal: Bool = true) async throws {
    guard try catalog.physicalBootstrap() != nil else { return }
    guard let managedController, let creation = try catalog.deletionCreation(),
          let actual = try await composition.repository.deletionSagaV4(requestID: creation.requestID) else { throw AuthorityError.identityChanged }
    let borrow = try await composition.verifyManagedDeletionParent(controller: managedController, saga: actual, requireFullSeal: requireFullSeal)
    guard borrow.catalog === catalog, let originalLedger = ledger as? SQLiteCloudLedger, borrow.ledger === originalLedger else { throw AuthorityError.identityChanged }
  }
  func intentGate(_ intent: ControlIntentV1) async throws {
    guard try catalog.physicalBootstrap() != nil else { return }
    guard intent.operation == .deleteAccount, let creation = try catalog.deletionCreation(),
          M4CatalogIO.raw(creation.requestID, intent.requestID),
          let actual = try await composition.repository.deletionSagaV4(requestID: intent.requestID),
          actual.intent.canonicalRequest == intent.canonicalRequest else { throw AuthorityError.intentMismatch }
    try await positiveGate()
  }
  func analyticsGate(_ enabled: Bool) async throws {
    guard try catalog.physicalBootstrap() != nil else { return }
    guard !enabled, let managedController, let creation = try catalog.deletionCreation() else { throw AuthorityError.identityChanged }
    try await positiveGate(requireFullSeal: !managedController.isDispatching(creation.requestID))
  }
  func creationCommitted(_ saga: DeletionSagaV4) async throws {
    try await positiveGate(requireFullSeal: false)
    _ = try catalog.requireOriginalReservation(saga: saga)
    try await composition.session.setAnalyticsEnabled(false)
    try await positiveGate(requireFullSeal: false)
    do { try await ledger.recordScopeIssue(scope: scope, issue: .accountChanged, at: Date(), nextAttemptAt: nil) }
    catch let error as CloudError where error.issue == .accountChanged {
      guard try await ledger.scopeState(scope: scope).issue == .accountChanged else { throw error }
    }
    try await positiveGate(requireFullSeal: false)
  }
  func resume(requestID: String) async throws -> DeletionSagaV4 {
    try await positiveGate()
    guard let original = try await composition.repository.deletionSagaV4(requestID: requestID) else { throw LifecycleClientError.unknownOriginal }
    let plan = try catalog.requireOriginalParentSeal(saga: original)
    guard plan.scope == scope else { throw AuthorityError.intentMismatch }
    try await composition.quiesceBusiness()
    try await sameFacade()
    _ = try await rawArtifact(plan)
    // requestDeletion's prior-saga return skips these operations. Restore them
    // idempotently on every original resume, including reopen and generic retry.
    try await positiveGate()
    try await composition.session.setAnalyticsEnabled(false)
    try await positiveGate()
    do { try await ledger.recordScopeIssue(scope: scope, issue: .accountChanged, at: Date(), nextAttemptAt: nil) }
    catch let error as CloudError where error.issue == .accountChanged {
      guard try await ledger.scopeState(scope: scope).issue == .accountChanged else { throw error }
    }
    guard let actual = try await composition.repository.deletionSagaV4(requestID: requestID), actual.intent == original.intent else { throw AuthorityError.intentMismatch }
    _ = try catalog.requireOriginalParentSeal(saga: actual)
    try await positiveGate()
    return actual
  }
  func creation(_ saga: DeletionSagaV4) async throws {
    let managed = try catalog.physicalBootstrap() != nil
    if managed {
      guard let managedController else { throw AuthorityError.identityChanged }
      let borrow = try managedController.creationBorrow()
      guard borrow.catalog === catalog, let originalLedger = ledger as? SQLiteCloudLedger, borrow.ledger === originalLedger else { throw AuthorityError.identityChanged }
      try await composition.verifyManagedDeletionCreation(controller: managedController, proposed: saga, borrow: borrow)
    }
    let plan = try catalog.requireOriginalReservation(saga: saga)
    guard plan.scope == scope else { throw AuthorityError.intentMismatch }
    try await composition.quiesceBusiness(); try await sameFacade(); _ = try await rawArtifact(plan)
    _ = try catalog.requireOriginalReservation(saga: saga)
    if managed {
      guard let managedController else { throw AuthorityError.identityChanged }
      try await composition.verifyManagedDeletionCreation(controller: managedController, proposed: saga, borrow: managedController.creationBorrow())
      try managedController.recordDispatchProposal(saga)
    }
  }
  func parentStored() async throws {
    guard try catalog.physicalBootstrap() != nil else { return }
    guard let managedController else { throw AuthorityError.identityChanged }
    try await managedController.observe(.parentStored)
  }
  func localErase(requestID: String) async throws -> DeletionSagaV4 {
    let original = try await resume(requestID: requestID), plan = try catalog.requireOriginalParentSeal(saga: original)
    if plan.choices.health == .keep { try await localPrerequisites(plan); return original }
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
    try await localPrerequisites(after)
    if actual.localProgress == .completed {
      // Never infer an empty selection from an already-erased Store. Reopen
      // keeps the original raw/prepared/seal and freshly proves this same Store.
      guard let store = after.entries.first(where: { $0.capsule.kind == .businessStore }) else { throw M4LocalErasureError.unsupportedComponent }
      _ = try await composition.localStoreEvidence(capsule: store.capsule, parentID: requestID, parentIntentDigest: try requiredDigest(after), scope: scope)
    } else {
      // quiesceBusiness has joined the real original capture writer. Complete046
      // validates canonical reverse closure, including orphan/diagnostic facts.
      try await composition.validateHealthReservationFacts(raw)
    }
    return actual
  }
  private func localPrerequisites(_ plan: M4FrozenDeletionPlan) async throws {
    guard let leaves = localLeaves, leaves.catalog === catalog else { throw M4LocalErasureError.unsupportedComponent }
    try await copyDrain.assertDrained(scope: scope, requestID: plan.requestID, parentIntentDigest: try requiredDigest(plan))
    try await positiveGate()
    // Every business Store needs its own original facade and same-parent proof.
    // Prove route identities before the first mutating Store entrance.
    let stores = plan.entries.filter { $0.capsule.kind == .businessStore }
    // Multiple facade routes do not prove one original parent/facts provenance.
    // Preserve every Store until such a proof exists; never erase the first and
    // discover the missing second Saga afterwards.
    guard stores.count == 1, let original = stores.first,
          let route = leaves.storeRoutes[original.capsule.componentID], route === composition else { throw M4LocalErasureError.unsupportedComponent }
    try route.validateOriginalStoreCapsule(original.capsule, scope: plan.scope)
  }
  private func requiredDigest(_ plan: M4FrozenDeletionPlan) throws -> String {
    guard let digest = plan.parentIntentDigest else { throw M4LocalErasureError.intentMismatch }; return digest
  }
  func storeCompletion(requestID: String) async throws {
    let original = try await localErase(requestID: requestID), plan = try catalog.requireOriginalParentSeal(saga: original)
    guard original.localChoice == .delete, original.localProgress == .completed,
          let leaves = localLeaves, leaves.catalog === catalog else { throw M4LocalErasureError.unsupportedComponent }
    let stores = plan.entries.filter { $0.capsule.kind == .businessStore }
    guard !stores.isEmpty else { throw M4LocalErasureError.unsupportedComponent }
    // A crash after Store commit and before catalog receipt can reconstruct only
    // this original component using a fresh045 read, never a cached progress bit.
    for entry in stores { _ = try await leaves.erase(componentID: entry.capsule.componentID, parentID: requestID, parentIntentDigest: try requiredDigest(plan)) }
  }
  func purgeLocalCopies(requestID: String, requireFirstReceipts: Bool = false) async throws {
    let original = try await localErase(requestID: requestID), plan = try catalog.requireOriginalParentSeal(saga: original)
    guard original.localProgress == .completed, let leaves = localLeaves, leaves.catalog === catalog else { throw M4LocalErasureError.unsupportedComponent }
    if requireFirstReceipts {
      guard plan.receipts?.count == plan.entries.count else { throw M4LocalErasureError.intentMismatch }
    }
    try await storeCompletion(requestID: requestID)
    for entry in plan.entries where entry.capsule.kind != .businessStore {
      _ = try await leaves.erase(componentID: entry.capsule.componentID, parentID: requestID, parentIntentDigest: try requiredDigest(plan))
    }
    let actual = try await resume(requestID: requestID), after = try catalog.requireOriginalParentSeal(saga: actual)
    guard after.catalogDigest == plan.catalogDigest, after.parentIntentDigest == plan.parentIntentDigest,
          let receipts = after.receipts, receipts.count == after.entries.count else { throw M4LocalErasureError.intentMismatch }
    for receipt in receipts { try receipt.validate(plan: after) }
    try await copyDrain.assertDrained(scope: scope, requestID: requestID, parentIntentDigest: try requiredDigest(after))
  }
  func validateHistoricalLocalCompletion(_ saga: DeletionSagaV4) async throws {
    guard saga.localChoice == .delete else { return }
    if saga.localProgress == .completed { try await storeCompletion(requestID: saga.intent.requestID) }
    if saga.localTransportProgress == .completed { try await purgeLocalCopies(requestID: saga.intent.requestID, requireFirstReceipts: true) }
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
    try await admission.intentGate(intent)
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    try await original.beginControlAttempt(intent, at: at)
    try await admission.intentGate(intent)
  }
  func failControlAttempt(_ intent: ControlIntentV1, issue: LifecycleIssueV4, retryable: Bool, at: Date) async throws {
    // Failure bookkeeping cannot be blocked by a new positive authority veto.
    // The original Session/Store still validates its pending intent/queue.
    try await original.failControlAttempt(intent, issue: issue, retryable: retryable, at: at)
  }
  func prepareLifecycleControl(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4 {
    try await admission.intentGate(intent)
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    let result = try await original.prepareLifecycleControl(intent)
    try await admission.intentGate(intent); return result
  }
  func acceptMigrationCheckpoint(migrationID: String, proof: VerifiedAccountCheckpointV4) async throws {
    guard try admission.catalog.physicalBootstrap() == nil else { throw AuthorityError.unavailable }
    try await original.acceptMigrationCheckpoint(migrationID: migrationID, proof: proof)
  }
  func acceptLifecycleResult(intent: ControlIntentV1, receipt: VerifiedAuthorityReceiptV1) async throws {
    try await admission.intentGate(intent)
    if intent.operation == .deleteAccount { guard try await admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
    try await original.acceptLifecycleResult(intent: intent, receipt: receipt)
    try await admission.intentGate(intent)
  }
  func suspendAccount() async throws {
    guard try admission.catalog.physicalBootstrap() == nil else { throw AuthorityError.unavailable }
    try await original.suspendAccount()
  }
  func createDeletionSaga(_ saga: DeletionSagaV4) async throws {
    try await admission.creation(saga); try await original.createDeletionSaga(saga)
    try await admission.parentStored()
    try await admission.positiveGate(requireFullSeal: false)
  }
  func updateDeletionSaga(_ saga: DeletionSagaV4, expectedRevision: Int64) async throws {
    let prior = try await admission.resume(requestID: saga.intent.requestID)
    if prior.localProgress == .completed { try await admission.storeCompletion(requestID: saga.intent.requestID) }
    if saga.localTransportProgress == .completed { try await admission.purgeLocalCopies(requestID: saga.intent.requestID, requireFirstReceipts: true) }
    if saga.healthProgress == .completed, prior.healthProgress != .completed { try await admission.healthCompletion(requestID: saga.intent.requestID) }
    try await original.updateDeletionSaga(saga, expectedRevision: expectedRevision)
    try await admission.positiveGate()
  }
  func acceptDeletion(requestID: String, receipt: VerifiedAuthorityReceiptV1, expectedRevision: Int64) async throws -> DeletionSagaV4 {
    _ = try await admission.resume(requestID: requestID)
    let result = try await original.acceptDeletion(requestID: requestID, receipt: receipt, expectedRevision: expectedRevision)
    try await admission.positiveGate(); return result
  }
  func eraseLocalBusiness(requestID: String, expectedRevision: Int64) async throws -> DeletionSagaV4 {
    _ = try await admission.localErase(requestID: requestID)
    let erased = try await original.eraseLocalBusiness(requestID: requestID, expectedRevision: expectedRevision)
    try await admission.storeCompletion(requestID: requestID)
    return erased
  }
  func setAnalyticsEnabled(_ enabled: Bool) async throws {
    try await admission.analyticsGate(enabled); try await original.setAnalyticsEnabled(enabled); try await admission.analyticsGate(enabled)
  }
  func enqueueAnalytics(_ event: AnalyticsEventV4) async throws {
    try await admission.positiveGate(); try await original.enqueueAnalytics(event); try await admission.positiveGate()
  }
  func acknowledgeAnalytics(requestID: String) async throws {
    try await admission.positiveGate(); try await original.acknowledgeAnalytics(requestID: requestID); try await admission.positiveGate()
  }
}
struct M4GuardedLocalTransportDeletion: LocalTransportDeletionDriver {
  let admission: M4DeletionAdmission
  func purgeBusinessCopies(_ request: LocalTransportDeletionRequest) async throws {
    let saga = try await admission.localErase(requestID: request.requestID)
    guard saga.intent.digest == request.requestDigest, request.scope == admission.scope else { throw AuthorityError.intentMismatch }
    try await admission.purgeLocalCopies(requestID: request.requestID)
  }
}

private enum M4DeletionOperationContext {
  @TaskLocal static var ownerID: UUID?
}
private enum M4DeletionOperationResult: Sendable {
  case saga(DeletionSagaV4), recovery([DeletionSagaV4]), receipt(VerifiedAuthorityReceiptV1)
}

@MainActor final class M4DeletionResumeController {
  private struct Binding {
    let admission: M4DeletionAdmission
    let service: LifecycleService
    let borrow: M4ManagedDeletionBorrow?
  }
  private let composition: M4AccountComposition
  let controlLifetime: UUID?
  private var binding: Binding?
  private var dispatchParent: Data?
  private var dispatchProposal: DeletionSagaV4?
  // Per-body veto only: never persisted, never used to admit a later retry.
  private var creating = false
  private var creationCredential: Data?
  enum Phase: Equatable { case initialAssociated, initialReserved, quiescedBeforeCatalog, reserved, started, parentStored, requestReturned, beforeFullSeal, sealed, beforeResume, afterResume }
  /// A veto/delay after real stages only; never supplies proof or service output.
  #if DEBUG
  var observation: (@MainActor (Phase) async throws -> Void)?
  #endif
  func observe(_ phase: Phase) async throws {
    #if DEBUG
    try await observation?(phase)
    #endif
  }
  private let operationOwnerID = UUID()
  enum OperationKind: Hashable, Sendable { case create, resume, recover, reconcile }
  enum QueuePhase: Equatable, Sendable { case registered, released, predecessorParked, bodyEntered, bodyJoined, admissionClosed }
  enum ResultCategory: Equatable, Sendable { case success, failure }
  struct QueueEvent: Sendable {
    let phase: QueuePhase
    let operationID: UUID?
    let borrowerID: UUID?
    let kind: OperationKind?
    let borrowerCount: Int
    let predecessorID: UUID?
    let predecessorBorrowerCount: Int?
  }
  struct ReturnTailSnapshot: Sendable {
    let operationID, borrowerID: UUID
    let kind: OperationKind
    let borrowerCount: Int
    let result: ResultCategory
  }
  #if DEBUG
  var queueObservation: (@MainActor (QueueEvent) -> Void)?
  var returnTailObservation: (@MainActor (ReturnTailSnapshot) async -> Void)?
  #endif
  private func emit(_ phase: QueuePhase, gate: DrainGate?, borrowerID: UUID? = nil, kind: OperationKind? = nil,
                    predecessor: DrainGate? = nil) {
    #if DEBUG
    queueObservation?(QueueEvent(phase: phase, operationID: gate?.id, borrowerID: borrowerID, kind: kind,
      borrowerCount: gate?.borrowerCount ?? 0, predecessorID: predecessor?.id, predecessorBorrowerCount: predecessor?.borrowerCount))
    #endif
  }
  @MainActor private final class DrainGate {
    let id = UUID()
    private(set) var bodyFinished = false
    private var borrowers: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var borrowerCount: Int { borrowers.count }
    var isDrained: Bool { bodyFinished && borrowers.isEmpty }
    func registerBorrower() -> UUID {
      precondition(!isDrained)
      let id = UUID(); borrowers.insert(id); return id
    }
    func finishBody() {
      precondition(!bodyFinished); bodyFinished = true; wakeIfDrained()
    }
    func releaseBorrower(_ id: UUID) {
      precondition(borrowers.remove(id) != nil); wakeIfDrained()
    }
    func waitUntilDrained(onPark: @MainActor () -> Void = {}) async {
      if isDrained { return }
      await withCheckedContinuation { continuation in
        waiters.append(continuation); onPark()
      }
    }
    private func wakeIfDrained() {
      guard isDrained else { return }
      let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() }
    }
  }
  private struct Key: Hashable {
    let kind: OperationKind
    let parent: Data
  }
  private final class Operation {
    let id: UUID
    let kind: OperationKind
    let fingerprint: Data
    let task: Task<M4DeletionOperationResult, any Error>
    let join: Task<Void, Never>
    let gate: DrainGate
    init(kind: OperationKind, fingerprint: Data, task: Task<M4DeletionOperationResult, any Error>, join: Task<Void, Never>, gate: DrainGate) {
      id = gate.id; self.kind = kind; self.fingerprint = fingerprint; self.task = task; self.join = join; self.gate = gate
    }
  }
  private var operations: [Key: Operation] = [:]
  private var fifoTail: DrainGate?
  private var stopped = false
  private var stopping: Task<Void, any Error>?
  init(admission: M4DeletionAdmission, cloudDeletion: any CloudAccountDeletionDriver = UnavailableCloudAccountDeletionDriver(), healthDeletion: any AppWorkoutDeletionDriver = UnavailableAppWorkoutDeletionDriver()) {
    composition = admission.composition; controlLifetime = nil
    let service = LifecycleService(client: admission.composition.client, repository: admission.composition.repository,
      coordinator: M4GuardedLifecycleCoordinator(admission: admission), scope: admission.scope, ledger: admission.ledger,
      cloudDeletion: cloudDeletion, healthDeletion: healthDeletion, localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
    binding = Binding(admission: admission, service: service, borrow: nil)
    if !admission.composition.registerControlOwner(self) { stopped = true }
  }
  init(managedComposition: M4AccountComposition, controlLifetime: UUID) {
    composition = managedComposition; self.controlLifetime = controlLifetime
    if !composition.registerControlOwner(self) { stopped = true }
  }
  func bindManagedBorrow(_ borrow: M4ManagedDeletionBorrow) throws {
    try composition.requireManagedDeletionBinding(controller: self, borrow: borrow)
    if binding != nil { try requireBinding(borrow); return }
    let drain = try composition.managedDeletionCopyDrain(controller: self)
    let leaves = M4LocalTransportLeaves(catalog: borrow.catalog, storeRoutes: [borrow.storeCapsule.componentID: composition])
    let admission = M4DeletionAdmission(composition: composition, catalog: borrow.catalog, scope: borrow.attachment.scope,
      ledger: borrow.ledger, localLeaves: leaves, copyDrain: drain, managedController: self)
    let service = LifecycleService(client: composition.client, repository: composition.repository,
      coordinator: M4GuardedLifecycleCoordinator(admission: admission), scope: borrow.attachment.scope, ledger: borrow.ledger,
      localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
    binding = Binding(admission: admission, service: service, borrow: borrow)
  }
  func requireBinding(_ borrow: M4ManagedDeletionBorrow) throws {
    try composition.requireManagedDeletionBinding(controller: self, borrow: borrow)
    guard let original = binding?.borrow, original.catalog === borrow.catalog, original.ledger === borrow.ledger,
          try original.attachment.digest() == borrow.attachment.digest(),
          try M4CatalogIO.encode(original.physical) == M4CatalogIO.encode(borrow.physical),
          try M4CatalogIO.encode(original.seal) == M4CatalogIO.encode(borrow.seal) else { throw AuthorityError.identityChanged }
    try original.verify(); try borrow.verify()
  }
  func requireCreationCredential(_ bytes: Data) throws {
    try requireManagedOperationCaller()
    guard creating else { throw AuthorityError.conflict }
    if let original = creationCredential {
      guard original == bytes else { throw AuthorityError.identityChanged }
    } else { creationCredential = bytes }
  }
  func isDispatching(_ parent: String) -> Bool { dispatchParent == Data(parent.utf8) }
  func creationBorrow() throws -> M4ManagedDeletionBorrow {
    try composition.requireManagedDeletionController(self)
    guard let borrow = binding?.borrow else { throw AuthorityError.identityChanged }
    try requireBinding(borrow); return borrow
  }
  func recordDispatchProposal(_ proposal: DeletionSagaV4) throws {
    guard isDispatching(proposal.intent.requestID), dispatchProposal == nil else { throw AuthorityError.conflict }
    dispatchProposal = proposal
  }
  private func currentBinding() throws -> Binding {
    guard let binding else { throw AuthorityError.unavailable }; return binding
  }
  private func checkedParent(_ requestID: String, full: Bool = true) async throws -> DeletionSagaV4 {
    guard let saga = try await composition.repository.deletionSagaV4(requestID: requestID) else { throw LifecycleClientError.unknownOriginal }
    if controlLifetime != nil {
      _ = try await composition.verifyManagedDeletionParent(controller: self, saga: saga, requireFullSeal: full)
    }
    return saga
  }
  private func enqueue(kind: OperationKind, parent: String, fingerprint: Data = Data(), body: @escaping @MainActor @Sendable () async throws -> M4DeletionOperationResult) async throws -> M4DeletionOperationResult {
    guard !stopped else { throw AuthorityError.identityChanged }
    try requireExternalCloseCaller()
    let key = Key(kind: kind, parent: Data(parent.utf8)), operation: Operation, borrowerID: UUID
    // Deduplicate overlapping borrowers only. A sequential invocation must
    // revalidate current Store/leaf truth even if join cleanup is still queued.
    if let prior = operations[key], prior.gate.borrowerCount > 0 {
      guard prior.fingerprint == fingerprint else { throw AuthorityError.conflict }
      operation = prior
      borrowerID = prior.gate.registerBorrower()
    } else {
      let predecessor = fifoTail, ownerID = operationOwnerID
      let gate = DrainGate()
      borrowerID = gate.registerBorrower()
      let task = Task<M4DeletionOperationResult, any Error> {
        if let predecessor {
          await predecessor.waitUntilDrained {
            self.emit(.predecessorParked, gate: gate, kind: kind, predecessor: predecessor)
          }
        }
        try Task.checkCancellation()
        return try await M4DeletionOperationContext.$ownerID.withValue(ownerID) {
          self.emit(.bodyEntered, gate: gate, kind: kind)
          return try await body()
        }
      }
      let join = Task<Void, Never> {
        _ = await task.result; gate.finishBody(); self.emit(.bodyJoined, gate: gate, kind: kind)
      }
      operation = Operation(kind: kind, fingerprint: fingerprint, task: task, join: join, gate: gate)
      operations[key] = operation; fifoTail = gate
      Task { [weak self, weak operation] in
        await gate.waitUntilDrained()
        guard let self, let operation else { return }
        self.removeFinished(key, operation)
      }
    }
    emit(.registered, gate: operation.gate, borrowerID: borrowerID, kind: kind)
    defer {
      operation.gate.releaseBorrower(borrowerID)
      emit(.released, gate: operation.gate, borrowerID: borrowerID, kind: kind)
      removeFinished(key, operation)
    }
    let task = operation.task
    return try await M4DeletionOperationContext.$ownerID.withValue(operationOwnerID) {
      let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
      #if DEBUG
      let category: ResultCategory = switch outcome { case .success: .success; case .failure: .failure }
      await returnTailObservation?(ReturnTailSnapshot(operationID: operation.id, borrowerID: borrowerID, kind: kind,
        borrowerCount: operation.gate.borrowerCount, result: category))
      #endif
      switch outcome {
      case .success(let result): try Task.checkCancellation(); return result
      case .failure(let error): throw error
      }
    }
  }
  private func removeFinished(_ key: Key, _ operation: Operation) {
    if operation.gate.isDrained, operations[key] === operation { operations[key] = nil }
  }
  private func resumeNow(requestID: String) async throws -> DeletionSagaV4 {
    if controlLifetime != nil { _ = try await checkedParent(requestID) }
    let bound = try currentBinding(), admission = bound.admission, service = bound.service
    let original = try await admission.resume(requestID: requestID)
    try await admission.validateHistoricalLocalCompletion(original); try Task.checkCancellation()
    try await observe(.beforeResume)
    if controlLifetime != nil { _ = try await checkedParent(requestID) }
    let result = try await service.resumeDeletion(requestID: requestID)
    try await admission.validateHistoricalLocalCompletion(result)
    try await observe(.afterResume)
    if controlLifetime != nil { _ = try await checkedParent(requestID) }
    try Task.checkCancellation()
    return result
  }
  func resume(requestID: String) async throws -> DeletionSagaV4 {
    let value = try await enqueue(kind: .resume, parent: requestID) { .saga(try await self.resumeNow(requestID: requestID)) }
    guard case .saga(let saga) = value else { throw AuthorityError.conflict }; return saga
  }
  func recover() async throws -> [DeletionSagaV4] {
    let value = try await enqueue(kind: .recover, parent: "") {
      let originals = try await self.composition.repository.deletionSagasV4()
      var results: [DeletionSagaV4] = []
      for original in originals { results.append(try await self.resumeNow(requestID: original.intent.requestID)) }
      return .recovery(results)
    }
    guard case .recovery(let sagas) = value else { throw AuthorityError.conflict }; return sagas
  }
  func requireExternalCloseCaller() throws {
    guard M4DeletionOperationContext.ownerID != operationOwnerID else { throw AuthorityError.conflict }
  }
  func requireManagedOperationCaller() throws {
    guard M4DeletionOperationContext.ownerID == operationOwnerID else { throw AuthorityError.conflict }
  }
  /// Final-close only. Business quiescence must retain this same control facade
  /// and relay so the original deletion Saga can still recover unknown outcomes.
  func stopAndJoin() async throws {
    try requireExternalCloseCaller()
    if let stopping { return try await stopping.value }
    stopped = true
    emit(.admissionClosed, gate: nil)
    let pending = Array(operations.values)
    pending.forEach { $0.task.cancel() }
    let join = Task<Void, any Error> {
      for operation in pending {
        await operation.join.value
        await operation.gate.waitUntilDrained()
      }
      self.operations.removeAll(); self.fifoTail = nil
    }
    stopping = join
    try await join.value
  }
  func reconcile(_ intent: ControlIntentV1) async throws -> VerifiedAuthorityReceiptV1 {
    let value = try await enqueue(kind: .reconcile, parent: intent.requestID, fingerprint: intent.canonicalRequest) {
      try Task.checkCancellation()
      if self.controlLifetime != nil {
        guard intent.operation == .deleteAccount, try await self.checkedParent(intent.requestID).intent.canonicalRequest == intent.canonicalRequest else { throw AuthorityError.intentMismatch }
      }
      let bound = try self.currentBinding()
      if intent.operation == .deleteAccount { guard try await bound.admission.resume(requestID: intent.requestID).intent == intent else { throw AuthorityError.intentMismatch } }
      let result = try await bound.service.reconcileLifecycle(intent)
      if self.controlLifetime != nil { _ = try await self.checkedParent(intent.requestID) }
      try Task.checkCancellation()
      return .receipt(result)
    }
    guard case .receipt(let receipt) = value else { throw AuthorityError.conflict }; return receipt
  }
  func create(requestID: String, confirmedAt: Int64) async throws -> DeletionSagaV4 {
    let value = try await enqueue(kind: .create, parent: requestID, fingerprint: Data(String(confirmedAt).utf8)) {
      .saga(try await self.createNow(requestID: requestID, confirmedAt: confirmedAt))
    }
    guard case .saga(let saga) = value else { throw AuthorityError.conflict }; return saga
  }
  private func createNow(requestID: String, confirmedAt: Int64) async throws -> DeletionSagaV4 {
    try composition.requireManagedDeletionController(self)
    guard !creating else { throw AuthorityError.conflict }
    creating = true
    defer { creationCredential = nil; creating = false }
    try AuthorityWire.identifier(requestID)
    guard (0...253_402_300_799).contains(confirmedAt) else { throw AuthorityError.invalidWire }
    // Consumed/terminal purpose context must never be consulted before the real
    // original parent. It remains authoritative after source generation changes.
    let actual = try await composition.repository.deletionSagaV4(requestID: requestID)
    try composition.requireManagedDeletionController(self)
    let control = try await composition.repository.lifecycleControlIntentV4(requestID: requestID)
    try composition.requireManagedDeletionController(self)
    if let actual {
      guard control?.canonicalRequest == actual.intent.canonicalRequest else { throw AuthorityError.intentMismatch }
      let original = try await composition.verifyManagedDeletionParent(controller: self, saga: actual, requireFullSeal: false)
      guard let prior = try original.catalog.deletionCreation(), prior.dispatch == .started,
            M4CatalogIO.raw(prior.requestID, requestID), prior.confirmedAt == confirmedAt else { throw AuthorityError.conflict }
      return try await sealCreation(actual)
    }
    guard control == nil else { throw AuthorityError.conflict }
    let otherParents = try await composition.repository.deletionSagasV4()
    try composition.requireManagedDeletionController(self)
    guard otherParents.isEmpty else { throw AuthorityError.conflict }
    if let borrow = binding?.borrow, let prior = try borrow.catalog.deletionCreation(), prior.dispatch == .started {
      guard M4CatalogIO.raw(prior.requestID, requestID), prior.confirmedAt == confirmedAt else { throw AuthorityError.conflict }
      // A started dispatch can only reuse actual original Store bytes. Its
      // absence remains unknown, regardless of the prior caller's outcome.
      let actual = try await checkedParent(requestID, full: false)
      return try await sealCreation(actual)
    }
    let (creation, borrow) = try await composition.prepareManagedDeletionCreation(controller: self, requestID: requestID, confirmedAt: confirmedAt)
    try bindManagedBorrow(borrow)
    _ = try borrow.catalog.reserveManagedDeletion(creation: creation, borrow: borrow, health: .empty)
    guard let saved = try borrow.catalog.deletionCreation(), try M4CatalogIO.encode(saved) == M4CatalogIO.encode(creation) else { throw M4CatalogError.storageBlocked }
    try await observe(.reserved)
    try await composition.revalidateManagedDeletionCreation(controller: self, creation: creation, borrow: borrow)
    let started = try borrow.catalog.markManagedDeletionStarted(requestID: requestID, borrow: borrow)
    var expected = creation; expected.dispatch = .started
    guard try M4CatalogIO.encode(started) == M4CatalogIO.encode(expected) else { throw M4CatalogError.storageBlocked }
    try await observe(.started)
    try await composition.revalidateManagedDeletionCreation(controller: self, creation: started, borrow: borrow)
    let bound = try currentBinding()
    dispatchParent = Data(requestID.utf8); dispatchProposal = nil
    let outcome: Result<DeletionSagaV4, any Error>
    do {
      outcome = .success(try await bound.service.requestDeletion(requestID: requestID, reauthenticationID: started.firstReauthID,
        cloud: .keep, local: .delete, health: .keep, healthConfirmed: false))
    } catch { outcome = .failure(error) }
    let proposed = dispatchProposal; dispatchParent = nil; dispatchProposal = nil
    // Read-only outcome inspection is deliberately unconditional, even after
    // cancellation/close. No positive seal can pass the subsequent live gate.
    let committed = try await composition.repository.deletionSagaV4(requestID: requestID)
    let committedControl = try await composition.repository.lifecycleControlIntentV4(requestID: requestID)
    guard let actual = committed else {
      if case .failure(let error) = outcome { throw error }
      throw LifecycleClientError.unknownOriginal
    }
    guard let proposed, actual.intent.canonicalRequest == proposed.intent.canonicalRequest,
          Data(actual.recoveryCapability.utf8) == Data(proposed.recoveryCapability.utf8),
          committedControl?.canonicalRequest == actual.intent.canonicalRequest else { throw AuthorityError.intentMismatch }
    if case .success(let result) = outcome {
      guard result.intent.canonicalRequest == actual.intent.canonicalRequest,
            Data(result.recoveryCapability.utf8) == Data(actual.recoveryCapability.utf8) else { throw AuthorityError.intentMismatch }
    }
    try await observe(.requestReturned)
    return try await sealCreation(actual)
  }
  private func sealCreation(_ saga: DeletionSagaV4) async throws -> DeletionSagaV4 {
    let borrow = try await composition.verifyManagedDeletionParent(controller: self, saga: saga, requireFullSeal: false)
    let bound = try currentBinding()
    try await bound.admission.creationCommitted(saga)
    try borrow.verify(); _ = try borrow.catalog.seal(requestID: saga.intent.requestID, parentIntentDigest: saga.intent.digest)
    try borrow.verify(); try await observe(.beforeFullSeal)
    _ = try await composition.verifyManagedDeletionParent(controller: self, saga: saga, requireFullSeal: false)
    try borrow.verify(); try borrow.catalog.sealFullControls(saga: saga); try borrow.verify()
    try await observe(.sealed)
    return try await checkedParent(saga.intent.requestID)
  }
  #if DEBUG
  struct Snapshot {
    let dispatch: M4DeletionCreationMetadata.Dispatch
    let parentDigest: String?
    let fullSealDigest: String?
    let entryCount: Int
    let receiptCount: Int
    let catalogID, ledgerID: ObjectIdentifier
  }
  func snapshot() throws -> Snapshot {
    guard let borrow = binding?.borrow, let creation = try borrow.catalog.deletionCreation(),
          let plan = try borrow.catalog.plan(requestID: creation.requestID) else { throw AuthorityError.unavailable }
    return Snapshot(dispatch: creation.dispatch, parentDigest: plan.parentIntentDigest, fullSealDigest: plan.fullSeal?.parentIntentDigest,
      entryCount: plan.entries.count, receiptCount: plan.receipts?.count ?? 0, catalogID: ObjectIdentifier(borrow.catalog), ledgerID: ObjectIdentifier(borrow.ledger))
  }
  #endif
}
