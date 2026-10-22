import Foundation
import Darwin
import AccountKit
import MatchStore
import MatchSession
import CloudSync
#if DEBUG
import MatchPresentation
#endif

enum M4BootstrapError: Error, Equatable {
  case invalidNamespace, identityUnavailable, foreignNamespace, storageUnavailable
  case leaseInUse, alreadyOpened, closed
}
struct M4IdentitySeed: Sendable {
  let root, namespaceDirectory, controlDirectory, businessDatabaseURL: URL
  let namespace, installationID: String
  let businessExisted: Bool
}
/// Protocol fixtures or a later approved original vault supply this material.
/// This bootstrap never constructs a real SDK store or generates a signing key.
struct M4IdentityMaterial: Sendable {
  let signer: any DeviceProofSigner
  let vault: any DeviceCredentialVault
}
enum M4ResourceCrashPoint: Sendable { case afterReservation, afterResourceRename, afterBusinessRename, afterLedgerReservation, afterLedgerRename, afterLedgerInitialization, afterPairSeal }

/// Unserializable provenance borrow from one live original physical owner.
/// It grants reservation validation only, never business or deletion authority.
@MainActor final class M4ManagedDeletionBorrow {
  let catalog: M4OwnedDataCatalog
  let physical: M4PhysicalResourceReservation
  let attachment: M4PhoneScopeAttachment
  let seal: M4PhonePairSeal
  let storeCapsule, ledgerCapsule: M4OwnershipCapsule
  let ledger: SQLiteCloudLedger
  let active: Bool
  private let physicalBytes, phoneBytes, entriesBytes: Data
  private let verifyOriginal: @MainActor () throws -> Void
  fileprivate init(catalog: M4OwnedDataCatalog, physical: M4PhysicalResourceReservation, phone: M4PhoneResourceState,
    handle: M4ManagedPhoneResources, entries: [M4CatalogEntry], active: Bool, verifyOriginal: @escaping @MainActor () throws -> Void) throws {
    self.catalog = catalog; self.physical = physical; attachment = handle.attachment; seal = handle.seal
    storeCapsule = handle.storeCapsule; ledgerCapsule = handle.ledgerCapsule; ledger = handle.ledger; self.active = active
    physicalBytes = try M4CatalogIO.encode(physical); phoneBytes = try M4CatalogIO.encode(phone); entriesBytes = try M4CatalogIO.encode(entries)
    self.verifyOriginal = verifyOriginal
  }
  func verify() throws { try verifyOriginal() }
  /// Pure comparison against the transaction's supplied state. Never call the
  /// verifier, catalog, SQLite, a clock or an observer from this method.
  func requireCapturedState(_ state: M4CatalogState) throws {
    guard let physical = state.physicalBootstrap, physical.resourcesPublished, physical.businessPublished, physical.watch == nil,
          let phone = physical.phone, phone.published, phone.seal != nil,
          try M4CatalogIO.encode(physical.reservation) == physicalBytes, try M4CatalogIO.encode(phone) == phoneBytes,
          try M4CatalogIO.encode(state.entries) == entriesBytes else { throw M4CatalogError.identityChanged }
  }
}

