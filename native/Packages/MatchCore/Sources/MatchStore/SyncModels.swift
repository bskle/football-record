import Foundation
import MatchCore

public enum PeerEnvironment: Codable, Sendable, Equatable {
    case production
    case development(databaseNamespace: String)
    func validate() throws {
        if case .development(let namespace) = self { try SyncWire.id(namespace) }
    }
}

/// Authorization is an assertion from a trusted provider, never authentication by checksum.
/// Store binds the local environment; the provider must revalidate account, pair and epoch.
public struct PeerAuthorization: Codable, Sendable, Equatable {
    public let localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch: String
    public let environment: PeerEnvironment
    public let issuedAt, expiresAt: Date
    public init(localDeviceID: String, remoteDeviceID: String, accountSubject: String, pairingID: String, trustEpoch: String, environment: PeerEnvironment, issuedAt: Date, expiresAt: Date) throws {
        for id in [localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch] { try SyncWire.id(id) }
        try environment.validate()
        guard localDeviceID != remoteDeviceID, issuedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > issuedAt else { throw StoreError.invalidPeerAuthorization }
        self.localDeviceID = localDeviceID; self.remoteDeviceID = remoteDeviceID; self.accountSubject = accountSubject
        self.pairingID = pairingID; self.trustEpoch = trustEpoch; self.environment = environment
        self.issuedAt = issuedAt; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch, environment, issuedAt, expiresAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(localDeviceID: c.decode(String.self, forKey: .localDeviceID), remoteDeviceID: c.decode(String.self, forKey: .remoteDeviceID), accountSubject: c.decode(String.self, forKey: .accountSubject), pairingID: c.decode(String.self, forKey: .pairingID), trustEpoch: c.decode(String.self, forKey: .trustEpoch), environment: c.decode(PeerEnvironment.self, forKey: .environment), issuedAt: c.decode(Date.self, forKey: .issuedAt), expiresAt: c.decode(Date.self, forKey: .expiresAt))
    }
    /// Expiry can be refreshed by the trusted provider; immutable identity and epoch cannot be rebound.
    func sameBinding(as other: Self) -> Bool {
        localDeviceID == other.localDeviceID && remoteDeviceID == other.remoteDeviceID && accountSubject == other.accountSubject && pairingID == other.pairingID && trustEpoch == other.trustEpoch && environment == other.environment
    }
}

public enum PeerOperation: Sendable { case route, send, receive, acknowledge }
public protocol PeerTrustProvider: Sendable {
    func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization
    func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws
}
public struct UnavailablePeerTrustProvider: PeerTrustProvider {
    public init() {}
    public func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization { throw StoreError.trustUnavailable }
    public func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws { throw StoreError.trustUnavailable }
}

public struct MatchPacketV2: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public let version: Int
        public let packetID, idempotencyKey: String
        public let sequence: Int64
        public let sourceDeviceID, targetDeviceID: String
        public let descriptor: MatchDescriptor
        public let events: [MatchEvent]
        public let captureRevisions: [CaptureRevision]
    }
    public let body: Body
    public let checksum: String
    public init(packetID: String, idempotencyKey: String, sequence: Int64, sourceDeviceID: String, targetDeviceID: String, descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision]) throws {
        body = try Body(packetID: packetID, idempotencyKey: idempotencyKey, sequence: sequence, sourceDeviceID: sourceDeviceID, targetDeviceID: targetDeviceID, descriptor: descriptor, events: events, captureRevisions: captureRevisions)
        checksum = try SyncWire.hash(body, domain: "packet")
        try validate()
    }
    func validate() throws {
        try body.validateFields()
        guard checksum == (try SyncWire.hash(body, domain: "packet")) else { throw StoreError.invalidPacket }
    }

    private enum CodingKeys: String, CodingKey { case body, checksum }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decode(Body.self, forKey: .body); checksum = try c.decode(String.self, forKey: .checksum); try validate()
    }
    public func canonicalBytes() throws -> Data { try Canonical.data(self) }
}

public struct DurableACKV2: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public let version: Int
        public let ackID, packetID, idempotencyKey, matchID: String
        public let sequence: Int64
        public let packetChecksum, sourceDeviceID, targetDeviceID: String
    }
    public let body: Body
    public let checksum: String
    public init(packet: MatchPacketV2) throws {
        body = try Body(packet: packet)
        checksum = try SyncWire.hash(body, domain: "ack"); try validate()
    }
    func validate() throws {
        try body.validateFields()
        guard checksum == (try SyncWire.hash(body, domain: "ack")) else { throw StoreError.invalidACK }
    }

    private enum CodingKeys: String, CodingKey { case body, checksum }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decode(Body.self, forKey: .body); checksum = try c.decode(String.self, forKey: .checksum); try validate()
    }
    public func canonicalBytes() throws -> Data { try Canonical.data(self) }
}

