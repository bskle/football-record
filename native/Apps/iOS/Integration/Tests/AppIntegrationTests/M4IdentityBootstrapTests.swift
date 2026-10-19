import Foundation
import Darwin
import XCTest
import AccountKit
import MatchSession
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