@MainActor final class M4PreparedIdentity {
  let seed: M4IdentitySeed
  let material: M4IdentityMaterial
  private let lease: M4NamespaceLease
  private var repository: SQLiteSessionRepository?
  private var resources: M4PhysicalResourceOwner?
  private var managedResourcesRequired = false
  private var authorityTrust: AuthorityTrustConfiguration?
  private var resourceReplyGate: (@MainActor () async -> Void)?
  private var closing = false
  private var closed = false
  fileprivate init(seed: M4IdentitySeed, material: M4IdentityMaterial, lease: M4NamespaceLease) {
    self.seed = seed; self.material = material; self.lease = lease
  }
  func prepareManagedResources(crashHook: ((M4ResourceCrashPoint) throws -> Void)? = nil, resourceReplyGate: (@MainActor () async -> Void)? = nil) throws {
    guard !closed, repository == nil, resources == nil else { throw M4BootstrapError.alreadyOpened }
    try lease.verifyIdentity()
    managedResourcesRequired = true
    self.resourceReplyGate = resourceReplyGate
    resources = try M4PhysicalResourceOwner(seed: seed, keyID: AuthorityWire.deviceKeyID(publicKey: material.signer.publicKey), crashHook: crashHook)
  }
  func openRepository(authorityTrust: AuthorityTrustConfiguration? = nil, cloudSavePolicy: CloudSaveProofPolicy = .unavailable) throws -> SQLiteSessionRepository {
    guard !closed else { throw M4BootstrapError.closed }
    guard repository == nil else { throw M4BootstrapError.alreadyOpened }
    guard !managedResourcesRequired || resources != nil else { throw M4BootstrapError.identityUnavailable }
    try lease.verifyIdentity()
    try resources?.verify()
    let value = try SQLiteSessionRepository(rootDirectory: seed.root, databaseNamespace: seed.namespace, authorityTrust: authorityTrust, cloudSavePolicy: cloudSavePolicy)
    repository = value; self.authorityTrust = authorityTrust
    try resources?.verify()
    return value
  }
  func requireUnboundResources() throws {
    guard !closed, !closing, let resources else { throw AuthorityError.unavailable }
    try lease.verifyIdentity(); try resources.verify()
    guard try resources.catalog.phoneResources() == nil, try resources.catalog.watchResources() == nil, try resources.catalog.index().entries.isEmpty else { throw AuthorityError.unavailable }
  }
  func activePhoneAttachment() throws -> M4PhoneScopeAttachment? {
    guard !closed, !closing, let resources else { throw AuthorityError.unavailable }
    try lease.verifyIdentity(); return try resources.catalog.phoneResources()?.attachment
  }
  func prepareCurrentPhoneResources(expectedIdentityGeneration: Int64, observed: M4CurrentAccountIdentity) async throws -> M4ManagedPhoneResources {
    guard !closed, !closing, let repository, let resources, let trust = authorityTrust else { throw AuthorityError.unavailable }
    try lease.verifyIdentity()
    guard let proof = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration),
          proof.binding.role == .phone else { throw AuthorityError.unavailable }
    guard !closed, !closing, proof.attempt.publicKey == material.signer.publicKey,
          M4CatalogIO.raw(proof.binding.deviceID, seed.installationID),
          M4CatalogIO.raw(proof.binding.accountID, observed.accountID), M4CatalogIO.raw(proof.binding.cloudSpaceID, observed.cloudSpaceID),
          proof.binding.environment == observed.environment, observed.environment == trust.environment else { throw AuthorityError.identityChanged }
    let handle = try resources.preparePhone(proof: proof, observed: observed, trust: trust)
    // A test/observation boundary outside every catalog/SQLite critical section.
    await resourceReplyGate?()
    guard !closed, !closing, let current = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration),
          try handle.attachment.matches(current), !closed, !closing else { throw AuthorityError.identityChanged }
    try requirePhoneResources(handle)
    return handle
  }
  func requirePhoneResources(_ handle: M4ManagedPhoneResources) throws {
    guard !closed, !closing, let resources else { throw AuthorityError.identityChanged }
    try lease.verifyIdentity(); try resources.verify()
    guard try M4CatalogIO.encode(resources.catalog.requirePhoneSeal()) == M4CatalogIO.encode(handle.seal),
          let original = try resources.catalog.phoneResources(), try original.attachment.digest() == handle.attachment.digest() else { throw AuthorityError.identityChanged }
  }
  func borrowActiveDeletionResources(handle: M4ManagedPhoneResources) async throws -> M4ManagedDeletionBorrow {
    guard !closed, !closing, let repository, let resources, let trust = authorityTrust else { throw AuthorityError.unavailable }
    try lease.verifyIdentity(); try resources.requireCachedPhone(handle, trust: trust)
    let generation = handle.attachment.identityGeneration
    guard let proof = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation),
          try handle.attachment.matches(proof), M4CatalogIO.raw(proof.attempt.publicKey, material.signer.publicKey),
          M4CatalogIO.raw(proof.binding.deviceID, seed.installationID) else { throw AuthorityError.identityChanged }
    guard !closed, !closing else { throw AuthorityError.identityChanged }
    try lease.verifyIdentity(); try resources.requireCachedPhone(handle, trust: trust)
    await resourceReplyGate?()
    guard let after = try await repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation),
          try handle.attachment.matches(after), !closed, !closing else { throw AuthorityError.identityChanged }
    let borrow = try mintDeletionBorrow(handle: handle, active: true, resources: resources, trust: trust)
    try borrow.verify(); return borrow
  }
  func borrowRetainedDeletionResources(saga: DeletionSagaV4) async throws -> M4ManagedDeletionBorrow {
    guard !closed, !closing, let resources, let trust = authorityTrust else { throw AuthorityError.unavailable }
    try lease.verifyIdentity()
    // Same-live-cache only: this read never opens a database or makes a ledger.
    let handle = try resources.cachedDeletionPhone(trust: trust)
    try await requireRetainedDeletion(saga: saga, handle: handle, trust: trust)
    guard !closed, !closing else { throw AuthorityError.identityChanged }
    try lease.verifyIdentity(); try resources.requireCachedPhone(handle, trust: trust)
    try await requireRetainedDeletion(saga: saga, handle: handle, trust: trust)
    let borrow = try mintDeletionBorrow(handle: handle, active: false, resources: resources, trust: trust)
    try borrow.verify(); return borrow
  }
  private func mintDeletionBorrow(handle: M4ManagedPhoneResources, active: Bool, resources: M4PhysicalResourceOwner, trust: AuthorityTrustConfiguration) throws -> M4ManagedDeletionBorrow {
    guard !closed, !closing, let phone = try resources.catalog.phoneResources() else { throw AuthorityError.identityChanged }
    try resources.requireCachedPhone(handle, trust: trust)
    return try M4ManagedDeletionBorrow(catalog: resources.catalog, physical: resources.reservation, phone: phone, handle: handle,
      entries: resources.catalog.index().entries, active: active) { [self] in
      guard !closed, !closing, self.resources === resources else { throw AuthorityError.identityChanged }
      try lease.verifyIdentity(); try resources.requireCachedPhone(handle, trust: trust)
    }
  }
  private func requireRetainedDeletion(saga: DeletionSagaV4, handle: M4ManagedPhoneResources, trust: AuthorityTrustConfiguration) async throws {
    guard let repository, let resources,
          let creation = try resources.catalog.deletionCreation(), creation.dispatch == .started,
          let plan = try resources.catalog.plan(requestID: saga.intent.requestID),
          M4CatalogIO.raw(creation.requestID, saga.intent.requestID), creation.scope == handle.scope, plan.scope == handle.scope,
          M4CatalogIO.raw(saga.intent.fields.reauthenticationID ?? "", creation.firstReauthID),
          creation.identityGeneration == handle.attachment.identityGeneration,
          M4CatalogIO.raw(creation.authRequestID, handle.attachment.currentAuthRequestID),
          creation.authReceiptDigest == M4CatalogIO.hash(handle.attachment.receiptRaw),
          try M4CatalogIO.encode(plan.choices) == M4CatalogIO.encode(creation.choices),
          plan.parentIntentDigest == nil || plan.parentIntentDigest == saga.intent.digest else { throw AuthorityError.identityChanged }
    let attachment = handle.attachment
    let generation = try await repository.identityGenerationV4()
    guard let stored = try await repository.deletionSagaV4(requestID: saga.intent.requestID),
          try M4CatalogIO.encode(stored) == M4CatalogIO.encode(saga),
          let control = try await repository.lifecycleControlIntentV4(requestID: saga.intent.requestID),
          control.canonicalRequest == saga.intent.canonicalRequest,
          let binding = try await repository.accountBindingV4(), let authID = try await repository.currentAuthRequestIDV4(),
          M4CatalogIO.raw(authID, attachment.currentAuthRequestID),
          let attempt = try await repository.authAttemptV4(requestID: authID),
          try M4CatalogIO.encode(attempt) == M4CatalogIO.encode(attachment.attempt),
          let original = saga.originalScope,
          M4CatalogIO.raw(original.accountID, attachment.scope.accountID), M4CatalogIO.raw(original.cloudSpaceID, attachment.scope.cloudSpaceID),
          M4CatalogIO.raw(original.zoneID, attachment.scope.zoneID), original.activationEpoch == attachment.scope.activationEpoch,
          M4CatalogIO.raw(saga.accountID, attachment.binding.accountID), saga.activationEpoch == attachment.scope.activationEpoch,
          M4CatalogIO.raw(binding.accountID, attachment.binding.accountID), M4CatalogIO.raw(binding.cloudSpaceID, attachment.binding.cloudSpaceID),
          M4CatalogIO.raw(binding.deviceID, seed.installationID), binding.role == .phone, binding.environment == attachment.binding.environment,
          binding.activationEpoch == attachment.binding.activationEpoch, M4CatalogIO.raw(attempt.publicKey, material.signer.publicKey),
          saga.cloudChoice == .keep, saga.localChoice == .delete, saga.healthChoice == .keep, !saga.healthConfirmed else { throw AuthorityError.identityChanged }
    _ = try DeletionSagaV4(intent: saga.intent, accountID: saga.accountID, activationEpoch: saga.activationEpoch, recoveryCapability: saga.recoveryCapability,
      cloudChoice: saga.cloudChoice, localChoice: saga.localChoice, healthChoice: saga.healthChoice, healthConfirmed: saga.healthConfirmed, originalScope: original)
    if saga.backendDeleted {
      guard binding.suspended, attachment.identityGeneration < 9_007_199_254_740_991, generation == attachment.identityGeneration + 1,
            let raw = saga.backendReceipt else { throw AuthorityError.identityChanged }
      // Historical signed provenance only: verification uses the original trust
      // and expected intent, never fresh auth admission or a fabricated clock.
      let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(saga.intent, accountID: saga.accountID, epoch: saga.activationEpoch), trust: trust)
      guard receipt.body.result == .deleted, receipt.body.deletion?.backend == "backendDeleted", receipt.body.deletion?.apple == "revoked" else { throw AuthorityError.identityChanged }
    } else {
      guard !binding.suspended, generation == attachment.identityGeneration, saga.backendReceipt == nil else { throw AuthorityError.identityChanged }
    }
    guard generation == (try await repository.identityGenerationV4()),
          let finalSaga = try await repository.deletionSagaV4(requestID: saga.intent.requestID),
          try M4CatalogIO.encode(finalSaga) == M4CatalogIO.encode(saga),
          try M4CatalogIO.encode(resources.catalog.deletionCreation()) == M4CatalogIO.encode(creation),
          try resources.catalog.plan(requestID: saga.intent.requestID)?.canonicalBytes() == plan.canonicalBytes(),
          !closed, !closing else { throw AuthorityError.identityChanged }
  }
  func activeWatchAttachment() throws -> M4WatchScopeAttachment? {
    guard !closed, !closing, let resources else { throw AuthorityError.unavailable }
    try lease.verifyIdentity(); return try resources.catalog.watchResources()?.attachment
  }
  func prepareCurrentWatchResources(expectedIdentityGeneration: Int64, observed: M4CurrentAccountIdentity, phoneContext: WatchRegistrationContextV4) async throws -> M4ManagedWatchResources {
    guard !closed, !closing, let repository, let resources, let trust = authorityTrust else { throw AuthorityError.unavailable }
    try lease.verifyIdentity()
    guard let proof = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration), proof.binding.role == .watch else { throw AuthorityError.unavailable }
    guard !closed, !closing, M4CatalogIO.raw(proof.attempt.payload.watchPublicKey, material.signer.publicKey),
          M4CatalogIO.raw(proof.binding.deviceID, seed.installationID), M4CatalogIO.raw(proof.binding.accountID, observed.accountID),
          M4CatalogIO.raw(proof.binding.cloudSpaceID, observed.cloudSpaceID), proof.binding.environment == observed.environment, observed.environment == trust.environment,
          try M4CatalogIO.encode(proof.admittedContext) == M4CatalogIO.encode(phoneContext) else { throw AuthorityError.identityChanged }
    let handle = try resources.prepareWatch(proof: proof, observed: observed, phoneContext: phoneContext, trust: trust)
    await resourceReplyGate?()
    guard !closed, !closing, let current = try await repository.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration),
          try handle.attachment.matches(current), !closed, !closing else { throw AuthorityError.identityChanged }
    try requireWatchResources(handle); return handle
  }
  func requireWatchResources(_ handle: M4ManagedWatchResources) throws {
    guard !closed, !closing, let resources else { throw AuthorityError.identityChanged }
    try lease.verifyIdentity(); try resources.verify()
    guard try M4CatalogIO.encode(resources.catalog.requireWatchSeal()) == M4CatalogIO.encode(handle.seal),
          let original = try resources.catalog.watchResources(), try original.attachment.digest() == handle.attachment.digest() else { throw AuthorityError.identityChanged }
  }
  func close() async throws {
    guard !closed else { return }
    guard !closing else { throw M4BootstrapError.alreadyOpened }; closing = true; defer { closing = false }
    try lease.verifyIdentity()
    try await resources?.close()
    try await repository?.close(); repository = nil
    closed = true; lease.close()
  }
}
struct M4ManagedPhoneResources: Sendable {
  let attachment: M4PhoneScopeAttachment
  let ledger: SQLiteCloudLedger
  let storeCapsule, ledgerCapsule: M4OwnershipCapsule
  let seal: M4PhonePairSeal
  var scope: CloudScope { attachment.scope }
  fileprivate init(attachment: M4PhoneScopeAttachment, ledger: SQLiteCloudLedger, storeCapsule: M4OwnershipCapsule, ledgerCapsule: M4OwnershipCapsule, seal: M4PhonePairSeal) {
    self.attachment = attachment; self.ledger = ledger; self.storeCapsule = storeCapsule; self.ledgerCapsule = ledgerCapsule; self.seal = seal
  }
}
struct M4ManagedWatchResources: Sendable {
  let attachment: M4WatchScopeAttachment
  let ledger: SQLiteCloudLedger
  let storeCapsule, ledgerCapsule: M4OwnershipCapsule
  let seal: M4WatchPairSeal
  var scope: CloudScope { attachment.scope }
  fileprivate init(attachment: M4WatchScopeAttachment, ledger: SQLiteCloudLedger, storeCapsule: M4OwnershipCapsule, ledgerCapsule: M4OwnershipCapsule, seal: M4WatchPairSeal) {
    self.attachment = attachment; self.ledger = ledger; self.storeCapsule = storeCapsule; self.ledgerCapsule = ledgerCapsule; self.seal = seal
  }
}
/// Owns original physical publication and the first signed Phone resources.
/// It grants no deletion authority.
@MainActor private final class M4PhysicalResourceOwner {
  let catalog: M4OwnedDataCatalog
  let reservation: M4PhysicalResourceReservation
  private var closed = false
  private var ledger: SQLiteCloudLedger?
  private let crashHook: ((M4ResourceCrashPoint) throws -> Void)?
  init(seed: M4IdentitySeed, keyID: String, crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    self.crashHook = crashHook
    let parent = seed.controlDirectory.deletingLastPathComponent()
    let directory = parent.appendingPathComponent("resources", isDirectory: true)
    let catalogDirectory = parent.appendingPathComponent("catalog", isDirectory: true)
    // A pre-existing positive database never creates a replacement catalog.
    guard !seed.businessExisted || M4CatalogIO.exists(catalogDirectory) else { throw M4BootstrapError.identityUnavailable }
    catalog = try M4OwnedDataCatalog(directory: catalogDirectory)
    do {
      if let prior = try catalog.physicalBootstrap() {
        reservation = prior.reservation
      } else {
        guard !seed.businessExisted, !M4CatalogIO.exists(seed.businessDatabaseURL), !M4CatalogIO.exists(directory) else { throw M4BootstrapError.identityUnavailable }
        let candidate = try Self.makeCandidate(seed: seed, directory: directory, keyID: keyID, catalogDirectory: catalogDirectory)
        try catalog.reservePhysicalBootstrap(candidate)
        guard let readback = try catalog.physicalBootstrap(), try M4CatalogIO.encode(readback.reservation) == M4CatalogIO.encode(candidate) else { throw M4CatalogError.storageBlocked }
        reservation = candidate
      }
      guard M4CatalogIO.raw(reservation.namespace, seed.namespace), M4CatalogIO.raw(reservation.installationID, seed.installationID),
            reservation.keyID == keyID, M4CatalogIO.raw(reservation.directory.path, directory.path),
            M4CatalogIO.raw(reservation.businessDatabase.path, seed.businessDatabaseURL.path),
            try M4CatalogIO.encode(reservation.identityControls) == M4CatalogIO.encode([
              M4CatalogIO.anchor(seed.controlDirectory.appendingPathComponent("identity.owner")), M4CatalogIO.anchor(seed.namespaceDirectory.appendingPathComponent("device.identity"))]) else { throw M4BootstrapError.identityUnavailable }
      try crashHook?(.afterReservation)
      try publishResourceDirectory(crashHook: crashHook)
      try publishBusinessFile(crashHook: crashHook)
      try verify()
    } catch { try? catalog.close(); throw error }
  }
  private static func makeCandidate(seed: M4IdentitySeed, directory: URL, keyID: String, catalogDirectory: URL) throws -> M4PhysicalResourceReservation {
    let id = UUID().uuidString, parent = directory.deletingLastPathComponent()
    let candidate = parent.appendingPathComponent(".resources.init-" + id, isDirectory: true)
    guard mkdir(candidate.path, S_IRWXU) == 0 else { throw M4BootstrapError.storageUnavailable }
    try M4CatalogIO.syncDirectory(parent)
    func create(_ name: String) throws {
      let url = candidate.appendingPathComponent(name)
      let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
      try M4CatalogIO.writeDescriptor(fd, bytes: Data())
    }
    try create("resource.owner"); try create("business.slot"); try create("ledger.slot")
    func atFinal(_ value: M4CatalogPath) -> M4CatalogPath {
      M4CatalogPath(path: value.path == candidate.path ? directory.path : directory.path + String(value.path.dropFirst(candidate.path.count)), device: value.device, inode: value.inode, directory: value.directory)
    }
    let sourceBusiness = try M4CatalogIO.anchor(candidate.appendingPathComponent("business.slot"))
    let business = M4CatalogPath(path: seed.businessDatabaseURL.path, device: sourceBusiness.device, inode: sourceBusiness.inode, directory: false)
    let controls = try [M4CatalogIO.anchor(seed.controlDirectory.appendingPathComponent("identity.owner")), M4CatalogIO.anchor(seed.namespaceDirectory.appendingPathComponent("device.identity"))]
    let catalogControls = try ["catalog.owner", "catalog.slot0", "catalog.slot1"].map { try M4CatalogIO.anchor(catalogDirectory.appendingPathComponent($0)) }
    let catalogOwnerDigest = try M4CatalogIO.hash(M4CatalogIO.read(catalogDirectory.appendingPathComponent("catalog.owner"), limit: 65536))
    let actualOwner = try M4CatalogIO.anchor(candidate.appendingPathComponent("resource.owner"))
    let ancestors = try M4CatalogIO.ancestors([actualOwner, business] + controls + catalogControls).map { M4CatalogIO.raw($0.path, candidate.path) ? atFinal($0) : $0 }.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
    let value = try M4PhysicalResourceReservation(version: 1, reservationID: id, namespace: seed.namespace, installationID: seed.installationID, keyID: keyID,
      candidate: M4CatalogIO.anchor(candidate), directory: atFinal(M4CatalogIO.anchor(candidate)), owner: atFinal(actualOwner),
      businessSlot: atFinal(sourceBusiness), businessDatabase: business, ledgerSlot: atFinal(M4CatalogIO.anchor(candidate.appendingPathComponent("ledger.slot"))), identityControls: controls, catalogControls: catalogControls, ancestors: ancestors, catalogOwnerDigest: catalogOwnerDigest)
    try value.validate()
    let bytes = try M4CatalogIO.encode(value)
    guard bytes.count <= 65536 else { throw M4CatalogError.budgetExceeded }
    let fd = Darwin.open(candidate.appendingPathComponent("resource.owner").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
    try M4CatalogIO.writeDescriptor(fd, bytes: bytes); try M4CatalogIO.syncDirectory(candidate); try M4CatalogIO.syncDirectory(parent)
    return value
  }
  private func state() throws -> M4PhysicalBootstrapState {
    guard let value = try catalog.physicalBootstrap(), try M4CatalogIO.encode(value.reservation) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.identityChanged }; return value
  }
  private func original(_ expected: M4CatalogPath, at url: URL) throws {
    let actual = try M4CatalogIO.anchor(url)
    guard actual.directory == expected.directory, M4CatalogIO.sameInode(actual, expected) else { throw M4CatalogError.identityChanged }
  }
  private func resourceLocation() throws -> URL {
    let source = URL(fileURLWithPath: reservation.candidate.path), target = URL(fileURLWithPath: reservation.directory.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    let actual = hasSource ? source : target
    try original(reservation.directory, at: actual)
    try original(reservation.owner, at: actual.appendingPathComponent("resource.owner"))
    guard try M4CatalogIO.read(actual.appendingPathComponent("resource.owner"), limit: 65536) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.identityChanged }
    for expected in reservation.ancestors {
      let url = URL(fileURLWithPath: expected.path == reservation.directory.path ? actual.path : expected.path)
      try original(expected, at: url)
    }
    for expected in reservation.identityControls + reservation.catalogControls { try original(expected, at: URL(fileURLWithPath: expected.path)) }
    guard try M4CatalogIO.hash(M4CatalogIO.read(URL(fileURLWithPath: reservation.catalogControls[0].path), limit: 65536)) == reservation.catalogOwnerDigest else { throw M4CatalogError.identityChanged }
    let actualAncestors = try M4CatalogIO.ancestors([M4CatalogIO.anchor(actual.appendingPathComponent("resource.owner")), reservation.businessDatabase] + reservation.identityControls + reservation.catalogControls).map { value in
      M4CatalogIO.raw(value.path, actual.path) ? M4CatalogPath(path: reservation.directory.path, device: value.device, inode: value.inode, directory: value.directory) : value
    }.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
    guard try M4CatalogIO.encode(actualAncestors) == M4CatalogIO.encode(reservation.ancestors) else { throw M4CatalogError.identityChanged }
    var mode = stat()
    guard lstat(actual.path, &mode) == 0, mode.st_uid == geteuid(), mode.st_mode & 0o7777 == 0o700 else { throw M4CatalogError.identityChanged }
    try privateFile(actual.appendingPathComponent("resource.owner"))
    return actual
  }
  private func privateFile(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o7777 == 0o600 else { throw M4CatalogError.identityChanged }
  }
  private func requireEmpty(_ url: URL, original expected: M4CatalogPath) throws {
    try original(expected, at: url); try privateFile(url)
    var st = stat(); guard lstat(url.path, &st) == 0, st.st_size == 0, st.st_nlink == 1 else { throw M4CatalogError.identityChanged }
  }
  private func rejectSidecarsForUninitializedBusiness(_ url: URL) throws {
    var main = stat()
    guard lstat(url.path, &main) == 0 else { throw M4CatalogError.identityChanged }
    // Our reserved zero-byte main has never owned SQLite recovery files. Leave
    // unknown evidence intact; initialized databases retain normal WAL recovery.
    guard main.st_size == 0 else { return }
    for suffix in ["-wal", "-shm", "-journal"] {
      var sidecar = stat()
      guard lstat(url.path + suffix, &sidecar) == -1, errno == ENOENT else { throw M4CatalogError.unknownControl }
    }
  }
  private func publishResourceDirectory(crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    let current = try state(), actual = try resourceLocation(), target = URL(fileURLWithPath: reservation.directory.path)
    if M4CatalogIO.raw(actual.path, reservation.candidate.path) {
      guard !current.resourcesPublished, !current.businessPublished, !M4CatalogIO.exists(URL(fileURLWithPath: reservation.businessDatabase.path)) else { throw M4CatalogError.identityChanged }
      try requireEmpty(actual.appendingPathComponent("business.slot"), original: reservation.businessSlot)
      try requireEmpty(actual.appendingPathComponent("ledger.slot"), original: reservation.ledgerSlot)
      guard Set(try FileManager.default.contentsOfDirectory(atPath: actual.path)) == ["resource.owner", "business.slot", "ledger.slot"] else { throw M4CatalogError.unknownControl }
      guard renameatx_np(AT_FDCWD, actual.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterResourceRename)
      try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    }
    _ = try resourceLocation()
    // A retry after the rename must stabilize its parent too, before marking
    // the original publication durable in the catalog.
    try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.recordPhysicalPublication(reservation, business: false)
  }
  private func publishBusinessFile(crashHook: ((M4ResourceCrashPoint) throws -> Void)?) throws {
    let current = try state(), directory = try resourceLocation()
    guard current.resourcesPublished, M4CatalogIO.raw(directory.path, reservation.directory.path) else { throw M4CatalogError.identityChanged }
    let source = directory.appendingPathComponent("business.slot"), target = URL(fileURLWithPath: reservation.businessDatabase.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    if hasSource {
      guard !current.businessPublished else { throw M4CatalogError.identityChanged }
      try requireEmpty(source, original: reservation.businessSlot)
      guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterBusinessRename)
    }
    try original(reservation.businessDatabase, at: target)
    if !current.businessPublished { try requireEmpty(target, original: reservation.businessDatabase) }
    try rejectSidecarsForUninitializedBusiness(target)
    try M4CatalogIO.syncDirectory(directory); try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.recordPhysicalPublication(reservation, business: true)
  }
  func verify() throws {
    guard !closed else { throw M4CatalogError.closed }
    let current = try state(), directory = try resourceLocation()
    guard current.resourcesPublished, current.businessPublished, M4CatalogIO.raw(directory.path, reservation.directory.path) else { throw M4CatalogError.unknownControl }
    var names: Set<String> = ["resource.owner"]
    if let phone = current.phone {
      let source = URL(fileURLWithPath: phone.ledger.source.path), target = URL(fileURLWithPath: phone.ledger.published.path)
      let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
      guard hasSource != hasTarget, !phone.published || hasTarget else { throw M4CatalogError.identityChanged }
      let url = hasSource ? source : target
      try original(reservation.ledgerSlot, at: url); try privateFile(url)
      guard try M4CatalogIO.encode(phone.ledger.ancestors) == M4CatalogIO.encode(M4CatalogIO.ancestors([phone.ledger.published] + controls)) else { throw M4CatalogError.identityChanged }
      names.insert(url.lastPathComponent)
      try rejectSidecarsForUninitializedBusiness(url)
      for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = URL(fileURLWithPath: url.path + suffix)
        if M4CatalogIO.exists(sidecar) { _ = try M4CatalogIO.anchor(sidecar); try privateFile(sidecar); names.insert(sidecar.lastPathComponent) }
      }
      if hasSource { try requireEmpty(url, original: reservation.ledgerSlot) }
    } else if let watch = current.watch {
      let source = URL(fileURLWithPath: watch.ledger.source.path), target = URL(fileURLWithPath: watch.ledger.published.path)
      let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
      guard hasSource != hasTarget, !watch.published || hasTarget else { throw M4CatalogError.identityChanged }
      let url = hasSource ? source : target
      try original(reservation.ledgerSlot, at: url); try privateFile(url)
      guard try M4CatalogIO.encode(watch.ledger.ancestors) == M4CatalogIO.encode(M4CatalogIO.ancestors([watch.ledger.published] + controls)) else { throw M4CatalogError.identityChanged }
      names.insert(url.lastPathComponent); try rejectSidecarsForUninitializedBusiness(url)
      for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = URL(fileURLWithPath: url.path + suffix)
        if M4CatalogIO.exists(sidecar) { _ = try M4CatalogIO.anchor(sidecar); try privateFile(sidecar); names.insert(sidecar.lastPathComponent) }
      }
      if hasSource { try requireEmpty(url, original: reservation.ledgerSlot) }
    } else {
      try requireEmpty(directory.appendingPathComponent("ledger.slot"), original: reservation.ledgerSlot); names.insert("ledger.slot")
    }
    guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == names else { throw M4CatalogError.unknownControl }
    let business = URL(fileURLWithPath: reservation.businessDatabase.path)
    try original(reservation.businessDatabase, at: business); try privateFile(business)
    try rejectSidecarsForUninitializedBusiness(business)
  }
  private var controls: [M4CatalogPath] { [reservation.owner] + reservation.identityControls + reservation.catalogControls }
  private func capsule(_ root: M4CatalogPath, kind: M4OwnedLeafKind, id: String, scope: CloudScope) throws -> M4OwnershipCapsule {
    let value = M4OwnershipCapsule(version: 1, namespaceID: reservation.reservationID, componentID: id, revision: 1, kind: kind, scope: scope,
      root: root, retainedControls: controls, ancestors: try M4CatalogIO.ancestors([root] + controls))
    try value.validate(); return value
  }
  func preparePhone(proof: VerifiedLocalAuthenticationEvidenceV4, observed: M4CurrentAccountIdentity, trust: AuthorityTrustConfiguration) throws -> M4ManagedPhoneResources {
    try verify()
    guard try catalog.watchResources() == nil else { throw AuthorityError.identityChanged }
    let scope = try CloudScope(accountID: proof.binding.accountID, cloudSpaceID: proof.binding.cloudSpaceID, zoneID: observed.zoneID, activationEpoch: proof.binding.activationEpoch)
    let phone: M4PhoneResourceState
    if let prior = try catalog.phoneResources() {
      guard try prior.attachment.matches(proof), prior.attachment.scope == scope else { throw AuthorityError.identityChanged }; phone = prior
    } else {
      let id = UUID().uuidString
      let attachment = M4PhoneScopeAttachment(attachmentID: UUID().uuidString, physicalReservationID: reservation.reservationID,
        identityGeneration: proof.identityGeneration, currentAuthRequestID: proof.currentAuthRequestID, attempt: proof.attempt,
        binding: proof.binding, receiptRaw: proof.receipt.raw, scope: scope)
      let target = M4CatalogPath(path: reservation.directory.path + "/ledger-" + id + ".sqlite", device: reservation.ledgerSlot.device, inode: reservation.ledgerSlot.inode, directory: false)
      let descriptor = M4PhoneLedgerDescriptor(ledgerID: id, source: reservation.ledgerSlot, published: target, ancestors: try M4CatalogIO.ancestors([target] + controls))
      phone = M4PhoneResourceState(attachment: attachment, ledger: descriptor, published: false, seal: nil)
    }
    try phone.validate(reservation)
    let verified = try VerifiedAuthorityReceiptV1.verify(phone.attachment.receiptRaw,
      expected: AuthorityExpectedIntent(requestID: phone.attachment.currentAuthRequestID, digest: phone.attachment.attempt.requestDigest, operation: .authApple, accountID: phone.attachment.binding.accountID, epoch: scope.activationEpoch), trust: trust)
    guard verified.raw == proof.receipt.raw, verified.body.result == .registered, proof.binding.role == .phone else { throw AuthorityError.unavailable }
    let store = try capsule(reservation.businessDatabase, kind: .businessStore, id: "m4-business-store", scope: scope)
    let ledgerCapsule = try capsule(phone.ledger.published, kind: .cloudLedger, id: phone.ledger.componentID, scope: scope)
    try catalog.reservePhoneResources(phone, store: store, ledger: ledgerCapsule)
    try crashHook?(.afterLedgerReservation)
    let source = URL(fileURLWithPath: phone.ledger.source.path), target = URL(fileURLWithPath: phone.ledger.published.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    if hasSource {
      guard !phone.published else { throw M4CatalogError.identityChanged }
      try requireEmpty(source, original: reservation.ledgerSlot); try rejectSidecarsForUninitializedBusiness(source)
      guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterLedgerRename)
    }
    try original(reservation.ledgerSlot, at: target); try privateFile(target); try rejectSidecarsForUninitializedBusiness(target)
    try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.publishPhoneLedger(phone.ledger); try verify()
    if ledger == nil { ledger = try SQLiteCloudLedger(url: target) }
    guard let ledger else { throw M4CatalogError.storageBlocked }
    try crashHook?(.afterLedgerInitialization)
    try store.verifyCurrent(); try ledgerCapsule.verifyCurrent()
    let seal = try catalog.sealPhoneResources(store: store, ledger: ledgerCapsule)
    try crashHook?(.afterPairSeal)
    return M4ManagedPhoneResources(attachment: phone.attachment, ledger: ledger, storeCapsule: store, ledgerCapsule: ledgerCapsule, seal: seal)
  }
  func prepareWatch(proof: VerifiedLocalWatchRegistrationEvidenceV4, observed: M4CurrentAccountIdentity, phoneContext: WatchRegistrationContextV4, trust: AuthorityTrustConfiguration) throws -> M4ManagedWatchResources {
    try verify()
    guard try catalog.phoneResources() == nil, try M4CatalogIO.encode(phoneContext) == M4CatalogIO.encode(proof.admittedContext) else { throw AuthorityError.identityChanged }
    let scope = try CloudScope(accountID: proof.binding.accountID, cloudSpaceID: proof.binding.cloudSpaceID, zoneID: observed.zoneID, activationEpoch: proof.binding.activationEpoch)
    let watch: M4WatchResourceState
    if let prior = try catalog.watchResources() {
      guard try prior.attachment.matches(proof), prior.attachment.scope == scope else { throw AuthorityError.identityChanged }; watch = prior
    } else {
      let id = UUID().uuidString
      let attachment = M4WatchScopeAttachment(version: 1, attachmentID: UUID().uuidString, physicalReservationID: reservation.reservationID,
        binding: proof.binding, identityGeneration: proof.identityGeneration, acceptedGeneration: proof.acceptedGeneration,
        currentWatchRequestID: proof.currentWatchRequestID, attempt: proof.attempt, admittedContext: proof.admittedContext,
        watchDeviceKeyID: proof.watchDeviceKeyID, receiptRaw: proof.receipt.raw, latestMigration: proof.latestMigration, scope: scope)
      let target = M4CatalogPath(path: reservation.directory.path + "/ledger-" + id + ".sqlite", device: reservation.ledgerSlot.device, inode: reservation.ledgerSlot.inode, directory: false)
      let descriptor = M4WatchLedgerDescriptor(ledgerID: id, source: reservation.ledgerSlot, published: target, ancestors: try M4CatalogIO.ancestors([target] + controls))
      watch = M4WatchResourceState(attachment: attachment, ledger: descriptor, published: false, seal: nil)
    }
    try watch.validate(reservation)
    let verified = try VerifiedAuthorityReceiptV1.verify(watch.attachment.receiptRaw,
      expected: AuthorityExpectedIntent(requestID: watch.attachment.currentWatchRequestID, digest: watch.attachment.attempt.requestDigest, operation: .registerWatch, accountID: watch.attachment.binding.accountID, epoch: scope.activationEpoch), trust: trust)
    guard verified.raw == proof.receipt.raw, verified.body.result == .registered, proof.binding.role == .watch,
          M4CatalogIO.raw(verified.body.registration?.watchID ?? "", proof.attempt.payload.watchID),
          M4CatalogIO.raw(verified.body.registration?.watchPublicKey ?? "", proof.attempt.payload.watchPublicKey) else { throw AuthorityError.unavailable }
    let store = try capsule(reservation.businessDatabase, kind: .businessStore, id: "m4-business-store", scope: scope)
    let ledgerCapsule = try capsule(watch.ledger.published, kind: .cloudLedger, id: watch.ledger.componentID, scope: scope)
    try catalog.reserveWatchResources(watch, store: store, ledger: ledgerCapsule)
    try crashHook?(.afterLedgerReservation)
    let source = URL(fileURLWithPath: watch.ledger.source.path), target = URL(fileURLWithPath: watch.ledger.published.path)
    let hasSource = M4CatalogIO.exists(source), hasTarget = M4CatalogIO.exists(target)
    guard hasSource != hasTarget else { throw M4CatalogError.identityChanged }
    if hasSource {
      guard !watch.published else { throw M4CatalogError.identityChanged }
      try requireEmpty(source, original: reservation.ledgerSlot); try rejectSidecarsForUninitializedBusiness(source)
      guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw M4CatalogError.storageBlocked }
      try crashHook?(.afterLedgerRename)
    }
    try original(reservation.ledgerSlot, at: target); try privateFile(target); try rejectSidecarsForUninitializedBusiness(target)
    try M4CatalogIO.syncDirectory(target.deletingLastPathComponent())
    try catalog.publishWatchLedger(watch.ledger); try verify()
    if ledger == nil { ledger = try SQLiteCloudLedger(url: target) }
    guard let ledger else { throw M4CatalogError.storageBlocked }
    try crashHook?(.afterLedgerInitialization)
    try store.verifyCurrent(); try ledgerCapsule.verifyCurrent()
    let seal = try catalog.sealWatchResources(store: store, ledger: ledgerCapsule)
    try crashHook?(.afterPairSeal)
    return M4ManagedWatchResources(attachment: watch.attachment, ledger: ledger, storeCapsule: store, ledgerCapsule: ledgerCapsule, seal: seal)
  }
  func requireCachedPhone(_ handle: M4ManagedPhoneResources, trust: AuthorityTrustConfiguration) throws {
    try verify()
    guard let ledger, ledger === handle.ledger,
          let phone = try catalog.phoneResources(), try catalog.watchResources() == nil, phone.published,
          try M4CatalogIO.encode(phone.attachment) == M4CatalogIO.encode(handle.attachment),
          try M4CatalogIO.encode(catalog.requirePhoneSeal()) == M4CatalogIO.encode(handle.seal) else { throw AuthorityError.identityChanged }
    let entries = try catalog.index().entries
    guard entries.count == 2, entries.allSatisfy({ !$0.retired }),
          let store = entries.first(where: { $0.capsule.kind == .businessStore }),
          let cloud = entries.first(where: { $0.capsule.kind == .cloudLedger }),
          try M4CatalogIO.encode(store.capsule) == M4CatalogIO.encode(handle.storeCapsule),
          try M4CatalogIO.encode(cloud.capsule) == M4CatalogIO.encode(handle.ledgerCapsule),
          M4CatalogIO.raw(handle.attachment.physicalReservationID, reservation.reservationID),
          handle.storeCapsule.scope == handle.scope, handle.ledgerCapsule.scope == handle.scope,
          M4CatalogIO.raw(handle.attachment.attempt.keyID, reservation.keyID) else { throw AuthorityError.identityChanged }
    try handle.attachment.validate(reservation); try handle.storeCapsule.verifyCurrent(); try handle.ledgerCapsule.verifyCurrent()
    let verified = try VerifiedAuthorityReceiptV1.verify(handle.attachment.receiptRaw,
      expected: AuthorityExpectedIntent(requestID: handle.attachment.currentAuthRequestID, digest: handle.attachment.attempt.requestDigest, operation: .authApple, accountID: handle.scope.accountID, epoch: handle.scope.activationEpoch), trust: trust)
    guard verified.body.result == .registered, trust.environment == handle.attachment.binding.environment,
          handle.seal.attachmentDigest == (try handle.attachment.digest()), handle.seal.storeDigest == (try handle.storeCapsule.digest()),
          handle.seal.ledgerDigest == (try handle.ledgerCapsule.digest()) else { throw AuthorityError.identityChanged }
    try verify()
  }
  func cachedDeletionPhone(trust: AuthorityTrustConfiguration) throws -> M4ManagedPhoneResources {
    guard let ledger, let phone = try catalog.phoneResources(), let seal = phone.seal else { throw AuthorityError.unavailable }
    let entries = try catalog.index().entries
    guard let store = entries.first(where: { $0.capsule.kind == .businessStore }), let cloud = entries.first(where: { $0.capsule.kind == .cloudLedger }) else { throw AuthorityError.identityChanged }
    let handle = M4ManagedPhoneResources(attachment: phone.attachment, ledger: ledger, storeCapsule: store.capsule, ledgerCapsule: cloud.capsule, seal: seal)
    try requireCachedPhone(handle, trust: trust); return handle
  }
  func close() async throws {
    guard !closed else { return }
    try verify(); try await ledger?.close(); try catalog.close(); closed = true
  }
}