public struct RouteReceiptV3: Codable, Sendable, Equatable {
    public let outboxID, sourcePayloadDigest: String
    public let packet: MatchPacketV2
    public init(outboxID: String, sourcePayloadDigest: String, packet: MatchPacketV2) throws {
        try SyncWire.id(outboxID); try packet.validate()
        guard SyncWire.isHash(sourcePayloadDigest) else { throw StoreError.invalidRequest }
        self.outboxID = outboxID; self.sourcePayloadDigest = sourcePayloadDigest; self.packet = packet
    }
    private enum CodingKeys: String, CodingKey { case outboxID, sourcePayloadDigest, packet }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(outboxID: c.decode(String.self, forKey: .outboxID), sourcePayloadDigest: c.decode(String.self, forKey: .sourcePayloadDigest), packet: c.decode(MatchPacketV2.self, forKey: .packet))
    }
}
public struct InboundReceiptV3: Codable, Sendable, Equatable {
    public let ack: DurableACKV2
    public let matchID: String
    public let generation: Int64
    public let insertedEventIDs, insertedCaptureRevisionIDs: [String]
    public init(ack: DurableACKV2, matchID: String, generation: Int64, insertedEventIDs: [String], insertedCaptureRevisionIDs: [String]) throws {
        try SyncWire.id(matchID)
        for id in insertedEventIDs + insertedCaptureRevisionIDs { try SyncWire.id(id) }
        guard generation > 0, ack.body.matchID == matchID,
              Set(insertedEventIDs).count == insertedEventIDs.count, Set(insertedCaptureRevisionIDs).count == insertedCaptureRevisionIDs.count else { throw StoreError.invalidRequest }
        self.ack = ack; self.matchID = matchID; self.generation = generation
        self.insertedEventIDs = insertedEventIDs; self.insertedCaptureRevisionIDs = insertedCaptureRevisionIDs
    }
    private enum CodingKeys: String, CodingKey { case ack, matchID, generation, insertedEventIDs, insertedCaptureRevisionIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(ack: c.decode(DurableACKV2.self, forKey: .ack), matchID: c.decode(String.self, forKey: .matchID), generation: c.decode(Int64.self, forKey: .generation), insertedEventIDs: c.decode([String].self, forKey: .insertedEventIDs), insertedCaptureRevisionIDs: c.decode([String].self, forKey: .insertedCaptureRevisionIDs))
    }
}
public struct SyncGap: Codable, Sendable, Equatable {
    public let lowerBound, upperBound: Int64
    public init(lowerBound: Int64, upperBound: Int64) throws {
        guard lowerBound > 0, upperBound >= lowerBound, upperBound < Int64.max else { throw StoreError.invalidRequest }
        self.lowerBound = lowerBound; self.upperBound = upperBound
    }
    private enum CodingKeys: String, CodingKey { case lowerBound, upperBound }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lowerBound: c.decode(Int64.self, forKey: .lowerBound), upperBound: c.decode(Int64.self, forKey: .upperBound))
    }
}
public enum SyncIssue: String, Codable, Sendable { case peerUnavailable, trustUnavailable, transportUnavailable, retryScheduled, ancestryIncomplete, invalidPayload, blockedIntegrity, quotaExceeded }
public struct SyncState: Codable, Sendable, Equatable {
    public let matchID: String
    public let unroutedCount, pendingACKCount, receivedGapCount: Int
    public let lastPeerACKAt: Date?
    public let issue: SyncIssue?
    public init(matchID: String, unroutedCount: Int, pendingACKCount: Int, receivedGapCount: Int, lastPeerACKAt: Date?, issue: SyncIssue?) throws {
        try SyncWire.id(matchID)
        guard unroutedCount >= 0, pendingACKCount >= 0, receivedGapCount >= 0, lastPeerACKAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false else { throw StoreError.invalidRequest }
        self.matchID = matchID; self.unroutedCount = unroutedCount; self.pendingACKCount = pendingACKCount
        self.receivedGapCount = receivedGapCount; self.lastPeerACKAt = lastPeerACKAt; self.issue = issue
    }
    private enum CodingKeys: String, CodingKey { case matchID, unroutedCount, pendingACKCount, receivedGapCount, lastPeerACKAt, issue }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(matchID: c.decode(String.self, forKey: .matchID), unroutedCount: c.decode(Int.self, forKey: .unroutedCount), pendingACKCount: c.decode(Int.self, forKey: .pendingACKCount), receivedGapCount: c.decode(Int.self, forKey: .receivedGapCount), lastPeerACKAt: c.decodeIfPresent(Date.self, forKey: .lastPeerACKAt), issue: c.decodeIfPresent(SyncIssue.self, forKey: .issue))
    }
}

