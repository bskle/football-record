import Foundation
import CloudSync
import DeviceSync
import MatchStore
import HealthKitDeletion

enum M4CatalogError: String, Error, Sendable {
  case storageBlocked, identityChanged, intentMismatch, unsupportedSchema, unknownControl
  case budgetExceeded, closed, busy, injectedFailure
}
enum M4OwnedLeafKind: String, Codable, Sendable { case businessStore, cloudLedger, cloudStaging, deviceSync }
struct M4CatalogPath: Codable, Sendable {
  let path: String
  let device, inode: UInt64
  let directory: Bool
}
/// Immutable membership only. Derived bindings, retirement and receipts are not
/// part of this body, so a DeviceSync binding cannot reference its own digest.
struct M4OwnershipCapsule: Codable, Sendable {
  let version: Int
  let namespaceID, componentID: String
  let revision: UInt64
  let kind: M4OwnedLeafKind
  let scope: CloudScope
  let root: M4CatalogPath
  let retainedControls, ancestors: [M4CatalogPath]
  static func capture(namespaceID: String, componentID: String, kind: M4OwnedLeafKind, scope: CloudScope, root: URL, retainedControls: [URL]) throws -> Self {
    let root = try M4CatalogIO.anchor(root), controls = try retainedControls.map(M4CatalogIO.anchor)
    let value = Self(version: 1, namespaceID: namespaceID, componentID: componentID, revision: 1,
      kind: kind, scope: scope, root: root, retainedControls: controls,
      ancestors: try M4CatalogIO.ancestors([root] + controls))
    try value.validate(); return value
  }
  func validate() throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard UUID(uuidString: namespaceID)?.uuidString == namespaceID, revision > 0,
          M4CatalogIO.opaque(componentID, limit: 128), retainedControls.count <= 256,
          ancestors.count <= 4096 else { throw M4CatalogError.intentMismatch }
    _ = try CloudScope(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)
    for path in [root] + retainedControls + ancestors { try M4CatalogIO.validate(path) }
    let paths = retainedControls.map { Data($0.path.utf8) }
    guard Set(paths).count == paths.count else { throw M4CatalogError.intentMismatch }
  }
  func verifyCurrent() throws {
    try validate()
    for value in [root] + retainedControls {
      guard try M4CatalogIO.encode(value) == M4CatalogIO.encode(M4CatalogIO.anchor(URL(fileURLWithPath: value.path))) else { throw M4CatalogError.identityChanged }
    }
    guard try M4CatalogIO.encode(ancestors) == M4CatalogIO.encode(M4CatalogIO.ancestors([root] + retainedControls)) else { throw M4CatalogError.identityChanged }
  }
  func digest() throws -> String {
    try validate(); return M4CatalogIO.hash(Data("football-record.owned-capsule.v1\0".utf8) + (try M4CatalogIO.encode(self)))
  }
  func deviceBinding() throws -> DeviceSyncNamespaceBinding {
    guard kind == .deviceSync, root.directory else { throw M4CatalogError.intentMismatch }
    return try DeviceSyncNamespaceBinding(namespaceID: namespaceID, accountID: scope.accountID,
      cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: UInt64(scope.activationEpoch),
      catalogRevision: revision, catalogDigest: digest(), rootIdentity: DeviceSyncRootIdentity(device: root.device, inode: root.inode))
  }
}
struct M4DeletionChoices: Codable, Sendable {
  let cloud, local, health: ClientDeletionChoiceV4
  let healthConfirmed: Bool
}
/// One bounded dispatch record, atomically published with its frozen plan.
/// This is neither fresh authorization nor proof that a Store Saga committed.
struct M4DeletionCreationMetadata: Codable, Sendable {
  enum Dispatch: String, Codable, Sendable { case reserved, started }
  let version: Int
  let requestID: String
  let scope: CloudScope
  let choices: M4DeletionChoices
  let firstReauthID, authRequestID, authReceiptDigest: String
  let identityGeneration, confirmedAt: Int64
  var dispatch: Dispatch
  init(version: Int, requestID: String, scope: CloudScope, choices: M4DeletionChoices, firstReauthID: String, authRequestID: String, authReceiptDigest: String, identityGeneration: Int64, confirmedAt: Int64, dispatch: Dispatch) {
    self.version = version; self.requestID = requestID; self.scope = scope; self.choices = choices
    self.firstReauthID = firstReauthID; self.authRequestID = authRequestID; self.authReceiptDigest = authReceiptDigest
    self.identityGeneration = identityGeneration; self.confirmedAt = confirmedAt; self.dispatch = dispatch
  }
  private enum CodingKeys: String, CodingKey { case version, requestID, scope, choices, firstReauthID, authRequestID, authReceiptDigest, identityGeneration, confirmedAt, dispatch }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(version: try c.decode(Int.self, forKey: .version), requestID: try c.decode(String.self, forKey: .requestID), scope: try c.decode(CloudScope.self, forKey: .scope), choices: try c.decode(M4DeletionChoices.self, forKey: .choices), firstReauthID: try c.decode(String.self, forKey: .firstReauthID), authRequestID: try c.decode(String.self, forKey: .authRequestID), authReceiptDigest: try c.decode(String.self, forKey: .authReceiptDigest), identityGeneration: try c.decode(Int64.self, forKey: .identityGeneration), confirmedAt: try c.decode(Int64.self, forKey: .confirmedAt), dispatch: try c.decode(Dispatch.self, forKey: .dispatch))
    try validate()
  }
  func validate() throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard [requestID, firstReauthID, authRequestID].allSatisfy({ M4CatalogIO.opaque($0, limit: 128) }),
          M4CatalogIO.isDigest(authReceiptDigest), (0...9_007_199_254_740_991).contains(identityGeneration),
          (0...253_402_300_799).contains(confirmedAt) else { throw M4CatalogError.intentMismatch }
    _ = try CloudScope(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)
    guard try M4CatalogIO.encode(self).count <= 4096 else { throw M4CatalogError.budgetExceeded }
  }
  func validateTransition(from prior: Self) throws {
    try validate(); try prior.validate()
    var immutable = self; immutable.dispatch = prior.dispatch
    guard try M4CatalogIO.encode(immutable) == M4CatalogIO.encode(prior),
          prior.dispatch == .reserved || dispatch == .started else { throw M4CatalogError.intentMismatch }
  }
}
enum M4ManagedDeletionVerificationPhase { case beforeTransaction, afterTransaction }
struct M4HealthSelectionReference: Codable, Sendable {
  let requestID: UUID
  let selectionDigest: String
  let confirmationID: UUID?
}
enum M4HealthSelectionIssue: String, Codable, Sendable { case sourceUnavailable, missingMapping, unsupportedSelection }
/// The exact target payload lives in the retained 028 ledger. This journal only
/// retains references/digests and honest missing-mapping diagnostics.
struct M4HealthReservation: Codable, Sendable {
  let selections: [M4HealthSelectionReference]
  let issue: M4HealthSelectionIssue?
  let rawArtifactDigest: String?
  init(selections: [M4HealthSelectionReference], issue: M4HealthSelectionIssue?, rawArtifactDigest: String? = nil) {
    self.selections = selections; self.issue = issue; self.rawArtifactDigest = rawArtifactDigest
  }
  static let empty = Self(selections: [], issue: nil)
}
struct M4HealthPreparedReference: Codable, Sendable {
  let reservationDigest, preparedDigest, parentDigest: String
  let selection: M4HealthSelectionReference
}
struct M4DeletionFullSeal: Codable, Sendable {
  let version: Int
  let parentIntentDigest, catalogDigest: String
  let health: M4HealthFullSeal?
}
struct M4CatalogEntry: Codable, Sendable { let capsule: M4OwnershipCapsule; var retired: Bool }
struct M4CatalogIndex: Codable, Sendable {
  let revision: UInt64
  let entries: [M4CatalogEntry]
  func digest() throws -> String { M4CatalogIO.hash(Data("football-record.owned-index.v1\0".utf8) + (try M4CatalogIO.encode(self))) }
}
struct M4CatalogChild: Codable, Sendable {
  let componentID, capsuleDigest, requestID: String
}
/// Routing and exact first bytes only; a cached receipt never replaces replay
/// of each real leaf's current inventory/zero checks by the aggregate driver.
struct M4StoreCompletionEvidence: Codable, Sendable {
  let requestID, parentIntentDigest, backendReceiptDigest: String
  let scope: CloudScope
  let database: M4CatalogPath
  let localProgress: ClientDeletionProgressV4
}
struct M4StagingCompletionEvidence: Codable, Sendable {
  let requestID, requestDigest, stableZoneKey: String
  init(_ receipt: CloudStagingEraseReceipt) { requestID = receipt.requestID; requestDigest = receipt.requestDigest; stableZoneKey = receipt.stableZoneKey }
}
struct M4RetainedLeafReceipt: Codable, Sendable {
  static let maximumPayloadBytes = 16_384
  let version: Int
  let parentID, parentIntentDigest, catalogDigest: String
  let componentID, capsuleDigest, childRequestID: String
  let kind: M4OwnedLeafKind
  let leafDigest, receiptDigest: String
  let canonicalReceipt: Data
  static func capture(plan: M4FrozenDeletionPlan, componentID: String, leafDigest: String, canonicalReceipt: Data) throws -> Self {
    guard canonicalReceipt.count <= Self.maximumPayloadBytes else { throw M4CatalogError.budgetExceeded }
    guard let parent = plan.parentIntentDigest, let entry = plan.entries.first(where: { M4CatalogIO.raw($0.capsule.componentID, componentID) }), let child = plan.children.first(where: { M4CatalogIO.raw($0.componentID, componentID) }) else { throw M4CatalogError.intentMismatch }
    let value = Self(version: 1, parentID: plan.requestID, parentIntentDigest: parent, catalogDigest: plan.catalogDigest, componentID: componentID, capsuleDigest: try entry.capsule.digest(), childRequestID: child.requestID, kind: entry.capsule.kind, leafDigest: leafDigest, receiptDigest: M4CatalogIO.hash(canonicalReceipt), canonicalReceipt: canonicalReceipt)
    try value.validate(plan: plan); return value
  }
  func validate(plan: M4FrozenDeletionPlan) throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard canonicalReceipt.count <= Self.maximumPayloadBytes else { throw M4CatalogError.budgetExceeded }
    guard plan.choices.local == .delete, M4CatalogIO.raw(parentID, plan.requestID), parentIntentDigest == plan.parentIntentDigest, catalogDigest == plan.catalogDigest,
          let entry = plan.entries.first(where: { M4CatalogIO.raw($0.capsule.componentID, componentID) }),
          let child = plan.children.first(where: { M4CatalogIO.raw($0.componentID, componentID) }),
          kind == entry.capsule.kind, capsuleDigest == (try entry.capsule.digest()), capsuleDigest == child.capsuleDigest,
          M4CatalogIO.raw(childRequestID, child.requestID), M4CatalogIO.isDigest(leafDigest), receiptDigest == M4CatalogIO.hash(canonicalReceipt) else { throw M4CatalogError.intentMismatch }
    let capsule = entry.capsule
    switch kind {
    case .businessStore:
      let proof: M4StoreCompletionEvidence = try M4CatalogIO.decode(canonicalReceipt)
      guard M4CatalogIO.raw(proof.requestID, parentID), proof.parentIntentDigest == parentIntentDigest,
            M4CatalogIO.isDigest(proof.backendReceiptDigest), proof.scope == plan.scope,
            try M4CatalogIO.encode(proof.database) == M4CatalogIO.encode(capsule.root), proof.localProgress == .completed,
            leafDigest == receiptDigest else { throw M4CatalogError.intentMismatch }
    case .cloudLedger:
      let proof: CloudLocalTransportEraseReceipt = try M4CatalogIO.decode(canonicalReceipt)
      guard M4CatalogIO.raw(proof.requestID, childRequestID), proof.stableZoneKey == capsule.scope.stableZoneKey,
            M4CatalogIO.isDigest(proof.requestDigest), leafDigest == proof.requestDigest else { throw M4CatalogError.intentMismatch }
    case .cloudStaging:
      let proof: M4StagingCompletionEvidence = try M4CatalogIO.decode(canonicalReceipt)
      guard M4CatalogIO.raw(proof.requestID, childRequestID), proof.stableZoneKey == capsule.scope.stableZoneKey,
            proof.requestDigest == parentIntentDigest, leafDigest == proof.requestDigest else { throw M4CatalogError.intentMismatch }
    case .deviceSync:
      let proof: DeviceSyncLocalEraseReceipt = try M4CatalogIO.decode(canonicalReceipt)
      let expected = try DeviceSyncLocalEraseRequest(binding: capsule.deviceBinding(), requestID: parentID, requestDigest: parentIntentDigest)
      guard proof.request == expected, proof.intentDigest == (try expected.intentDigest), proof.fenceGeneration > 0,
            leafDigest == proof.intentDigest else { throw M4CatalogError.intentMismatch }
    }
  }
}
struct M4FrozenDeletionPlan: Codable, Sendable {
  let version: Int
  let requestID: String
  let scope: CloudScope
  let choices: M4DeletionChoices
  let health: M4HealthReservation
  let catalogRevision: UInt64
  let catalogDigest: String
  let entries: [M4CatalogEntry]
  var parentIntentDigest: String?
  var children: [M4CatalogChild]
  var receipts: [M4RetainedLeafReceipt]? = nil
  var preparedHealth: M4HealthPreparedReference? = nil
  var fullSeal: M4DeletionFullSeal? = nil
  private struct Metadata: Encodable {
    let preparedHealth: M4HealthPreparedReference?
    let fullSeal: M4DeletionFullSeal?
  }
  func validateControlMetadata() throws {
    guard try M4CatalogIO.encode(Metadata(preparedHealth: preparedHealth, fullSeal: fullSeal)).count <= 16_384 else { throw M4CatalogError.budgetExceeded }
    if let digest = health.rawArtifactDigest {
      guard M4CatalogIO.isDigest(digest), choices.health == .delete, health.issue == nil, health.selections.isEmpty else { throw M4CatalogError.intentMismatch }
    }
    if let prepared = preparedHealth {
      guard choices.health == .delete, health.issue == nil, prepared.reservationDigest == health.rawArtifactDigest,
            prepared.parentDigest == parentIntentDigest, M4CatalogIO.isDigest(prepared.preparedDigest),
            M4CatalogIO.isDigest(prepared.selection.selectionDigest), prepared.selection.confirmationID != nil else { throw M4CatalogError.intentMismatch }
    }
    if let seal = fullSeal {
      guard seal.version == 1 else { throw M4CatalogError.unsupportedSchema }
      guard seal.parentIntentDigest == parentIntentDigest, seal.catalogDigest == catalogDigest else { throw M4CatalogError.intentMismatch }
      if choices.health == .delete {
        guard let prepared = preparedHealth, let value = seal.health, value.version == 1,
              M4CatalogIO.raw(value.parentID, requestID), value.parentDigest == parentIntentDigest,
              value.reservationDigest == health.rawArtifactDigest, value.preparedDigest == prepared.preparedDigest,
              value.catalogDigest == catalogDigest, value.scope == (try CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)),
              value.cloud == choices.cloud, value.local == choices.local, value.health == choices.health,
              value.healthConfirmed == choices.healthConfirmed, choices.healthConfirmed else { throw M4CatalogError.intentMismatch }
      } else { guard seal.health == nil, preparedHealth == nil, health.rawArtifactDigest == nil else { throw M4CatalogError.intentMismatch } }
    }
  }
  func canonicalBytes() throws -> Data { try M4CatalogIO.encode(self) }
  func expectedChildren(_ digest: String) throws -> [M4CatalogChild] {
    try entries.map { entry in
      let c = entry.capsule, capsuleDigest = try c.digest()
      let fields = [requestID, digest, c.namespaceID, c.componentID, capsuleDigest, c.kind.rawValue,
        c.scope.accountID, c.scope.cloudSpaceID, c.scope.zoneID, String(c.scope.activationEpoch)]
      // 037 deliberately binds the original parent, while 033/024 use child IDs.
      let child = c.kind == .deviceSync ? requestID : M4CatalogIO.framedHash(domain: "football-record.local-erase-child.v1", fields: fields)
      return M4CatalogChild(componentID: c.componentID, capsuleDigest: capsuleDigest, requestID: child)
    }
  }
  func validate() throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard M4CatalogIO.opaque(requestID, limit: 128), !entries.isEmpty, entries.count <= 256,
          M4CatalogIO.isDigest(catalogDigest), catalogRevision > 0,
          try M4CatalogIndex(revision: catalogRevision, entries: entries).digest() == catalogDigest,
          health.selections.count <= 256,
          Set(health.selections.map(\.requestID)).count == health.selections.count,
          health.selections.allSatisfy({ M4CatalogIO.isDigest($0.selectionDigest) }) else { throw M4CatalogError.intentMismatch }
    guard choices.health != .delete || (choices.healthConfirmed && (!health.selections.isEmpty || health.issue != nil || health.rawArtifactDigest != nil)) else { throw M4CatalogError.intentMismatch }
    guard choices.health != .keep || (health.selections.isEmpty && health.issue == nil && health.rawArtifactDigest == nil) else { throw M4CatalogError.intentMismatch }
    try validateControlMetadata()
    for entry in entries {
      try entry.capsule.validate()
      let original = entry.capsule.scope
      guard M4CatalogIO.raw(original.accountID, scope.accountID), M4CatalogIO.raw(original.cloudSpaceID, scope.cloudSpaceID),
            M4CatalogIO.raw(original.zoneID, scope.zoneID), original.activationEpoch <= scope.activationEpoch else { throw M4CatalogError.intentMismatch }
    }
    if let digest = parentIntentDigest {
      guard M4CatalogIO.isDigest(digest), try M4CatalogIO.encode(children) == M4CatalogIO.encode(expectedChildren(digest)) else { throw M4CatalogError.intentMismatch }
    } else { guard children.isEmpty else { throw M4CatalogError.intentMismatch } }
    if let receipts {
      guard !receipts.isEmpty, receipts.count <= entries.count,
            Set(receipts.map { Data($0.componentID.utf8) }).count == receipts.count,
            try M4CatalogIO.encode(receipts) == M4CatalogIO.encode(receipts.sorted { Data($0.componentID.utf8).lexicographicallyPrecedes(Data($1.componentID.utf8)) }) else { throw M4CatalogError.intentMismatch }
      for receipt in receipts { try receipt.validate(plan: self) }
    }
  }
}
/// Physical ownership only. No account, epoch, deletion parent or business permission.
struct M4PhysicalResourceReservation: Codable, Sendable {
  let version: Int
  let reservationID, namespace, installationID, keyID: String
  let candidate, directory, owner, businessSlot, businessDatabase, ledgerSlot: M4CatalogPath
  let identityControls, catalogControls, ancestors: [M4CatalogPath]
  let catalogOwnerDigest: String
  func validate() throws {
    guard version == 1, UUID(uuidString: reservationID)?.uuidString == reservationID,
          UUID(uuidString: installationID)?.uuidString == installationID,
          M4CatalogIO.opaque(namespace, limit: 128), M4CatalogIO.isDigest(keyID),
          candidate.directory, directory.directory, !owner.directory, !businessSlot.directory,
          !businessDatabase.directory, !ledgerSlot.directory,
          M4CatalogIO.sameInode(candidate, directory), M4CatalogIO.sameInode(businessSlot, businessDatabase),
          identityControls.count == 2, catalogControls.count == 3, M4CatalogIO.isDigest(catalogOwnerDigest), ancestors.count <= 4096 else { throw M4CatalogError.intentMismatch }
    for path in [candidate, directory, owner, businessSlot, businessDatabase, ledgerSlot] + identityControls + catalogControls + ancestors { try M4CatalogIO.validate(path) }
    let catalogDirectory = URL(fileURLWithPath: directory.path).deletingLastPathComponent().appendingPathComponent("catalog")
    guard catalogControls.map({ $0.path }) == ["catalog.owner", "catalog.slot0", "catalog.slot1"].map({ catalogDirectory.appendingPathComponent($0).path }), catalogControls.allSatisfy({ !$0.directory }),
          owner.path == directory.path + "/resource.owner", businessSlot.path == directory.path + "/business.slot",
          ledgerSlot.path == directory.path + "/ledger.slot", businessDatabase.path != businessSlot.path,
          candidate.path == URL(fileURLWithPath: directory.path).deletingLastPathComponent().appendingPathComponent(".resources.init-" + reservationID).path,
          businessDatabase.path.hasSuffix("/matches.sqlite"),
          Set(identityControls.map { Data($0.path.utf8) }).count == 2,
          Set(([owner, businessSlot, ledgerSlot] + identityControls + catalogControls).map { "\($0.device):\($0.inode)" }).count == 8 else { throw M4CatalogError.intentMismatch }
  }
}
/// Retained signed-grant provenance; only the original factory witness may
/// select it. Decoding this DTO is never current identity admission.
struct M4PhoneScopeAttachment: Codable, Sendable {
  let attachmentID, physicalReservationID: String
  let identityGeneration: Int64
  let currentAuthRequestID: String
  let attempt: AuthAttemptV4
  let binding: AccountBindingV4
  let receiptRaw: Data
  let scope: CloudScope
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    guard UUID(uuidString: attachmentID)?.uuidString == attachmentID,
          physicalReservationID == physical.reservationID, (0...9_007_199_254_740_991).contains(identityGeneration),
          binding.role == .phone, !binding.suspended, receiptRaw.count > 0, receiptRaw.count <= 65536,
          M4CatalogIO.raw(currentAuthRequestID, attempt.requestID),
          M4CatalogIO.raw(binding.deviceID, physical.installationID), M4CatalogIO.raw(attempt.deviceID, binding.deviceID),
          M4CatalogIO.raw(attempt.cloudSpaceID, binding.cloudSpaceID), attempt.keyID == physical.keyID,
          attempt.environment == binding.environment,
          M4CatalogIO.raw(scope.accountID, binding.accountID), M4CatalogIO.raw(scope.cloudSpaceID, binding.cloudSpaceID),
          scope.activationEpoch == binding.activationEpoch else { throw M4CatalogError.intentMismatch }
    guard try AuthorityWire.deviceKeyID(publicKey: attempt.publicKey) == attempt.keyID else { throw M4CatalogError.intentMismatch }
    _ = try CloudScope(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)
    guard try M4CatalogIO.encode(self).count <= 131072 else { throw M4CatalogError.budgetExceeded }
  }
  func matches(_ value: VerifiedLocalAuthenticationEvidenceV4) throws -> Bool {
    let attemptMatches = try M4CatalogIO.encode(attempt) == M4CatalogIO.encode(value.attempt)
    let bindingMatches = try M4CatalogIO.encode(binding) == M4CatalogIO.encode(value.binding)
    return identityGeneration == value.identityGeneration && value.admissionGeneration == identityGeneration &&
      M4CatalogIO.raw(currentAuthRequestID, value.currentAuthRequestID) && receiptRaw == value.receipt.raw && attemptMatches && bindingMatches
  }
  func digest() throws -> String { M4CatalogIO.hash(try M4CatalogIO.encode(self)) }
}
struct M4PhoneLedgerDescriptor: Codable, Sendable {
  let ledgerID: String
  let source, published: M4CatalogPath
  let ancestors: [M4CatalogPath]
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    guard UUID(uuidString: ledgerID)?.uuidString == ledgerID,
          try M4CatalogIO.encode(source) == M4CatalogIO.encode(physical.ledgerSlot),
          published.path == physical.directory.path + "/ledger-" + ledgerID + ".sqlite",
          !published.directory, M4CatalogIO.sameInode(source, published), ancestors.count <= 4096 else { throw M4CatalogError.intentMismatch }
    for value in [source, published] + ancestors { try M4CatalogIO.validate(value) }
  }
  var componentID: String { "m4-cloud-ledger-" + ledgerID }
}
struct M4PhonePairSeal: Codable, Sendable {
  let attachmentDigest, storeDigest, ledgerDigest: String
}
struct M4PhoneResourceState: Codable, Sendable {
  let attachment: M4PhoneScopeAttachment
  let ledger: M4PhoneLedgerDescriptor
  var published: Bool
  var seal: M4PhonePairSeal?
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    try attachment.validate(physical); try ledger.validate(physical)
    if let seal {
      guard published, seal.attachmentDigest == (try attachment.digest()),
            M4CatalogIO.isDigest(seal.storeDigest), M4CatalogIO.isDigest(seal.ledgerDigest) else { throw M4CatalogError.intentMismatch }
    }
  }
}
/// Original accepted055 provenance only; no Phone authentication is embedded.
struct M4WatchScopeAttachment: Codable, Sendable {
  let version: Int
  let attachmentID, physicalReservationID: String
  let binding: AccountBindingV4
  let identityGeneration, acceptedGeneration: Int64
  let currentWatchRequestID: String
  let attempt: WatchRegistrationAttemptV4
  let admittedContext: WatchRegistrationContextV4
  let watchDeviceKeyID: String
  let receiptRaw: Data
  let latestMigration: AuthorityMigrationV1?
  let scope: CloudScope
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    try attempt.validate()
    guard version == 1, UUID(uuidString: attachmentID)?.uuidString == attachmentID,
          physicalReservationID == physical.reservationID, (0...9_007_199_254_740_991).contains(identityGeneration), acceptedGeneration == identityGeneration,
          binding.role == .watch, !binding.suspended, receiptRaw.count > 0, receiptRaw.count <= 65536,
          M4CatalogIO.raw(currentWatchRequestID, attempt.requestID),
          M4CatalogIO.raw(binding.deviceID, physical.installationID), M4CatalogIO.raw(attempt.payload.watchID, binding.deviceID),
          watchDeviceKeyID == physical.keyID, try AuthorityWire.deviceKeyID(publicKey: attempt.payload.watchPublicKey) == watchDeviceKeyID,
          M4CatalogIO.raw(binding.accountID, admittedContext.accountID), M4CatalogIO.raw(binding.cloudSpaceID, admittedContext.cloudSpaceID),
          binding.activationEpoch == admittedContext.activationEpoch, binding.environment == admittedContext.environment,
          try M4CatalogIO.encode(admittedContext) == M4CatalogIO.encode(attempt.context),
          M4CatalogIO.raw(scope.accountID, binding.accountID), M4CatalogIO.raw(scope.cloudSpaceID, binding.cloudSpaceID), scope.activationEpoch == binding.activationEpoch,
          latestMigration == nil || latestMigration?.state == "activated" else { throw M4CatalogError.intentMismatch }
    _ = try CloudScope(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)
    guard try M4CatalogIO.encode(self).count <= 131072 else { throw M4CatalogError.budgetExceeded }
  }
  func matches(_ value: VerifiedLocalWatchRegistrationEvidenceV4) throws -> Bool {
    let bindingMatches = try M4CatalogIO.encode(binding) == M4CatalogIO.encode(value.binding)
    let attemptMatches = try M4CatalogIO.encode(attempt) == M4CatalogIO.encode(value.attempt)
    let contextMatches = try M4CatalogIO.encode(admittedContext) == M4CatalogIO.encode(value.admittedContext)
    let migrationMatches = try M4CatalogIO.encode(latestMigration) == M4CatalogIO.encode(value.latestMigration)
    return identityGeneration == value.identityGeneration && acceptedGeneration == value.acceptedGeneration &&
      M4CatalogIO.raw(currentWatchRequestID, value.currentWatchRequestID) && M4CatalogIO.raw(watchDeviceKeyID, value.watchDeviceKeyID) &&
      receiptRaw == value.receipt.raw && bindingMatches && attemptMatches && contextMatches && migrationMatches
  }
  func digest() throws -> String { M4CatalogIO.hash(try M4CatalogIO.encode(self)) }
}
struct M4WatchLedgerDescriptor: Codable, Sendable {
  let ledgerID: String
  let source, published: M4CatalogPath
  let ancestors: [M4CatalogPath]
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    guard UUID(uuidString: ledgerID)?.uuidString == ledgerID,
          try M4CatalogIO.encode(source) == M4CatalogIO.encode(physical.ledgerSlot),
          published.path == physical.directory.path + "/ledger-" + ledgerID + ".sqlite",
          !published.directory, M4CatalogIO.sameInode(source, published), ancestors.count <= 4096 else { throw M4CatalogError.intentMismatch }
    for value in [source, published] + ancestors { try M4CatalogIO.validate(value) }
  }
  var componentID: String { "m4-watch-cloud-ledger-" + ledgerID }
}
struct M4WatchPairSeal: Codable, Sendable {
  let attachmentDigest, storeDigest, ledgerDigest: String
}
struct M4WatchResourceState: Codable, Sendable {
  let attachment: M4WatchScopeAttachment
  let ledger: M4WatchLedgerDescriptor
  var published: Bool
  var seal: M4WatchPairSeal?
  func validate(_ physical: M4PhysicalResourceReservation) throws {
    try attachment.validate(physical); try ledger.validate(physical)
    if let seal {
      guard published, seal.attachmentDigest == (try attachment.digest()),
            M4CatalogIO.isDigest(seal.storeDigest), M4CatalogIO.isDigest(seal.ledgerDigest) else { throw M4CatalogError.intentMismatch }
    }
  }
}
struct M4PhysicalBootstrapState: Codable, Sendable {
  let reservation: M4PhysicalResourceReservation
  var resourcesPublished, businessPublished: Bool
  var phone: M4PhoneResourceState? = nil
  var watch: M4WatchResourceState? = nil
  func validate() throws {
    try reservation.validate()
    try phone?.validate(reservation); try watch?.validate(reservation)
    guard phone == nil || watch == nil, watch == nil || businessPublished else { throw M4CatalogError.intentMismatch }
    guard phone == nil || businessPublished else { throw M4CatalogError.intentMismatch }
    guard !businessPublished || resourcesPublished else { throw M4CatalogError.intentMismatch }
  }
}
struct M4CatalogState: Codable {
  let version: Int
  var revision: UInt64
  var entries: [M4CatalogEntry]
  var plans: [M4FrozenDeletionPlan]
  var membershipRevision: UInt64? = nil
  var physicalBootstrap: M4PhysicalBootstrapState? = nil
  var deletionCreation: M4DeletionCreationMetadata? = nil
  var ownedRevision: UInt64 { membershipRevision ?? plans.first?.catalogRevision ?? revision }
  static let empty = Self(version: 1, revision: 0, entries: [], plans: [])
  /// Encode a private, deliberately invalid upper-bound shape only to measure
  /// space. It is never validated as a receipt, returned, or written. Every
  /// actual payload stays at most maximumPayloadBytes; hashes have fixed width.
  /// Reserve additional bounded room for raw/prepared refs and the full seal.
  func requireCompletionCapacity() throws {
    guard let original = plans.first else { throw M4CatalogError.intentMismatch }
    let missingReceipts = original.choices.local == .delete ? original.entries.count - (original.receipts?.count ?? 0) : 0
    // One write per first receipt and sixteen bounded preparation/seal steps.
    // Idempotent retries do not advance the journal. Refuse before any erase if
    // even these control writes could exhaust the retained revision counter.
    guard revision <= UInt64.max - UInt64(missingReceipts + 16) else { throw M4CatalogError.budgetExceeded }
    var bound = self, plan = original
    bound.revision = UInt64.max; bound.membershipRevision = UInt64.max
    let digest = plan.parentIntentDigest ?? String(repeating: "f", count: 64)
    plan.parentIntentDigest = digest; plan.children = try plan.expectedChildren(digest)
    if plan.choices.local == .delete {
      let payload = Data(repeating: 0, count: M4RetainedLeafReceipt.maximumPayloadBytes)
      plan.receipts = try plan.entries.map { entry in
        let capsule = entry.capsule
        guard let child = plan.children.first(where: { M4CatalogIO.raw($0.componentID, capsule.componentID) }) else { throw M4CatalogError.intentMismatch }
        return M4RetainedLeafReceipt(version: 1, parentID: plan.requestID, parentIntentDigest: digest, catalogDigest: plan.catalogDigest,
          componentID: capsule.componentID, capsuleDigest: try capsule.digest(), childRequestID: child.requestID, kind: capsule.kind,
          leafDigest: String(repeating: "f", count: 64), receiptDigest: String(repeating: "f", count: 64), canonicalReceipt: payload)
      }
    }
    // The fixed metadata reserve replaces, rather than duplicates, metadata
    // already published by a later preparation/seal step.
    try plan.validateControlMetadata()
    plan.preparedHealth = nil; plan.fullSeal = nil
    bound.plans = [plan]
    let reservedControlBytes = 16_384
    guard try M4CatalogIO.encode(bound).count <= M4CatalogJournal.maximumJournalBytes - reservedControlBytes else { throw M4CatalogError.budgetExceeded }
  }
  func validate() throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard ownedRevision <= revision else { throw M4CatalogError.intentMismatch }
    try physicalBootstrap?.validate()
    guard entries.count <= 256, plans.count <= 1 else { throw M4CatalogError.budgetExceeded }
    guard Set(entries.map { Data($0.capsule.componentID.utf8) }).count == entries.count,
          try M4CatalogIO.encode(entries) == M4CatalogIO.encode(entries.sorted { Data($0.capsule.componentID.utf8).lexicographicallyPrecedes(Data($1.capsule.componentID.utf8)) }) else { throw M4CatalogError.intentMismatch }
    for entry in entries { try entry.capsule.validate() }
    if let phone = physicalBootstrap?.phone, let seal = phone.seal {
      guard let store = entries.first(where: { $0.capsule.componentID == "m4-business-store" }),
            let ledger = entries.first(where: { $0.capsule.componentID == phone.ledger.componentID }),
            !store.retired, !ledger.retired, store.capsule.kind == .businessStore, ledger.capsule.kind == .cloudLedger,
            store.capsule.scope == phone.attachment.scope, ledger.capsule.scope == phone.attachment.scope,
            try store.capsule.digest() == seal.storeDigest, try ledger.capsule.digest() == seal.ledgerDigest,
            let physical = physicalBootstrap?.reservation,
            try M4CatalogIO.encode(store.capsule.root) == M4CatalogIO.encode(physical.businessDatabase),
            try M4CatalogIO.encode(ledger.capsule.root) == M4CatalogIO.encode(phone.ledger.published) else { throw M4CatalogError.intentMismatch }
    }
    if let watch = physicalBootstrap?.watch, let seal = watch.seal {
      guard let store = entries.first(where: { $0.capsule.componentID == "m4-business-store" }),
            let ledger = entries.first(where: { $0.capsule.componentID == watch.ledger.componentID }),
            !store.retired, !ledger.retired, store.capsule.kind == .businessStore, ledger.capsule.kind == .cloudLedger,
            store.capsule.scope == watch.attachment.scope, ledger.capsule.scope == watch.attachment.scope,
            try store.capsule.digest() == seal.storeDigest, try ledger.capsule.digest() == seal.ledgerDigest,
            let physical = physicalBootstrap?.reservation,
            try M4CatalogIO.encode(store.capsule.root) == M4CatalogIO.encode(physical.businessDatabase),
            try M4CatalogIO.encode(ledger.capsule.root) == M4CatalogIO.encode(watch.ledger.published) else { throw M4CatalogError.intentMismatch }
    }
    if let creation = deletionCreation {
      try creation.validate()
      guard let physical = physicalBootstrap, physical.resourcesPublished, physical.businessPublished, physical.watch == nil,
            let phone = physical.phone, phone.published, let seal = phone.seal,
            entries.count == 2, entries.allSatisfy({ !$0.retired }), let plan = plans.first,
            M4CatalogIO.raw(plan.requestID, creation.requestID), plan.scope == creation.scope,
            try M4CatalogIO.encode(plan.choices) == M4CatalogIO.encode(creation.choices),
            creation.scope == phone.attachment.scope,
            M4CatalogIO.raw(creation.authRequestID, phone.attachment.currentAuthRequestID),
            creation.authReceiptDigest == M4CatalogIO.hash(phone.attachment.receiptRaw),
            creation.identityGeneration == phone.attachment.identityGeneration,
            creation.choices.cloud == .keep, creation.choices.local == .delete, creation.choices.health == .keep, !creation.choices.healthConfirmed,
            try M4CatalogIO.encode(plan.health) == M4CatalogIO.encode(M4HealthReservation.empty),
            Set(entries.map { $0.capsule.kind }) == [.businessStore, .cloudLedger],
            entries.allSatisfy({ $0.capsule.scope == creation.scope }),
            try entries.contains(where: { try $0.capsule.kind == .businessStore && $0.capsule.digest() == seal.storeDigest }),
            try entries.contains(where: { try $0.capsule.kind == .cloudLedger && $0.capsule.digest() == seal.ledgerDigest }) else { throw M4CatalogError.intentMismatch }
      if creation.dispatch == .reserved {
        guard plan.parentIntentDigest == nil, plan.children.isEmpty, plan.receipts == nil, plan.preparedHealth == nil, plan.fullSeal == nil else { throw M4CatalogError.intentMismatch }
      }
    }
    for plan in plans {
      try plan.validate()
      guard plan.catalogRevision == ownedRevision, plan.catalogRevision <= revision, try M4CatalogIO.encode(plan.entries) == M4CatalogIO.encode(entries) else { throw M4CatalogError.intentMismatch }
    }
  }
}
/// A provisional storage projection only. This grants no resource-owner,
/// lineage, lease, parent, business or deletion authority. A future physical
/// owner must retain the same catalog object and apply its original admission gates.
struct M4CatalogOpeningSnapshot: Sendable {
  let journalRevision: UInt64
  let index: M4CatalogIndex
  let physical: M4PhysicalBootstrapState?
  let creation: M4DeletionCreationMetadata?
  let plan: M4FrozenDeletionPlan?
}
/// All operations are synchronous bounded journal transactions. An outer
/// composition barrier must quiesce actors before reserve/seal/resume admission.
final class M4OwnedDataCatalog: @unchecked Sendable {
  private let journal: M4CatalogJournal
  init(directory: URL, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)? = nil, synchronizationFault: M4CatalogSyncBoundary? = nil) throws { journal = try M4CatalogJournal(directory: directory, crashHook: crashHook, synchronizationFault: synchronizationFault) }
  init(existingDirectory: URL, crashHook: (@Sendable (M4CatalogCrashPoint) -> Void)? = nil, synchronizationFault: M4CatalogSyncBoundary? = nil) throws {
    journal = try M4CatalogJournal(existingDirectory: existingDirectory, crashHook: crashHook, synchronizationFault: synchronizationFault)
  }
  /// One validated journal read, including original fsync/pending stabilization.
  /// This neither creates a state/revision nor authorizes a consumer action.
  func openingSnapshot() throws -> M4CatalogOpeningSnapshot {
    let state = try journal.read()
    return M4CatalogOpeningSnapshot(journalRevision: state.revision,
      index: M4CatalogIndex(revision: state.ownedRevision, entries: state.entries),
      physical: state.physicalBootstrap, creation: state.deletionCreation, plan: state.plans.first)
  }
  func physicalBootstrap() throws -> M4PhysicalBootstrapState? { try journal.read().physicalBootstrap }
  func reservePhysicalBootstrap(_ reservation: M4PhysicalResourceReservation) throws {
    try reservation.validate()
    try journal.transaction { state in
      if let prior = state.physicalBootstrap {
        guard try M4CatalogIO.encode(prior.reservation) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.intentMismatch }; return
      }
      guard state.entries.isEmpty, state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
      state.membershipRevision = state.ownedRevision
      state.physicalBootstrap = M4PhysicalBootstrapState(reservation: reservation, resourcesPublished: false, businessPublished: false)
    }
    guard let saved = try physicalBootstrap(), try M4CatalogIO.encode(saved.reservation) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.storageBlocked }
  }
  func recordPhysicalPublication(_ reservation: M4PhysicalResourceReservation, business: Bool) throws {
    try journal.transaction { state in
      guard var prior = state.physicalBootstrap, state.plans.isEmpty,
            try M4CatalogIO.encode(prior.reservation) == M4CatalogIO.encode(reservation) else { throw M4CatalogError.intentMismatch }
      if business { guard prior.resourcesPublished else { throw M4CatalogError.intentMismatch }; prior.businessPublished = true }
      else { prior.resourcesPublished = true }
      state.physicalBootstrap = prior
    }
    guard let saved = try physicalBootstrap(), saved.resourcesPublished, !business || saved.businessPublished else { throw M4CatalogError.storageBlocked }
  }
  func phoneResources() throws -> M4PhoneResourceState? { try journal.read().physicalBootstrap?.phone }
  func reservePhoneResources(_ phone: M4PhoneResourceState, store: M4OwnershipCapsule, ledger: M4OwnershipCapsule) throws {
    func matches(_ value: M4PhoneResourceState?) throws -> Bool {
      guard let value else { return false }
      return try M4CatalogIO.encode(value.attachment) == M4CatalogIO.encode(phone.attachment) && M4CatalogIO.encode(value.ledger) == M4CatalogIO.encode(phone.ledger)
    }
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, physical.businessPublished, physical.watch == nil, state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
        try phone.validate(physical.reservation)
        if physical.phone != nil { guard try matches(physical.phone) else { throw M4CatalogError.intentMismatch }; return }
        guard !phone.published, phone.seal == nil, state.entries.isEmpty else { throw M4CatalogError.intentMismatch }
        // Private capacity estimate with exact prospective paths/inodes/capsules.
        // It is never persisted or returned as a seal before real publication.
        var bound = state, future = physical, complete = phone
        complete.published = true
        complete.seal = M4PhonePairSeal(attachmentDigest: try phone.attachment.digest(), storeDigest: try store.digest(), ledgerDigest: try ledger.digest())
        future.phone = complete; bound.physicalBootstrap = future
        bound.entries = [M4CatalogEntry(capsule: store, retired: false), M4CatalogEntry(capsule: ledger, retired: false)]
        guard try M4CatalogIO.encode(bound).count <= M4CatalogJournal.maximumJournalBytes - 16384 else { throw M4CatalogError.budgetExceeded }
        physical.phone = phone; state.physicalBootstrap = physical
      }
    } catch { guard (try? matches(phoneResources())) == true else { throw error } }
    guard try matches(phoneResources()) else { throw M4CatalogError.storageBlocked }
  }
  func publishPhoneLedger(_ descriptor: M4PhoneLedgerDescriptor) throws {
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, var phone = physical.phone, state.plans.isEmpty,
              try M4CatalogIO.encode(phone.ledger) == M4CatalogIO.encode(descriptor) else { throw M4CatalogError.intentMismatch }
        phone.published = true; physical.phone = phone; state.physicalBootstrap = physical
      }
    } catch { guard (try? phoneResources()?.published) == true else { throw error } }
    guard let saved = try phoneResources(), saved.published,
          try M4CatalogIO.encode(saved.ledger) == M4CatalogIO.encode(descriptor) else { throw M4CatalogError.storageBlocked }
  }
  func sealPhoneResources(store: M4OwnershipCapsule, ledger: M4OwnershipCapsule) throws -> M4PhonePairSeal {
    try store.verifyCurrent(); try ledger.verifyCurrent()
    func recordReadback(_ capsule: M4OwnershipCapsule) throws {
      do { try record(capsule) }
      catch {
        guard let entry = try? index().entries.first(where: { $0.capsule.componentID == capsule.componentID }),
              try entry.capsule.digest() == capsule.digest() else { throw error }
      }
    }
    try recordReadback(ledger); try recordReadback(store)
    guard let phone = try phoneResources(), phone.published else { throw M4CatalogError.intentMismatch }
    let seal = M4PhonePairSeal(attachmentDigest: try phone.attachment.digest(), storeDigest: try store.digest(), ledgerDigest: try ledger.digest())
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, var current = physical.phone, state.plans.isEmpty,
              try current.attachment.digest() == seal.attachmentDigest else { throw M4CatalogError.intentMismatch }
        if let first = current.seal { guard try M4CatalogIO.encode(first) == M4CatalogIO.encode(seal) else { throw M4CatalogError.intentMismatch }; return }
        current.seal = seal; physical.phone = current; state.physicalBootstrap = physical
      }
    } catch {
      guard let saved = try? phoneResources(), let first = saved.seal,
            try M4CatalogIO.encode(first) == M4CatalogIO.encode(seal) else { throw error }
    }
    return try requirePhoneSeal()
  }
  func requirePhoneSeal() throws -> M4PhonePairSeal {
    let state = try journal.read()
    guard let phone = state.physicalBootstrap?.phone, let seal = phone.seal else { throw M4CatalogError.intentMismatch }
    for id in ["m4-business-store", phone.ledger.componentID] {
      guard let entry = state.entries.first(where: { $0.capsule.componentID == id }), !entry.retired else { throw M4CatalogError.intentMismatch }
      try entry.capsule.verifyCurrent()
    }
    return seal
  }
  func watchResources() throws -> M4WatchResourceState? { try journal.read().physicalBootstrap?.watch }
  func reserveWatchResources(_ watch: M4WatchResourceState, store: M4OwnershipCapsule, ledger: M4OwnershipCapsule) throws {
    func matches(_ value: M4WatchResourceState?) throws -> Bool {
      guard let value else { return false }
      return try M4CatalogIO.encode(value.attachment) == M4CatalogIO.encode(watch.attachment) && M4CatalogIO.encode(value.ledger) == M4CatalogIO.encode(watch.ledger)
    }
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, physical.businessPublished, physical.phone == nil, state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
        try watch.validate(physical.reservation)
        if physical.watch != nil { guard try matches(physical.watch) else { throw M4CatalogError.intentMismatch }; return }
        guard !watch.published, watch.seal == nil, state.entries.isEmpty else { throw M4CatalogError.intentMismatch }
        // Private capacity estimate with exact prospective paths/inodes/capsules.
        // It is never persisted or returned as a seal before real publication.
        var bound = state, future = physical, complete = watch
        complete.published = true
        complete.seal = M4WatchPairSeal(attachmentDigest: try watch.attachment.digest(), storeDigest: try store.digest(), ledgerDigest: try ledger.digest())
        future.watch = complete; bound.physicalBootstrap = future
        bound.entries = [M4CatalogEntry(capsule: store, retired: false), M4CatalogEntry(capsule: ledger, retired: false)]
        guard try M4CatalogIO.encode(bound).count <= M4CatalogJournal.maximumJournalBytes - 16384 else { throw M4CatalogError.budgetExceeded }
        physical.watch = watch; state.physicalBootstrap = physical
      }
    } catch { guard (try? matches(watchResources())) == true else { throw error } }
    guard try matches(watchResources()) else { throw M4CatalogError.storageBlocked }
  }
  func publishWatchLedger(_ descriptor: M4WatchLedgerDescriptor) throws {
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, var watch = physical.watch, state.plans.isEmpty,
              try M4CatalogIO.encode(watch.ledger) == M4CatalogIO.encode(descriptor) else { throw M4CatalogError.intentMismatch }
        watch.published = true; physical.watch = watch; state.physicalBootstrap = physical
      }
    } catch { guard (try? watchResources()?.published) == true else { throw error } }
    guard let saved = try watchResources(), saved.published,
          try M4CatalogIO.encode(saved.ledger) == M4CatalogIO.encode(descriptor) else { throw M4CatalogError.storageBlocked }
  }
  func sealWatchResources(store: M4OwnershipCapsule, ledger: M4OwnershipCapsule) throws -> M4WatchPairSeal {
    try store.verifyCurrent(); try ledger.verifyCurrent()
    func recordReadback(_ capsule: M4OwnershipCapsule) throws {
      do { try record(capsule) }
      catch {
        guard let entry = try? index().entries.first(where: { $0.capsule.componentID == capsule.componentID }),
              try entry.capsule.digest() == capsule.digest() else { throw error }
      }
    }
    try recordReadback(ledger); try recordReadback(store)
    guard let watch = try watchResources(), watch.published else { throw M4CatalogError.intentMismatch }
    let seal = M4WatchPairSeal(attachmentDigest: try watch.attachment.digest(), storeDigest: try store.digest(), ledgerDigest: try ledger.digest())
    do {
      try journal.transaction { state in
        guard var physical = state.physicalBootstrap, var current = physical.watch, state.plans.isEmpty,
              try current.attachment.digest() == seal.attachmentDigest else { throw M4CatalogError.intentMismatch }
        if let first = current.seal { guard try M4CatalogIO.encode(first) == M4CatalogIO.encode(seal) else { throw M4CatalogError.intentMismatch }; return }
        current.seal = seal; physical.watch = current; state.physicalBootstrap = physical
      }
    } catch {
      guard let saved = try? watchResources(), let first = saved.seal,
            try M4CatalogIO.encode(first) == M4CatalogIO.encode(seal) else { throw error }
    }
    return try requireWatchSeal()
  }
  func requireWatchSeal() throws -> M4WatchPairSeal {
    let state = try journal.read()
    guard let watch = state.physicalBootstrap?.watch, let seal = watch.seal else { throw M4CatalogError.intentMismatch }
    for id in ["m4-business-store", watch.ledger.componentID] {
      guard let entry = state.entries.first(where: { $0.capsule.componentID == id }), !entry.retired else { throw M4CatalogError.intentMismatch }
      try entry.capsule.verifyCurrent()
    }
    return seal
  }
  func record(_ capsule: M4OwnershipCapsule) throws {
    try capsule.verifyCurrent()
    try journal.transaction { state in
      if let prior = state.entries.first(where: { M4CatalogIO.raw($0.capsule.componentID, capsule.componentID) }) {
        guard try prior.capsule.digest() == capsule.digest() else { throw M4CatalogError.intentMismatch }; return
      }
      guard state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
      try journal.requireOutside(capsule)
      for entry in state.entries {
        let prior = entry.capsule
        guard !M4CatalogIO.sameInode(prior.root, capsule.root),
          !(prior.root.directory && capsule.ancestors.contains(where: { M4CatalogIO.sameInode($0, prior.root) })),
          !(capsule.root.directory && prior.ancestors.contains(where: { M4CatalogIO.sameInode($0, capsule.root) })) else { throw M4CatalogError.intentMismatch }
      }
      guard state.entries.count < 256 else { throw M4CatalogError.budgetExceeded }
      guard state.ownedRevision < UInt64.max else { throw M4CatalogError.budgetExceeded }
      state.membershipRevision = state.ownedRevision + 1
      state.entries.append(M4CatalogEntry(capsule: capsule, retired: false))
      state.entries.sort { Data($0.capsule.componentID.utf8).lexicographicallyPrecedes(Data($1.capsule.componentID.utf8)) }
    }
  }
  func retire(componentID: String) throws {
    try journal.transaction { state in
      guard let index = state.entries.firstIndex(where: { M4CatalogIO.raw($0.capsule.componentID, componentID) }) else { throw M4CatalogError.intentMismatch }
      if state.entries[index].retired { return }
      guard state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
      guard state.ownedRevision < UInt64.max else { throw M4CatalogError.budgetExceeded }
      state.membershipRevision = state.ownedRevision + 1
      state.entries[index].retired = true
    }
  }
  func index() throws -> M4CatalogIndex {
    let state = try journal.read(); return M4CatalogIndex(revision: state.ownedRevision, entries: state.entries)
  }
  func deletionCreation() throws -> M4DeletionCreationMetadata? { try journal.read().deletionCreation }
  /// Full lease/inode/cache checks deliberately bracket the journal lock.
  /// Inside the nonrecursive lock only the captured immutable tuple is compared.
  @MainActor func reserveManagedDeletion(creation: M4DeletionCreationMetadata, borrow: M4ManagedDeletionBorrow, health: M4HealthReservation,
    verificationObserver: (@MainActor (M4ManagedDeletionVerificationPhase) -> Void)? = nil) throws -> M4FrozenDeletionPlan {
    try creation.validate()
    guard borrow.catalog === self, borrow.active, creation.dispatch == .reserved,
          creation.scope == borrow.attachment.scope,
          M4CatalogIO.raw(creation.authRequestID, borrow.attachment.currentAuthRequestID),
          creation.authReceiptDigest == M4CatalogIO.hash(borrow.attachment.receiptRaw),
          creation.identityGeneration == borrow.attachment.identityGeneration,
          creation.choices.cloud == .keep, creation.choices.local == .delete, creation.choices.health == .keep, !creation.choices.healthConfirmed,
          try M4CatalogIO.encode(health) == M4CatalogIO.encode(M4HealthReservation.empty) else { throw M4CatalogError.intentMismatch }
    try managedTransaction(borrow: borrow, verificationObserver: verificationObserver) { state in
      try borrow.requireCapturedState(state)
      if let prior = state.deletionCreation {
        try creation.validateTransition(from: prior)
        guard try M4CatalogIO.encode(prior) == M4CatalogIO.encode(creation) else { throw M4CatalogError.intentMismatch }
        try state.requireCompletionCapacity(); return
      }
      guard state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
      let index = M4CatalogIndex(revision: state.ownedRevision, entries: state.entries)
      let plan = try M4FrozenDeletionPlan(version: 1, requestID: creation.requestID, scope: creation.scope, choices: creation.choices, health: health,
        catalogRevision: index.revision, catalogDigest: index.digest(), entries: index.entries, parentIntentDigest: nil, children: [])
      state.membershipRevision = state.ownedRevision; state.deletionCreation = creation; state.plans = [plan]
      try state.validate(); try Self.requireManagedPublicationCapacity(state)
    }
    guard let saved = try deletionCreation(), try M4CatalogIO.encode(saved) == M4CatalogIO.encode(creation) else { throw M4CatalogError.storageBlocked }
    let plan = try requiredPlan(creation.requestID)
    guard plan.scope == creation.scope, try M4CatalogIO.encode(plan.choices) == M4CatalogIO.encode(creation.choices) else { throw M4CatalogError.storageBlocked }
    try borrow.verify(); return plan
  }
  @MainActor func markManagedDeletionStarted(requestID: String, borrow: M4ManagedDeletionBorrow,
    verificationObserver: (@MainActor (M4ManagedDeletionVerificationPhase) -> Void)? = nil) throws -> M4DeletionCreationMetadata {
    guard borrow.catalog === self else { throw M4CatalogError.intentMismatch }
    try managedTransaction(borrow: borrow, verificationObserver: verificationObserver) { state in
      try borrow.requireCapturedState(state)
      guard let prior = state.deletionCreation, M4CatalogIO.raw(prior.requestID, requestID) else { throw M4CatalogError.intentMismatch }
      if prior.dispatch == .started { try state.requireCompletionCapacity(); return }
      guard borrow.active else { throw M4CatalogError.intentMismatch }
      var next = prior; next.dispatch = .started; try next.validateTransition(from: prior)
      state.deletionCreation = next; try state.validate(); try Self.requireManagedPublicationCapacity(state)
    }
    guard let saved = try deletionCreation(), M4CatalogIO.raw(saved.requestID, requestID), saved.dispatch == .started else { throw M4CatalogError.storageBlocked }
    try borrow.verify(); return saved
  }
  @MainActor private func managedTransaction(borrow: M4ManagedDeletionBorrow,
    verificationObserver: (@MainActor (M4ManagedDeletionVerificationPhase) -> Void)?,
    mutate: (inout M4CatalogState) throws -> Void) throws {
    verificationObserver?(.beforeTransaction); try borrow.verify()
    let publication = Result { try journal.transaction(mutate) }
    verificationObserver?(.afterTransaction)
    let postcheck = Result { try borrow.verify() }
    // A lost response remains the original unknown outcome. Verification never
    // compensates by clearing the published creation or replacing its request.
    try publication.get(); try postcheck.get()
  }
  private static func requireManagedPublicationCapacity(_ state: M4CatalogState) throws {
    // The journal itself adds one after this closure returns. Budget against
    // that actual prospective revision, retaining sixteen further control writes.
    guard state.revision < UInt64.max else { throw M4CatalogError.budgetExceeded }
    var prospective = state; prospective.revision += 1; try prospective.requireCompletionCapacity()
  }
  func reserve(requestID: String, scope: CloudScope, choices: M4DeletionChoices, health: M4HealthReservation) throws -> M4FrozenDeletionPlan {
    try journal.transaction { state in
      guard state.physicalBootstrap == nil else { throw M4CatalogError.intentMismatch }
      if let prior = state.plans.first {
        guard M4CatalogIO.raw(prior.requestID, requestID), prior.scope == scope,
              try M4CatalogIO.encode(prior.choices) == M4CatalogIO.encode(choices),
              try M4CatalogIO.encode(prior.health) == M4CatalogIO.encode(health) else { throw M4CatalogError.intentMismatch }
        try state.requireCompletionCapacity(); return
      }
      let index = M4CatalogIndex(revision: state.ownedRevision, entries: state.entries)
      let plan = try M4FrozenDeletionPlan(version: 1, requestID: requestID, scope: scope, choices: choices, health: health,
        catalogRevision: index.revision, catalogDigest: index.digest(), entries: index.entries, parentIntentDigest: nil, children: [])
      try plan.validate(); state.membershipRevision = state.ownedRevision; state.plans.append(plan); try state.requireCompletionCapacity()
    }
    return try requiredPlan(requestID)
  }
  func seal(requestID: String, parentIntentDigest: String) throws -> M4FrozenDeletionPlan {
    guard M4CatalogIO.isDigest(parentIntentDigest) else { throw M4CatalogError.intentMismatch }
    try journal.transaction { state in
      guard let index = state.plans.firstIndex(where: { M4CatalogIO.raw($0.requestID, requestID) }) else { throw M4CatalogError.intentMismatch }
      try state.requireCompletionCapacity()
      if let prior = state.plans[index].parentIntentDigest {
        guard prior == parentIntentDigest else { throw M4CatalogError.intentMismatch }; return
      }
      state.plans[index].parentIntentDigest = parentIntentDigest
      state.plans[index].children = try state.plans[index].expectedChildren(parentIntentDigest)
    }
    return try requiredPlan(requestID)
  }
  func plan(requestID: String) throws -> M4FrozenDeletionPlan? { try journal.read().plans.first(where: { M4CatalogIO.raw($0.requestID, requestID) }) }
  private func requiredPlan(_ requestID: String) throws -> M4FrozenDeletionPlan {
    guard let plan = try plan(requestID: requestID) else { throw M4CatalogError.intentMismatch }; return plan
  }
  /// Capacity only, not proof that identity/quiescence/full-seal admission passed.
  /// Every aggregate erase entrance must call this before invoking any mutating leaf.
  func requireOriginalParentSeal(saga: DeletionSagaV4) throws -> M4FrozenDeletionPlan { try requireOriginalPlan(saga: saga, sealed: true) }
  func requireOriginalReservation(saga: DeletionSagaV4) throws -> M4FrozenDeletionPlan { try requireOriginalPlan(saga: saga, sealed: false) }
  private func requireOriginalPlan(saga: DeletionSagaV4, sealed: Bool) throws -> M4FrozenDeletionPlan {
    try journal.transaction { state in
      guard let plan = state.plans.first, M4CatalogIO.raw(plan.requestID, saga.intent.requestID), saga.intent.operation == .deleteAccount,
            saga.originalScope == (try CloudScopeV1(accountID: plan.scope.accountID, cloudSpaceID: plan.scope.cloudSpaceID, zoneID: plan.scope.zoneID, activationEpoch: plan.scope.activationEpoch)),
            M4CatalogIO.raw(saga.accountID, plan.scope.accountID), saga.activationEpoch == plan.scope.activationEpoch,
            saga.cloudChoice == plan.choices.cloud, saga.localChoice == plan.choices.local,
            saga.healthChoice == plan.choices.health, saga.healthConfirmed == plan.choices.healthConfirmed,
            !sealed || plan.parentIntentDigest == saga.intent.digest,
            plan.parentIntentDigest == nil || plan.parentIntentDigest == saga.intent.digest else { throw M4CatalogError.intentMismatch }
      if plan.choices.health == .delete, plan.health.rawArtifactDigest == nil, plan.health.issue == nil { throw M4CatalogError.unsupportedSchema }
      try state.requireCompletionCapacity()
      for entry in plan.entries { try entry.capsule.verifyCurrent() }
    }
    return try requiredPlan(saga.intent.requestID)
  }
  func sealFullControls(saga: DeletionSagaV4, raw: M4HealthRawReservation? = nil, prepared: M4HealthPreparedMapping? = nil, entry: HealthDeletionEntry? = nil) throws {
    try journal.transaction { state in
      guard var plan = state.plans.first, M4CatalogIO.raw(plan.requestID, saga.intent.requestID),
            saga.intent.operation == .deleteAccount, plan.parentIntentDigest == saga.intent.digest,
            saga.originalScope == (try CloudScopeV1(accountID: plan.scope.accountID, cloudSpaceID: plan.scope.cloudSpaceID, zoneID: plan.scope.zoneID, activationEpoch: plan.scope.activationEpoch)),
            M4CatalogIO.raw(saga.accountID, plan.scope.accountID), saga.activationEpoch == plan.scope.activationEpoch,
            saga.cloudChoice == plan.choices.cloud, saga.localChoice == plan.choices.local,
            saga.healthChoice == plan.choices.health, saga.healthConfirmed == plan.choices.healthConfirmed else { throw M4CatalogError.intentMismatch }
      for value in plan.entries { try value.capsule.verifyCurrent() }
      var healthSeal: M4HealthFullSeal?
      var reference: M4HealthPreparedReference?
      if plan.choices.health == .delete {
        guard plan.health.issue == nil, let raw, let prepared, let entry,
              raw.scope == saga.originalScope, M4CatalogIO.raw(raw.parentID, plan.requestID),
              raw.cloud == plan.choices.cloud, raw.local == plan.choices.local, raw.health == plan.choices.health,
              raw.healthConfirmed == plan.choices.healthConfirmed, try raw.digest() == plan.health.rawArtifactDigest,
              try prepared.canonicalBytes() == M4HealthPreparedMapping(reservation: raw, parentDigest: saga.intent.digest).canonicalBytes(),
              try entry.request.canonicalBytes() == prepared.request.canonicalBytes(),
              entry.selectionDigest == prepared.confirmation.selectionDigest,
              try entry.confirmation.map(M4CatalogIO.encode) == M4CatalogIO.encode(prepared.confirmation) else { throw M4CatalogError.intentMismatch }
        let digest = try M4CatalogIO.hash(prepared.canonicalBytes())
        reference = M4HealthPreparedReference(reservationDigest: try raw.digest(), preparedDigest: digest, parentDigest: saga.intent.digest,
          selection: M4HealthSelectionReference(requestID: prepared.request.requestID, selectionDigest: prepared.confirmation.selectionDigest, confirmationID: prepared.confirmation.confirmationID))
        healthSeal = M4HealthFullSeal(version: 1, parentID: plan.requestID, parentDigest: saga.intent.digest,
          reservationDigest: try raw.digest(), preparedDigest: digest, catalogDigest: plan.catalogDigest,
          scope: raw.scope, cloud: raw.cloud, local: raw.local, health: raw.health, healthConfirmed: raw.healthConfirmed)
      } else { guard raw == nil, prepared == nil, entry == nil else { throw M4CatalogError.intentMismatch } }
      let seal = M4DeletionFullSeal(version: 1, parentIntentDigest: saga.intent.digest, catalogDigest: plan.catalogDigest, health: healthSeal)
      if let previous = plan.fullSeal {
        guard try M4CatalogIO.encode(previous) == M4CatalogIO.encode(seal),
              try M4CatalogIO.encode(plan.preparedHealth) == M4CatalogIO.encode(reference) else { throw M4CatalogError.intentMismatch }
        try state.requireCompletionCapacity(); return
      }
      guard plan.preparedHealth == nil else { throw M4CatalogError.intentMismatch }
      plan.preparedHealth = reference; plan.fullSeal = seal; try plan.validate()
      state.plans = [plan]; try state.requireCompletionCapacity()
    }
  }
  func healthFullSeal(parentID: String) throws -> M4HealthFullSeal? {
    try plan(requestID: parentID)?.fullSeal?.health
  }
  func preflightErasure(requestID: String) throws {
    try journal.transaction { state in
      guard state.plans.contains(where: { M4CatalogIO.raw($0.requestID, requestID) }) else { throw M4CatalogError.intentMismatch }
      try state.requireCompletionCapacity()
    }
  }
  func saveReceipt(_ receipt: M4RetainedLeafReceipt) throws {
    try journal.transaction { state in
      guard let index = state.plans.firstIndex(where: { M4CatalogIO.raw($0.requestID, receipt.parentID) }) else { throw M4CatalogError.intentMismatch }
      try state.requireCompletionCapacity()
      try receipt.validate(plan: state.plans[index])
      if let prior = state.plans[index].receipts?.first(where: { M4CatalogIO.raw($0.componentID, receipt.componentID) }) {
        guard try M4CatalogIO.encode(prior) == M4CatalogIO.encode(receipt) else { throw M4CatalogError.intentMismatch }; return
      }
      state.membershipRevision = state.ownedRevision
      var receipts = state.plans[index].receipts ?? []; receipts.append(receipt)
      receipts.sort { Data($0.componentID.utf8).lexicographicallyPrecedes(Data($1.componentID.utf8)) }
      state.plans[index].receipts = receipts
    }
  }
  func receipts(requestID: String) throws -> [M4RetainedLeafReceipt] { try plan(requestID: requestID)?.receipts ?? [] }
  func injectNextFailure(_ fault: M4CatalogFault) { journal.injectNextFailure(fault) }
  func injectNextSynchronizationFailure(_ boundary: M4CatalogSyncBoundary) { journal.injectNextSynchronizationFailure(boundary) }
  func close() throws { try journal.close() }
}
