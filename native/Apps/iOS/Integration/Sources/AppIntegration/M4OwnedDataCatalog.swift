import Foundation
import CloudSync
import DeviceSync
import MatchStore

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
  static let empty = Self(selections: [], issue: nil)
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
    guard choices.health != .delete || (choices.healthConfirmed && (!health.selections.isEmpty || health.issue != nil)) else { throw M4CatalogError.intentMismatch }
    guard choices.health != .keep || (health.selections.isEmpty && health.issue == nil) else { throw M4CatalogError.intentMismatch }
    for entry in entries {
      try entry.capsule.validate()
      let original = entry.capsule.scope
      guard M4CatalogIO.raw(original.accountID, scope.accountID), M4CatalogIO.raw(original.cloudSpaceID, scope.cloudSpaceID),
            M4CatalogIO.raw(original.zoneID, scope.zoneID), original.activationEpoch <= scope.activationEpoch else { throw M4CatalogError.intentMismatch }
    }
    if let digest = parentIntentDigest {
      guard M4CatalogIO.isDigest(digest), try M4CatalogIO.encode(children) == M4CatalogIO.encode(expectedChildren(digest)) else { throw M4CatalogError.intentMismatch }
    } else { guard children.isEmpty else { throw M4CatalogError.intentMismatch } }
  }
}
struct M4CatalogState: Codable {
  let version: Int
  var revision: UInt64
  var entries: [M4CatalogEntry]
  var plans: [M4FrozenDeletionPlan]
  static let empty = Self(version: 1, revision: 0, entries: [], plans: [])
  func validate() throws {
    guard version == 1 else { throw M4CatalogError.unsupportedSchema }
    guard entries.count <= 256, plans.count <= 1 else { throw M4CatalogError.budgetExceeded }
    guard Set(entries.map { Data($0.capsule.componentID.utf8) }).count == entries.count,
          try M4CatalogIO.encode(entries) == M4CatalogIO.encode(entries.sorted { Data($0.capsule.componentID.utf8).lexicographicallyPrecedes(Data($1.capsule.componentID.utf8)) }) else { throw M4CatalogError.intentMismatch }
    for entry in entries { try entry.capsule.validate() }
    for plan in plans {
      try plan.validate()
      guard plan.catalogRevision <= revision, try M4CatalogIO.encode(plan.entries) == M4CatalogIO.encode(entries) else { throw M4CatalogError.intentMismatch }
    }
  }
}
/// All operations are synchronous bounded journal transactions. An outer
/// composition barrier must quiesce actors before reserve/seal/resume admission.
final class M4OwnedDataCatalog: @unchecked Sendable {
  private let journal: M4CatalogJournal
  init(directory: URL) throws { journal = try M4CatalogJournal(directory: directory) }
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
      state.entries.append(M4CatalogEntry(capsule: capsule, retired: false))
      state.entries.sort { Data($0.capsule.componentID.utf8).lexicographicallyPrecedes(Data($1.capsule.componentID.utf8)) }
    }
  }
  func retire(componentID: String) throws {
    try journal.transaction { state in
      guard let index = state.entries.firstIndex(where: { M4CatalogIO.raw($0.capsule.componentID, componentID) }) else { throw M4CatalogError.intentMismatch }
      if state.entries[index].retired { return }
      guard state.plans.isEmpty else { throw M4CatalogError.intentMismatch }
      state.entries[index].retired = true
    }
  }
  func index() throws -> M4CatalogIndex {
    let state = try journal.read(); return M4CatalogIndex(revision: state.revision, entries: state.entries)
  }
  func reserve(requestID: String, scope: CloudScope, choices: M4DeletionChoices, health: M4HealthReservation) throws -> M4FrozenDeletionPlan {
    try journal.transaction { state in
      if let prior = state.plans.first {
        guard M4CatalogIO.raw(prior.requestID, requestID), prior.scope == scope,
              try M4CatalogIO.encode(prior.choices) == M4CatalogIO.encode(choices),
              try M4CatalogIO.encode(prior.health) == M4CatalogIO.encode(health) else { throw M4CatalogError.intentMismatch }
        return
      }
      let index = M4CatalogIndex(revision: state.revision, entries: state.entries)
      let plan = try M4FrozenDeletionPlan(version: 1, requestID: requestID, scope: scope, choices: choices, health: health,
        catalogRevision: index.revision, catalogDigest: index.digest(), entries: index.entries, parentIntentDigest: nil, children: [])
      try plan.validate(); state.plans.append(plan)
    }
    return try requiredPlan(requestID)
  }
  func seal(requestID: String, parentIntentDigest: String) throws -> M4FrozenDeletionPlan {
    guard M4CatalogIO.isDigest(parentIntentDigest) else { throw M4CatalogError.intentMismatch }
    try journal.transaction { state in
      guard let index = state.plans.firstIndex(where: { M4CatalogIO.raw($0.requestID, requestID) }) else { throw M4CatalogError.intentMismatch }
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
  func injectNextFailure(_ fault: M4CatalogFault) { journal.injectNextFailure(fault) }
  func close() throws { try journal.close() }
}
