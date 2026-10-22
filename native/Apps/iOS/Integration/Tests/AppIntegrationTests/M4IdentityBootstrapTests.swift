import Foundation
import Darwin
import XCTest
import AccountKit
import MatchSession
import MatchStore
import CloudSync
import CryptoKit
@testable import AppIntegration

@MainActor final class M4IdentityBootstrapTests: XCTestCase {
  private func location() -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-bootstrap-" + UUID().uuidString)
    return (root.appendingPathComponent("business"), root.appendingPathComponent("retained"))
  }
  private func material(_ seed: M4IdentitySeed) throws -> M4IdentityMaterial {
    let key = seed.controlDirectory.appendingPathComponent("fixture-key")
    let bytes: Data
    if FileManager.default.fileExists(atPath: key.path) { bytes = try Data(contentsOf: key) }
    else {
      guard !seed.businessExisted else { throw M4BootstrapError.identityUnavailable }
      bytes = Data(repeating: 17, count: 32); try bytes.write(to: key, options: .withoutOverwriting)
    }
    return M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: seed.namespace, rawRepresentation: bytes), vault: MemoryDeviceCredentialVault())
  }
  func testVaultFinishesBeforeFirstBusinessDatabaseCreationAndOriginalIDAgrees() async throws {
    let (root, control) = location(); var calls = 0
    let value = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-one", controlDirectory: control) { seed in
      calls += 1
      XCTAssertFalse(FileManager.default.fileExists(atPath: seed.businessDatabaseURL.path))
      XCTAssertEqual(try String(contentsOf: seed.namespaceDirectory.appendingPathComponent("device.identity"), encoding: .utf8), "football-record.identity.v1:" + seed.installationID)
      return try self.material(seed)
    }
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: value.seed.businessDatabaseURL.path))
    let repository = try value.openRepository()
    let provider = PersistentDeviceIdentityProvider(url: value.seed.namespaceDirectory.appendingPathComponent("device.identity"), repository: repository)
    let actual = try await provider.localDeviceID(); XCTAssertEqual(actual, value.seed.installationID)
    let databaseURL = await repository.databaseURL
    XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    do { _ = try value.openRepository(); XCTFail("second facade must be refused") } catch { XCTAssertEqual(error as? M4BootstrapError, .alreadyOpened) }
    try await value.close()
  }
  func testExistingEmptyDatabaseMissingIdentityFailsBeforeVaultAndPreservesDatabase() async throws {
    let (root, control) = location()
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-two", controlDirectory: control) { try self.material($0) }
    let opened = try first.openRepository(); let database = await opened.databaseURL
    let identity = first.seed.namespaceDirectory.appendingPathComponent("device.identity")
    try await first.close(); let prior = try Data(contentsOf: database)
    try FileManager.default.removeItem(at: identity); var called = false
    do {
      _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-two", controlDirectory: control) { seed in called = true; return try self.material(seed) }
      XCTFail("existing empty DB cannot regenerate identity")
    } catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertFalse(called); XCTAssertEqual(try Data(contentsOf: database), prior)
    XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
  }
  func testExistingEmptyDatabaseMissingOriginalKeyCannotReplaceIt() async throws {
    let (root, control) = location()
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-three", controlDirectory: control) { try self.material($0) }
    let opened = try first.openRepository(); let database = await opened.databaseURL; let id = first.seed.installationID
    try await first.close(); let prior = try Data(contentsOf: database)
    try FileManager.default.removeItem(at: control.appendingPathComponent("fixture-key"))
    do { _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-three", controlDirectory: control) { try self.material($0) }; XCTFail("missing key") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertEqual(try Data(contentsOf: database), prior)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("m4-local-three/device.identity"), encoding: .utf8), "football-record.identity.v1:" + id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("fixture-key").path))
  }
  func testVaultFailureLeavesNoDatabaseAndRetryKeepsOriginalIdentity() async throws {
    let (root, control) = location(); var original: String?
    do {
      _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-four", controlDirectory: control) { seed in original = seed.installationID; throw M4BootstrapError.identityUnavailable }
      XCTFail("vault failed")
    } catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m4-local-four/matches.sqlite").path))
    let retry = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-four", controlDirectory: control) { try self.material($0) }
    XCTAssertEqual(retry.seed.installationID, original); try await retry.close()
  }
  func testUnknownUnboundNamespacePreservesBytesWithoutAdoption() async throws {
    let (root, control) = location(); let directory = root.appendingPathComponent("m4-local-five")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("unknown.bin"), bytes = Data([0, 7, 255]); try bytes.write(to: file)
    do { _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-five", controlDirectory: control) { try self.material($0) }; XCTFail("legacy must not be adopted") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .foreignNamespace) }
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("device.identity").path))
  }
  func testActiveLeasePreventsConcurrentFreshIdentityReplacement() async throws {
    let (root, control) = location(); let barrier = BootstrapBarrier()
    let pending = Task { try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-six", controlDirectory: control) { seed in await barrier.wait(); return try self.material(seed) } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !barrier.started, ContinuousClock.now < deadline { await Task.yield() }
    guard barrier.started else { _ = try await pending.value; XCTFail("factory never reached"); return }
    let original = try String(contentsOf: root.appendingPathComponent("m4-local-six/device.identity"), encoding: .utf8)
    do { _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-six", controlDirectory: control) { try self.material($0) }; XCTFail("already active") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .leaseInUse) }
    barrier.release(); let result = try await pending.value
    XCTAssertEqual(original, "football-record.identity.v1:" + result.seed.installationID)
    try await result.close()
  }
  func testClosedLeaseReopensSameOriginalKeyAndIdentity() async throws {
    let (root, control) = location()
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-seven", controlDirectory: control) { try self.material($0) }
    let id = first.seed.installationID, key = first.material.signer.publicKey
    _ = try first.openRepository(); try await first.close()
    let next = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-seven", controlDirectory: control) { try self.material($0) }
    XCTAssertEqual(next.seed.installationID, id); XCTAssertEqual(next.material.signer.publicKey, key)
    XCTAssertTrue(next.seed.businessExisted); try await next.close()
    do { _ = try next.openRepository(); XCTFail("closed context") } catch { XCTAssertEqual(error as? M4BootstrapError, .closed) }
  }
  func testMissingRetainedOwnerCannotAdoptExistingDatabase() async throws {
    let (root, control) = location()
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-eight", controlDirectory: control) { try self.material($0) }
    let opened = try first.openRepository(); let database = await opened.databaseURL; try await first.close()
    let owner = control.appendingPathComponent("identity.owner"), prior = try Data(contentsOf: database)
    try FileManager.default.removeItem(at: owner)
    do { _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-eight", controlDirectory: control) { try self.material($0) }; XCTFail("cannot re-own old DB") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertEqual(try Data(contentsOf: database), prior)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
  }
  func testCaseAliasedControlDirectoryCannotOverlapBusinessStorage() async throws {
    for relation in ["same", "child", "ancestor"] {
      let (root, _) = location(), namespace = "m4-case-" + relation
      let business = root.appendingPathComponent(namespace)
      try FileManager.default.createDirectory(at: business, withIntermediateDirectories: true)
      let original = relation == "ancestor" ? root : business
      let alias = original.deletingLastPathComponent().appendingPathComponent(original.lastPathComponent.uppercased())
      var a = stat(), b = stat()
      XCTAssertEqual(lstat(original.path, &a), 0)
      guard lstat(alias.path, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else {
        throw XCTSkip("Test volume is case-sensitive; case alias is not the original directory")
      }
      XCTAssertNotEqual(Data(original.path.utf8), Data(alias.path.utf8))
      let control = relation == "child" ? alias.appendingPathComponent("retained") : alias
      var vaultCalled = false
      do {
        let value = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { seed in
          vaultCalled = true; return try self.material(seed)
        }
        try await value.close(); XCTFail("case-aliased " + relation + " controls overlap business storage")
      } catch { XCTAssertEqual(error as? M4BootstrapError, .foreignNamespace) }
      XCTAssertFalse(vaultCalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("identity.owner").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("fixture-key").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: business.appendingPathComponent("device.identity").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: business.appendingPathComponent("matches.sqlite").path))
    }
  }
  func testSymlinkedRootAndOverlappingControlsAreRejected() async throws {
    let (root, control) = location(); let target = root.deletingLastPathComponent().appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
    do { _ = try await M4IdentityBootstrap.prepare(root: root, namespace: "m4-local-nine", controlDirectory: control) { try self.material($0) }; XCTFail("symlink root") } catch {}
    do { _ = try await M4IdentityBootstrap.prepare(root: target, namespace: "m4-local-nine", controlDirectory: target.appendingPathComponent("m4-local-nine/control")) { try self.material($0) }; XCTFail("controls inside business") } catch {}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).isEmpty)
  }
}
@MainActor private final class BootstrapBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  var started = false
  func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}

