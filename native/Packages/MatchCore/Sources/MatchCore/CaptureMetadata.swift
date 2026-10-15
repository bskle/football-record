import Foundation

public enum CaptureMetadataError: Error, Sendable, Equatable {
    case invalidIdentifier, nonFiniteBoundary, invertedWindow, mismatchedBinding, duplicateID
}

private func validateCaptureID(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CaptureMetadataError.invalidIdentifier
    }
}

/// The original match and its single recording device; recovery never creates a new binding.
public struct CaptureBinding: Codable, Sendable, Equatable {
    public let matchID: String
    public let recordingDeviceID: String
    public init(matchID: String, recordingDeviceID: String) throws {
        try validateCaptureID(matchID)
        try validateCaptureID(recordingDeviceID)
        self.matchID = matchID
        self.recordingDeviceID = recordingDeviceID
    }
    private enum CodingKeys: String, CodingKey { case matchID, recordingDeviceID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(matchID: values.decode(String.self, forKey: .matchID),
                      recordingDeviceID: values.decode(String.self, forKey: .recordingDeviceID))
    }
}

/// Observed wall-clock boundaries only. nil stays unknown, including both-nil lost windows.
/// There is deliberately no default boundary, duration, or inferred continuity.
public struct CaptureWindow: Codable, Sendable, Equatable {
    public let start: Date?
    public let end: Date?
    public init(start: Date?, end: Date?) throws {
        for boundary in [start, end].compactMap({ $0 }) {
            guard boundary.timeIntervalSinceReferenceDate.isFinite else {
                throw CaptureMetadataError.nonFiniteBoundary
            }
        }
        if let start, let end, start > end { throw CaptureMetadataError.invertedWindow }
        self.start = start
        self.end = end
    }
    private enum CodingKeys: String, CodingKey { case start, end }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: values.decodeIfPresent(Date.self, forKey: .start),
                      end: values.decodeIfPresent(Date.self, forKey: .end))
    }
}

/// Non-health metadata for an actually observed segment. Both IDs come from the caller;
/// workoutID must identify its real Workout, never a generated placeholder for missing data.
public struct CaptureSegment: Codable, Sendable, Equatable {
    public let id: String
    public let binding: CaptureBinding
    public let workoutID: String
    public let window: CaptureWindow
    public init(id: String, binding: CaptureBinding, workoutID: String, window: CaptureWindow) throws {
        try validateCaptureID(id)
        try validateCaptureID(workoutID)
        self.id = id
        self.binding = binding
        self.workoutID = workoutID
        self.window = window
    }
    private enum CodingKeys: String, CodingKey { case id, binding, workoutID, window }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      binding: values.decode(CaptureBinding.self, forKey: .binding),
                      workoutID: values.decode(String.self, forKey: .workoutID),
                      window: values.decode(CaptureWindow.self, forKey: .window))
    }
}

/// A missing capture window, not zero-valued samples or evidence that capture completed.
public struct CaptureGap: Codable, Sendable, Equatable {
    public let id: String
    public let binding: CaptureBinding
    public let window: CaptureWindow
    public init(id: String, binding: CaptureBinding, window: CaptureWindow) throws {
        try validateCaptureID(id)
        self.id = id
        self.binding = binding
        self.window = window
    }
    private enum CodingKeys: String, CodingKey { case id, binding, window }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      binding: values.decode(CaptureBinding.self, forKey: .binding),
                      window: values.decode(CaptureWindow.self, forKey: .window))
    }
}

/// A value snapshot of capture associations, with one ID namespace for segments and gaps.
/// Multiple Workouts may belong to the same original binding. Array order is preserved;
/// windows are neither joined nor required to be complete. This does not change match clocks.
public struct CaptureMetadata: Codable, Sendable, Equatable {
    public let binding: CaptureBinding
    public let segments: [CaptureSegment]
    public let gaps: [CaptureGap]
    public init(binding: CaptureBinding, segments: [CaptureSegment], gaps: [CaptureGap]) throws {
        guard segments.allSatisfy({ $0.binding == binding }), gaps.allSatisfy({ $0.binding == binding }) else {
            throw CaptureMetadataError.mismatchedBinding
        }
        let ids = segments.map(\.id) + gaps.map(\.id)
        guard Set(ids).count == ids.count else { throw CaptureMetadataError.duplicateID }
        self.binding = binding
        self.segments = segments
        self.gaps = gaps
    }
    private enum CodingKeys: String, CodingKey { case binding, segments, gaps }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(binding: values.decode(CaptureBinding.self, forKey: .binding),
                      segments: values.decode([CaptureSegment].self, forKey: .segments),
                      gaps: values.decode([CaptureGap].self, forKey: .gaps))
    }
}
