import CryptoKit
import Foundation

public enum CaptureValueError: Error, Sendable, Equatable {
    case invalidIdentifier, invalidRevision, nonFiniteDate, mismatchedBinding, invalidObservation
}
private func captureID(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureValueError.invalidIdentifier }
}
private func captureDate(_ value: Date) throws {
    guard value.timeIntervalSinceReferenceDate.isFinite else { throw CaptureValueError.nonFiniteDate }
}
public enum CaptureAction: String, Codable, Sendable { case start, pause, resume, finish, recover }
public enum CaptureOperationState: String, Codable, Sendable { case pending, needsReconciliation, settled, failed }
public enum CaptureFailure: String, Codable, Sendable {
    case writeDenied, locationDenied, unavailable, recoveryUnavailable, routeFailed, captureFailed
}
public enum WorkoutOutcome: Codable, Sendable, Equatable {
    case running, paused, stopped, linked(workoutID: String), savedAwaitingLink, notCreated(CaptureFailure), unknown
}

public struct CaptureRevision: Codable, Sendable, Equatable {
    public let id: String
    public let binding: CaptureBinding
    public let parentID: String?
    public let revision: Int64
    public let observedAt: Date
    public let metadata: CaptureMetadata
    public init(id: String, binding: CaptureBinding, parentID: String?, revision: Int64, observedAt: Date, metadata: CaptureMetadata) throws {
        try captureID(id); try captureDate(observedAt)
        if let parentID { try captureID(parentID) }
        guard revision > 0, (revision == 1) == (parentID == nil), parentID != id else { throw CaptureValueError.invalidRevision }
        guard metadata.binding == binding else { throw CaptureValueError.mismatchedBinding }
        self.id = id
        self.binding = binding
        self.parentID = parentID
        self.revision = revision
        self.observedAt = observedAt
        self.metadata = metadata
    }
    private enum CodingKeys: String, CodingKey { case id, binding, parentID, revision, observedAt, metadata }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id),
                      binding: c.decode(CaptureBinding.self, forKey: .binding),
                      parentID: c.decodeIfPresent(String.self, forKey: .parentID),
                      revision: c.decode(Int64.self, forKey: .revision),
                      observedAt: c.decode(Date.self, forKey: .observedAt),
                      metadata: c.decode(CaptureMetadata.self, forKey: .metadata))
    }
    /// Canonical full-set digest, including an explicit domain for the empty capture set.
    public static func digest(_ revisions: [CaptureRevision]) throws -> String {
        struct Input: Encodable { let domain: String; let revisions: [CaptureRevision] }
        let input = Input(domain: "football-record.capture-revisions.v2", revisions: revisions.sorted { $0.id < $1.id })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CaptureOperation: Codable, Sendable, Equatable {
    public let id: String
    public let binding: CaptureBinding
    public let associatedCommandID: String
    public let action: CaptureAction
    public let requestedAt: Date
    public let externalToken: String
    public init(id: String, binding: CaptureBinding, associatedCommandID: String, action: CaptureAction, requestedAt: Date, externalToken: String) throws {
        for value in [id, associatedCommandID, externalToken] { try captureID(value) }
        try captureDate(requestedAt)
        if action == .start, externalToken != id { throw CaptureValueError.invalidIdentifier }
        self.id = id
        self.binding = binding
        self.associatedCommandID = associatedCommandID
        self.action = action
        self.requestedAt = requestedAt
        self.externalToken = externalToken
    }
    private enum CodingKeys: String, CodingKey { case id, binding, associatedCommandID, action, requestedAt, externalToken }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id),
                      binding: c.decode(CaptureBinding.self, forKey: .binding),
                      associatedCommandID: c.decode(String.self, forKey: .associatedCommandID),
                      action: c.decode(CaptureAction.self, forKey: .action),
                      requestedAt: c.decode(Date.self, forKey: .requestedAt),
                      externalToken: c.decode(String.self, forKey: .externalToken))
    }
}