#if DEBUG
extension M4IdentityBootstrapTests {
  func testIndependentControlledIdentityRereadsBothOriginalInputs() async throws {
    let directory = try identityObservationDirectory(), namespace = "m4-ui-observation-phone"
    let observer = try M4ControlledCurrentIdentity(directory: directory, namespace: namespace)
    let first = try await observer.currentIdentity()
    XCTAssertEqual(first.accountID, "independent-account"); XCTAssertEqual(first.cloudSpaceID, "independent-cloud"); XCTAssertEqual(first.zoneID, "independent-zone")
    try updateObservation(directory.appendingPathComponent("apple-account.json"), field: "accountID", value: "changed-independent-account")
    let second = try await observer.currentIdentity(); XCTAssertEqual(second.accountID, "changed-independent-account", "never cache configured/bound/credential identity")
    try updateObservation(directory.appendingPathComponent("cloud-space.json"), field: "observationID", value: UUID().uuidString)
    do { _ = try await observer.currentIdentity(); XCTFail("different controlled pair IDs cannot admit") } catch {}
  }
  func testIndependentControlledIdentityRejectsMissingBadAndReplacedOriginalFiles() async throws {
    for kind in ["missing", "mode", "replacement", "parent", "environment", "extra"] {
      let directory = try identityObservationDirectory(), file = directory.appendingPathComponent("apple-account.json")
      let observer = try M4ControlledCurrentIdentity(directory: directory, namespace: "m4-ui-observation-phone")
      switch kind {
      case "missing": try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("saved"))
      case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      case "replacement":
        let bytes = try Data(contentsOf: file); try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("saved")); try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      case "parent":
        let saved = directory.appendingPathExtension("saved"); try FileManager.default.moveItem(at: directory, to: saved); try FileManager.default.copyItem(at: saved, to: directory)
      case "environment": try updateObservation(file, field: "environment", value: "production")
      default: try updateObservation(file, field: "configuredSubject", value: "not-an-observation")
      }
      do { _ = try await observer.currentIdentity(); XCTFail("preserve and refuse " + kind) } catch {}
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "observer never deletes borrowed input")
    }
  }
  func testIndependentControlledIdentityRejectsLateBytesAndGenerationChange() async throws {
    for changeGeneration in [false, true] {
      let directory = try identityObservationDirectory(), gate = BootstrapBarrier()
      let observer = try M4ControlledCurrentIdentity(directory: directory, namespace: "m4-ui-observation-phone", readReplyGate: { await gate.wait() })
      let current = Task { try await observer.currentIdentity() }
      while !gate.started { await Task.yield() }
      if changeGeneration { try await observer.advanceIdentityFence(to: 1) }
      else { try updateObservation(directory.appendingPathComponent("cloud-space.json"), field: "cloudSpaceID", value: "late-changed-cloud") }
      gate.release()
      do { _ = try await current.value; XCTFail("held original read cannot cross changed bytes/generation") } catch {}
    }
  }
  private func identityObservationDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m4-independent-identity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let observation = UUID().uuidString
    let common: [String: Any] = ["version": 1, "environment": "development", "namespace": "m4-ui-observation-phone", "observationID": observation]
    for (name, values) in [("apple-account.json", ["accountID": "independent-account"]), ("cloud-space.json", ["cloudSpaceID": "independent-cloud", "zoneID": "independent-zone"])] {
      let object = common.merging(values) { _, new in new }, file = directory.appendingPathComponent(name)
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    return directory
  }
  private func updateObservation(_ file: URL, field: String, value: String) throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]); object[field] = value
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    let original = try FileHandle(forWritingTo: file); defer { try? original.close() }
    try original.truncate(atOffset: 0); try original.write(contentsOf: bytes); try original.synchronize()
  }
}
#endif


