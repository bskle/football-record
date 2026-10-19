import XCTest
import CryptoKit
import Foundation
import MatchStore
@testable import AccountKit

final class FileKeychainFixture: KeychainItemDriver, @unchecked Sendable {
    let url: URL
    var identity: String { url.path }
    var fault: Fault?
    var beforeUpdate: (@Sendable () -> Void)?
    enum Fault { case beforeWrite, afterWrite, duplicate }
    init(_ url: URL) { self.url = url }
    func read() throws -> Data? { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
    func add(_ bytes: Data) throws {
        if fault == .duplicate { fault = nil; try bytes.write(to: url, options: .atomic); throw DeviceKeychainError.duplicate }
        guard try read() == nil else { throw DeviceKeychainError.duplicate }
        try update(bytes)
    }
    func update(_ bytes: Data) throws {
        beforeUpdate?()
        if fault == .beforeWrite { fault = nil; throw DeviceKeychainError.storageUnavailable }
        try bytes.write(to: url, options: .atomic)
        if fault == .afterWrite { fault = nil; throw DeviceKeychainError.storageUnavailable }
    }
}
final class KeychainDeviceCredentialStoreTests: XCTestCase, @unchecked Sendable {
    func fixture() throws -> (KeychainDeviceConfiguration, FileKeychainFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try KeychainDeviceConfiguration(service: "fixture", account: "watch", installationID: "installation", controlDirectory: root.appendingPathComponent("control"), businessDatabaseURL: root.appendingPathComponent("business.sqlite")), FileKeychainFixture(root.appendingPathComponent("keychain-item")))
    }
    func credential(_ store: KeychainDeviceCredentialStore, session: String = "session") throws -> DeviceCredential {
        DeviceCredential(token: AuthorityWire.base64URL(Data(repeating: 3, count: 32)), sessionID: session, accountID: "account", deviceID: "installation", keyID: try AuthorityWire.deviceKeyID(publicKey: store.publicKey), activationEpoch: 1, expiresAt: 9000)
    }
    func testNewIdentityReopensOriginalEd25519Key() async throws {
        let (c,d) = try fixture(), first = try KeychainDeviceCredentialStore(configuration: c, driver: d)
        let publicKey = first.publicKey, message = Data("watch challenge".utf8)
        let signature = try await first.sign(message)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(publicKey, count: 32))
        XCTAssertTrue(key.isValidSignature(signature, for: message))
        let second = try KeychainDeviceCredentialStore(configuration: c, driver: FileKeychainFixture(d.url))
        XCTAssertEqual(publicKey, second.publicKey)
    }
    func testMissingControlWithExistingEmptyDatabaseNeverCreatesKey() throws {
        let (c,d) = try fixture(); try Data().write(to: c.businessDatabaseURL)
        XCTAssertThrowsError(try KeychainDeviceCredentialStore(configuration: c, driver: d))
        XCTAssertNil(try d.read())
    }
    func testFenceAndCredentialPersistTogetherAcrossHandlesAndReopen() async throws {
        let (c,d) = try fixture(), a = try KeychainDeviceCredentialStore(configuration: c, driver: d)
        let b = try KeychainDeviceCredentialStore(configuration: c, driver: FileKeychainFixture(d.url))
        let original = try credential(a)
        try await a.replace(original, expectedIdentityGeneration: 0)
        try await b.advanceIdentityFence(to: 1)
        do { try await a.replace(original, expectedIdentityGeneration: 0); XCTFail("late write revived credential") } catch {}
        do { _ = try await a.credential(); XCTFail("old credential survived fence") } catch {}
        let fresh = try credential(a, session: "fresh")
        try await b.replace(fresh, expectedIdentityGeneration: 1)
        try await a.advanceIdentityFence(to: 1)
        let current = try await b.credential(); XCTAssertEqual(current, fresh)
        let reopened = try KeychainDeviceCredentialStore(configuration: c, driver: FileKeychainFixture(d.url))
        do { try await reopened.advanceIdentityFence(to: 0); XCTFail() } catch {}
        let after = try await reopened.credential(); XCTAssertEqual(after, fresh)
    }
    func testFailedWriteAndLostResponsePreserveDurableFence() async throws {
        let (c,d) = try fixture(), a = try KeychainDeviceCredentialStore(configuration: c, driver: d)
        let old = try credential(a); try await a.replace(old, expectedIdentityGeneration: 0)
        d.fault = .beforeWrite
        do { try await a.advanceIdentityFence(to: 1); XCTFail() } catch {}
        let still = try await a.credential(); XCTAssertEqual(still, old)
        d.fault = .afterWrite
        do { try await a.advanceIdentityFence(to: 1); XCTFail() } catch {}
        let reopened = try KeychainDeviceCredentialStore(configuration: c, driver: FileKeychainFixture(d.url))
        do { try await reopened.replace(old, expectedIdentityGeneration: 0); XCTFail() } catch {}
        do { _ = try await reopened.credential(); XCTFail() } catch {}
    }
    func testCorruptAndFutureControlNeverResetsOriginalBytes() throws {
        for raw in [Data("broken".utf8), Data("{\"version\":99}".utf8)] {
            let (c,d) = try fixture(); try raw.write(to: d.url)
            XCTAssertThrowsError(try KeychainDeviceCredentialStore(configuration: c, driver: d))
            XCTAssertEqual(try d.read(), raw)
        }
    }
    func testChangedInstallationCannotReuseOrOverwriteKey() throws {
        let (c,d) = try fixture(); _ = try KeychainDeviceCredentialStore(configuration: c, driver: d)
        let original = try XCTUnwrap(d.read())
        let other = try KeychainDeviceConfiguration(service: c.service, account: c.account, installationID: "other", controlDirectory: c.controlDirectory, businessDatabaseURL: c.businessDatabaseURL)
        XCTAssertThrowsError(try KeychainDeviceCredentialStore(configuration: other, driver: d))
        XCTAssertEqual(try d.read(), original)
    }
    func testDefaultSDKIsDisabledBeforeAnyItemAccess() throws {
        let (c,d) = try fixture()
        XCTAssertThrowsError(try KeychainDeviceCredentialStore(configuration: c))
        XCTAssertNil(try d.read()); XCTAssertFalse(FileManager.default.fileExists(atPath: c.controlDirectory.path))
    }
    func testDuplicateAddRereadsExistingItemWithoutRekeying() throws {
        let (c,d) = try fixture(); d.fault = .duplicate
        let a = try KeychainDeviceCredentialStore(configuration:c,driver:d)
        let original = try XCTUnwrap(d.read())
        let b = try KeychainDeviceCredentialStore(configuration:c,driver:FileKeychainFixture(d.url))
        XCTAssertEqual(a.publicKey,b.publicKey); XCTAssertEqual(try d.read(),original)
    }
    func testActualDelayedWriteAndConcurrentFenceUseOneGateAcrossInstances() async throws {
        let (c,d) = try fixture(), a = try KeychainDeviceCredentialStore(configuration:c,driver:d)
        let b = try KeychainDeviceCredentialStore(configuration:c,driver:FileKeychainFixture(d.url))
        let entered = expectation(description:"actual item update entered"), release = DispatchSemaphore(value:0)
        d.beforeUpdate = { entered.fulfill(); _ = release.wait(timeout:.now()+5) }
        let old = try credential(a)
        let write = Task.detached { try await a.replace(old,expectedIdentityGeneration:0) }
        await fulfillment(of:[entered],timeout:3)
        let fence = Task.detached { try await b.advanceIdentityFence(to:1) }
        release.signal(); try await write.value; try await fence.value
        d.beforeUpdate=nil
        do { _=try await b.credential(); XCTFail("credential crossed the completed fence") } catch {}
        do { try await a.replace(old,expectedIdentityGeneration:0); XCTFail() } catch {}
        let object=try JSONSerialization.jsonObject(with:XCTUnwrap(d.read())) as! [String:Any]
        XCTAssertEqual(object["generation"] as? Int,1); XCTAssertNil(object["credential"])
    }
    func testSameItemCannotOpenWithAnotherOwnerDirectory() throws {
        let (c,d)=try fixture(), a=try KeychainDeviceCredentialStore(configuration:c,driver:d)
        let other=try KeychainDeviceConfiguration(service:c.service,account:c.account,installationID:c.installationID,controlDirectory:c.controlDirectory.appendingPathComponent("other"),businessDatabaseURL:c.businessDatabaseURL)
        XCTAssertThrowsError(try KeychainDeviceCredentialStore(configuration:other,driver:FileKeychainFixture(d.url)))
        XCTAssertFalse(a.publicKey.isEmpty)
    }

}