@MainActor enum M4IdentityBootstrap {
  #if DEBUG
  static func readDevelopmentConfiguration(_ url: URL) throws -> DevelopmentAuthorityConfiguration {
    let url = M4BootstrapFile.canonical(url)
    let parents = try M4BootstrapFile.anchors([url.deletingLastPathComponent()]), original = try M4BootstrapFile.anchor(url, directory: false)
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o7777 == 0o600 else { throw M4BootstrapError.identityUnavailable }
    let bytes = try M4BootstrapFile.read(url, maximum: 16384)
    guard try M4BootstrapFile.encode(original) == M4BootstrapFile.encode(M4BootstrapFile.anchor(url, directory: false)),
          try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([url.deletingLastPathComponent()])) else { throw M4BootstrapError.identityUnavailable }
    return try JSONDecoder().decode(DevelopmentAuthorityConfiguration.self, from: bytes)
  }
  #endif
  static func prepare(root: URL, namespace: String, controlDirectory: URL, vaultFactory: @MainActor (M4IdentitySeed) async throws -> M4IdentityMaterial) async throws -> M4PreparedIdentity {
    try Task.checkCancellation()
    guard !namespace.isEmpty, namespace.utf8.count <= 128,
          namespace.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
          root.isFileURL, controlDirectory.isFileURL else { throw M4BootstrapError.invalidNamespace }
    let root = M4BootstrapFile.canonical(root), control = M4BootstrapFile.canonical(controlDirectory)
    let directory = root.appendingPathComponent(namespace, isDirectory: true)
    guard !M4BootstrapFile.overlap(directory, control) else { throw M4BootstrapError.foreignNamespace }
    let lease = try M4NamespaceLease(root: root, namespace: namespace, directory: directory, control: control)
    let seed = M4IdentitySeed(root: root, namespaceDirectory: directory, controlDirectory: control,
      businessDatabaseURL: directory.appendingPathComponent("matches.sqlite"), namespace: namespace,
      installationID: lease.installationID, businessExisted: try lease.businessExists())
    // The retained nonblocking ownership lease spans the context lifetime. No
    // mutable-file/SQL critical section or blocking lock wait spans this await.
    let material = try await vaultFactory(seed)
    try Task.checkCancellation()
    _ = try AuthorityWire.deviceKeyID(publicKey: material.signer.publicKey)
    try lease.verifyIdentity()
    guard try lease.businessExists() == seed.businessExisted else { throw M4BootstrapError.identityUnavailable }
    return M4PreparedIdentity(seed: seed, material: material, lease: lease)
  }
}