extension M4IdentityBootstrapTests {
  func testManagedResourceReservationPrecedesPositiveBusinessSQLiteAndKeepsOriginalInode() async throws {
    let (root, control) = location(), namespace = "managed-physical-first"
    let prepared = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    var reserved = false
    try prepared.prepareManagedResources { point in
      if point == .afterReservation {
        reserved = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
        let catalog = try Data(contentsOf: control.deletingLastPathComponent().appendingPathComponent("catalog/catalog.json"))
        XCTAssertTrue(String(decoding: catalog, as: UTF8.self).contains(prepared.seed.installationID))
      }
    }
    XCTAssertTrue(reserved)
    var before = stat(); XCTAssertEqual(lstat(prepared.seed.businessDatabaseURL.path, &before), 0); XCTAssertEqual(before.st_size, 0)
    let repository = try prepared.openRepository()
    let binding = try await repository.accountBindingV4(); XCTAssertNil(binding)
    try await prepared.close()
    var after = stat(); XCTAssertEqual(lstat(prepared.seed.businessDatabaseURL.path, &after), 0)
    XCTAssertEqual(before.st_dev, after.st_dev); XCTAssertEqual(before.st_ino, after.st_ino); XCTAssertGreaterThan(after.st_size, 0)
  }
  func testManagedNoLoginReopenRetainsOriginalReservationIdentityAndBusinessInode() async throws {
    let (root, control) = location(), namespace = "managed-no-login"
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    try first.prepareManagedResources(); let db = try first.openRepository(), database = await db.databaseURL
    let id = first.seed.installationID, key = first.material.signer.publicKey
    try await first.close(); let bytes = try Data(contentsOf: database)
    let owner = control.deletingLastPathComponent().appendingPathComponent("resources/resource.owner"), ownerBytes = try Data(contentsOf: owner)
    let next = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    try next.prepareManagedResources()
    XCTAssertEqual(next.seed.installationID, id); XCTAssertEqual(next.material.signer.publicKey, key)
    XCTAssertEqual(try Data(contentsOf: owner), ownerBytes); XCTAssertEqual(try Data(contentsOf: database), bytes)
    let original = try next.openRepository(); let binding = try await original.accountBindingV4(); XCTAssertNil(binding)
    try await next.close()
  }
  func testManagedReplacedOwnerCannotAdoptPositiveDatabaseOrRegenerateReservation() async throws {
    let (root, control) = location(), namespace = "managed-replaced-owner"
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    try first.prepareManagedResources(); _ = try first.openRepository(); let database = first.seed.businessDatabaseURL
    try await first.close(); let before = try Data(contentsOf: database)
    let owner = control.deletingLastPathComponent().appendingPathComponent("resources/resource.owner"), old = owner.appendingPathExtension("original")
    let bytes = try Data(contentsOf: owner); try FileManager.default.moveItem(at: owner, to: old); try bytes.write(to: owner)
    let next = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    XCTAssertThrowsError(try next.prepareManagedResources())
    XCTAssertEqual(try Data(contentsOf: database), before); XCTAssertEqual(try Data(contentsOf: owner), bytes)
    try await next.close()
  }
  func testManagedReservationAndPublicationCrashesResumeOnlyOriginalPhysicalSlots() async throws {
    for point in [M4ResourceCrashPoint.afterReservation, .afterResourceRename, .afterBusinessRename] {
      let (root, control) = location(), namespace = "managed-crash"
      let first = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
      let id = first.seed.installationID
      XCTAssertThrowsError(try first.prepareManagedResources { if $0 == point { throw M4BootstrapError.storageUnavailable } })
      try await first.close()
      let next = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
      try next.prepareManagedResources(); XCTAssertEqual(next.seed.installationID, id)
      let db = try next.openRepository(); let binding = try await db.accountBindingV4(); XCTAssertNil(binding)
      try await next.close()
    }
  }
}


