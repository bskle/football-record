import Foundation
import MatchCore

private func storeID(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidRequest }
}
public struct BusinessDeltaV2: Codable, Sendable, Equatable {
    public let descriptor: MatchDescriptor
    public let events: [MatchEvent]
    public let captureRevisions: [CaptureRevision]
    public init(descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision]) throws {
        guard events.allSatisfy({ $0.matchID == descriptor.matchID }),
              captureRevisions.allSatisfy({ $0.binding.matchID == descriptor.matchID && $0.binding.recordingDeviceID == descriptor.recordingDeviceID }) else { throw StoreError.invalidRequest }
        self.descriptor = descriptor
        self.events = events
        self.captureRevisions = captureRevisions
    }
    private enum CodingKeys: String, CodingKey { case descriptor, events, captureRevisions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(descriptor: c.decode(MatchDescriptor.self, forKey: .descriptor),
                      events: c.decode([MatchEvent].self, forKey: .events),
                      captureRevisions: c.decode([CaptureRevision].self, forKey: .captureRevisions))
    }
}

public struct BusinessOutboxItem: Codable, Sendable, Equatable {
    public let id: String
    public let matchID: String
    public let sourceDeviceID: String
    public let payload: BusinessDeltaV2
    public init(id: String, matchID: String, sourceDeviceID: String, payload: BusinessDeltaV2) throws {
        for value in [id, matchID, sourceDeviceID] { try storeID(value) }
        guard payload.descriptor.matchID == matchID else { throw StoreError.invalidRequest }
        self.id = id
        self.matchID = matchID
        self.sourceDeviceID = sourceDeviceID
        self.payload = payload
    }
    private enum CodingKeys: String, CodingKey { case id, matchID, sourceDeviceID, payload }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id),
                      matchID: c.decode(String.self, forKey: .matchID),
                      sourceDeviceID: c.decode(String.self, forKey: .sourceDeviceID),
                      payload: c.decode(BusinessDeltaV2.self, forKey: .payload))
    }
}

public struct StoreCommitV2: Codable, Sendable, Equatable {
    public let commandID: String
    public let expectedGeneration: Int64
    public let descriptor: MatchDescriptor
    public let events: [MatchEvent]
    public let captureRevisions: [CaptureRevision]
    public let newCaptureOperations: [CaptureOperation]
    public let captureOperationUpdates: [CaptureOperationUpdate]
    public let businessOutbox: [BusinessOutboxItem]
    public init(commandID: String, expectedGeneration: Int64, descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision], newCaptureOperations: [CaptureOperation], captureOperationUpdates: [CaptureOperationUpdate], businessOutbox: [BusinessOutboxItem]) throws {
        try storeID(commandID)
        guard expectedGeneration >= 0, expectedGeneration < Int64.max else { throw StoreError.invalidRequest }
        self.commandID = commandID
        self.expectedGeneration = expectedGeneration
        self.descriptor = descriptor
        self.events = events
        self.captureRevisions = captureRevisions
        self.newCaptureOperations = newCaptureOperations
        self.captureOperationUpdates = captureOperationUpdates
        self.businessOutbox = businessOutbox
    }
    private enum CodingKeys: String, CodingKey { case commandID, expectedGeneration, descriptor, events, captureRevisions, newCaptureOperations, captureOperationUpdates, businessOutbox }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(commandID: c.decode(String.self, forKey: .commandID),
                      expectedGeneration: c.decode(Int64.self, forKey: .expectedGeneration),
                      descriptor: c.decode(MatchDescriptor.self, forKey: .descriptor),
                      events: c.decode([MatchEvent].self, forKey: .events),
                      captureRevisions: c.decode([CaptureRevision].self, forKey: .captureRevisions),
                      newCaptureOperations: c.decode([CaptureOperation].self, forKey: .newCaptureOperations),
                      captureOperationUpdates: c.decode([CaptureOperationUpdate].self, forKey: .captureOperationUpdates),
                      businessOutbox: c.decode([BusinessOutboxItem].self, forKey: .businessOutbox))
    }
}

