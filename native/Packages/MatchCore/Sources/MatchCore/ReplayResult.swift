import Foundation

public enum MatchState: String, Codable, Sendable { case notStarted, running, paused, endedPendingSync, completed, incomplete, conflict }
public enum DiagnosticCode: String, Codable, Sendable {
    case conflictingEventID, duplicateSequence, invalidRevision, unauthorizedWriter, invalidEvent
    case missingStart, missingPermit, duplicateStart, duplicateFieldTransition, duplicatePauseTransition
    case staleCompletionEvidence
    case beforeStart, afterEnd, futureEvent, elapsedMismatch, duplicateTermination
}
public struct ReplayDiagnostic: Codable, Sendable, Equatable {
    public let code: DiagnosticCode
    public let eventIDs: [String]
    public let isConflict: Bool
    init(_ code: DiagnosticCode, _ eventIDs: [String] = [], conflict: Bool = false) {
        self.code = code; self.eventIDs = eventIDs.sorted(); self.isConflict = conflict
    }
}
public struct Score: Codable, Sendable, Equatable {
    public var forTeam: Int
    public var against: Int
    public init(forTeam: Int = 0, against: Int = 0) { self.forTeam = forTeam; self.against = against }
    mutating func add(_ impact: ScoreImpact) { if impact == .forTeam { forTeam += 1 } else { against += 1 } }
}
public struct MatchInterval: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}
public enum MatchOutcome: String, Codable, Sendable { case win, draw, loss }
public struct CareerEligibility: Codable, Sendable, Equatable {
    public let includeRecordedMatch: Bool
    public let includeAppearance: Bool
    public let includeWinRate: Bool
    public let includeFitness: Bool
    public let result: MatchOutcome?
}
public struct HealthSummary: Codable, Sendable, Equatable {
    public let distanceMeters: Double?
    public let averageHeartRate: Double?
}
public struct ReplayResult: Codable, Sendable, Equatable {
    public var state: MatchState = .notStarted
    public let matchID: String
    public let recordingDeviceID: String
    public let backendLockState: BackendLockState
    public var effectiveEvents: [MatchEvent] = []
    public var diagnostics: [ReplayDiagnostic] = []
    public var runningIntervals: [MatchInterval] = []
    public var pausedIntervals: [MatchInterval] = []
    public var fieldIntervals: [MatchInterval] = []
    public var matchDuration: TimeInterval? = nil
    public var appearanceDuration: TimeInterval? = nil
    public var isOnField = false
    public var score = Score()
    public var onFieldScore = Score()
    public var personalGoals = 0
    public var personalAssists = 0
    public var excludedAfterEndEventIDs: [String] = []
    public var health: HealthSummary? = nil
    public var onFieldGoalDifference: Int { onFieldScore.forTeam - onFieldScore.against }
    public var career: CareerEligibility {
        let completed = state == .completed
        let appeared = completed && appearanceDuration.map { $0 > 0 } == true
        let outcome: MatchOutcome = score.forTeam > score.against ? .win : score.forTeam < score.against ? .loss : .draw
        return CareerEligibility(includeRecordedMatch: completed, includeAppearance: appeared,
            includeWinRate: appeared, includeFitness: appeared, result: appeared ? outcome : nil)
    }
    public var timingComplete: Bool { matchDuration != nil && appearanceDuration != nil }
    public func elapsed(at date: Date) -> TimeInterval? {
        guard timingComplete else { return nil }
        return runningIntervals.reduce(0) { $0 + max(0, min(date, $1.end).timeIntervalSince($1.start)) }
    }
    init(descriptor: MatchDescriptor) {
        matchID = descriptor.matchID; recordingDeviceID = descriptor.recordingDeviceID
        backendLockState = descriptor.backendLockState
    }
}