extension M4IdentityBootstrapTests {
  func testManagedReplacementCatalogCannotBorrowOriginalPhysicalReservation() async throws {
    let (root, control) = location(), namespace = "managed-catalog-replacement"
    let first = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    try first.prepareManagedResources(); _ = try first.openRepository(); let database = first.seed.businessDatabaseURL
    try await first.close(); let bytes = try Data(contentsOf: database)
    let path = control.deletingLastPathComponent().appendingPathComponent("catalog")
    let original = try M4OwnedDataCatalog(directory: path), saved = try XCTUnwrap(original.physicalBootstrap())
    try original.close()
    try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("original"))
    let replacement = try M4OwnedDataCatalog(directory: path)
    try replacement.reservePhysicalBootstrap(saved.reservation)
    try replacement.recordPhysicalPublication(saved.reservation, business: false)
    try replacement.recordPhysicalPublication(saved.reservation, business: true)
    try replacement.close()
    let next = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    XCTAssertThrowsError(try next.prepareManagedResources(), "a new valid catalog cannot adopt original positive SQLite via copied reservation bytes")
    XCTAssertEqual(try Data(contentsOf: database), bytes)
    try await next.close()
  }
  func testManagedPreparationFailureCannotFallBackToUnreservedSQLiteOpen() async throws {
    let (root, control) = location(), namespace = "managed-failed-preparation"
    let prepared = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
    XCTAssertThrowsError(try prepared.prepareManagedResources { if $0 == .afterReservation { throw M4BootstrapError.storageUnavailable } })
    XCTAssertThrowsError(try prepared.openRepository(), "a failed managed resource path cannot silently use the legacy fixture opening")
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
    try await prepared.close()
  }
}


