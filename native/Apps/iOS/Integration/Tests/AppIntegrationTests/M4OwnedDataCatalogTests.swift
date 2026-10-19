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
  func testReopenStabilizesDirectoriesBeforeReadAndInactiveSlotReuse() throws {
    for phase in ["afterInitializationRename", "afterPublicationRename"] {
      let dir = try root(), control = dir.appendingPathComponent("retained")
      if phase == "afterPublicationRename" {
        let initial = try M4OwnedDataCatalog(directory: control); try initial.record(capsule(dir, "ledger")); try initial.close()
      }
      try crashChild(root: dir,
        method: phase == "afterInitializationRename" ? "testFreshInitializationCrashWindowsPublishOnlyCompleteDirectory" : "testFsyncedPendingCrashBeforeRenameRecoversExactFrozenParent", phase: phase)
      let trace = CatalogSyncTrace()
      let reopened = try M4OwnedDataCatalog(directory: control, crashHook: { trace.append($0) })
      XCTAssertEqual(Array(trace.values().prefix(2)), [.afterCatalogDirectorySync, .afterPublicationParentSync], "constructor cannot expose unflushed namespace state")
      trace.clear(); _ = try reopened.index()
      XCTAssertEqual(Array(trace.values().prefix(2)), [.afterCatalogDirectorySync, .afterPublicationParentSync])
      trace.clear()
      if phase == "afterInitializationRename" { try reopened.record(capsule(dir, "first")) }
      else { _ = try reopened.seal(requestID: "crash-original-parent", parentIntentDigest: String(repeating: "f", count: 64)) }
      let events = trace.values()
      let write = try XCTUnwrap(events.firstIndex(of: .beforeInactiveSlotWrite))
      XCTAssertGreaterThanOrEqual(write, 2)
      if write >= 2 { XCTAssertEqual(Array(events[(write - 2)..<write]), [.afterCatalogDirectorySync, .afterPublicationParentSync]) }
      try reopened.close()
    }
  }
  func testReopenSyncFailurePreservesPublishedStateAndBlocksReadback() throws {
    for phase in ["afterInitializationRename", "afterPublicationRename"] {
      for boundary in [M4CatalogSyncBoundary.catalogDirectory, .publicationParent] {
        let dir = try root(), control = dir.appendingPathComponent("retained")
        if phase == "afterPublicationRename" {
          let initial = try M4OwnedDataCatalog(directory: control); try initial.record(capsule(dir, "ledger")); try initial.close()
        }
        try crashChild(root: dir,
          method: phase == "afterInitializationRename" ? "testFreshInitializationCrashWindowsPublishOnlyCompleteDirectory" : "testFsyncedPendingCrashBeforeRenameRecoversExactFrozenParent", phase: phase)
        let before = try fixtureBytes(dir)
        XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control, synchronizationFault: boundary)) { error in XCTAssertEqual(error as? M4CatalogError, .storageBlocked) }
        XCTAssertEqual(Set(try fixtureBytes(dir).keys), Set(before.keys))
        for (path, bytes) in before { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes) }
        let retry = try M4OwnedDataCatalog(directory: control)
        if phase == "afterPublicationRename" { XCTAssertEqual(try retry.plan(requestID: "crash-original-parent")?.requestID, "crash-original-parent") }
        try retry.close()
      }
    }
  }
  func testSameInstanceSyncFailureCannotReuseInactiveSlot() throws {
    for boundary in [M4CatalogSyncBoundary.catalogDirectory, .publicationParent] {
      let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
      try catalog.record(capsule(dir, "ledger")); let next = try capsule(dir, "next")
      let before = try fixtureBytes(control)
      catalog.injectNextSynchronizationFailure(boundary)
      XCTAssertThrowsError(try catalog.record(next)) { error in XCTAssertEqual(error as? M4CatalogError, .storageBlocked) }
      for (path, bytes) in before { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes) }
      XCTAssertEqual(try catalog.index().entries.count, 1)
      try catalog.record(next); XCTAssertEqual(try catalog.index().entries.count, 2); try catalog.close()
    }
  }
  func testCurrentSlotExtraDescriptorIsPreservedAndRejected() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
    try catalog.record(capsule(dir, "ledger")); try catalog.close()
    let journal = control.appendingPathComponent("catalog.json"), bytes = try Data(contentsOf: journal)
    let state = try JSONDecoder().decode(M4CatalogState.self, from: bytes)
    let name = "catalog.pending.\(state.revision - 1).\(state.revision).\(String(repeating: "0", count: 64)).\(M4CatalogIO.hash(bytes))"
    let extra = control.appendingPathComponent(name)
    XCTAssertEqual(link(journal.path, extra.path), 0)
    let before = try fixtureBytes(control)
    XCTAssertThrowsError(try M4OwnedDataCatalog(directory: control))
    XCTAssertEqual(Set(try fixtureBytes(control).keys), Set(before.keys))
    for (path, expected) in before { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expected) }
  }
  @MainActor func testTypedReceiptsFromActualLocalLeavesKeepIndependentDigests() async throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control), scope = try scope()
    let ledgerURL = dir.appendingPathComponent("cloud-ledger.sqlite"), ledger = try SQLiteCloudLedger(url: ledgerURL)
    let stagingURL = dir.appendingPathComponent("assets"), stagingControl = dir.appendingPathComponent("staging-control.sqlite"), staging = try CloudOwnedStaging(rootURL: stagingURL, controlURL: stagingControl)
    let deviceURL = dir.appendingPathComponent("DeviceSync"), device = try DeviceSyncStorageContext(root: deviceURL)
    let ledgerCapsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "actual-ledger", kind: .cloudLedger, scope: scope, root: ledgerURL, retainedControls: [])
    let stagingCapsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "actual-staging", kind: .cloudStaging, scope: scope, root: stagingURL, retainedControls: [stagingControl, URL(fileURLWithPath: stagingControl.path + ".owner"), URL(fileURLWithPath: stagingURL.path + ".owner")])
    let deviceCapsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "actual-device", kind: .deviceSync, scope: scope, root: deviceURL, retainedControls: [deviceURL.appendingPathComponent(".control/.owner"), deviceURL.appendingPathComponent(".control/control.sqlite")])
    try device.bind(deviceCapsule.deviceBinding())
    for capsule in [ledgerCapsule, stagingCapsule, deviceCapsule] { try catalog.record(capsule) }
    _ = try catalog.reserve(requestID: "actual-leaves-parent", scope: scope, choices: choices, health: .empty)
    let plan = try catalog.seal(requestID: "actual-leaves-parent", parentIntentDigest: String(repeating: "c", count: 64))
    func child(_ id: String) throws -> String { try XCTUnwrap(plan.children.first { $0.componentID == id }).requestID }
    let cloud = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID: child(ledgerCapsule.componentID), scope: scope))
    XCTAssertNotEqual(cloud.requestDigest, plan.parentIntentDigest, "033 retains its own leaf digest")
    try catalog.saveReceipt(M4RetainedLeafReceipt.capture(plan: plan, componentID: ledgerCapsule.componentID, leafDigest: cloud.requestDigest, canonicalReceipt: M4CatalogIO.encode(cloud)))
    let files = try staging.erase(CloudStagingEraseRequest(requestID: child(stagingCapsule.componentID), requestDigest: try XCTUnwrap(plan.parentIntentDigest), scope: scope))
    try catalog.saveReceipt(M4RetainedLeafReceipt.capture(plan: plan, componentID: stagingCapsule.componentID, leafDigest: files.requestDigest, canonicalReceipt: M4CatalogIO.encode(M4StagingCompletionEvidence(files))))
    let request = try DeviceSyncLocalEraseRequest(binding: deviceCapsule.deviceBinding(), requestID: plan.requestID, requestDigest: try XCTUnwrap(plan.parentIntentDigest))
    let unavailable = try await DeviceSyncErasureService(context: device).erase(request)
    XCTAssertEqual(unavailable, .pending(.unresolved), "default native driver cannot supply a completion receipt")
    // Explicit controlled protocol fixture, not WC/native driver evidence.
    guard case .completed(let native) = try await DeviceSyncErasureService(context: device, driver: CatalogControlledDrain()).erase(request) else { return XCTFail("controlled empty root should drain") }
    XCTAssertNotEqual(native.intentDigest, plan.parentIntentDigest)
    try catalog.saveReceipt(M4RetainedLeafReceipt.capture(plan: plan, componentID: deviceCapsule.componentID, leafDigest: native.intentDigest, canonicalReceipt: M4CatalogIO.encode(native)))
    let saved = try catalog.receipts(requestID: plan.requestID); XCTAssertEqual(saved.count, 3)
    XCTAssertEqual(saved.first { $0.kind == .cloudLedger }?.leafDigest, cloud.requestDigest)
    XCTAssertEqual(saved.first { $0.kind == .deviceSync }?.canonicalReceipt, try M4CatalogIO.encode(native))
    try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: control)
    XCTAssertEqual(try M4CatalogIO.encode(reopened.receipts(requestID: plan.requestID)), try M4CatalogIO.encode(saved))
    try reopened.close(); try staging.close(); try await ledger.close()
  }
  func testFirstReceiptReopensExactBytesWithoutChangingMembershipOrDeviceBinding() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
    let ledger = try capsule(dir, "ledger"), device = try capsule(dir, "device", kind: .deviceSync)
    try catalog.record(ledger); try catalog.record(device)
    let original = try catalog.index(), binding = try device.deviceBinding()
    let plan = try catalog.reserve(requestID: "receipt-parent", scope: scope(), choices: choices, health: .empty)
    let sealed = try catalog.seal(requestID: plan.requestID, parentIntentDigest: String(repeating: "c", count: 64))
    let receipt = try ledgerReceipt(sealed, ledger.componentID)
    catalog.injectNextFailure(.afterCommitResponseLost)
    XCTAssertThrowsError(try catalog.saveReceipt(receipt))
    try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: control)
    let saved = try reopened.receipts(requestID: plan.requestID)
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(try M4CatalogIO.encode(saved.first), try M4CatalogIO.encode(Optional(receipt)))
    XCTAssertEqual(try reopened.index().revision, original.revision)
    XCTAssertEqual(try reopened.index().digest(), try original.digest())
    XCTAssertEqual(try reopened.index().entries.first(where: { $0.capsule.kind == .deviceSync })?.capsule.deviceBinding(), binding)
    let before = try Data(contentsOf: control.appendingPathComponent("catalog.json"))
    try reopened.saveReceipt(receipt)
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.json")), before)
    try reopened.close()
  }
  func testChangedFirstReceiptAndForeignParentCannotOverwriteRetainedBytes() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
    let ledger = try capsule(dir, "ledger"); try catalog.record(ledger)
    _ = try catalog.reserve(requestID: "receipt-parent", scope: scope(), choices: choices, health: .empty)
    let plan = try catalog.seal(requestID: "receipt-parent", parentIntentDigest: String(repeating: "c", count: 64))
    let receipt = try ledgerReceipt(plan, ledger.componentID); try catalog.saveReceipt(receipt)
    let before = try Data(contentsOf: control.appendingPathComponent("catalog.json"))
    let changed = try ledgerReceipt(plan, ledger.componentID, leafDigest: String(repeating: "b", count: 64))
    XCTAssertThrowsError(try catalog.saveReceipt(changed))
    for key in ["parentID", "parentIntentDigest", "catalogDigest", "componentID", "capsuleDigest", "childRequestID", "leafDigest", "receiptDigest"] {
      var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: M4CatalogIO.encode(receipt)) as? [String: Any])
      raw[key] = key.hasSuffix("Digest") || key == "leafDigest" ? String(repeating: "f", count: 64) : "foreign"
      let altered = try JSONDecoder().decode(M4RetainedLeafReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
      XCTAssertThrowsError(try catalog.saveReceipt(altered), key)
      XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.json")), before)
    }
    try catalog.close()
  }
  func testReceiptBeforeCommitAndOversizeCannotAdvanceProgress() throws {
    let dir = try root(), control = dir.appendingPathComponent("retained"), catalog = try M4OwnedDataCatalog(directory: control)
    let ledger = try capsule(dir, "ledger"); try catalog.record(ledger)
    let reserved = try catalog.reserve(requestID: "receipt-parent", scope: scope(), choices: choices, health: .empty)
    XCTAssertThrowsError(try M4RetainedLeafReceipt.capture(plan: reserved, componentID: ledger.componentID, leafDigest: String(repeating: "a", count: 64), canonicalReceipt: Data()))
    let plan = try catalog.seal(requestID: reserved.requestID, parentIntentDigest: String(repeating: "c", count: 64))
    let before = try Data(contentsOf: control.appendingPathComponent("catalog.json")), receipt = try ledgerReceipt(plan, ledger.componentID)
    catalog.injectNextFailure(.beforeCommit); XCTAssertThrowsError(try catalog.saveReceipt(receipt))
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty)
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.json")), before)
    XCTAssertThrowsError(try M4RetainedLeafReceipt.capture(plan: plan, componentID: ledger.componentID, leafDigest: receipt.leafDigest, canonicalReceipt: Data(repeating: 1, count: 16_385))) { XCTAssertEqual($0 as? M4CatalogError, .budgetExceeded) }
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.json")), before)
    try catalog.close()
  }
  private func ledgerReceipt(_ plan: M4FrozenDeletionPlan, _ component: String, leafDigest: String = String(repeating: "a", count: 64)) throws -> M4RetainedLeafReceipt {
    let child = try XCTUnwrap(plan.children.first { $0.componentID == component })
    let scope = try XCTUnwrap(plan.entries.first { $0.capsule.componentID == component }).capsule.scope
    let bytes = try JSONSerialization.data(withJSONObject: ["requestID": child.requestID, "requestDigest": leafDigest, "stableZoneKey": scope.stableZoneKey], options: [.sortedKeys, .withoutEscapingSlashes])
    return try M4RetainedLeafReceipt.capture(plan: plan, componentID: component, leafDigest: leafDigest, canonicalReceipt: bytes)
  }
  func testLegacyReservedPlanKeepsOriginalMembershipOnReopen() throws {
    let external = ProcessInfo.processInfo.environment["M4_LEGACY_CATALOG_ROOT"]
    let mode = ProcessInfo.processInfo.environment["M4_LEGACY_CATALOG_MODE"]
    let dir = try external.map { URL(fileURLWithPath: $0) } ?? root(), control = dir.appendingPathComponent("retained")
    let expected = dir.appendingPathComponent("expected-plan.json")
    if mode != "read" {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let catalog = try M4OwnedDataCatalog(directory: control)
      try catalog.record(capsule(dir, "legacy-device", kind: .deviceSync))
      let plan = try catalog.reserve(requestID: "legacy-original-parent", scope: scope(), choices: choices, health: .empty)
      let sealed = try catalog.seal(requestID: plan.requestID, parentIntentDigest: String(repeating: "d", count: 64))
      try sealed.canonicalBytes().write(to: expected, options: .withoutOverwriting); try catalog.close()
      // The ordinary suite also verifies the exact prior v1 canonical shape.
      // The separately preserved capture/read run executes the actual old writer.
      let journal = control.appendingPathComponent("catalog.json")
      var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
      if value.removeValue(forKey: "membershipRevision") != nil {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        let file = try FileHandle(forWritingTo: journal); try file.truncate(atOffset: 0); try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
      }
    }
    let bytes = try Data(contentsOf: expected), original = try JSONDecoder().decode(M4FrozenDeletionPlan.self, from: bytes)
    let before = try Data(contentsOf: control.appendingPathComponent("catalog.json"))
    let reopened = try M4OwnedDataCatalog(directory: control), current = try XCTUnwrap(reopened.plan(requestID: original.requestID))
    XCTAssertEqual(try current.canonicalBytes(), bytes)
    XCTAssertEqual(try reopened.index().revision, original.catalogRevision)
    XCTAssertEqual(try reopened.index().digest(), original.catalogDigest)
    XCTAssertEqual(try reopened.seal(requestID: original.requestID, parentIntentDigest: try XCTUnwrap(original.parentIntentDigest)).canonicalBytes(), bytes)
    XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("catalog.json")), before)
    try reopened.close()
  }
  func testReserveAndSealProgressDoNotChangeOwnedMembershipRevisionOrDigest() throws {
    let dir = try root(), catalog = try M4OwnedDataCatalog(directory: dir.appendingPathComponent("retained"))
    let original = try capsule(dir, "device", kind: .deviceSync)
    try catalog.record(original)
    let before = try catalog.index(), binding = try original.deviceBinding()
    let plan = try catalog.reserve(requestID: "membership-stable-parent", scope: scope(), choices: choices, health: .empty)
    XCTAssertEqual(plan.catalogRevision, before.revision)
    XCTAssertEqual(try catalog.index().revision, before.revision)
    XCTAssertEqual(try catalog.index().digest(), try before.digest())
    _ = try catalog.seal(requestID: plan.requestID, parentIntentDigest: String(repeating: "e", count: 64))
    XCTAssertEqual(try catalog.index().revision, before.revision)
    XCTAssertEqual(try catalog.index().digest(), try before.digest())
    XCTAssertEqual(try catalog.index().entries[0].capsule.deviceBinding(), binding)
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

private final class CatalogSyncTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [M4CatalogCrashPoint] = []
  func append(_ point: M4CatalogCrashPoint) { lock.withLock { events.append(point) } }
  func values() -> [M4CatalogCrashPoint] { lock.withLock { events } }
  func clear() { lock.withLock { events.removeAll() } }
}

private struct CatalogControlledDrain: DeviceSyncErasureDriving {
  func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .drained }
}