private struct M4BootstrapAnchor: Codable {
  let path: String
  let device, inode: UInt64
}
private struct M4BootstrapOwner: Codable {
  let version: Int
  let namespace, installationID: String
  let owner: M4BootstrapAnchor
  let anchors: [M4BootstrapAnchor]
}
/// Exclusive namespace ownership, distinct from a short file-mutation lock.
/// Closing releases the descriptor, never the retained inode or its parent.
fileprivate final class M4NamespaceLease {
  private var fd: Int32 = -1
  private let root, directory, control, ownerURL: URL
  private let namespace: String
  private var record: M4BootstrapOwner?
  private var originalBytes = Data()
  var installationID: String { record!.installationID }
  init(root: URL, namespace: String, directory: URL, control: URL) throws {
    self.root = root; self.namespace = namespace; self.directory = directory; self.control = control
    ownerURL = control.appendingPathComponent("identity.owner")
    try M4BootstrapFile.ensureDirectory(directory)
    try M4BootstrapFile.ensureDirectory(control)
    try M4BootstrapFile.requireDisjoint(directory, control)
    let hasOwner = M4BootstrapFile.exists(ownerURL)
    if !hasOwner {
      if try Self.businessExists(directory) { throw M4BootstrapError.identityUnavailable }
      guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty else { throw M4BootstrapError.foreignNamespace }
      if M4BootstrapFile.exists(control) {
        guard try FileManager.default.contentsOfDirectory(at: control, includingPropertiesForKeys: nil).isEmpty else { throw M4BootstrapError.identityUnavailable }
      }
    }
    var created = false
    fd = Darwin.open(ownerURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    if fd >= 0 { created = true }
    else {
      guard errno == EEXIST else { throw M4BootstrapError.storageUnavailable }
      fd = Darwin.open(ownerURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    }
    guard fd >= 0 else { throw M4BootstrapError.identityUnavailable }
    do {
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw M4BootstrapError.leaseInUse }
      let actualOwner = try M4BootstrapFile.anchor(ownerURL, directory: false)
      if created {
        let value = M4BootstrapOwner(version: 1, namespace: namespace, installationID: UUID().uuidString,
          owner: actualOwner, anchors: try M4BootstrapFile.anchors([directory, control]))
        let bytes = try M4BootstrapFile.encode(value)
        guard bytes.count <= 65536, bytes.withUnsafeBytes({ Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }) == bytes.count, fsync(fd) == 0 else { throw M4BootstrapError.storageUnavailable }
        record = value; originalBytes = bytes
        try M4BootstrapFile.syncDirectory(control)
      } else {
        let bytes = try M4BootstrapFile.read(ownerURL, maximum: 65536)
        let value = try JSONDecoder().decode(M4BootstrapOwner.self, from: bytes)
        guard value.version == 1, Data(value.namespace.utf8) == Data(namespace.utf8),
              UUID(uuidString: value.installationID)?.uuidString == value.installationID,
              try M4BootstrapFile.encode(value) == bytes,
              try M4BootstrapFile.encode(value.owner) == M4BootstrapFile.encode(actualOwner),
              try M4BootstrapFile.encode(value.anchors) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory, control])) else { throw M4BootstrapError.identityUnavailable }
        record = value; originalBytes = bytes
      }
      let identity = directory.appendingPathComponent("device.identity")
      if !M4BootstrapFile.exists(identity) {
        guard try !Self.businessExists(directory) else { throw M4BootstrapError.identityUnavailable }
        try Data(("football-record.identity.v1:" + installationID).utf8).write(to: identity, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        let file = Darwin.open(identity.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw M4BootstrapError.storageUnavailable }
        defer { Darwin.close(file) }
        guard fsync(file) == 0 else { throw M4BootstrapError.storageUnavailable }
        try M4BootstrapFile.syncDirectory(directory)
      }
      try verifyIdentity()
    } catch {
      close()
      if error is M4BootstrapError { throw error }
      throw M4BootstrapError.identityUnavailable
    }
  }
  func verifyIdentity() throws {
    guard fd >= 0, let record else { throw M4BootstrapError.closed }
    try M4BootstrapFile.requireDisjoint(directory, control)
    guard try M4BootstrapFile.encode(record.owner) == M4BootstrapFile.encode(M4BootstrapFile.anchor(ownerURL, directory: false)),
          try M4BootstrapFile.encode(record.anchors) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory, control])),
          try M4BootstrapFile.read(ownerURL, maximum: 65536) == originalBytes,
          try M4BootstrapFile.read(directory.appendingPathComponent("device.identity"), maximum: 256) == Data(("football-record.identity.v1:" + installationID).utf8) else { throw M4BootstrapError.identityUnavailable }
  }
  func businessExists() throws -> Bool { try Self.businessExists(directory) }
  private static func businessExists(_ directory: URL) throws -> Bool {
    let main = directory.appendingPathComponent("matches.sqlite")
    var found = false
    for name in ["matches.sqlite", "matches.sqlite-wal", "matches.sqlite-shm", "matches.sqlite-journal"] {
      let path = directory.appendingPathComponent(name)
      if M4BootstrapFile.exists(path) { _ = try M4BootstrapFile.anchor(path, directory: false); found = true }
    }
    guard !found || M4BootstrapFile.exists(main) else { throw M4BootstrapError.identityUnavailable }
    return found
  }
  func close() {
    if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
  }
  deinit { close() }
}