extension M4IdentityBootstrapTests {
  private func unrelatedSQLiteSidecars() async throws -> (Data, Data) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-foreign-wal-" + UUID().uuidString)
    let foreign = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "foreign-wal")
    try await foreign.setAnalyticsEnabledV4(false)
    let path = await foreign.databaseURL
    let wal = try Data(contentsOf: URL(fileURLWithPath: path.path + "-wal")), shm = try Data(contentsOf: URL(fileURLWithPath: path.path + "-shm"))
    XCTAssertFalse(wal.isEmpty); XCTAssertFalse(shm.isEmpty)
    try await foreign.close()
    return (wal, shm)
  }
  private func assertPreservedSidecar(_ url: URL, inode: UInt64, bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { XCTFail("unowned sidecar was removed by SQLite", file: file, line: line); return }
    XCTAssertEqual(info.st_ino, inode, file: file, line: line)
    XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
  }
  func testManagedUninitializedMainRejectsUnownedSidecarsBeforeSQLiteRecovery() async throws {
    let (wal, shm) = try await unrelatedSQLiteSidecars()
    // The WAL/SHM bytes come from a different real SQLite. The journal case is
    // explicitly unrelated bytes under that recognized sidecar name.
    for suffixes in [["-wal"], ["-shm"], ["-wal", "-shm"], ["-journal"]] {
      let (root, control) = location(), namespace = "managed-foreign-sidecars"
      let first = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
      XCTAssertThrowsError(try first.prepareManagedResources { if $0 == .afterBusinessRename { throw M4BootstrapError.storageUnavailable } })
      let main = first.seed.businessDatabaseURL
      try await first.close(); XCTAssertEqual(try Data(contentsOf: main), Data())
      var originalMain = stat(); XCTAssertEqual(lstat(main.path, &originalMain), 0)
      var originals: [(URL, UInt64, Data)] = []
      for suffix in suffixes {
        let file = URL(fileURLWithPath: main.path + suffix), bytes = suffix == "-shm" ? shm : wal
        try bytes.write(to: file, options: .withoutOverwriting)
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0); originals.append((file, info.st_ino, bytes))
      }
      let next = try await M4IdentityBootstrap.prepare(root: root, namespace: namespace, controlDirectory: control) { try self.material($0) }
      var reachedSQLiteConstruction = false
      do {
        try next.prepareManagedResources(); reachedSQLiteConstruction = true
        _ = try next.openRepository()
      } catch {}
      XCTAssertFalse(reachedSQLiteConstruction, "the uninitialized main must reject foreign sidecars before sqlite3_open")
      try? await next.close()
      XCTAssertEqual(try Data(contentsOf: main), Data(), "foreign WAL must not initialize the original zero-byte main")
      var finalMain = stat(); XCTAssertEqual(lstat(main.path, &finalMain), 0); XCTAssertEqual(finalMain.st_ino, originalMain.st_ino)
      for (file, inode, bytes) in originals { try assertPreservedSidecar(file, inode: inode, bytes: bytes) }
    }
  }
  func testManagedPublishedZeroByteMainRechecksSidecarsImmediatelyBeforeFirstOpen() async throws {
    let (wal, _) = try await unrelatedSQLiteSidecars(), (root, control) = location()
    let prepared = try await M4IdentityBootstrap.prepare(root: root, namespace: "managed-late-sidecar", controlDirectory: control) { try self.material($0) }
    try prepared.prepareManagedResources()
    let main = prepared.seed.businessDatabaseURL, sidecar = URL(fileURLWithPath: main.path + "-wal")
    try wal.write(to: sidecar, options: .withoutOverwriting)
    var original = stat(); XCTAssertEqual(lstat(sidecar.path, &original), 0)
    var originalMain = stat(); XCTAssertEqual(lstat(main.path, &originalMain), 0)
    XCTAssertThrowsError(try prepared.openRepository(), "a late unowned WAL cannot bypass the pre-SQL check")
    try? await prepared.close()
    XCTAssertEqual(try Data(contentsOf: main), Data()); try assertPreservedSidecar(sidecar, inode: original.st_ino, bytes: wal)
    var finalMain = stat(); XCTAssertEqual(lstat(main.path, &finalMain), 0); XCTAssertEqual(finalMain.st_ino, originalMain.st_ino)
  }
  func testManagedInitializedDatabaseReopensItsOwnUncheckpointedWAL() async throws {
    #if os(macOS)
    let variable = "NATIVE026_MANAGED_WAL_CHILD_ROOT"
    if let path = ProcessInfo.processInfo.environment[variable] {
      let root = URL(fileURLWithPath: path)
      let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "managed-original-wal", controlDirectory: root.appendingPathComponent("retained")) { try self.material($0) }
      try prepared.prepareManagedResources()
      let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["fixture": prepared.material.signer.publicKey])
      let db = try prepared.openRepository(authorityTrust: trust)
      // Direct public Store binding is only a fixture for WAL recovery; it is
      // not authentication/signed account authority evidence.
      try await db.bindAccountV4(AccountBindingV4(accountID: "wal-original-account", cloudSpaceID: "wal-original-cloud", deviceID: prepared.seed.installationID, activationEpoch: 1, role: .phone, environment: .development))
      guard FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path + "-wal") else { XCTFail("actual WAL required"); return }
      _exit(86) // No SQLite close/checkpoint; the OS releases the original lease.
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-original-wal-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    child.arguments = ["xctest", "-XCTest", "AppIntegrationTests.M4IdentityBootstrapTests/testManagedInitializedDatabaseReopensItsOwnUncheckpointedWAL", Bundle(for: Self.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment; environment[variable] = root.path; child.environment = environment
    let log = root.appendingPathComponent("child.log"); XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
    let output = try FileHandle(forWritingTo: log); child.standardOutput = output; child.standardError = output
    try child.run(); child.waitUntilExit(); try output.close()
    XCTAssertEqual(child.terminationReason, .exit); XCTAssertEqual(child.terminationStatus, 86)
    let main = root.appendingPathComponent("business/managed-original-wal/matches.sqlite"), wal = URL(fileURLWithPath: main.path + "-wal")
    var before = stat(); XCTAssertEqual(lstat(main.path, &before), 0); XCTAssertGreaterThan(before.st_size, 0)
    XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0)
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "managed-original-wal", controlDirectory: root.appendingPathComponent("retained")) { try self.material($0) }
    try prepared.prepareManagedResources()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["fixture": prepared.material.signer.publicKey])
    let db = try prepared.openRepository(authorityTrust: trust), binding = try await db.accountBindingV4()
    XCTAssertEqual(binding?.accountID, "wal-original-account")
    var after = stat(); XCTAssertEqual(lstat(main.path, &after), 0); XCTAssertEqual(after.st_ino, before.st_ino)
    print("managed-original-wal-child exit=86 root=\(root.path)")
    try await prepared.close()
    #endif
  }
}

