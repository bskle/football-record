import Foundation
import XCTest
import CloudSync
import DeviceSync
@testable import AppIntegration

final class M4OwnedDataCatalogTests: XCTestCase {
  private func root() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("m4-catalog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
  }
  private func scope(_ account: String = "account", epoch: Int64 = 1) throws -> CloudScope {
    try CloudScope(accountID: account, cloudSpaceID: "cloud", zoneID: "matches", activationEpoch: epoch)
  }
  private func capsule(_ parent: URL, _ id: String, kind: M4OwnedLeafKind = .cloudLedger, scope: CloudScope? = nil) throws -> M4OwnershipCapsule {
    let path = parent.appendingPathComponent("business/" + id)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: id, kind: kind,
      scope: scope ?? self.scope(), root: path, retainedControls: [])
  }
  private var choices: M4DeletionChoices { M4DeletionChoices(cloud: .keep, local: .delete, health: .keep, healthConfirmed: false) }
  func testRetiredLedgerAndStagingRemainRequiredCatalogMembers() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained")
    let catalog = try M4OwnedDataCatalog(directory: control)
    let old = try capsule(dir, "ledger-old"), new = try capsule(dir, "staging-new", kind: .cloudStaging, scope: scope(epoch: 2))
    try catalog.record(old); try catalog.retire(componentID: old.componentID); try catalog.record(new)
    let plan = try catalog.reserve(requestID: "delete-one", scope: scope(epoch: 2), choices: choices, health: .empty)
    XCTAssertEqual(plan.entries.count, 2)
    XCTAssertEqual(plan.entries.first(where: { $0.capsule.componentID == old.componentID })?.retired, true)
    let sealed = try catalog.seal(requestID: plan.requestID, parentIntentDigest: String(repeating: "a", count: 64))
    XCTAssertEqual(sealed.children.count, 2)
    XCTAssertEqual(Set(sealed.children.map(\.componentID)), [old.componentID, new.componentID])
    XCTAssertNotEqual(sealed.children[0].requestID, sealed.children[1].requestID)
    try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: control)
    XCTAssertEqual(try reopened.plan(requestID: plan.requestID)?.canonicalBytes(), try sealed.canonicalBytes())
    try reopened.close()
  }
  func testCatalogCapsuleDigestHasNoSelfReferenceAndNeverRebindsOldRoot() throws {
    let dir = try root(), catalog = try M4OwnedDataCatalog(directory: dir.appendingPathComponent("retained"))
    let device = try capsule(dir, "device", kind: .deviceSync)
    let original = try device.deviceBinding()
    XCTAssertEqual(original.catalogDigest, try device.digest())
    XCTAssertEqual(original.catalogRevision, 1)
    try catalog.record(device); try catalog.record(capsule(dir, "other")); try catalog.retire(componentID: device.componentID)
    let current = try XCTUnwrap(catalog.index().entries.first(where: { $0.capsule.componentID == device.componentID }))
    XCTAssertEqual(try current.capsule.deviceBinding(), original)
    XCTAssertGreaterThan(try catalog.index().revision, original.catalogRevision)
    let conflicting = try M4OwnershipCapsule.capture(namespaceID: device.namespaceID, componentID: device.componentID,
      kind: .deviceSync, scope: scope(epoch: 2), root: URL(fileURLWithPath: device.root.path), retainedControls: [])
    XCTAssertThrowsError(try catalog.record(conflicting))
    XCTAssertEqual(try catalog.index().entries.first(where: { $0.capsule.componentID == device.componentID })?.capsule.digest(), try device.digest())
    try catalog.close()
  }
  func testForeignRawUnicodeScopePreservesBytes() throws {
    let dir = try root(), catalog = try M4OwnedDataCatalog(directory: dir.appendingPathComponent("retained"))
    let decomposed = "cafe\u{301}", composed = "caf\u{e9}"
    XCTAssertEqual(decomposed, composed); XCTAssertNotEqual(Data(decomposed.utf8), Data(composed.utf8))
    let value = try capsule(dir, "foreign", scope: scope(decomposed)); try catalog.record(value)
    let before = try Data(contentsOf: dir.appendingPathComponent("retained/catalog.json"))
    XCTAssertThrowsError(try catalog.reserve(requestID: "delete-two", scope: scope(composed), choices: choices, health: .empty))
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("retained/catalog.json")), before)
    let saved = try XCTUnwrap(catalog.index().entries.first)
    XCTAssertEqual(Data(saved.capsule.scope.accountID.utf8), Data(decomposed.utf8)); try catalog.close()
  }
  func testUnknownOrFutureControlAndReplacedOwnerFailClosed() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained")
    let catalog = try M4OwnedDataCatalog(directory: control); try catalog.close()
    let journal = control.appendingPathComponent("catalog.json"), prior = try Data(contentsOf: journal)
    let unknown = control.appendingPathComponent("unknown.bin"), unknownBytes = Data([0, 255, 9]); try unknownBytes.write(to: unknown)
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control)); XCTAssertEqual(try Data(contentsOf: unknown), unknownBytes)
    try FileManager.default.removeItem(at: unknown)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: prior) as? [String: Any]); object["version"] = 900
    let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); try future.write(to: journal)
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control)); XCTAssertEqual(try Data(contentsOf: journal), future)
    try prior.write(to: journal)
    let owner = control.appendingPathComponent("catalog.owner"), bytes = try Data(contentsOf: owner)
    try FileManager.default.moveItem(at: owner, to: control.appendingPathComponent("old-owner")); try bytes.write(to: owner)
    try FileManager.default.removeItem(at: control.appendingPathComponent("old-owner"))
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control)); XCTAssertEqual(try Data(contentsOf: owner), bytes)
  }
  func testCrashBeforeAndAfterFreezeReopensSameParentAndStableChildren() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained")
    var catalog = try M4OwnedDataCatalog(directory: control); try catalog.record(capsule(dir, "ledger"))
    catalog.injectNextFailure(.beforeCommit)
    XCTAssertThrowsError(try catalog.reserve(requestID: "original-parent", scope: scope(), choices: choices, health: .empty))
    XCTAssertNil(try catalog.plan(requestID: "original-parent"))
    catalog.injectNextFailure(.afterCommitResponseLost)
    XCTAssertThrowsError(try catalog.reserve(requestID: "original-parent", scope: scope(), choices: choices, health: .empty))
    try catalog.close(); catalog = try M4OwnedDataCatalog(directory: control)
    let reserved = try XCTUnwrap(catalog.plan(requestID: "original-parent")); XCTAssertNil(reserved.parentIntentDigest)
    XCTAssertTrue(reserved.children.isEmpty)
    catalog.injectNextFailure(.afterCommitResponseLost)
    XCTAssertThrowsError(try catalog.seal(requestID: reserved.requestID, parentIntentDigest: String(repeating: "b", count: 64)))
    try catalog.close(); catalog = try M4OwnedDataCatalog(directory: control)
    let sealed = try catalog.seal(requestID: reserved.requestID, parentIntentDigest: String(repeating: "b", count: 64))
    XCTAssertEqual(sealed.requestID, "original-parent"); XCTAssertEqual(sealed.children.count, 1)
    let same = try catalog.seal(requestID: reserved.requestID, parentIntentDigest: String(repeating: "b", count: 64))
    XCTAssertEqual(try same.canonicalBytes(), try sealed.canonicalBytes())
    XCTAssertThrowsError(try catalog.seal(requestID: reserved.requestID, parentIntentDigest: String(repeating: "c", count: 64)))
    XCTAssertThrowsError(try catalog.record(capsule(dir, "late-ledger")))
    try catalog.close()
  }
  func testCapsuleCountBudgetPreservesCompleteExistingIndex() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained")
    let catalog = try M4OwnedDataCatalog(directory: control)
    for number in 0..<256 { try catalog.record(capsule(dir, "item-" + String(format: "%03d", number))) }
    let journal = control.appendingPathComponent("catalog.json"), prior = try Data(contentsOf: journal)
    XCTAssertEqual(try catalog.index().entries.count, 256)
    XCTAssertThrowsError(try catalog.record(capsule(dir, "item-over-limit"))) { error in
      XCTAssertEqual(error as? M4CatalogError, .budgetExceeded)
    }
    XCTAssertEqual(try Data(contentsOf: journal), prior); XCTAssertEqual(try catalog.index().entries.count, 256)
    try catalog.close()
  }
  func testEncodedJournalBudgetPreservesAllPriorCapsulesAndControls() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), shared = dir.appendingPathComponent("shared-controls")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    var controls: [URL] = []
    for number in 0..<256 {
      let file = shared.appendingPathComponent(String(repeating: "c", count: 180) + String(number))
      try Data([7]).write(to: file); controls.append(file)
    }
    let catalog = try M4OwnedDataCatalog(directory: control), journal = control.appendingPathComponent("catalog.json")
    var blocked = false, admitted = 0
    for number in 0..<30 {
      let base = try capsule(dir, "large-" + String(number))
      let value = try M4OwnershipCapsule.capture(namespaceID: base.namespaceID, componentID: base.componentID,
        kind: base.kind, scope: base.scope, root: URL(fileURLWithPath: base.root.path), retainedControls: controls)
      let prior = try Data(contentsOf: journal)
      do { try catalog.record(value); admitted += 1 }
      catch {
        XCTAssertEqual(error as? M4CatalogError, .budgetExceeded)
        XCTAssertEqual(try Data(contentsOf: journal), prior); blocked = true; break
      }
    }
    XCTAssertTrue(blocked); XCTAssertGreaterThan(admitted, 0); XCTAssertLessThan(admitted, 30)
    XCTAssertEqual(try catalog.index().entries.count, admitted)
    for file in controls { XCTAssertEqual(try Data(contentsOf: file), Data([7])) }
    try catalog.close()
  }
  func testRetainedControlsCannotLiveInsideBusinessRoot() throws {
    let dir = try root(), control = dir.appendingPathComponent("business/owned/retained")
    let catalog = try M4OwnedDataCatalog(directory: control)
    let value = try capsule(dir, "owned", kind: .cloudStaging)
    XCTAssertThrowsError(try catalog.record(value)); XCTAssertTrue(try catalog.index().entries.isEmpty)
    try catalog.close()
  }
}
