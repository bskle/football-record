import Foundation
import CloudSync
import DeviceSync

/// A component result only. The aggregate must separately establish the original
/// Store proof, full seal and every required component before reporting success.
enum M4LocalErasureError: Error, Equatable {
  case unavailable, intentMismatch, pendingTransfer, unsupportedComponent
}
struct M4LocalTransportLeaves: Sendable {
  let catalog: M4OwnedDataCatalog
  let stagingControls: [String: URL]
  let deviceDriver: any DeviceSyncErasureDriving
  init(catalog: M4OwnedDataCatalog, stagingControls: [String: URL] = [:], deviceDriver: any DeviceSyncErasureDriving = UnavailableDeviceSyncErasureDriver()) {
    self.catalog = catalog; self.stagingControls = stagingControls; self.deviceDriver = deviceDriver
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
    case .cloudLedger, .businessStore:
      // No cached-receipt fallback. Store proof and the 033 all-epoch current-zero
      // boundary are supplied only by their concrete aggregate implementation.
      throw M4LocalErasureError.unsupportedComponent
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
