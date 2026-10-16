import Foundation
import MatchStore

public struct SyncDelivery: Codable, Sendable, Equatable {
    public let bytes: Data
    public let transportDeliveryID: String
    public init(bytes: Data, transportDeliveryID: String) throws {
        guard !bytes.isEmpty, bytes.count <= SyncFragment.maximumEncodedBytes, !transportDeliveryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidRequest }
        self.bytes = bytes; self.transportDeliveryID = transportDeliveryID
    }
    private enum CodingKeys: String, CodingKey { case bytes, transportDeliveryID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bytes: c.decode(Data.self, forKey: .bytes), transportDeliveryID: c.decode(String.self, forKey: .transportDeliveryID))
    }
}
public protocol SyncTransport: Sendable {
    func activate() async
    func deliveries() async -> AsyncStream<SyncDelivery>
    func send(_ fragmentBytes: Data, deliveryID: String) async throws
    /// Store accepted the original frame durably. Release only transport-owned input;
    /// this is not a peer business ACK and must never confirm a packet delivery.
    func didPersistDelivery(_ transportDeliveryID: String) async
}
public extension SyncTransport {
    func didPersistDelivery(_ transportDeliveryID: String) async {}
}
public struct UnavailableSyncTransport: SyncTransport {
    public init() {}
    public func activate() async {}
    public func deliveries() async -> AsyncStream<SyncDelivery> { AsyncStream { $0.finish() } }
    public func send(_ fragmentBytes: Data, deliveryID: String) async throws { throw StoreError.syncTransportUnavailable }
}
public protocol SyncClock: Sendable { func now() -> Date }
public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
}
