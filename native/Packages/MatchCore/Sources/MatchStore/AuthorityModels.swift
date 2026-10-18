import CryptoKit
import Foundation
import MatchCore

public enum AuthorityError: Error, Sendable, Equatable {
    case invalidWire, invalidSignature, intentMismatch, identityChanged, staleAttestation, terminalLock, unavailable, conflict
}
/// M4 control wire has a separate encoder; legacy Canonical remains byte-for-byte unchanged.
public enum AuthorityWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    public static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    public static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func decodeBase64URL(_ value: String, count: Int? = nil) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4-value.count%4)%4)),
              base64URL(data) == value, count.map({ data.count == $0 }) ?? true else { throw AuthorityError.invalidWire }; return data
    }
    public static func identifier(_ value: String, empty: Bool = false) throws {
        if empty && value.isEmpty { return }
        guard (1...128).contains(value.utf8.count), value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,58,95].contains($0) }) else { throw AuthorityError.invalidWire }
    }
    public static func decode<T: Codable>(_ type: T.Type, _ bytes: Data, limit: Int = 16384) throws -> T {
        guard bytes.count <= limit else { throw AuthorityError.invalidWire }
        do { let value = try JSONDecoder().decode(type, from: bytes); guard try encode(value) == bytes else { throw AuthorityError.invalidWire }; return value }
        catch { throw AuthorityError.invalidWire }
    }
    public static func signedInput(_ domain: String, body: Data) -> Data { Data((domain + "\n").utf8) + body }
    public static func deviceKeyID(publicKey: String) throws -> String { _ = try decodeBase64URL(publicKey, count: 32); return hash(Data(publicKey.utf8)) }
}
public enum AuthorityEnvironment: String, Codable, Sendable { case development, production }
public struct AuthorityTrustConfiguration: Sendable, Equatable {
    public let environment: AuthorityEnvironment
    public let publicKeys: [String: String]
    public init(environment: AuthorityEnvironment, publicKeys: [String: String]) throws {
        guard !publicKeys.isEmpty else { throw AuthorityError.invalidWire }
        for (id, key) in publicKeys { try AuthorityWire.identifier(id); _ = try AuthorityWire.decodeBase64URL(key, count: 32) }
        self.environment = environment; self.publicKeys = publicKeys
    }
}
public enum AuthorityOperation: String, Codable, Sendable {
    case acquire, terminate, authApple, registerWatch, prepareMigration, checkpointMigration, activateMigration
    case requestLostMigration, lostRecovery, terminateLost, forceMigration, deleteAccount, peerGrant
}
public struct AuthorityFields: Codable, Sendable, Equatable {
    public var matchID, recordingDeviceID, lockID, mode, cloudConfirmationID, contentCommitment: String?
    public var activationEpoch: Int64?
    public var newPhoneID, migrationID, checkpointID, cloudSpaceID, reauthenticationID, grantID: String?
    public var originalRecordingDeviceID: String?
    public var originalActivationEpoch, confirmedAt: Int64?
    public var localDeviceID, remoteDeviceID, pairingID, recoveryCapabilityDigest: String?
    public init() {}
}
public struct ControlIntentV1: Codable, Sendable, Equatable {
    public let requestID: String
    public let operation: AuthorityOperation
    public let fields: AuthorityFields
    public let canonicalRequest: Data
    public var digest: String { AuthorityWire.hash(canonicalRequest) }
    public var matchID: String { fields.matchID ?? "" }
    public init(requestID: String, operation: AuthorityOperation, fields: AuthorityFields) throws {
        try AuthorityWire.identifier(requestID)
        let bytes = try AuthorityWire.encode(fields)
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let allowed: Set<String>
        switch operation {
        case .acquire: allowed = ["matchID","recordingDeviceID","activationEpoch"]
        case .terminate: allowed = Set(["matchID","lockID","recordingDeviceID","activationEpoch","mode"] + (fields.mode == "normal" ? ["cloudConfirmationID","contentCommitment"] : []))
        case .prepareMigration: allowed = ["newPhoneID","activationEpoch"]
        case .checkpointMigration: allowed = ["migrationID","checkpointID","contentCommitment","activationEpoch"]
        case .activateMigration: allowed = ["migrationID","checkpointID","contentCommitment","cloudSpaceID"]
        case .requestLostMigration: allowed = ["newPhoneID","cloudSpaceID"]
        case .lostRecovery: allowed = ["migrationID","reauthenticationID","matchID","lockID","originalRecordingDeviceID","originalActivationEpoch","confirmedAt"]
        case .terminateLost: allowed = ["migrationID","grantID","matchID","lockID","originalRecordingDeviceID","originalActivationEpoch"]
        case .forceMigration: allowed = ["migrationID","reauthenticationID"]
        case .deleteAccount: allowed = ["reauthenticationID","recoveryCapabilityDigest"]
        case .peerGrant: allowed = ["localDeviceID","remoteDeviceID","activationEpoch","pairingID"]
        case .authApple, .registerWatch: throw AuthorityError.invalidWire // transient auth has its own boundary
        }
        guard Set(object.keys) == allowed else { throw AuthorityError.invalidWire }
        for (key, value) in object {
            if ["activationEpoch","originalActivationEpoch","confirmedAt"].contains(key) {
                guard let n = value as? NSNumber, n.int64Value >= (key == "confirmedAt" ? 0 : 1), n.int64Value <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
            } else if let string = value as? String {
                if key == "mode" { guard string == "normal" || string == "abnormal" else { throw AuthorityError.invalidWire } }
                else if key == "contentCommitment" || key == "recoveryCapabilityDigest" { guard string.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AuthorityError.invalidWire } }
                else { try AuthorityWire.identifier(string) }
            } else { throw AuthorityError.invalidWire }
        }
        object["version"] = 1; object["requestID"] = requestID
        canonicalRequest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        self.requestID = requestID; self.operation = operation; self.fields = fields
    }
    public static func acquire(_ intent: StartIntent, epoch: Int64) throws -> Self {
        var f = AuthorityFields(); f.matchID = intent.matchID; f.recordingDeviceID = intent.recordingDeviceID; f.activationEpoch = epoch
        return try Self(requestID: intent.id, operation: .acquire, fields: f)
    }
    private enum CodingKeys: String, CodingKey { case requestID, operation, fields, canonicalRequest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: c.decode(String.self, forKey: .requestID), operation: c.decode(AuthorityOperation.self, forKey: .operation), fields: c.decode(AuthorityFields.self, forKey: .fields))
        guard canonicalRequest == (try c.decode(Data.self, forKey: .canonicalRequest)) else { throw AuthorityError.invalidWire }
    }
}
public struct AuthorityMigrationV1: Codable, Sendable, Equatable {
    public let migrationID, kind, state, oldPhoneID, newPhoneID, cloudSpaceID, checkpointID, contentCommitment: String
    public let oldActivationEpoch, requestedAt, eligibleAt: Int64
}
public struct AuthorityPeerGrantV1: Codable, Sendable, Equatable {
    public let grantID, pairingID, localDeviceID, remoteDeviceID, localPublicKey, remotePublicKey, localRole, remoteRole, activePhoneID: String
    public let expiresAt: Int64
}
public struct AuthorityWatchRegistrationV1: Codable, Sendable, Equatable { public let watchID, watchPublicKey: String }
public struct AuthorityLostGrantV1: Codable, Sendable, Equatable { public let grantID, migrationID, newPhoneID: String; public let expiresAt: Int64 }
public struct AuthorityDeletionV1: Codable, Sendable, Equatable { public let backend, apple, cloud, local, health: String }
public enum AuthorityResult: String, Codable, Sendable {
    case held, originalMatch, releasedNormal, releasedAbnormal, registered, knownAbandoned, waitingMigration, checkpointAccepted, activated, waitingPeriod, deleted, grantIssued
}
public struct AuthorityReceiptBodyV1: Codable, Sendable, Equatable {
    public let version: Int
    public let environment: AuthorityEnvironment
    public let keyID, receiptID, requestID, requestDigest: String
    public let operation: AuthorityOperation
    public let accountID: String
    public let activationEpoch: Int64
    public let matchID, lockID, recordingDeviceID: String
    public let result: AuthorityResult
    public let issuedAt: Int64
    public let migration: AuthorityMigrationV1?
    public let peerGrant: AuthorityPeerGrantV1?
    public let registration: AuthorityWatchRegistrationV1?
    public let lostRecovery: AuthorityLostGrantV1?
    public let deletion: AuthorityDeletionV1?
}
public struct AuthorityExpectedIntent: Sendable {
    public let requestID, digest, accountID: String
    public let operation: AuthorityOperation
    public let epoch: Int64
    public init(requestID: String, digest: String, operation: AuthorityOperation, accountID: String, epoch: Int64) {
        self.requestID=requestID; self.digest=digest; self.operation=operation; self.accountID=accountID; self.epoch=epoch
    }
    public init(_ intent: ControlIntentV1, accountID: String, epoch: Int64) {
        self.init(requestID: intent.requestID, digest: intent.digest, operation: intent.operation, accountID: accountID, epoch: epoch)
    }
}
/// Not Codable and no public initializer. Store re-verifies raw bytes with its own fixed keyset.
public struct VerifiedAuthorityReceiptV1: Sendable, Equatable {
    public let raw: Data
    public let body: AuthorityReceiptBodyV1
    private init(raw: Data, body: AuthorityReceiptBodyV1) { self.raw=raw; self.body=body }
    private struct Envelope: Codable { let body: AuthorityReceiptBodyV1; let signature: String }
    public static func verify(_ raw: Data, expected: AuthorityExpectedIntent, trust: AuthorityTrustConfiguration) throws -> Self {
        let envelope = try AuthorityWire.decode(Envelope.self, raw)
        let b = envelope.body
        guard b.version == 1, b.environment == trust.environment, let publicKey = trust.publicKeys[b.keyID],
              b.activationEpoch > 0, b.activationEpoch <= 9_007_199_254_740_991, b.issuedAt >= 0, b.issuedAt <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        for id in [b.keyID,b.receiptID,b.requestID,b.accountID] { try AuthorityWire.identifier(id) }
        for id in [b.matchID,b.lockID,b.recordingDeviceID] { try AuthorityWire.identifier(id,empty:true) }
        guard b.requestDigest.count == 64, b.requestDigest == expected.digest, b.requestID == expected.requestID,
              b.operation == expected.operation, b.accountID == expected.accountID, b.activationEpoch == expected.epoch else { throw AuthorityError.intentMismatch }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(publicKey,count:32))
        guard key.isValidSignature(try AuthorityWire.decodeBase64URL(envelope.signature,count:64),for:AuthorityWire.signedInput("football-record.authority.receipt.v1",body:try AuthorityWire.encode(b))) else { throw AuthorityError.invalidSignature }
        return Self(raw:raw,body:b)
    }
}