public struct CommitReceiptV2: Codable, Sendable, Equatable {
    public let commandID: String
    public let matchID: String
    public let generation: Int64
    public let eventIDs: [String]
    public let captureRevisionIDs: [String]
    public let operationIDs: [String]
    public let businessOutboxIDs: [String]
    public init(commandID: String, matchID: String, generation: Int64, eventIDs: [String], captureRevisionIDs: [String], operationIDs: [String], businessOutboxIDs: [String]) throws {
        try storeID(commandID); try storeID(matchID)
        for id in eventIDs + captureRevisionIDs + operationIDs + businessOutboxIDs { try storeID(id) }
        guard generation > 0 else { throw StoreError.invalidRequest }
        self.commandID = commandID
        self.matchID = matchID
        self.generation = generation
        self.eventIDs = eventIDs
        self.captureRevisionIDs = captureRevisionIDs
        self.operationIDs = operationIDs
        self.businessOutboxIDs = businessOutboxIDs
    }
    private enum CodingKeys: String, CodingKey { case commandID, matchID, generation, eventIDs, captureRevisionIDs, operationIDs, businessOutboxIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(commandID: c.decode(String.self, forKey: .commandID),
                      matchID: c.decode(String.self, forKey: .matchID),
                      generation: c.decode(Int64.self, forKey: .generation),
                      eventIDs: c.decode([String].self, forKey: .eventIDs),
                      captureRevisionIDs: c.decode([String].self, forKey: .captureRevisionIDs),
                      operationIDs: c.decode([String].self, forKey: .operationIDs),
                      businessOutboxIDs: c.decode([String].self, forKey: .businessOutboxIDs))
    }
}

public struct StoreSnapshotV2: Sendable {
    public let business: StoreSnapshot
    public let captureRevisions: [CaptureRevision]
    public let captureOperations: [CaptureOperationRecord]
    public var captureDigest: String { get throws { try CaptureRevision.digest(captureRevisions) } }
    public init(business: StoreSnapshot, captureRevisions: [CaptureRevision], captureOperations: [CaptureOperationRecord]) throws {
        let descriptor = business.descriptor
        guard business.generation > 0,
              captureRevisions.allSatisfy({ $0.binding.matchID == descriptor.matchID && $0.binding.recordingDeviceID == descriptor.recordingDeviceID }),
              captureOperations.allSatisfy({ $0.operation.binding.matchID == descriptor.matchID && $0.operation.binding.recordingDeviceID == descriptor.recordingDeviceID }) else { throw StoreError.invalidRequest }
        self.business = business; self.captureRevisions = captureRevisions; self.captureOperations = captureOperations
    }
}

public struct CommittedCommandV2: Codable, Sendable, Equatable {
    public let request: StoreCommitV2
    public let receipt: CommitReceiptV2
    public init(request: StoreCommitV2, receipt: CommitReceiptV2) throws {
        guard request.commandID == receipt.commandID, request.descriptor.matchID == receipt.matchID,
              request.expectedGeneration + 1 == receipt.generation,
              receipt.eventIDs == request.events.map(\.eventID), receipt.captureRevisionIDs == request.captureRevisions.map(\.id),
              receipt.operationIDs == request.newCaptureOperations.map(\.id) + request.captureOperationUpdates.map(\.operationID),
              receipt.businessOutboxIDs == request.businessOutbox.map(\.id) else { throw StoreError.invalidRequest }
        self.request = request; self.receipt = receipt
    }
    private enum CodingKeys: String, CodingKey { case request, receipt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(request: c.decode(StoreCommitV2.self, forKey: .request), receipt: c.decode(CommitReceiptV2.self, forKey: .receipt))
    }
}

/// Immutable binding used by both legacy and capture-aware complete-save boundaries.
struct CaptureCompletionConfirmation: Codable, Equatable {
    let evidence: TrustedCompletionEvidence
    let captureDigest: String
}
