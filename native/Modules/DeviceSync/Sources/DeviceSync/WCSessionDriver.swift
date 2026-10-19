import Foundation

public struct DriverSnapshot: Sendable, Equatable {
    public let activated, reachable, counterpartAvailable: Bool
    public init(activated: Bool, reachable: Bool, counterpartAvailable: Bool) { self.activated = activated; self.reachable = reachable; self.counterpartAvailable = counterpartAvailable }
}
public struct DriverFileTransfer: Codable, Sendable, Equatable {
    public let deliveryID, checksum, token: String
    public let url: URL
    public init(deliveryID: String, checksum: String, token: String, url: URL) { self.deliveryID = deliveryID; self.checksum = checksum; self.token = token; self.url = url }
}
public enum DriverEvent: Sendable {
    case activationCompleted(DriverSnapshot, DeviceSyncError?)
    case stateChanged(DriverSnapshot)
    case inactive, deactivated, pairingChanged, companionChanged
    case fileCompleted(DriverFileTransfer, DeviceSyncError?)
}
public enum TrustInvalidationReason: String, Codable, Sendable, Equatable {
    case sessionInactive, pairingChanged, companionChanged
    /// These two come only from the application identity/account owner, never WCSession.
    case accountChanged, localIdentityChanged, remoteIdentityChanged
}
public enum DeviceSyncEvent: Sendable, Equatable {
    case activated, wake
    case trustInvalidated(TrustInvalidationReason)
    case failure(DeviceSyncError)
}
public enum TransportReply: String, Sendable, Equatable {
    case accepted, deferred, unavailable
    public var wireBytes: Data { Data(("football-record.transport.v1:" + rawValue).utf8) }
    public init(wireBytes: Data) throws {
        guard wireBytes.count <= 64, let text = String(data: wireBytes, encoding: .utf8), text.hasPrefix("football-record.transport.v1:"), let value = Self(rawValue: String(text.dropFirst(29))) else { throw DeviceSyncError.invalidReply }
        self = value
    }
}
/// All callbacks are synchronous and carry only value types. In particular file adoption
/// finishes here, before the native delegate returns and the SDK removes its source URL.
public struct DriverCallbacks: Sendable {
    public let message: @Sendable (Data) -> TransportReply
    public let file: @Sendable (URL) -> Void
    public let event: @Sendable (DriverEvent) -> Void
    public init(message: @escaping @Sendable (Data) -> TransportReply, file: @escaping @Sendable (URL) -> Void, event: @escaping @Sendable (DriverEvent) -> Void) { self.message = message; self.file = file; self.event = event }
}
public protocol WCSessionDriving: Sendable {
    func install(_ callbacks: DriverCallbacks) async
    func activate() async
    func snapshot() async -> DriverSnapshot
    func sendMessage(_ bytes: Data) async throws -> TransportReply
    func outstandingFiles() async -> [DriverFileTransfer]
    /// Returns after SDK enqueue, not after counterpart delivery or a business receipt.
    func enqueueFile(_ transfer: DriverFileTransfer) async throws
}

// Optional internal capability: the built-in driver and controlled host drivers
// prove that synchronous SDK dispatch uses the collection's retained storage gate.
protocol DeviceSyncStorageBoundDriving: WCSessionDriving {
    var storageContext: DeviceSyncStorageContext { get }
}

/// Handles cancellation-before-install, concurrent reply/error, and late callbacks once.
final class DriverSettlement<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    func install(_ value: CheckedContinuation<Value, any Error>) {
        let ready = lock.withLock { () -> Result<Value, any Error>? in
            if let result { return result }; continuation = value; return nil
        }
        if let ready { value.resume(with: ready) }
    }
    @discardableResult func finish(_ value: Result<Value, any Error>) -> Bool {
        let action = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
            guard result == nil else { return (false, nil) }
            result = value; let old = continuation; continuation = nil; return (true, old)
        }
        action.1?.resume(with: value); return action.0
    }
}
