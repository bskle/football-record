import Foundation
import CryptoKit

public enum DeviceSyncError: String, Error, Codable, Sendable, Equatable {
    case unavailable, inactive, activationFailed, deliveryFailed, invalidReply
    case invalidFrame, quotaExceeded, fileIO, corruptFile, conflictingDelivery
}
public enum DeviceSyncPolicy {
    /// Matches the frozen MatchSync v2 encoded-frame bound; no business decoding occurs here.
    public static let maximumFrameBytes = 16 * 1024 * 1024
    /// Application policy, not an Apple transport guarantee.
    public static let interactiveBytes = 48 * 1024
}
func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
func canonical<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }

public struct InboxLimits: Sendable {
    public let maximumFrameBytes, maximumBytes, maximumFrames: Int
    public init(maximumFrameBytes: Int = DeviceSyncPolicy.maximumFrameBytes, maximumBytes: Int = 64 * 1024 * 1024, maximumFrames: Int = 256) throws {
        guard maximumFrameBytes > 0, maximumFrameBytes <= DeviceSyncPolicy.maximumFrameBytes, maximumBytes > 0, maximumFrames > 0 else { throw DeviceSyncError.invalidFrame }
        self.maximumFrameBytes = maximumFrameBytes; self.maximumBytes = maximumBytes; self.maximumFrames = maximumFrames
    }
}
public struct InboxFailure: Codable, Sendable, Equatable {
    public let transportDeliveryID: String
    public let issue: DeviceSyncError
}
