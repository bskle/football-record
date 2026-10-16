import Foundation
import MatchCore

public struct SyncRepositoryIdentity: Codable, Sendable, Equatable {
    public let instanceID: String
    public let databaseNamespace: String
    public init(instanceID: String, databaseNamespace: String) throws {
        try SyncWire.id(instanceID); try SyncWire.id(databaseNamespace)
        self.instanceID = instanceID
        self.databaseNamespace = databaseNamespace
    }
    private enum CodingKeys: String, CodingKey { case instanceID, databaseNamespace }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(instanceID: c.decode(String.self, forKey: .instanceID), databaseNamespace: c.decode(String.self, forKey: .databaseNamespace))
    }
}
public enum SyncMessageKind: String, Codable, Sendable { case packet, ack }
public struct SyncDeliveryRecord: Codable, Sendable, Equatable {
    public let deliveryID: String
    public let messageID: String
    public let matchID: String
    public let sourceDeviceID: String
    public let targetDeviceID: String
    public let kind: SyncMessageKind
    public let fragmentBytes: Data
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public init(deliveryID: String, messageID: String, matchID: String, sourceDeviceID: String, targetDeviceID: String, kind: SyncMessageKind, fragmentBytes: Data, attemptCount: Int, nextAttemptAt: Date) throws {
        for id in [deliveryID, messageID, matchID, sourceDeviceID, targetDeviceID] { try SyncWire.id(id) }
        guard attemptCount >= 0, sourceDeviceID != targetDeviceID, nextAttemptAt.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidRequest }
        guard fragmentBytes.count <= SyncFragment.maximumEncodedBytes else { throw StoreError.syncQuotaExceeded }
        let fragment = try JSONDecoder().decode(SyncFragment.self, from: fragmentBytes), b = fragment.body
        guard fragmentBytes == (try fragment.canonicalBytes()), deliveryID == (try fragment.fragmentID),
              messageID == b.messageID, matchID == b.matchID, sourceDeviceID == b.sourceDeviceID,
              targetDeviceID == b.targetDeviceID, kind == b.kind else { throw StoreError.invalidPacket }
        self.deliveryID = deliveryID
        self.messageID = messageID
        self.matchID = matchID
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.kind = kind
        self.fragmentBytes = fragmentBytes
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
    }
    private enum CodingKeys: String, CodingKey { case deliveryID, messageID, matchID, sourceDeviceID, targetDeviceID, kind, fragmentBytes, attemptCount, nextAttemptAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(deliveryID: c.decode(String.self, forKey: .deliveryID), messageID: c.decode(String.self, forKey: .messageID), matchID: c.decode(String.self, forKey: .matchID), sourceDeviceID: c.decode(String.self, forKey: .sourceDeviceID), targetDeviceID: c.decode(String.self, forKey: .targetDeviceID), kind: c.decode(SyncMessageKind.self, forKey: .kind), fragmentBytes: c.decode(Data.self, forKey: .fragmentBytes), attemptCount: c.decode(Int.self, forKey: .attemptCount), nextAttemptAt: c.decode(Date.self, forKey: .nextAttemptAt))
    }
}

public enum FragmentAssemblyResult: Sendable, Equatable {
    case incomplete
    case complete(messageID: String, kind: SyncMessageKind, matchID: String, wholeChecksum: String, bytes: Data)
}
public protocol SyncInboundCoordinator: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func receiveSyncPacket(_ bytes: Data, peer: PeerAuthorization, matchID: String) async throws -> InboundReceiptV3
    func receiveSyncACK(_ bytes: Data, peer: PeerAuthorization) async throws
}
public protocol SyncRepository: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func matchIDs() async throws -> [String]
    func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem]
    func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3
    func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2]
    func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3
    func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws
    func syncStateV3(matchID: String) async throws -> SyncState
    func ensureSyncDeliveriesV3(matchID: String) async throws
    func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord]
    func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws
    func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws
    func reactivateSyncACKsV3() async throws
    func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult
    func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult]
    func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws
    func expireSyncAssembliesV3(now: Date) async throws
}

/// Read failure is a separate event with no invented counters or stale success projection.
public enum SyncStateUpdate: Codable, Sendable, Equatable {
    case state(SyncState)
    case unavailable(matchID: String, issue: SyncIssue)
    private enum Representation: Codable { case state(SyncState); case unavailable(matchID: String, issue: SyncIssue) }
    public init(from decoder: any Decoder) throws {
        switch try Representation(from: decoder) {
        case .state(let state): self = .state(state)
        case .unavailable(let match, let issue): try SyncWire.id(match); self = .unavailable(matchID: match, issue: issue)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .state(let state): try Representation.state(state).encode(to: encoder)
        case .unavailable(let match, let issue): try SyncWire.id(match); try Representation.unavailable(matchID: match, issue: issue).encode(to: encoder)
        }
    }
}
extension FragmentAssemblyResult: Codable {
    private enum Representation: Codable {
        case incomplete
        case complete(messageID: String, kind: SyncMessageKind, matchID: String, wholeChecksum: String, bytes: Data)
    }
    public init(messageID: String, kind: SyncMessageKind, matchID: String, wholeChecksum: String, bytes: Data) throws {
        let header = try SyncMessageHeader(bytes: bytes, kind: kind)
        guard header.messageID == messageID, header.matchID == matchID, SyncWire.isHash(wholeChecksum), Canonical.hash(bytes) == wholeChecksum else { throw StoreError.invalidPacket }
        self = .complete(messageID: messageID, kind: kind, matchID: matchID, wholeChecksum: wholeChecksum, bytes: bytes)
    }
    public init(from decoder: any Decoder) throws {
        switch try Representation(from: decoder) {
        case .incomplete: self = .incomplete
        case .complete(let message, let kind, let match, let checksum, let bytes): try self.init(messageID: message, kind: kind, matchID: match, wholeChecksum: checksum, bytes: bytes)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .incomplete: try Representation.incomplete.encode(to: encoder)
        case .complete(let message, let kind, let match, let checksum, let bytes):
            _ = try Self(messageID: message, kind: kind, matchID: match, wholeChecksum: checksum, bytes: bytes)
            try Representation.complete(messageID: message, kind: kind, matchID: match, wholeChecksum: checksum, bytes: bytes).encode(to: encoder)
        }
    }
}
