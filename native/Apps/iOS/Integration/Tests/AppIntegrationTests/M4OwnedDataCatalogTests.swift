import Foundation
import Darwin
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
  private func crashChild(root: URL, method: String, phase: String) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xctest", "-XCTest", "AppIntegrationTests.M4OwnedDataCatalogTests/" + method, Bundle(for: Self.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["M4_CATALOG_CHILD_ROOT"] = root.path; environment["M4_CATALOG_CHILD_PHASE"] = phase
    process.environment = environment
    let log = root.appendingPathComponent("child-" + phase + ".log")
    XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
    let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    process.standardOutput = handle; process.standardError = handle
    try process.run(); process.waitUntilExit()
    print("catalog-crash-phase=\(phase) termination=\(process.terminationReason) status=\(process.terminationStatus)")
    XCTAssertEqual(process.terminationReason, .exit); XCTAssertEqual(process.terminationStatus, 86, "child must terminate at the real durable crash window")
  }
  private func fixtureBytes(_ root: URL) throws -> [String: Data] {
    let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    var bytes: [String: Data] = [:]
    for case let file as URL in paths where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { bytes[file.path] = try Data(contentsOf: file) }
    return bytes
  }
  func testFsyncedPendingCrashBeforeRenameRecoversExactFrozenParent() throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["M4_CATALOG_CHILD_ROOT"], let phase = env["M4_CATALOG_CHILD_PHASE"] {
      let catalog = try M4OwnedDataCatalog(directory: URL(fileURLWithPath: path).appendingPathComponent("retained"), crashHook: { point in if point.rawValue == phase { _exit(86) } })
      _ = try catalog.reserve(requestID: "crash-original-parent", scope: scope(), choices: choices, health: .empty)
      XCTFail("durable pending crash hook did not run"); return
    }
    for phase in ["afterPendingSync", "afterPublicationRename", "afterPublicationSync"] {
      let dir = try root(), control = dir.appendingPathComponent("retained")
      let catalog = try M4OwnedDataCatalog(directory: control); try catalog.record(capsule(dir, "ledger")); try catalog.close()
      let owner = try Data(contentsOf: control.appendingPathComponent("catalog.owner"))
      try crashChild(root: dir, method: #function.replacingOccurrences(of: "()", with: ""), phase: phase)
      let reopened = try M4OwnedDataCatalog(directory: control)
      let plan = try reopened.reserve(requestID: "crash-original-parent", scope: scope(), choices: choices, health: .empty)
      XCTAssertEqual(plan.requestID, "crash-original-parent"); XCTAssertEqual(plan.entries.count, 1)
      XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.owner")), owner)
      let sealed = try reopened.seal(requestID: plan.requestID, parentIntentDigest: String(repeating: "e", count: 64))
      try reopened.close(); let again = try M4OwnedDataCatalog(directory: control)
      XCTAssertEqual(try again.plan(requestID: plan.requestID)?.canonicalBytes(), try sealed.canonicalBytes()); try again.close()
    }
  }
  func testFreshInitializationCrashWindowsPublishOnlyCompleteDirectory() throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["M4_CATALOG_CHILD_ROOT"], let phase = env["M4_CATALOG_CHILD_PHASE"] {
      let catalog = try M4OwnedDataCatalog(directory: URL(fileURLWithPath: path).appendingPathComponent("retained"), crashHook: { point in if point.rawValue == phase { _exit(86) } })
      try catalog.close(); XCTFail("initialization crash hook did not run"); return
    }
    for phase in ["afterStageCreate", "afterSlotSync", "afterOwnerCreateBeforeWrite", "afterOwnerSync", "beforeInitializationPublish", "afterInitializationRename", "afterInitializationPublish"] {
      let dir = try root(), control = dir.appendingPathComponent("retained")
      try crashChild(root: dir, method: #function.replacingOccurrences(of: "()", with: ""), phase: phase)
      let before = try fixtureBytes(dir)
      let reopened = try M4OwnedDataCatalog(directory: control); XCTAssertTrue(try reopened.index().entries.isEmpty)
      for (path, bytes) in before { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, "unpublished candidates must be preserved") }
      try reopened.close(); let next = try M4OwnedDataCatalog(directory: control); XCTAssertTrue(try next.index().entries.isEmpty); try next.close()
    }
  }
  func testDeepOwnerBudgetRejectsBeforePermanentPublication() throws {
    var deep = try root()
    for _ in 0..<300 { deep.appendPathComponent("d") }
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    let control = deep.appendingPathComponent("retained")
    XCTAssertLessThan(control.path.utf8.count, 1024)
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control)) { error in XCTAssertEqual(error as? M4CatalogError, .budgetExceeded) }
    print("deep-control-path-bytes=\(control.path.utf8.count) owner-bytes=\((try? Data(contentsOf: control.appendingPathComponent("catalog.owner")))?.count ?? 0)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("catalog.owner").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("catalog.json").path))
  }
  func testPublishedJournalLossNeverCreatesAnEmptyReplacement() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
    try catalog.record(capsule(dir, "ledger")); try catalog.close()
    let owner = try Data(contentsOf: control.appendingPathComponent("catalog.owner"))
    try FileManager.default.removeItem(at: control.appendingPathComponent("catalog.json"))
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control))
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.owner")), owner)
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("catalog.json").path))
  }
  func testMalformedPublicationAndReplacedSlotPreserveEveryByte() throws {
    for mutation in ["wrong-before-hash", "foreign-pending-inode", "replaced-slot"] {
      let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
      try catalog.record(capsule(dir, "ledger")); try catalog.close()
      try crashChild(root: dir, method: "testFsyncedPendingCrashBeforeRenameRecoversExactFrozenParent", phase: "afterPendingSync")
      let names = try FileManager.default.contentsOfDirectory(atPath: control.path)
      let pendingName = try XCTUnwrap(names.first(where: { $0.hasPrefix("catalog.pending.") }))
      let pending = control.appendingPathComponent(pendingName), data = try Data(contentsOf: pending)
      if mutation == "wrong-before-hash" {
        var parts = pendingName.split(separator: ".").map(String.init); parts[4] = String(repeating: "0", count: 64)
        try FileManager.default.moveItem(at: pending, to: control.appendingPathComponent(parts.joined(separator: ".")))
      } else if mutation == "foreign-pending-inode" {
        try FileManager.default.removeItem(at: pending); try data.write(to: pending)
      } else {
        var pendingStat = stat(); XCTAssertEqual(lstat(pending.path, &pendingStat), 0)
        let slot = try XCTUnwrap(["catalog.slot0", "catalog.slot1"].first(where: { name in
          var value = stat(); return lstat(control.appendingPathComponent(name).path, &value) == 0 && value.st_ino == pendingStat.st_ino && value.st_dev == pendingStat.st_dev
        }))
        let url = control.appendingPathComponent(slot); try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("original-slot")); try data.write(to: url)
      }
      let before = try fixtureBytes(dir)
      XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control))
      XCTAssertEqual(Set(try fixtureBytes(dir).keys), Set(before.keys))
      for (path, bytes) in before { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes) }
    }
  }
  func testConcurrentUnknownFinalDirectoryCannotBeOverwritten() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), bytes = Data([0, 77, 255])
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control, crashHook: { point in
      if point == .beforeInitializationPublish {
        try? FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
        try? bytes.write(to: control.appendingPathComponent("foreign.bin"))
      }
    }))
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("foreign.bin")), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("catalog.owner").path))
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control))
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("foreign.bin")), bytes)
  }
  func testLegacyOwnerOnlyIsPreservedWithoutInitializationFallback() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained")
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
    let owner = control.appendingPathComponent("catalog.owner")
    let bytes = Data("{\"version\":1,\"unrecoverableLegacyOwner\":true}".utf8); try bytes.write(to: owner)
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control)) { error in XCTAssertEqual(error as? M4CatalogError, .unsupportedSchema) }
    XCTAssertEqual(try Data(contentsOf: owner), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: control.path), ["catalog.owner"])
  }
  func testRetainedControlsCannotLiveInsideBusinessRoot() throws {
    let dir = try root(), control = dir.appendingPathComponent("business/owned/retained")
    let catalog = try M4OwnedDataCatalog(directory: control)
    let value = try capsule(dir, "owned", kind: .cloudStaging)
    XCTAssertThrowsError(try catalog.record(value)); XCTAssertTrue(try catalog.index().entries.isEmpty)
    try catalog.close()
  }
}