#if DEBUG && os(macOS)
@MainActor private final class M4FoundationChangeGate {
  var repository: SQLiteSessionRepository?
  func run() async { if let repository { try? await repository.suspendAccountV4() } }
}
private struct M4FoundationUnavailableRelay: AuthorityHTTPRelay {
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse { throw AuthorityError.unavailable }
}
/// Local signed-grant fixture for provenance tests; never backend authorization.
@MainActor struct M4ManagedFoundationFixture {
  let root: URL
  let prepared: M4PreparedIdentity
  let repository: SQLiteSessionRepository
  let handle: M4ManagedPhoneResources
  let trust: AuthorityTrustConfiguration
  let key: Curve25519.Signing.PrivateKey
  let session: MatchSession
  let client: AuthorityClient
  static func make(test: XCTestCase? = nil, resourceReplyGate: (@MainActor () async -> Void)? = nil) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-foundation-" + UUID().uuidString)
    let key = Curve25519.Signing.PrivateKey()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["foundation-service": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "m4-foundation", controlDirectory: root.appendingPathComponent("retained/identity")) { _ in
      M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: "m4-foundation", rawRepresentation: Data(repeating: 29, count: 32)), vault: MemoryDeviceCredentialVault())
    }
    try prepared.prepareManagedResources(resourceReplyGate: resourceReplyGate)
    let repository = try prepared.openRepository(authorityTrust: trust)
    let attempt = try AuthAttemptV4(requestID: "foundation-auth", deviceID: prepared.seed.installationID, publicKey: prepared.material.signer.publicKey, cloudSpaceID: "foundation-cloud", challengeID: "foundation-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
    let binding = try AccountBindingV4(accountID: "foundation-account", cloudSpaceID: "foundation-cloud", deviceID: prepared.seed.installationID, activationEpoch: 1, role: .phone, environment: .development)
    let receipt = try signed(key: key, trust: trust, requestID: attempt.requestID, digest: attempt.requestDigest, operation: .authApple, result: "registered")
    try await repository.saveAuthAttemptV4(attempt, expectedIdentityGeneration: 0)
    try await repository.acceptAuthenticationV4(attempt: attempt, binding: binding, receipt: receipt, expectedIdentityGeneration: 0)
    let generation = try await repository.identityGenerationV4()
    let observed = M4CurrentAccountIdentity(accountID: binding.accountID, cloudSpaceID: binding.cloudSpaceID, zoneID: "foundation-zone", environment: .development)
    let handle = try await prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: generation, observed: observed)
    let client = AuthorityClient(relay: M4FoundationUnavailableRelay(), vault: prepared.material.vault, signer: prepared.material.signer, trust: trust)
    let device = PersistentDeviceIdentityProvider(url: prepared.seed.namespaceDirectory.appendingPathComponent("device.identity"), repository: repository)
    let session = MatchSession(store: repository, deviceIdentity: device, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: AuthorityStartPermitProvider(client: client, repository: repository), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: prepared.seed.namespace))
    let fixture = Self(root: root, prepared: prepared, repository: repository, handle: handle, trust: trust, key: key, session: session, client: client)
    test?.addTeardownBlock { try await fixture.close() }
    return fixture
  }
  static func signed(key: Curve25519.Signing.PrivateKey, trust: AuthorityTrustConfiguration, requestID: String, digest: String, operation: AuthorityOperation, result: String) throws -> VerifiedAuthorityReceiptV1 {
    var body: [String: Any] = ["version": 1, "environment": "development", "keyID": "foundation-service", "receiptID": UUID().uuidString, "requestID": requestID, "requestDigest": digest, "operation": operation.rawValue, "accountID": "foundation-account", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": result, "issuedAt": Int64(Date().timeIntervalSince1970)]
    if operation == .deleteAccount { body["deletion"] = ["backend": "backendDeleted", "apple": "revoked", "cloud": "clientManaged", "local": "clientManaged", "health": "separateConfirmation"] }
    let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    let bytes = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: raw)))], options: [.sortedKeys, .withoutEscapingSlashes])
    return try VerifiedAuthorityReceiptV1.verify(bytes, expected: AuthorityExpectedIntent(requestID: requestID, digest: digest, operation: operation, accountID: "foundation-account", epoch: 1), trust: trust)
  }
  func creation(_ requestID: String = "foundation-delete") -> M4DeletionCreationMetadata {
    M4DeletionCreationMetadata(version: 1, requestID: requestID, scope: handle.scope, choices: M4DeletionChoices(cloud: .keep, local: .delete, health: .keep, healthConfirmed: false), firstReauthID: "foundation-reauth", authRequestID: handle.attachment.currentAuthRequestID, authReceiptDigest: AuthorityWire.hash(handle.attachment.receiptRaw), identityGeneration: handle.attachment.identityGeneration, confirmedAt: Int64(Date().timeIntervalSince1970), dispatch: .reserved)
  }
  func saga(_ requestID: String = "foundation-delete") async throws -> DeletionSagaV4 {
    let service = LifecycleService(client: client, repository: repository, coordinator: session, scope: handle.scope, ledger: handle.ledger)
    return try await service.requestDeletion(requestID: requestID, reauthenticationID: "foundation-reauth", cloud: .keep, local: .delete, health: .keep, healthConfirmed: false)
  }
  func close() async throws {
    try await prepared.close()
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
extension M4IdentityBootstrapTests {
  func testManagedDeletionBorrowUsesOriginalCatalogAndCachedActor() async throws {
    let f = try await M4ManagedFoundationFixture.make(test: self)
    let first = try await f.prepared.borrowActiveDeletionResources(handle: f.handle)
    let second = try await f.prepared.borrowActiveDeletionResources(handle: f.handle)
    XCTAssertTrue(first.catalog === second.catalog); XCTAssertTrue(first.ledger === f.handle.ledger)
    XCTAssertTrue(second.ledger === first.ledger)
    try first.verify(); try second.verify()
    let before = try first.catalog.index()
    XCTAssertEqual(try first.catalog.physicalBootstrap()?.reservation.catalogOwnerDigest, first.physical.catalogOwnerDigest)
    XCTAssertEqual(try first.catalog.index().digest(), try before.digest())
    try await f.close()
    XCTAssertThrowsError(try first.verify())
  }
  func testManagedDeletionBorrowRejectsForeignActorUnknownInventoryAndReplacedInode() async throws {
    let f = try await M4ManagedFoundationFixture.make(test: self), foreign = try await M4ManagedFoundationFixture.make(test: self)
    do { _ = try await f.prepared.borrowActiveDeletionResources(handle: foreign.handle); XCTFail("foreign cached actor/physical pair") } catch {}
    let original = try await f.prepared.borrowActiveDeletionResources(handle: f.handle)
    let unknown = URL(fileURLWithPath: original.physical.directory.path).appendingPathComponent("unknown-producer")
    try Data([9]).write(to: unknown)
    XCTAssertThrowsError(try original.verify()); try FileManager.default.removeItem(at: unknown)
    let url = URL(fileURLWithPath: original.ledgerCapsule.root.path), moved = url.appendingPathExtension("original")
    try FileManager.default.moveItem(at: url, to: moved); try Data().write(to: url)
    XCTAssertThrowsError(try original.verify())
    try FileManager.default.removeItem(at: url); try FileManager.default.moveItem(at: moved, to: url)
    try original.verify(); try await foreign.close(); try await f.close()
  }
  func testRetainedBorrowRequiresSameOriginalStartedCreation() async throws {
    let f = try await M4ManagedFoundationFixture.make(test: self)
    let saga = try await f.saga()
    do { _ = try await f.prepared.borrowRetainedDeletionResources(saga: saga); XCTFail("original Saga alone cannot invent the managed creation/plan association") } catch {}
    try await f.close()
  }
  func testActiveBorrowRechecksOriginalStoreAfterAwaitAndRetainedRejectsUnrelatedSuspension() async throws {
    let gate = M4FoundationChangeGate()
    let f = try await M4ManagedFoundationFixture.make(test: self, resourceReplyGate: { await gate.run() })
    let borrow = try await f.prepared.borrowActiveDeletionResources(handle: f.handle), creation = f.creation()
    _ = try borrow.catalog.reserveManagedDeletion(creation: creation, borrow: borrow, health: .empty)
    _ = try borrow.catalog.markManagedDeletionStarted(requestID: creation.requestID, borrow: borrow)
    let saga = try await f.saga()
    gate.repository = f.repository
    do { _ = try await f.prepared.borrowActiveDeletionResources(handle: f.handle); XCTFail("current original proof changed during await") } catch {}
    do { _ = try await f.prepared.borrowRetainedDeletionResources(saga: saga); XCTFail("only actual backend acceptance permits suspended generation") } catch {}
    try await f.close()
  }
  func testRetainedBorrowRefusesMissingOriginalSagaAndMissingLedgerWithoutCreation() async throws {
    let f = try await M4ManagedFoundationFixture.make(test: self), foreign = try await M4ManagedFoundationFixture.make(test: self)
    let otherSaga = try await foreign.saga()
    do { _ = try await f.prepared.borrowRetainedDeletionResources(saga: otherSaga); XCTFail("no original Saga/control") } catch {}
    let saga = try await f.saga()
    let url = URL(fileURLWithPath: f.handle.ledgerCapsule.root.path), moved = url.appendingPathExtension("original")
    try FileManager.default.moveItem(at: url, to: moved)
    do { _ = try await f.prepared.borrowRetainedDeletionResources(saga: saga); XCTFail("missing original ledger") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "retained factory never recreates a missing database")
    try FileManager.default.moveItem(at: moved, to: url)
    try await foreign.close(); try await f.close()
  }
  func testRetainedBorrowUsesOriginalSagaControlAndSameLiveCacheAfterBackendAcceptance() async throws {
    let f = try await M4ManagedFoundationFixture.make(test: self)
    let active = try await f.prepared.borrowActiveDeletionResources(handle: f.handle), creation = f.creation()
    _ = try active.catalog.reserveManagedDeletion(creation: creation, borrow: active, health: .empty)
    _ = try active.catalog.markManagedDeletionStarted(requestID: creation.requestID, borrow: active)
    let saga = try await f.saga()
    let retainedBefore = try await f.prepared.borrowRetainedDeletionResources(saga: saga)
    XCTAssertTrue(retainedBefore.ledger === active.ledger)
    let receipt = try M4ManagedFoundationFixture.signed(key: f.key, trust: f.trust, requestID: saga.intent.requestID, digest: saga.intent.digest, operation: .deleteAccount, result: "deleted")
    let accepted = try await f.repository.acceptDeletionV4(requestID: saga.intent.requestID, receipt: receipt, expectedRevision: saga.revision)
    do { _ = try await f.prepared.borrowActiveDeletionResources(handle: f.handle); XCTFail("suspended original active proof") } catch {}
    let retained = try await f.prepared.borrowRetainedDeletionResources(saga: accepted)
    XCTAssertTrue(retained.catalog === active.catalog); XCTAssertTrue(retained.ledger === active.ledger); try retained.verify()
    var changed = accepted; changed.revision += 1
    do { _ = try await f.prepared.borrowRetainedDeletionResources(saga: changed); XCTFail("caller DTO is not original Store") } catch {}
    try await f.prepared.close()
    let reopened = try await M4IdentityBootstrap.prepare(root: f.prepared.seed.root, namespace: f.prepared.seed.namespace, controlDirectory: f.prepared.seed.controlDirectory) { _ in f.prepared.material }
    XCTAssertThrowsError(try reopened.prepareManagedResources(), "existing frozen plan blocks cold physical publication; no fresh admission")
    let ledgerURL = URL(fileURLWithPath: active.ledgerCapsule.root.path), anchor = try M4CatalogIO.anchor(ledgerURL)
    do { _ = try await reopened.borrowRetainedDeletionResources(saga: accepted); XCTFail("cold cache cannot open a replacement actor") } catch {}
    XCTAssertEqual(try M4CatalogIO.encode(M4CatalogIO.anchor(ledgerURL)), try M4CatalogIO.encode(anchor))
    try await reopened.close(); try FileManager.default.removeItem(at: f.root)
  }
}
#endif
