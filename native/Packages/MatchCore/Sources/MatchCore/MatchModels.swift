import Foundation

public struct StartIntent: Codable, Sendable, Equatable {
    public let id: String
    public let matchID: String
    public let recordingDeviceID: String
    public let requestedAt: Date
    public init(id: String, matchID: String, recordingDeviceID: String, requestedAt: Date) {
        self.id = id; self.matchID = matchID; self.recordingDeviceID = recordingDeviceID
        self.requestedAt = requestedAt
    }
}

/// An assertion made by a trusted adapter, not network verification performed by MatchCore.
/// Never construct this from an unverified remote payload. Persist the intent before requesting it.
public struct TrustedStartPermit: Codable, Sendable, Equatable {
    public enum Evidence: String, Codable, Sendable { case verifiedNetwork, developmentSimulation }
    public let intentID: String
    public let matchID: String
    public let recordingDeviceID: String
    public let evidence: Evidence
    public let permitID: String
    public static func acceptedByTrustedNetworkBoundary(for intent: StartIntent, permitID: String) -> Self {
        Self(intentID: intent.id, matchID: intent.matchID, recordingDeviceID: intent.recordingDeviceID,
             evidence: .verifiedNetwork, permitID: permitID)
    }
    fileprivate init(intentID: String, matchID: String, recordingDeviceID: String,
                     evidence: Evidence, permitID: String) {
        self.intentID = intentID; self.matchID = matchID; self.recordingDeviceID = recordingDeviceID
        self.evidence = evidence; self.permitID = permitID
    }
    func matches(_ intent: StartIntent) -> Bool {
        intentID == intent.id && matchID == intent.matchID && recordingDeviceID == intent.recordingDeviceID
            && !permitID.isEmpty
    }
}

/// Explicit development-only data; consumers must never present it as a real acquired lock.
public enum DevelopmentStartFixture {
    public static func permit(for intent: StartIntent) -> TrustedStartPermit {
        TrustedStartPermit(intentID: intent.id, matchID: intent.matchID,
            recordingDeviceID: intent.recordingDeviceID, evidence: .developmentSimulation,
            permitID: "development-simulation-" + intent.id)
    }
}

public enum BackendLockState: String, Codable, Sendable { case unknown, held, releaseRequested, releasedConfirmed }
public struct MatchDescriptor: Codable, Sendable, Equatable {
    public let startIntent: StartIntent
    public let starter: Bool
    public let startPermit: TrustedStartPermit?
    public let backendLockState: BackendLockState
    public var matchID: String { startIntent.matchID }
    public var recordingDeviceID: String { startIntent.recordingDeviceID }
    public init(startIntent: StartIntent, starter: Bool, startPermit: TrustedStartPermit? = nil,
                backendLockState: BackendLockState = .unknown) {
        self.startIntent = startIntent; self.starter = starter; self.startPermit = startPermit
        self.backendLockState = backendLockState
    }
}

public enum MatchEventType: String, Codable, Sendable {
    case matchStarted, matchPaused, matchResumed, matchEnded, enteredField, leftField, scoreEvent
    case matchTerminated
    // Reserved facts, with no V1 user interface or effect on match clocks.
    case warmupStarted, warmupEnded, stretchingStarted, stretchingEnded
}
public enum QuickRecordAction: String, Codable, Sendable { case myGoal, myAssist, teamGoal, conceded }
public enum EventStatus: String, Codable, Sendable { case active, deleted }
public enum EventAuthority: String, Codable, Sendable { case live, postMatch, abnormalTermination }
public enum ScoreImpact: String, Codable, Sendable { case forTeam = "for", against }
public enum GoalKind: String, Codable, Sendable { case normal, ownGoal }
public struct PlayerSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isSelf: Bool
    public init(id: String, displayName: String, isSelf: Bool = false) {
        self.id = id; self.displayName = displayName; self.isSelf = isSelf
    }
    public static let selfPlayer = PlayerSnapshot(id: "self", displayName: "我", isSelf: true)
}
public struct GoalPayload: Codable, Sendable, Equatable {
    /// The beneficiary; an own goal still contributes to this side of the score.
    public let scoreImpact: ScoreImpact
    public let goalKind: GoalKind
    public let scoringTeamSnapshot: String
    public let scorerSnapshot: PlayerSnapshot?
    public let assisterSnapshot: PlayerSnapshot?
    public let note: String?
    public init(scoreImpact: ScoreImpact, goalKind: GoalKind = .normal, scoringTeamSnapshot: String,
                scorerSnapshot: PlayerSnapshot? = nil, assisterSnapshot: PlayerSnapshot? = nil,
                note: String? = nil) {
        self.scoreImpact = scoreImpact; self.goalKind = goalKind; self.scoringTeamSnapshot = scoringTeamSnapshot
        self.scorerSnapshot = scorerSnapshot; self.assisterSnapshot = assisterSnapshot; self.note = note
    }
}

/// Immutable facts. A correction has a new ID and a complete replacement payload, references the
/// immediately preceding revision, and increments revision by one. A deleted revision is a tombstone.
public struct MatchEvent: Codable, Sendable, Equatable {
    public let eventID: String
    public let matchID: String
    /// Append sequence scoped to sourceDeviceID. A revision keeps a new audit sequence, while
    /// replay uses its root fact's sequence to preserve equal-time business order.
    public let sequence: Int
    public let occurredAt: Date
    /// Unknown only for an exceptional termination proposed before its start fact has arrived.
    public let matchElapsed: TimeInterval?
    public let type: MatchEventType
    public let sourceDeviceID: String
    public let createdAt: Date
    public let updatedAt: Date
    public let status: EventStatus
    public let correctionOfEventID: String?
    public let revision: Int
    public let authority: EventAuthority
    public let goal: GoalPayload?
    public let terminationID: String?
    public let quickAction: QuickRecordAction?
    public init(eventID: String, matchID: String, sequence: Int, occurredAt: Date,
                matchElapsed: TimeInterval?, type: MatchEventType, sourceDeviceID: String,
                createdAt: Date, updatedAt: Date, status: EventStatus = .active,
                correctionOfEventID: String? = nil, revision: Int = 0,
                authority: EventAuthority = .live, goal: GoalPayload? = nil, terminationID: String? = nil,
                quickAction: QuickRecordAction? = nil) {
        self.eventID = eventID; self.matchID = matchID; self.sequence = sequence
        self.occurredAt = occurredAt; self.matchElapsed = matchElapsed; self.type = type
        self.sourceDeviceID = sourceDeviceID; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.status = status; self.correctionOfEventID = correctionOfEventID; self.revision = revision
        self.authority = authority; self.goal = goal; self.terminationID = terminationID; self.quickAction = quickAction
    }
}