enum SyncWire {
    static let maximumBytes = 8 * 1024 * 1024
    static func id(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidRequest }
    }
    static func isHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func hash<T: Encodable>(_ value: T, domain: String) throws -> String {
        Canonical.hash(Data(("football-record.sync." + domain + ".v2\0").utf8) + (try Canonical.data(value)))
    }
    static func derive(_ domain: String, _ fields: [String]) throws -> String { try hash(fields, domain: domain) }
}

extension MatchPacketV2.Body {
    public init(packetID: String, idempotencyKey: String, sequence: Int64, sourceDeviceID: String, targetDeviceID: String, descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision]) throws {
        self.init(version: 2, packetID: packetID, idempotencyKey: idempotencyKey, sequence: sequence, sourceDeviceID: sourceDeviceID, targetDeviceID: targetDeviceID, descriptor: descriptor, events: events.sorted { $0.eventID < $1.eventID }, captureRevisions: captureRevisions.sorted { ($0.revision, $0.id) < ($1.revision, $1.id) })
        try validateFields()
    }
    func validateFields() throws {
        for id in [packetID, idempotencyKey, sourceDeviceID, targetDeviceID, descriptor.matchID] { try SyncWire.id(id) }
        guard version == 2, sequence > 0, sequence < Int64.max, sourceDeviceID != targetDeviceID,
              events == events.sorted(by: { $0.eventID < $1.eventID }), Set(events.map(\.eventID)).count == events.count,
              captureRevisions == captureRevisions.sorted(by: { ($0.revision, $0.id) < ($1.revision, $1.id) }),
              Set(captureRevisions.map(\.id)).count == captureRevisions.count else { throw StoreError.invalidPacket }
    }
    private enum CodingKeys: String, CodingKey { case version, packetID, idempotencyKey, sequence, sourceDeviceID, targetDeviceID, descriptor, events, captureRevisions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version), packetID: try c.decode(String.self, forKey: .packetID), idempotencyKey: try c.decode(String.self, forKey: .idempotencyKey), sequence: try c.decode(Int64.self, forKey: .sequence), sourceDeviceID: try c.decode(String.self, forKey: .sourceDeviceID), targetDeviceID: try c.decode(String.self, forKey: .targetDeviceID), descriptor: try c.decode(MatchDescriptor.self, forKey: .descriptor), events: try c.decode([MatchEvent].self, forKey: .events), captureRevisions: try c.decode([CaptureRevision].self, forKey: .captureRevisions))
        try validateFields()
    }
}
extension DurableACKV2.Body {
    public init(packet: MatchPacketV2) throws {
        try packet.validate(); let b = packet.body
        self.init(version: 2, ackID: try SyncWire.derive("ack-id", [b.packetID, packet.checksum, b.targetDeviceID]), packetID: b.packetID, idempotencyKey: b.idempotencyKey, matchID: b.descriptor.matchID, sequence: b.sequence, packetChecksum: packet.checksum, sourceDeviceID: b.targetDeviceID, targetDeviceID: b.sourceDeviceID)
        try validateFields()
    }
    func validateFields() throws {
        for id in [ackID, packetID, idempotencyKey, matchID, sourceDeviceID, targetDeviceID] { try SyncWire.id(id) }
        guard version == 2, sequence > 0, sequence < Int64.max, sourceDeviceID != targetDeviceID, SyncWire.isHash(packetChecksum),
              ackID == (try SyncWire.derive("ack-id", [packetID, packetChecksum, sourceDeviceID])) else { throw StoreError.invalidACK }
    }
    private enum CodingKeys: String, CodingKey { case version, ackID, packetID, idempotencyKey, matchID, sequence, packetChecksum, sourceDeviceID, targetDeviceID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version), ackID: try c.decode(String.self, forKey: .ackID), packetID: try c.decode(String.self, forKey: .packetID), idempotencyKey: try c.decode(String.self, forKey: .idempotencyKey), matchID: try c.decode(String.self, forKey: .matchID), sequence: try c.decode(Int64.self, forKey: .sequence), packetChecksum: try c.decode(String.self, forKey: .packetChecksum), sourceDeviceID: try c.decode(String.self, forKey: .sourceDeviceID), targetDeviceID: try c.decode(String.self, forKey: .targetDeviceID))
        try validateFields()
    }
}
extension PeerEnvironment {
    private enum CodingKeys: String, CodingKey { case production, development }
    private enum DevelopmentKeys: String, CodingKey { case databaseNamespace }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else { throw StoreError.invalidPeerAuthorization }
        if c.contains(.production) {
            _ = try c.nestedContainer(keyedBy: DevelopmentKeys.self, forKey: .production)
            self = .production
        } else {
            let nested = try c.nestedContainer(keyedBy: DevelopmentKeys.self, forKey: .development)
            let namespace = try nested.decode(String.self, forKey: .databaseNamespace)
            try SyncWire.id(namespace); self = .development(databaseNamespace: namespace)
        }
    }
}
