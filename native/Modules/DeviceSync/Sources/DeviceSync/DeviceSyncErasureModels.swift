import Foundation

public enum DeviceSyncErasureError: String, Error, Sendable {
    case unbound, unsupportedLayout, intentMismatch, unknownInventory, corruptControl
    case futureControl, ownerChanged, fileIO, faultInjected
}
public struct DeviceSyncRootIdentity: Codable, Sendable, Equatable {
    public let device, inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}
/// Catalog provenance is supplied by026. This value is not an account/peer authority proof.
public struct DeviceSyncNamespaceBinding: Codable, Sendable, Equatable {
    public let namespaceID, accountID, cloudSpaceID, zoneID: String
    public let activationEpoch, catalogRevision: UInt64
    public let catalogDigest: String
    public let rootIdentity: DeviceSyncRootIdentity
    public init(namespaceID: String, accountID: String, cloudSpaceID: String, zoneID: String, activationEpoch: UInt64, catalogRevision: UInt64, catalogDigest: String, rootIdentity: DeviceSyncRootIdentity) throws {
        self.namespaceID = namespaceID; self.accountID = accountID; self.cloudSpaceID = cloudSpaceID; self.zoneID = zoneID
        self.activationEpoch = activationEpoch; self.catalogRevision = catalogRevision; self.catalogDigest = catalogDigest; self.rootIdentity = rootIdentity
        try validate()
    }
    func validate() throws {
        guard UUID(uuidString: namespaceID) != nil, [accountID, cloudSpaceID, zoneID].allSatisfy(validOpaqueID), activationEpoch > 0, catalogRevision > 0, isDigest(catalogDigest), rootIdentity.inode > 0 else { throw DeviceSyncErasureError.intentMismatch }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { (try? canonical(lhs)) == (try? canonical(rhs)) }
    var ownerDigest: String { get throws { digest(try canonical(self)) } }
}
public struct DeviceSyncLocalEraseRequest: Codable, Sendable, Equatable {
    public let binding: DeviceSyncNamespaceBinding
    public let requestID, requestDigest: String
    public init(binding: DeviceSyncNamespaceBinding, requestID: String, requestDigest: String) throws {
        self.binding = binding; self.requestID = requestID; self.requestDigest = requestDigest; try validate()
    }
    func validate() throws { try binding.validate(); guard validOpaqueID(requestID), isDigest(requestDigest) else { throw DeviceSyncErasureError.intentMismatch } }
    public var intentDigest: String { get throws { digest(Data("football-record.device-sync-local-erase.v1\0".utf8) + (try canonical(self))) } }
    public static func == (lhs: Self, rhs: Self) -> Bool { (try? canonical(lhs)) == (try? canonical(rhs)) }
}
public struct DeviceSyncTransferIdentity: Codable, Sendable, Equatable {
    public let deliveryIDHash, checksum, token: String
    public init(deliveryIDHash: String, checksum: String, token: String) throws {
        guard isDigest(deliveryIDHash), isDigest(checksum), UUID(uuidString: token) != nil else { throw DeviceSyncErasureError.unknownInventory }
        self.deliveryIDHash = deliveryIDHash; self.checksum = checksum; self.token = token
    }
}
public struct DeviceSyncLocalEraseReceipt: Codable, Sendable, Equatable {
    public let request: DeviceSyncLocalEraseRequest
    public let intentDigest: String
    public let fenceGeneration: UInt64
}
public enum DeviceSyncDrainStatus: Sendable, Equatable { case drained, pending, unresolved }
public enum DeviceSyncEraseResult: Sendable, Equatable {
    case completed(DeviceSyncLocalEraseReceipt)
    case pending(DeviceSyncDrainStatus)
}
public protocol DeviceSyncLocalTransportErasing: Sendable {
    func erase(_ request: DeviceSyncLocalEraseRequest) async throws -> DeviceSyncEraseResult
}
/// Optional capability, independent of WCSessionDriving. Unsupported drivers cannot complete erase.
public protocol DeviceSyncErasureDriving: Sendable {
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus
}
public struct UnavailableDeviceSyncErasureDriver: DeviceSyncErasureDriving {
    public init() {}
    public func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .unresolved }
}
func validOpaqueID(_ value: String) -> Bool { !value.utf8.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0) }
// Internal deterministic crash seams. Never erase or reset control after injected failures.
enum DeviceSyncErasureFault: Equatable, Sendable {
    case beforeFenceCommit, afterFenceCommit, afterUnlink(Int), beforeReceiptCommit, afterReceiptCommit
}
