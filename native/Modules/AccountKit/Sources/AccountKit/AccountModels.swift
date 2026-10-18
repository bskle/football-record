import CryptoKit
import Foundation
import MatchStore

/// Credentials remain in the injected vault; no business SQLite DTO serializes this type.
public struct DeviceCredential: Decodable, Sendable, Equatable {
    public let token,sessionID,accountID,deviceID,keyID:String
    public let activationEpoch,expiresAt:Int64
    public init(token:String,sessionID:String,accountID:String,deviceID:String,keyID:String,activationEpoch:Int64,expiresAt:Int64) {
        self.token=token;self.sessionID=sessionID;self.accountID=accountID;self.deviceID=deviceID;self.keyID=keyID;self.activationEpoch=activationEpoch;self.expiresAt=expiresAt
    }
}
public protocol DeviceCredentialVault: Sendable {
    func credential() async throws -> DeviceCredential
    func replace(_ credential:DeviceCredential?) async throws
}
public actor MemoryDeviceCredentialVault: DeviceCredentialVault {
    private var current:DeviceCredential?
    public init(_ credential:DeviceCredential?=nil) { current=credential }
    public func credential() throws -> DeviceCredential { guard let current else { throw AuthorityError.unavailable };return current }
    public func replace(_ credential:DeviceCredential?) { current=credential }
}
public protocol DeviceProofSigner: Sendable {
    var publicKey:String { get }
    func sign(_ bytes:Data) async throws -> Data
}
/// Controlled development only; production Keychain implementation belongs to 024.
public struct DevelopmentDeviceSigner: DeviceProofSigner {
    private let privateKey:Curve25519.Signing.PrivateKey
    public var publicKey:String { AuthorityWire.base64URL(privateKey.publicKey.rawRepresentation) }
    public init(namespace:String,rawRepresentation:Data?=nil) throws {
        guard !namespace.isEmpty,namespace != "production",namespace.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==45||$0==95}) else { throw AuthorityError.identityChanged }
        privateKey = try rawRepresentation.map { try Curve25519.Signing.PrivateKey(rawRepresentation:$0) } ?? Curve25519.Signing.PrivateKey()
    }
    public func sign(_ bytes:Data) async throws -> Data { try privateKey.signature(for:bytes) }
}
public struct AuthorityHTTPRequest: Sendable {
    public let method,path:String
    public let body:Data
    public let authorization,deviceProof:String?
    init(method:String,path:String,body:Data,authorization:String?=nil,deviceProof:String?=nil) { self.method=method;self.path=path;self.body=body;self.authorization=authorization;self.deviceProof=deviceProof }
}
public struct AuthorityHTTPResponse: Sendable {
    public let status:Int
    public let body:Data
    public init(status:Int,body:Data) { self.status=status;self.body=body }
}
/// Phone proxies forward the original request unchanged, including recorder credential and PoP.
/// No Codable conformance: tokens and signatures are transient, never a durable control intent.
public protocol AuthorityHTTPRelay: Sendable { func send(_ request:AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse }
public struct AuthorityHTTPFailure: Error, Decodable, Sendable {
    public let code,requestID:String
    public let retryable:Bool
    public let retryAfterSeconds:Int?
}
