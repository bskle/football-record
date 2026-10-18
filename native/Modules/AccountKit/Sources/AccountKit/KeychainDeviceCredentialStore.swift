import CryptoKit
import Darwin
import Foundation
import MatchStore
#if canImport(Security)
import Security
#endif

public enum DeviceKeychainError: Error, Sendable, Equatable {
    case disabled, duplicate, storageUnavailable, invalidControl, identityChanged, ownerConflict
}
public struct KeychainDeviceConfiguration: Sendable {
    public let service, account, installationID: String
    public let controlDirectory, businessDatabaseURL: URL
    public let accessGroup: String?
    public init(service: String, account: String, installationID: String, controlDirectory: URL, businessDatabaseURL: URL, accessGroup: String? = nil) throws {
        for value in [service, account, installationID] + (accessGroup.map { [$0] } ?? []) {
            guard !value.isEmpty, value.utf8.count <= 512, !value.utf8.contains(0) else { throw DeviceKeychainError.invalidControl }
        }
        guard controlDirectory.isFileURL, businessDatabaseURL.isFileURL else { throw DeviceKeychainError.invalidControl }
        self.service=service; self.account=account; self.installationID=installationID
        self.controlDirectory=controlDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.businessDatabaseURL=businessDatabaseURL.standardizedFileURL.resolvingSymlinksInPath()
        self.accessGroup=accessGroup
    }
}
// Synchronous by design. No await can split the generation check from the item write.
protocol KeychainItemDriver: Sendable {
    var identity: String { get }
    func read() throws -> Data?
    func add(_ bytes: Data) throws
    func update(_ bytes: Data) throws
}
private final class KeychainOwner: @unchecked Sendable {
    let lock = NSLock()
    let directory: URL
    private let fd: Int32
    init(directory: URL, identity: String) throws {
        self.directory=directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name=SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        fd=Darwin.open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DeviceKeychainError.ownerConflict }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw DeviceKeychainError.ownerConflict }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
