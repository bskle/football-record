#if DEBUG
import Foundation
import CryptoKit
import Darwin
import XCTest
import AccountKit
import MatchStore
import MatchSession
@testable import MatchPresentation

final class DevelopmentAuthorityDeviceMaterialTests: XCTestCase, @unchecked Sendable {
  private struct Fixture {
    let root, directory: URL
    let configuration: DevelopmentAuthorityConfiguration
    let deviceID: String
    var identity: URL { directory.appendingPathComponent("device.identity") }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func material() throws -> DevelopmentAuthorityDeviceMaterial {
      try DevelopmentAuthorityScenario.deviceMaterial(configuration: configuration, namespaceDirectory: directory, installationID: deviceID)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
  }
  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), directory = root.appendingPathComponent("m4-ui-material-phone")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString, key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 71, count: 32))
    try Data(("football-record.identity.v1:" + id).utf8).write(to: directory.appendingPathComponent("device.identity"))
    let configuration = DevelopmentAuthorityConfiguration(dataset: "material", namespace: "m4-ui-material-phone", baseURL: "http://127.0.0.1:1", keyID: "fixture", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation), cloudSpaceID: "cloud", subject: "subject", role: "phone")
    return Fixture(root: root, directory: directory, configuration: configuration, deviceID: id)
  }
  private let names = ["development.key", "authority.fixture", "development.vault"]
  private func bytes(_ f: Fixture) throws -> [String: Data] { try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted().map { ($0, try Data(contentsOf: f.file($0))) }) }
  private func credential(_ f: Fixture, _ m: DevelopmentAuthorityDeviceMaterial) throws -> DeviceCredential {
    DeviceCredential(token: AuthorityWire.base64URL(Data(repeating: 9, count: 32)), sessionID: "session", accountID: "account", deviceID: f.deviceID, keyID: try AuthorityWire.deviceKeyID(publicKey: m.signer.publicKey), activationEpoch: 1, expiresAt: 2_000_000_000)
  }
  func testInitialEmptyVaultExistsBeforeAnyBusinessDatabaseAndReopensOriginalMaterial() async throws {
    let f = try fixture(); defer { f.close() }
    let identity = try Data(contentsOf: f.identity), m = try f.material()
    XCTAssertEqual(m.namespace, f.configuration.namespace); XCTAssertEqual(m.deviceID, f.deviceID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.file("matches.sqlite").path))
    for name in names { let a = try FileManager.default.attributesOfItem(atPath: f.file(name).path); XCTAssertEqual((a[.posixPermissions] as? NSNumber)?.intValue, 0o600) }
    let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file("development.vault"))) as? [String: Any])
    XCTAssertEqual(state["generation"] as? Int, 0); XCTAssertNil(state["credential"])
    let original = try bytes(f), reopened = try f.material()
    XCTAssertEqual(reopened.signer.publicKey, m.signer.publicKey); XCTAssertEqual(try bytes(f), original); XCTAssertEqual(try Data(contentsOf: f.identity), identity)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.file("matches.sqlite").path))
    do { _ = try await reopened.vault.credential(); XCTFail("initial vault has no credential") } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
  }
  func testOriginalCredentialAndGenerationSurviveReopenAndOldHandleCannotLowerFence() async throws {
    let f = try fixture(); defer { f.close() }; let first = try f.material(), value = try credential(f, first)
    try await first.vault.replace(value, expectedIdentityGeneration: 0)
    let second = try f.material(), loaded = try await second.vault.credential(); XCTAssertEqual(loaded, value)
    try await second.vault.advanceIdentityFence(to: 4)
    do { try await first.vault.replace(value, expectedIdentityGeneration: 0); XCTFail("old handle cannot lower persisted generation") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    let original = try bytes(f), third = try f.material()
    do { _ = try await third.vault.credential(); XCTFail("fence clears original credential") } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    XCTAssertEqual(try bytes(f), original)
    try await first.vault.replace(value, expectedIdentityGeneration: 4)
    let actual = try await third.vault.credential(); XCTAssertEqual(actual, value)
  }
  func testPartialMaterialNeverRegeneratesMissingFileEvenWithoutDatabase() throws {
    for missing in names {
      let f = try fixture(); defer { f.close() }; _ = try f.material(); try FileManager.default.removeItem(at: f.file(missing))
      let original = try bytes(f); XCTAssertThrowsError(try f.material()); XCTAssertEqual(try bytes(f), original)
    }
  }
  func testBusinessMainOrAnySidecarBlocksFirstMaterialPublication() throws {
    for name in ["matches.sqlite", "matches.sqlite-wal", "matches.sqlite-shm", "matches.sqlite-journal"] {
      let f = try fixture(); defer { f.close() }; try Data([0,255,7]).write(to: f.file(name)); let original = try bytes(f)
      XCTAssertThrowsError(try f.material()); XCTAssertEqual(try bytes(f), original)
    }
  }
  func testAlreadyHeldVaultCannotRecreateMissingOrBadOriginal() async throws {
    for broken in [false,true] {
      let f = try fixture(); defer { f.close() }; let m = try f.material()
      if broken { try Data([0,255,4]).write(to: f.file("development.vault")) } else { try FileManager.default.removeItem(at: f.file("development.vault")) }
      let original = try bytes(f)
      do { try await m.vault.replace(nil, expectedIdentityGeneration: 0); XCTFail("held vault must freshly reject missing/bad file") } catch {}
      do { _ = try await m.vault.credential(); XCTFail("held vault cannot use cached credential") } catch {}
      XCTAssertEqual(try bytes(f), original)
    }
  }
  func testInvalidVaultFieldsOrForeignCredentialPreservePublishedBytes() throws {
    for variant in 0..<5 {
      let f = try fixture(); defer { f.close() }; let m = try f.material(), c = try credential(f,m)
      var state: [String:Any] = ["generation": 0]
      if variant == 0 { state["generation"] = -1 }
      if variant == 1 { state["unknownFuture"] = 1 }
      if variant == 2 { state["credential"] = ["token": c.token,"sessionID":c.sessionID,"accountID":c.accountID,"deviceID":"foreign","keyID":c.keyID,"activationEpoch":1,"expiresAt":c.expiresAt] }
      if variant == 3 { state["credential"] = ["token": c.token,"sessionID":c.sessionID,"accountID":c.accountID,"deviceID":c.deviceID,"keyID":"foreign","activationEpoch":1,"expiresAt":c.expiresAt] }
      let raw = variant == 4 ? Data(repeating: 32,count:65537) : try JSONSerialization.data(withJSONObject:state)
      try raw.write(to: f.file("development.vault")); let original=try bytes(f)
      XCTAssertThrowsError(try f.material()); XCTAssertEqual(try bytes(f),original)
    }
  }
  func testWrongIdentityNamespacePinAndKeyNeverWriteMaterial() throws {
    for variant in 0..<4 {
      let f=try fixture();defer{f.close()};_=try f.material()
      if variant==0 {try Data(("football-record.identity.v1:"+UUID().uuidString).utf8).write(to:f.identity)}
      if variant==1 {try Data("wrong-pin".utf8).write(to:f.file("authority.fixture"))}
      if variant==2 {try Data(repeating:1,count:31).write(to:f.file("development.key"))}
      let original=try bytes(f)
      if variant==3 {var config=f.configuration;config.namespace="production";XCTAssertThrowsError(try DevelopmentAuthorityScenario.deviceMaterial(configuration:config,namespaceDirectory:f.directory,installationID:f.deviceID))}
      else {XCTAssertThrowsError(try f.material())}
      XCTAssertEqual(try bytes(f),original)
    }
  }
  func testSymlinkMaterialIsPreservedWithoutFollowingTarget() throws {
    let f=try fixture();defer{f.close()};let external=f.root.appendingPathComponent("outside"),raw=Data([0,255,8]);try raw.write(to:external)
    try FileManager.default.createSymbolicLink(at:f.file("development.key"),withDestinationURL:external)
    XCTAssertThrowsError(try f.material());XCTAssertEqual(try Data(contentsOf:external),raw)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:f.file("development.key").path),external.path)
  }
  func testHeldVaultRejectsDirectoryOrImmutableFileSubstitution() async throws {
    for variant in 0..<2 {
      let f=try fixture();defer{f.close()};let m=try f.material()
      if variant==0 {let raw=try Data(contentsOf:f.file("authority.fixture"));try raw.write(to:f.file("authority.fixture"),options:.atomic)}
      else {let held=f.root.appendingPathComponent("retained");try FileManager.default.moveItem(at:f.directory,to:held);try FileManager.default.createDirectory(at:f.directory,withIntermediateDirectories:false);for name in names+["device.identity"]{try FileManager.default.copyItem(at:held.appendingPathComponent(name),to:f.file(name))}}
      let original=try bytes(f)
      do {try await m.vault.advanceIdentityFence(to:1);XCTFail("old material cannot follow substituted original") } catch {}
      XCTAssertEqual(try bytes(f),original)
    }
  }
  func testCaseAliasHandlesSharePersistedGenerationWhenVolumeAliasesIt() async throws {
    let f = try fixture(); defer { f.close() }; let first = try f.material()
    let alias = f.root.deletingLastPathComponent().appendingPathComponent(f.root.lastPathComponent.lowercased()).appendingPathComponent(f.configuration.namespace)
    var original = stat(), other = stat()
    guard lstat(f.directory.path, &original) == 0, lstat(alias.path, &other) == 0, original.st_dev == other.st_dev, original.st_ino == other.st_ino else { throw XCTSkip("volume does not expose this case alias") }
    let second = try DevelopmentAuthorityScenario.deviceMaterial(configuration: f.configuration, namespaceDirectory: alias, installationID: f.deviceID)
    XCTAssertEqual(first.signer.publicKey, second.signer.publicKey)
    await withTaskGroup(of: Void.self) { group in
      for vault in [first.vault, second.vault] {
        group.addTask { for generation in 1...50 { do { try await vault.advanceIdentityFence(to: Int64(generation)) } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged, "interleaved lower generation is rejected; it must not overwrite newer state") } } }
      }
    }
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file("development.vault"))) as? [String:Any])
    XCTAssertEqual(value["generation"] as? Int, 50)
  }

}
#endif