public struct LiveLockQueryV1: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID, acquireRequestID, matchID, lockID, recordingDeviceID: String
    public let activationEpoch: Int64
    public let nonce: String
    public init(requestID: String, acquireRequestID: String, matchID: String, lockID: String, recordingDeviceID: String, activationEpoch: Int64, nonce: String) throws {
        for id in [requestID,acquireRequestID,matchID,lockID,recordingDeviceID,nonce] { try AuthorityWire.identifier(id) }
        guard activationEpoch > 0, activationEpoch <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        self.version=1; self.requestID=requestID; self.acquireRequestID=acquireRequestID; self.matchID=matchID; self.lockID=lockID; self.recordingDeviceID=recordingDeviceID; self.activationEpoch=activationEpoch; self.nonce=nonce
    }
}
public enum LiveLockStatusV1: String, Codable, Sendable { case held, terminal, mismatch }
public struct LiveLockBodyV1: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID, acquireRequestID, matchID, lockID, recordingDeviceID: String
    public let activationEpoch: Int64
    public let nonce, accountID, receiptID: String
    public let environment: AuthorityEnvironment
    public let keyID, requestDigest: String
    public let status: LiveLockStatusV1
    public let observedAt, expiresAt: Int64
}
public struct VerifiedLiveLockV1: Sendable, Equatable {
    public let raw: Data
    public let query: LiveLockQueryV1
    public let body: LiveLockBodyV1
    private struct Envelope: Codable { let body: LiveLockBodyV1; let signature: String }
    private init(raw: Data, query: LiveLockQueryV1, body: LiveLockBodyV1) { self.raw=raw;self.query=query;self.body=body }
    public static func verify(_ raw: Data, query: LiveLockQueryV1, accountID: String, trust: AuthorityTrustConfiguration, now: Date) throws -> Self {
        let e = try AuthorityWire.decode(Envelope.self,raw), b=e.body, time=now.timeIntervalSince1970
        guard time.isFinite, time >= 0, time <= 9_007_199_254_740_991,
              b.observedAt >= 0, b.observedAt <= 9_007_199_254_740_991, b.expiresAt >= 0, b.expiresAt <= 9_007_199_254_740_991,
              b.activationEpoch > 0, b.activationEpoch <= 9_007_199_254_740_991, b.version == 1, b.environment == trust.environment, let key=trust.publicKeys[b.keyID],
              b.accountID == accountID, b.requestID == query.requestID, b.acquireRequestID == query.acquireRequestID,
              b.matchID == query.matchID, b.lockID == query.lockID, b.recordingDeviceID == query.recordingDeviceID,
              b.activationEpoch == query.activationEpoch, b.nonce == query.nonce,
              b.requestDigest == AuthorityWire.hash(try AuthorityWire.encode(query)) else { throw AuthorityError.intentMismatch }
        guard Double(b.observedAt) <= time+60, Double(b.observedAt) >= time-60, b.expiresAt > b.observedAt,
              b.expiresAt-b.observedAt <= 60, Double(b.expiresAt) > time else { throw AuthorityError.staleAttestation }
        let pub=try Curve25519.Signing.PublicKey(rawRepresentation:AuthorityWire.decodeBase64URL(key,count:32))
        guard pub.isValidSignature(try AuthorityWire.decodeBase64URL(e.signature,count:64),for:AuthorityWire.signedInput("football-record.authority.live-lock.v1",body:try AuthorityWire.encode(b))) else { throw AuthorityError.invalidSignature }
        return Self(raw:raw,query:query,body:b)
    }
}
public struct AccountBindingV4: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case phone, watch, waiting }
    public let accountID, cloudSpaceID, deviceID: String
    public let activationEpoch: Int64
    public let role: Role
    public let environment: AuthorityEnvironment
    public let suspended: Bool
    public init(accountID:String,cloudSpaceID:String,deviceID:String,activationEpoch:Int64,role:Role,environment:AuthorityEnvironment,suspended:Bool=false) throws {
        for id in [accountID,cloudSpaceID,deviceID] { try AuthorityWire.identifier(id) }
        guard activationEpoch > 0, activationEpoch <= 9_007_199_254_740_991 else { throw AuthorityError.invalidWire }
        self.accountID=accountID;self.cloudSpaceID=cloudSpaceID;self.deviceID=deviceID;self.activationEpoch=activationEpoch;self.role=role;self.environment=environment;self.suspended=suspended
    }
}
public enum AuthorityStatusV4: String, Codable, Sendable { case unknown, held, terminationPending, terminal, releasedNormal, releasedAbnormal }
public struct ControlIntentReceiptV4: Codable, Sendable, Equatable { public let requestID, digest: String }
public struct AuthorityReceiptV4: Codable, Sendable, Equatable { public let requestID, receiptID, rawDigest: String; public let status: AuthorityStatusV4 }
public struct AuthorityStateV4: Sendable {
    public let status: AuthorityStatusV4
    public let acquire: VerifiedAuthorityReceiptV1?
    public let verifiedNormalRelease: VerifiedAuthorityReceiptV1?
    public let latestLive: VerifiedLiveLockV1?
}
public protocol AuthorityRepository: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func bindAccountV4(_ binding: AccountBindingV4) async throws
    func accountBindingV4() async throws -> AccountBindingV4?
    func suspendAccountV4() async throws
    func prepareControlV4(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4
    func pendingControlsV4() async throws -> [ControlIntentV1]
    func recordAuthorityResultV4(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4
    func recordLiveLockV4(_ proof: VerifiedLiveLockV1, now: Date) async throws
    func authorityStateV4(matchID: String, now: Date) async throws -> AuthorityStateV4
    func validateAuthorityStartV4(_ intent: StartIntent, now: Date) async throws
}