private final class KeychainOwners: @unchecked Sendable {
    static let shared=KeychainOwners()
    private let lock=NSLock()
    private final class Weak { weak var value: KeychainOwner?; init(_ value: KeychainOwner) { self.value=value } }
    private var owners: [String: Weak]=[:]
    func owner(identity: String, directory: URL) throws -> KeychainOwner {
        try lock.withLock {
            if let owner=owners[identity]?.value {
                guard owner.directory == directory else { throw DeviceKeychainError.ownerConflict }
                return owner
            }
            let owner=try KeychainOwner(directory: directory, identity: identity)
            owners[identity]=Weak(owner); return owner
        }
    }
}
// This private secure-item encoding is never a business/control DTO.
private struct KeychainCredential: Codable {
    let token, sessionID, accountID, deviceID, keyID: String
    let activationEpoch, expiresAt: Int64
    init(_ c: DeviceCredential) {
        token=c.token; sessionID=c.sessionID; accountID=c.accountID; deviceID=c.deviceID; keyID=c.keyID
        activationEpoch=c.activationEpoch; expiresAt=c.expiresAt
    }
    var value: DeviceCredential { DeviceCredential(token:token,sessionID:sessionID,accountID:accountID,deviceID:deviceID,keyID:keyID,activationEpoch:activationEpoch,expiresAt:expiresAt) }
}
private struct KeychainControl: Codable {
    var version=1
    var installationID: String
    var privateKey: Data
    var generation: Int64=0
    var credential: KeychainCredential?
    func encoded() throws -> Data {
        let e=JSONEncoder(); e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]; return try e.encode(self)
    }
}
/// One local identity item and one owner gate for both the signer and fenced vault.
/// Same-item processes must share this control directory (an App Group when applicable).
public final class KeychainDeviceCredentialStore: DeviceCredentialVault, DeviceProofSigner, @unchecked Sendable {
    public let publicKey: String
    private let configuration: KeychainDeviceConfiguration
    private let driver: any KeychainItemDriver
    private let owner: KeychainOwner
    public convenience init(configuration: KeychainDeviceConfiguration, executionEnabled: Bool = false) throws {
        guard executionEnabled else { throw DeviceKeychainError.disabled }
        #if canImport(Security)
        try self.init(configuration: configuration, driver: SecurityKeychainDriver(configuration))
        #else
        throw DeviceKeychainError.disabled
        #endif
    }
    init(configuration: KeychainDeviceConfiguration, driver: any KeychainItemDriver) throws {
        self.configuration=configuration; self.driver=driver
        owner=try KeychainOwners.shared.owner(identity: driver.identity, directory: configuration.controlDirectory)
        publicKey=try owner.lock.withLock {
            let control: KeychainControl
            if let bytes=try driver.read() { control=try Self.decode(bytes, configuration: configuration) }
            else {
                guard !FileManager.default.fileExists(atPath: configuration.businessDatabaseURL.path) else { throw DeviceKeychainError.identityChanged }
                let created=KeychainControl(installationID: configuration.installationID, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
                do { try driver.add(created.encoded()); control=created }
                catch DeviceKeychainError.duplicate {
                    guard let bytes=try driver.read() else { throw DeviceKeychainError.invalidControl }
                    control=try Self.decode(bytes, configuration: configuration)
                }
            }
            return AuthorityWire.base64URL(try Curve25519.Signing.PrivateKey(rawRepresentation: control.privateKey).publicKey.rawRepresentation)
        }
    }
    private static func decode(_ bytes: Data, configuration: KeychainDeviceConfiguration) throws -> KeychainControl {
        guard bytes.count <= 65536 else { throw DeviceKeychainError.invalidControl }
        do {
            let c=try JSONDecoder().decode(KeychainControl.self,from:bytes)
            guard c.version==1, c.generation>=0, c.generation<=9_007_199_254_740_991,
                  c.installationID.utf8.elementsEqual(configuration.installationID.utf8), c.privateKey.count==32,
                  try c.encoded()==bytes else { throw DeviceKeychainError.invalidControl }
            let key=try Curve25519.Signing.PrivateKey(rawRepresentation:c.privateKey)
            if let credential=c.credential { try validate(credential.value, key:key, installationID:c.installationID) }
            return c
        } catch let e as DeviceKeychainError { throw e } catch { throw DeviceKeychainError.invalidControl }
    }
    private static func validate(_ c: DeviceCredential, key: Curve25519.Signing.PrivateKey, installationID: String) throws {
        let publicKey=AuthorityWire.base64URL(key.publicKey.rawRepresentation)
        guard c.deviceID.utf8.elementsEqual(installationID.utf8), c.keyID == (try AuthorityWire.deviceKeyID(publicKey:publicKey)),
              c.activationEpoch>0, c.expiresAt>0, c.activationEpoch<=9_007_199_254_740_991, c.expiresAt<=9_007_199_254_740_991 else { throw DeviceKeychainError.identityChanged }
        _=try AuthorityWire.decodeBase64URL(c.token,count:32)
        for id in [c.sessionID,c.accountID,c.deviceID,c.keyID] { try AuthorityWire.identifier(id) }
    }
    private func read() throws -> KeychainControl {
        guard let bytes=try driver.read() else { throw DeviceKeychainError.identityChanged }
        let c=try Self.decode(bytes,configuration:configuration)
        guard AuthorityWire.base64URL(try Curve25519.Signing.PrivateKey(rawRepresentation:c.privateKey).publicKey.rawRepresentation)==publicKey else { throw DeviceKeychainError.identityChanged }
        return c
    }
    public func credential() async throws -> DeviceCredential {
        try owner.lock.withLock { guard let c=try read().credential else { throw AuthorityError.unavailable }; return c.value }
    }
    public func advanceIdentityFence(to generation: Int64) async throws {
        try owner.lock.withLock {
            var c=try read()
            guard generation>=c.generation, generation<=9_007_199_254_740_991 else { throw AuthorityError.identityChanged }
            if generation>c.generation { c.generation=generation; c.credential=nil; try driver.update(c.encoded()) }
        }
    }
    public func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) async throws {
        try owner.lock.withLock {
            var c=try read(); guard c.generation==expectedIdentityGeneration else { throw AuthorityError.identityChanged }
            if let credential { try Self.validate(credential,key:Curve25519.Signing.PrivateKey(rawRepresentation:c.privateKey),installationID:c.installationID) }
            c.credential=credential.map(KeychainCredential.init); try driver.update(c.encoded())
        }
    }
    public func sign(_ bytes: Data) async throws -> Data {
        try owner.lock.withLock { try Curve25519.Signing.PrivateKey(rawRepresentation: read().privateKey).signature(for:bytes) }
    }
}
#if canImport(Security)
private struct SecurityKeychainDriver: KeychainItemDriver {
    let configuration: KeychainDeviceConfiguration
    init(_ configuration: KeychainDeviceConfiguration) { self.configuration=configuration }
    var identity: String { "keychain\0" + configuration.service + "\0" + configuration.account + "\0" + (configuration.accessGroup ?? "") }
    var query: [String: Any] {
        var q: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:configuration.service,kSecAttrAccount as String:configuration.account,kSecAttrSynchronizable as String:false]
        if let group=configuration.accessGroup { q[kSecAttrAccessGroup as String]=group }; return q
    }
    func read() throws -> Data? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess, let bytes=result as? Data else { throw DeviceKeychainError.storageUnavailable }; return bytes
    }
    func add(_ bytes: Data) throws {
        var q=query; q[kSecValueData as String]=bytes; q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status=SecItemAdd(q as CFDictionary,nil)
        if status==errSecDuplicateItem { throw DeviceKeychainError.duplicate }
        guard status==errSecSuccess else { throw DeviceKeychainError.storageUnavailable }
    }
    func update(_ bytes: Data) throws {
        guard SecItemUpdate(query as CFDictionary,[kSecValueData as String:bytes] as CFDictionary)==errSecSuccess else { throw DeviceKeychainError.storageUnavailable }
    }
}
#endif