private enum M4BootstrapFile {
  static func canonical(_ url: URL) -> URL {
    let path = url.standardizedFileURL.path
    if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return URL(fileURLWithPath: "/private" + path, isDirectory: true) }
    return url.standardizedFileURL
  }
  static func overlap(_ a: URL, _ b: URL) -> Bool {
    let aa = Data(a.path.utf8), bb = Data(b.path.utf8)
    return aa == bb || aa.starts(with: Data((b.path + "/").utf8)) || bb.starts(with: Data((a.path + "/").utf8))
  }
  // Raw path checks alone cannot distinguish case aliases on APFS. Compare
  // real directory identities against the opposite ancestry before any owner,
  // identity or vault write; checkExistingChain still rejects all symlinks.
  static func requireDisjoint(_ a: URL, _ b: URL) throws {
    try checkExistingChain(a); try checkExistingChain(b)
    for (root, descendant) in [(a, b), (b, a)] {
      let original = try anchor(root, directory: true)
      var cursor = descendant
      while true {
        let current = try anchor(cursor, directory: true)
        guard original.device != current.device || original.inode != current.inode else { throw M4BootstrapError.foreignNamespace }
        if cursor.path == "/" { break }
        cursor.deleteLastPathComponent()
      }
    }
  }
  static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
  static func anchor(_ url: URL, directory: Bool) throws -> M4BootstrapAnchor {
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { throw M4BootstrapError.identityUnavailable }
    return M4BootstrapAnchor(path: url.path, device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino)
  }
  static func checkExistingChain(_ url: URL) throws {
    var cursor = url
    while cursor.path != "/" {
      if exists(cursor) { _ = try anchor(cursor, directory: true) }
      cursor.deleteLastPathComponent()
    }
  }
  static func ensureDirectory(_ url: URL) throws {
    try checkExistingChain(url)
    if exists(url) { return }
    let parent = url.deletingLastPathComponent()
    try ensureDirectory(parent)
    guard mkdir(url.path, S_IRWXU) == 0 || errno == EEXIST else { throw M4BootstrapError.storageUnavailable }
    _ = try anchor(url, directory: true)
    try syncDirectory(url); try syncDirectory(parent)
  }
  static func anchors(_ urls: [URL]) throws -> [M4BootstrapAnchor] {
    var seen = Set<Data>(), values: [M4BootstrapAnchor] = []
    for url in urls {
      var cursor = url
      while cursor.path != "/" {
        let key = Data(cursor.path.utf8)
        if seen.insert(key).inserted { values.append(try anchor(cursor, directory: true)) }
        cursor.deleteLastPathComponent()
      }
    }
    return values.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
  }
  static func read(_ url: URL, maximum: Int) throws -> Data {
    _ = try anchor(url, directory: false)
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.identityUnavailable }; defer { Darwin.close(fd) }
    var st = stat(); guard fstat(fd, &st) == 0, st.st_size > 0, st.st_size <= maximum else { throw M4BootstrapError.identityUnavailable }
    var bytes = Data(count: Int(st.st_size))
    let actual = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
    guard actual == bytes.count else { throw M4BootstrapError.identityUnavailable }
    return bytes
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4BootstrapError.storageUnavailable }; defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw M4BootstrapError.storageUnavailable }
  }
}

