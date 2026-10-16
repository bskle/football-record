import Foundation

/// Whole checksum binds complete canonical message bytes, not the packet body's checksum.
public struct SyncFragment: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public let version: Int
        public let kind: SyncMessageKind
        public let messageID, sourceDeviceID, targetDeviceID, matchID, wholeChecksum: String
        public let totalBytes, index, count: Int
        public let chunkChecksum: String
        public let payload: Data
        public init(kind: SyncMessageKind, messageID: String, sourceDeviceID: String, targetDeviceID: String, matchID: String, wholeChecksum: String, totalBytes: Int, index: Int, count: Int, payload: Data) throws {
            version = 2; self.kind = kind; self.messageID = messageID; self.sourceDeviceID = sourceDeviceID
            self.targetDeviceID = targetDeviceID; self.matchID = matchID; self.wholeChecksum = wholeChecksum
            self.totalBytes = totalBytes; self.index = index; self.count = count; self.payload = payload
            chunkChecksum = Canonical.hash(payload); try validate()
        }
        func validate() throws {
            for id in [messageID, sourceDeviceID, targetDeviceID, matchID] { try SyncWire.id(id) }
            guard version == 2, sourceDeviceID != targetDeviceID, SyncWire.isHash(wholeChecksum),
                  totalBytes > 0, totalBytes <= SyncWire.maximumBytes, count > 0, count <= 32,
                  index >= 0, index < count, payload.count <= SyncFragment.chunkBytes,
                  count == (totalBytes <= 32 * 1024 ? 1 : (totalBytes + SyncFragment.chunkBytes - 1) / SyncFragment.chunkBytes),
                  payload.count == (index == count - 1 ? totalBytes - index * SyncFragment.chunkBytes : SyncFragment.chunkBytes),
                  chunkChecksum == Canonical.hash(payload) else { throw StoreError.invalidPacket }
        }
        private enum CodingKeys: String, CodingKey { case version, kind, messageID, sourceDeviceID, targetDeviceID, matchID, wholeChecksum, totalBytes, index, count, chunkChecksum, payload }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version); kind = try c.decode(SyncMessageKind.self, forKey: .kind)
            messageID = try c.decode(String.self, forKey: .messageID); sourceDeviceID = try c.decode(String.self, forKey: .sourceDeviceID)
            targetDeviceID = try c.decode(String.self, forKey: .targetDeviceID); matchID = try c.decode(String.self, forKey: .matchID)
            wholeChecksum = try c.decode(String.self, forKey: .wholeChecksum); totalBytes = try c.decode(Int.self, forKey: .totalBytes)
            index = try c.decode(Int.self, forKey: .index); count = try c.decode(Int.self, forKey: .count)
            chunkChecksum = try c.decode(String.self, forKey: .chunkChecksum); payload = try c.decode(Data.self, forKey: .payload)
            try validate()
        }
    }
    public static let maximumEncodedBytes = 16 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public let body: Body
    public let checksum: String
    public var fragmentID: String { get throws { try SyncWire.derive("fragment-id", [body.messageID, body.wholeChecksum, String(body.index)]) } }
    public init(body: Body) throws { try body.validate(); self.body = body; checksum = try SyncWire.hash(body, domain: "fragment") }
    private enum CodingKeys: String, CodingKey { case body, checksum }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); body = try c.decode(Body.self, forKey: .body); checksum = try c.decode(String.self, forKey: .checksum)
        guard checksum == (try SyncWire.hash(body, domain: "fragment")) else { throw StoreError.invalidPacket }
    }
    public func canonicalBytes() throws -> Data { try Canonical.data(self) }
    public static func fragments(bytes: Data, kind: SyncMessageKind) throws -> [Self] {
        let header = try SyncMessageHeader(bytes: bytes, kind: kind)
        let count = bytes.count <= 32 * 1024 ? 1 : (bytes.count + chunkBytes - 1) / chunkBytes
        return try (0..<count).map { index in
            try Self(body: Body(kind: kind, messageID: header.messageID, sourceDeviceID: header.source, targetDeviceID: header.target, matchID: header.matchID, wholeChecksum: Canonical.hash(bytes), totalBytes: bytes.count, index: index, count: count, payload: bytes.subdata(in: index * chunkBytes..<min((index + 1) * chunkBytes, bytes.count))))
        }
    }
}

struct SyncMessageHeader {
    let messageID, source, target, matchID: String
    init(bytes: Data, kind: SyncMessageKind) throws {
        guard !bytes.isEmpty, bytes.count <= SyncWire.maximumBytes else { throw StoreError.syncQuotaExceeded }
        switch kind {
        case .packet:
            let p = try JSONDecoder().decode(MatchPacketV2.self, from: bytes)
            guard bytes == (try p.canonicalBytes()) else { throw StoreError.invalidPacket }
            messageID = p.body.packetID; source = p.body.sourceDeviceID; target = p.body.targetDeviceID; matchID = p.body.descriptor.matchID
        case .ack:
            let a = try JSONDecoder().decode(DurableACKV2.self, from: bytes)
            guard bytes == (try a.canonicalBytes()) else { throw StoreError.invalidACK }
            messageID = a.body.ackID; source = a.body.sourceDeviceID; target = a.body.targetDeviceID; matchID = a.body.matchID
        }
    }
    func matches(_ b: SyncFragment.Body) -> Bool { messageID == b.messageID && source == b.sourceDeviceID && target == b.targetDeviceID && matchID == b.matchID }
}
