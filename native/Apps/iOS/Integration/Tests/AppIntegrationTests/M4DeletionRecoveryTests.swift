import Foundation
import XCTest
import CloudSync
import DeviceSync
@testable import AppIntegration

@MainActor final class M4DeletionRecoveryTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-local-erase-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func scope() throws -> CloudScope { try CloudScope(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 2) }
  private func seal(_ catalog: M4OwnedDataCatalog, capsules: [M4OwnershipCapsule]) throws -> M4FrozenDeletionPlan {
    for capsule in capsules { try catalog.record(capsule) }
    _ = try catalog.reserve(requestID: "original-parent", scope: scope(), choices: M4DeletionChoices(cloud: .keep, local: .delete, health: .keep, healthConfirmed: false), health: .empty)
    return try catalog.seal(requestID: "original-parent", parentIntentDigest: String(repeating: "d", count: 64))
  }
  private func staging(_ root: URL, id: String = "staging") throws -> (CloudOwnedStaging, M4OwnershipCapsule, URL) {
    let directory = root.appendingPathComponent(id), control = root.appendingPathComponent(id + "-control.sqlite")
    let store = try CloudOwnedStaging(rootURL: directory, controlURL: control)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: id, kind: .cloudStaging, scope: scope(), root: directory,
      retainedControls: [control, URL(fileURLWithPath: control.path + ".owner"), URL(fileURLWithPath: directory.path + ".owner")])
    return (store, capsule, control)
  }
  private func erase(_ leaves: M4LocalTransportLeaves, _ capsule: M4OwnershipCapsule, _ plan: M4FrozenDeletionPlan) async throws -> M4RetainedLeafReceipt {
    try await leaves.erase(componentID: capsule.componentID, parentID: plan.requestID, parentIntentDigest: XCTUnwrap(plan.parentIntentDigest))
  }
  func testStagingOriginalReceiptReopensButRestoredDirectoryBlocksCachedSuccess() async throws {
    let root = try root(), catalogURL = root.appendingPathComponent("catalog"), catalog = try M4OwnedDataCatalog(directory: catalogURL)
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let leaves = M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control])
    let first = try await erase(leaves, capsule, plan)
    XCTAssertEqual(first.kind, .cloudStaging); XCTAssertEqual(first.leafDigest, plan.parentIntentDigest)
    let saved = try catalog.receipts(requestID: plan.requestID)
    XCTAssertEqual(try M4CatalogIO.encode(saved), try M4CatalogIO.encode([first])); try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: catalogURL), retry = M4LocalTransportLeaves(catalog: reopened, stagingControls: [capsule.componentID: control])
    let second = try await erase(retry, capsule, plan); XCTAssertEqual(try M4CatalogIO.encode(second), try M4CatalogIO.encode(first))
    let restored = URL(fileURLWithPath: capsule.root.path).appendingPathComponent(try scope().stableZoneKey)
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
    let foreign = restored.appendingPathComponent("unknown-restored"); try Data("preserve".utf8).write(to: foreign)
    do { _ = try await erase(retry, capsule, plan); XCTFail("cached receipt cannot replace actual current-zero replay") } catch {}
    XCTAssertEqual(try Data(contentsOf: foreign), Data("preserve".utf8))
    XCTAssertEqual(try M4CatalogIO.encode(reopened.receipts(requestID: plan.requestID)), try M4CatalogIO.encode(saved)); try reopened.close()
  }
  func testDefaultDeviceDrainIsIncompleteAndControlledReceiptStillChecksCurrentInventory() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let directory = root.appendingPathComponent("DeviceSync"), context = try DeviceSyncStorageContext(root: directory)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "device", kind: .deviceSync, scope: scope(), root: directory,
      retainedControls: [directory.appendingPathComponent(".control/.owner"), directory.appendingPathComponent(".control/control.sqlite")])
    try context.bind(capsule.deviceBinding()); let plan = try seal(catalog, capsules: [capsule])
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog), capsule, plan); XCTFail("default driver cannot complete") }
    catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty)
    let controlled = M4LocalTransportLeaves(catalog: catalog, deviceDriver: LocalControlledDrain())
    let first = try await erase(controlled, capsule, plan)
    XCTAssertEqual(first.kind, .deviceSync); XCTAssertNotEqual(first.leafDigest, plan.parentIntentDigest)
    let inbox = directory.appendingPathComponent("inbox"); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
    let bytes = Data("restored-original-frame".utf8), restored = inbox.appendingPathComponent("frame-" + M4CatalogIO.hash(bytes) + ".frame")
    try bytes.write(to: restored)
    do { _ = try await erase(controlled, capsule, plan); XCTFail("receipt replay must inspect current files") } catch {}
    XCTAssertEqual(try Data(contentsOf: restored), bytes)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)), try M4CatalogIO.encode([first])); try catalog.close()
  }
  func testUnregisteredStagingControlCannotBeOpenedOrCreateAReplacementOwner() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, _) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let wrong = root.appendingPathComponent("foreign-control.sqlite")
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: wrong]), capsule, plan); XCTFail("explicit control must match original retained paths") }
    catch { XCTAssertEqual(error as? M4LocalErasureError, .intentMismatch) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path + ".owner"))
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
  func testRetiredStagingCapsuleRemainsAnActualRequiredLeaf() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root, id: "retired-staging")
    try catalog.record(capsule); try catalog.retire(componentID: capsule.componentID)
    let plan = try seal(catalog, capsules: [capsule]); try staging.close()
    XCTAssertTrue(try XCTUnwrap(plan.entries.first).retired)
    let receipt = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control]), capsule, plan)
    XCTAssertEqual(receipt.componentID, capsule.componentID)
    XCTAssertEqual(try catalog.receipts(requestID: plan.requestID).count, 1); try catalog.close()
  }
  func testReplacedRetainedOwnerBlocksBeforeLeafAndPreservesForeignBytes() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let owner = URL(fileURLWithPath: control.path + ".owner"), retained = root.appendingPathComponent("original-owner-preserved")
    try FileManager.default.moveItem(at: owner, to: retained); try Data("foreign-owner".utf8).write(to: owner)
    let before = try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json"))
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control]), capsule, plan); XCTFail("replaced control inode cannot enter leaf") }
    catch { XCTAssertEqual(error as? M4CatalogError, .identityChanged) }
    XCTAssertEqual(try Data(contentsOf: owner), Data("foreign-owner".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), before); try catalog.close()
  }
  func testUnknownDeviceInventoryIsPreservedWithoutCallingDrainOrSavingReceipt() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let directory = root.appendingPathComponent("DeviceSync"), context = try DeviceSyncStorageContext(root: directory)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "unknown-device", kind: .deviceSync, scope: scope(), root: directory,
      retainedControls: [directory.appendingPathComponent(".control/.owner"), directory.appendingPathComponent(".control/control.sqlite")])
    try context.bind(capsule.deviceBinding()); let plan = try seal(catalog, capsules: [capsule])
    let foreign = directory.appendingPathComponent("unclassified"), bytes = Data("preserve-unknown".utf8); try bytes.write(to: foreign)
    let drain = LocalCountingDrain()
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, deviceDriver: drain), capsule, plan); XCTFail("unknown inventory cannot drain") }
    catch { XCTAssertEqual(error as? DeviceSyncErasureError, .unknownInventory) }
    let calls = await drain.calls; XCTAssertEqual(calls, 0)
    XCTAssertEqual(try Data(contentsOf: foreign), bytes); XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
  func testWrongOriginalParentOrDigestPreservesJournalAndLeaf() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let before = try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), leaves = M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control])
    for (parent, digest) in [("foreign", try XCTUnwrap(plan.parentIntentDigest)), (plan.requestID, String(repeating: "f", count: 64))] {
      do { _ = try await leaves.erase(componentID: capsule.componentID, parentID: parent, parentIntentDigest: digest); XCTFail("original intent required") }
      catch { XCTAssertEqual(error as? M4LocalErasureError, .intentMismatch) }
    }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), before)
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
}
private struct LocalControlledDrain: DeviceSyncErasureDriving {
  func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .drained }
}

private actor LocalCountingDrain: DeviceSyncErasureDriving {
  private(set) var calls = 0
  func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { calls += 1; return .drained }
}