#if DEBUG
/// Borrowed, explicitly controlled observations only. These files are never
/// synthesized from configuration, credentials, pending requests or local binding.
actor M4ControlledCurrentIdentity: M4CurrentIdentityObserving {
  private struct Apple: Codable { let version: Int; let environment, namespace, observationID, accountID: String }
  private struct Cloud: Codable { let version: Int; let environment, namespace, observationID, cloudSpaceID, zoneID: String }
  private let directory: URL
  private let namespace: String
  private let parents, files: [M4BootstrapAnchor]
  private let readReplyGate: (@Sendable () async -> Void)?
  private var generation: Int64 = 0
  private var lifetime = UUID()
  init(directory: URL, namespace: String, readReplyGate: (@Sendable () async -> Void)? = nil) throws {
    let directory = M4BootstrapFile.canonical(directory)
    guard namespace != SQLiteSessionRepository.productionNamespace else { throw AuthorityError.unavailable }
    let parents = try M4BootstrapFile.anchors([directory])
    let files = try ["apple-account.json", "cloud-space.json"].map { try M4BootstrapFile.anchor(directory.appendingPathComponent($0), directory: false) }
    let first = try Self.read(directory: directory, parents: parents, files: files)
    _ = try Self.decode(first, namespace: namespace)
    guard first == (try Self.read(directory: directory, parents: parents, files: files)) else { throw AuthorityError.identityChanged }
    self.directory = directory; self.namespace = namespace; self.parents = parents; self.files = files; self.readReplyGate = readReplyGate
  }
  func advanceIdentityFence(to generation: Int64) throws {
    guard generation >= self.generation, generation <= 9_007_199_254_740_991 else { throw AuthorityError.identityChanged }
    if generation > self.generation { self.generation = generation; lifetime = UUID() }
  }
  func currentIdentity() async throws -> M4CurrentAccountIdentity {
    try Task.checkCancellation()
    let token = lifetime, generation = generation
    let first = try Self.read(directory: directory, parents: parents, files: files)
    let observed = try Self.decode(first, namespace: namespace)
    await readReplyGate?()
    try Task.checkCancellation()
    guard token == lifetime, generation == self.generation,
          first == (try Self.read(directory: directory, parents: parents, files: files)) else { throw AuthorityError.identityChanged }
    return observed
  }
  private static func decode(_ pair: [Data], namespace: String) throws -> M4CurrentAccountIdentity {
    let apple = try JSONDecoder().decode(Apple.self, from: pair[0]), cloud = try JSONDecoder().decode(Cloud.self, from: pair[1])
    guard try M4BootstrapFile.encode(apple) == pair[0], try M4BootstrapFile.encode(cloud) == pair[1],
          apple.version == 1, cloud.version == 1, apple.environment == "development", cloud.environment == "development",
          Data(apple.namespace.utf8) == Data(namespace.utf8), Data(cloud.namespace.utf8) == Data(namespace.utf8),
          UUID(uuidString: apple.observationID)?.uuidString == apple.observationID,
          Data(apple.observationID.utf8) == Data(cloud.observationID.utf8) else { throw AuthorityError.identityChanged }
    for value in [apple.accountID, cloud.cloudSpaceID, cloud.zoneID] { try AuthorityWire.identifier(value) }
    return M4CurrentAccountIdentity(accountID: apple.accountID, cloudSpaceID: cloud.cloudSpaceID, zoneID: cloud.zoneID, environment: .development)
  }
  private static func read(directory: URL, parents: [M4BootstrapAnchor], files: [M4BootstrapAnchor]) throws -> [Data] {
    guard try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory])) else { throw AuthorityError.identityChanged }
    var dir = stat()
    guard lstat(directory.path, &dir) == 0, dir.st_uid == geteuid(), dir.st_mode & 0o7777 == 0o700 else { throw AuthorityError.unavailable }
    var result: [Data] = []
    for expected in files {
      let url = URL(fileURLWithPath: expected.path), actual = try M4BootstrapFile.anchor(url, directory: false)
      guard try M4BootstrapFile.encode(expected) == M4BootstrapFile.encode(actual) else { throw AuthorityError.identityChanged }
      let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw AuthorityError.unavailable }; defer { Darwin.close(fd) }
      var held = stat()
      guard fstat(fd, &held) == 0, held.st_uid == geteuid(), held.st_nlink == 1, held.st_mode & 0o7777 == 0o600,
            UInt64(UInt32(bitPattern: held.st_dev)) == expected.device, held.st_ino == expected.inode,
            held.st_size > 0, held.st_size <= 16384 else { throw AuthorityError.unavailable }
      var bytes = Data(count: Int(held.st_size))
      let count = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
      guard count == bytes.count, try M4BootstrapFile.encode(expected) == M4BootstrapFile.encode(M4BootstrapFile.anchor(url, directory: false)) else { throw AuthorityError.identityChanged }
      result.append(bytes)
    }
    guard try M4BootstrapFile.encode(parents) == M4BootstrapFile.encode(M4BootstrapFile.anchors([directory])) else { throw AuthorityError.identityChanged }
    return result
  }
}
#endif
