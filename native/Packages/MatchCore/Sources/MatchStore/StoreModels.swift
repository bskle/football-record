import CryptoKit
import Foundation
import MatchCore

public enum StoreError: Error, Sendable, Equatable {
    case sqlite(code: Int32, message: String), closed, notFound, staleGeneration, commandConflict
    case invalidRequest, descriptorConflict, eventConflict, packetConflict, invalidPacket, invalidACK
    case unsupportedSchema(Int64), corruptPayload(table: String, key: String), unresolvedDiagnostics
    case injectedFailure, responseLost, staleCompletionEvidence
    case captureConflict, invalidCaptureRevision, missingCaptureParent, captureBranch
    case operationConflict, invalidOperationTransition, staleCaptureEvidence
}

enum Canonical {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Integrity envelope only. Identity, same-account membership and device pairing must be verified
/// by a trusted transport adapter before receive; a checksum is not authentication.
public struct MatchPacket: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public let version: Int
        public let packetID: String
        public let idempotencyKey: String
        public let revision: Int64
        public let sourceDeviceID: String
        public let targetDeviceID: String
        public let descriptor: MatchDescriptor
        public let events: [MatchEvent]
    }
    public let body: Body
    public let checksum: String
    public init(packetID: String, idempotencyKey: String, revision: Int64, sourceDeviceID: String,
                targetDeviceID: String, descriptor: MatchDescriptor, events: [MatchEvent]) throws {
        body = Body(version: 1, packetID: packetID, idempotencyKey: idempotencyKey, revision: revision,
            sourceDeviceID: sourceDeviceID, targetDeviceID: targetDeviceID, descriptor: descriptor, events: events)
        checksum = Canonical.hash(try Canonical.data(body))
    }
    func validate() throws {
        guard body.version == 1, body.revision >= 0, !body.packetID.isEmpty, !body.idempotencyKey.isEmpty,
              !body.sourceDeviceID.isEmpty, !body.targetDeviceID.isEmpty,
              body.sourceDeviceID != body.targetDeviceID,
              checksum == Canonical.hash(try Canonical.data(body)) else { throw StoreError.invalidPacket }
    }
}

public struct StoreCommit: Codable, Sendable {
    public let commandID: String
    public let expectedGeneration: Int64
    public let descriptor: MatchDescriptor
    public let events: [MatchEvent]
    public let packets: [MatchPacket]
    public init(commandID: String, expectedGeneration: Int64, descriptor: MatchDescriptor,
                events: [MatchEvent], packets: [MatchPacket]) {
        self.commandID = commandID; self.expectedGeneration = expectedGeneration
        self.descriptor = descriptor; self.events = events; self.packets = packets
    }
}

public struct CommitReceipt: Codable, Sendable, Equatable {
    public let commandID: String
    public let matchID: String
    public let generation: Int64
    public let eventIDs: [String]
    public let packetIDs: [String]
}

/// Durable receiver receipt. Adapters must authenticate its origin before calling acknowledge.
public struct DurableACK: Codable, Sendable, Equatable {
    public let packetID: String
    public let checksum: String
    public let receivingDeviceID: String
    public init(packetID: String, checksum: String, receivingDeviceID: String) {
        self.packetID = packetID; self.checksum = checksum; self.receivingDeviceID = receivingDeviceID
    }
}

public enum StoreDiagnosticSeverity: String, Sendable { case audit, blocking }
public struct StoreDiagnostic: Sendable, Equatable {
    public let code: String
    public let key: String
    public let rawBytes: Data
    public let severity: StoreDiagnosticSeverity
}
public struct StoreSnapshot: Sendable {
    public let descriptor: MatchDescriptor
    public let generation: Int64
    public let events: [MatchEvent]
    public let diagnostics: [StoreDiagnostic]
    public let completionEvidence: TrustedCompletionEvidence?
    public func replay(now: Date) throws -> ReplayResult {
        guard !diagnostics.contains(where: { $0.severity == .blocking }) else { throw StoreError.unresolvedDiagnostics }
        return MatchReplay.replay(descriptor: descriptor, events: events, now: now, completionEvidence: completionEvidence)
    }
}

enum StoreFault: Sendable { case migrationAfterSchema, migrationBeforeV2Version, migrationAfterV2Version
    case afterEvents, afterCaptureRevisions, afterCaptureOperations, afterOutbox, afterReceipt, beforeCommit, afterCommit }