public struct WorkoutObservation: Codable, Sendable, Equatable {
    public let operationID: String
    public let binding: CaptureBinding
    public let externalToken: String
    public let observedAt: Date
    public let outcome: WorkoutOutcome
    public let window: CaptureWindow
    public let failure: CaptureFailure?
    public init(operationID: String, binding: CaptureBinding, externalToken: String, observedAt: Date, outcome: WorkoutOutcome, window: CaptureWindow, failure: CaptureFailure? = nil) throws {
        try captureID(operationID); try captureID(externalToken); try captureDate(observedAt)
        if case .linked(let workoutID) = outcome { try captureID(workoutID) }
        self.operationID = operationID
        self.binding = binding
        self.externalToken = externalToken
        self.observedAt = observedAt
        self.outcome = outcome
        self.window = window
        self.failure = failure
    }
    private enum CodingKeys: String, CodingKey { case operationID, binding, externalToken, observedAt, outcome, window, failure }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: c.decode(String.self, forKey: .operationID),
                      binding: c.decode(CaptureBinding.self, forKey: .binding),
                      externalToken: c.decode(String.self, forKey: .externalToken),
                      observedAt: c.decode(Date.self, forKey: .observedAt),
                      outcome: c.decode(WorkoutOutcome.self, forKey: .outcome),
                      window: c.decode(CaptureWindow.self, forKey: .window),
                      failure: c.decodeIfPresent(CaptureFailure.self, forKey: .failure))
    }
}

public struct CaptureOperationRecord: Codable, Sendable, Equatable {
    public let operation: CaptureOperation
    public let state: CaptureOperationState
    public let observation: WorkoutObservation?
    public init(operation: CaptureOperation, state: CaptureOperationState, observation: WorkoutObservation?) throws {
        if let observation {
            guard observation.operationID == operation.id, observation.binding == operation.binding,
                  observation.externalToken == operation.externalToken else { throw CaptureValueError.invalidObservation }
        }
        if case .notCreated = observation?.outcome, operation.action != .start { throw CaptureValueError.invalidObservation }
        switch (state, observation?.outcome) {
        case (.pending, nil), (.needsReconciliation, nil), (.needsReconciliation, .some(.unknown)),
             (.needsReconciliation, .some(.savedAwaitingLink)), (.failed, .some(.notCreated)): break
        case (.needsReconciliation, .some(.stopped)):
            guard observation?.failure == .captureFailed else { throw CaptureValueError.invalidObservation }
        case (.settled, .some(.running)), (.settled, .some(.paused)), (.settled, .some(.stopped)), (.settled, .some(.linked)):
            if case .stopped = observation?.outcome, observation?.failure == .captureFailed { throw CaptureValueError.invalidObservation }
        case (.failed, .some(.running)), (.failed, .some(.paused)), (.failed, .some(.stopped)), (.failed, .some(.linked)):
            guard observation?.failure != nil else { throw CaptureValueError.invalidObservation }
            if case .stopped = observation?.outcome, observation?.failure == .captureFailed { throw CaptureValueError.invalidObservation }
        default: throw CaptureValueError.invalidObservation
        }
        self.operation = operation
        self.state = state
        self.observation = observation
    }
    private enum CodingKeys: String, CodingKey { case operation, state, observation }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operation: c.decode(CaptureOperation.self, forKey: .operation),
                      state: c.decode(CaptureOperationState.self, forKey: .state),
                      observation: c.decodeIfPresent(WorkoutObservation.self, forKey: .observation))
    }
}

public struct CaptureOperationUpdate: Codable, Sendable, Equatable {
    public let operationID: String
    public let expectedState: CaptureOperationState
    public let state: CaptureOperationState
    public let observation: WorkoutObservation?
    public init(operationID: String, expectedState: CaptureOperationState, state: CaptureOperationState, observation: WorkoutObservation?) throws {
        try captureID(operationID)
        if let observation, observation.operationID != operationID { throw CaptureValueError.invalidObservation }
        self.operationID = operationID
        self.expectedState = expectedState
        self.state = state
        self.observation = observation
    }
    private enum CodingKeys: String, CodingKey { case operationID, expectedState, state, observation }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: c.decode(String.self, forKey: .operationID),
                      expectedState: c.decode(CaptureOperationState.self, forKey: .expectedState),
                      state: c.decode(CaptureOperationState.self, forKey: .state),
                      observation: c.decodeIfPresent(WorkoutObservation.self, forKey: .observation))
    }
}

