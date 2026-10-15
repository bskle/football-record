import Foundation

public struct ReplayImpact: Sendable, Equatable {
    public let before: ReplayResult
    public let after: ReplayResult
    public var appearanceDurationChange: TimeInterval? {
        guard let after = after.appearanceDuration, let before = before.appearanceDuration else { return nil }
        return after - before
    }
    public var requiresConfirmation: Bool {
        !before.timingComplete || !after.timingComplete
            || before.score != after.score || before.matchDuration != after.matchDuration
            || before.appearanceDuration != after.appearanceDuration || before.state != after.state
            || before.excludedAfterEndEventIDs != after.excludedAfterEndEventIDs
            || before.personalGoals != after.personalGoals || before.personalAssists != after.personalAssists
            || before.onFieldScore != after.onFieldScore || before.diagnostics != after.diagnostics
    }
}

/// These functions propose immutable facts; they do not save them, mutate health samples, or release locks.
/// The authenticated application boundary supplies phone edit / exceptional-termination authorization.
public enum PostMatchEditor {
    public static func revise(eventID: String, newEventID: String, descriptor: MatchDescriptor,
        events: [MatchEvent], occurredAt: Date? = nil, goal: GoalPayload? = nil, delete: Bool = false,
        sourceDeviceID: String, now: Date) throws -> MatchEvent {
        let result = try CommandFacts.requireEnded(descriptor: descriptor, events: events, now: now)
        try CommandFacts.validateNewID(newEventID, events: events)
        guard let target = events.first(where: { $0.eventID == eventID }),
              !events.contains(where: { $0.correctionOfEventID == eventID }) else { throw MatchCommandError.staleRevision }
        guard target.type != .matchTerminated else { throw MatchCommandError.immutableAbnormalTermination }
        if delete && (target.type == .matchStarted || target.type == .matchEnded) { throw MatchCommandError.immutableLifecycleDeletion }
        let date = occurredAt ?? target.occurredAt
        guard date.timeIntervalSince1970.isFinite, date <= now, target.revision < Int.max else { throw MatchCommandError.invalidTime }
        let sequence = try CommandFacts.nextSequence(events)
        func revision(elapsed: TimeInterval) -> MatchEvent {
            MatchEvent(eventID: newEventID, matchID: descriptor.matchID,
                sequence: sequence, occurredAt: date, matchElapsed: elapsed,
                type: target.type, sourceDeviceID: sourceDeviceID, createdAt: now, updatedAt: now,
                status: delete ? .deleted : .active, correctionOfEventID: eventID, revision: target.revision + 1,
                authority: .postMatch, goal: goal ?? target.goal, quickAction: target.quickAction)
        }
        guard let originalElapsed = result.elapsed(at: date) else { throw MatchCommandError.invalidTime }
        let provisional = revision(elapsed: originalElapsed)
        let recomputed = MatchReplay.replay(descriptor: descriptor, events: events + [provisional], now: now)
        if (target.type == .matchStarted || target.type == .matchEnded) && recomputed.state == .conflict {
            throw MatchCommandError.invalidTime
        }
        guard let correctedElapsed = recomputed.elapsed(at: date) else { throw MatchCommandError.invalidTime }
        return revision(elapsed: correctedElapsed)
    }

    public static func insertScore(eventID: String, descriptor: MatchDescriptor, events: [MatchEvent],
        occurredAt: Date, goal: GoalPayload, sourceDeviceID: String, now: Date) throws -> MatchEvent {
        let result = try CommandFacts.requireEnded(descriptor: descriptor, events: events, now: now)
        try CommandFacts.validateNewID(eventID, events: events)
        guard occurredAt.timeIntervalSince1970.isFinite, occurredAt <= now else { throw MatchCommandError.invalidTime }
        guard let elapsed = result.elapsed(at: occurredAt) else { throw MatchCommandError.invalidTime }
        return MatchEvent(eventID: eventID, matchID: descriptor.matchID, sequence: try CommandFacts.nextSequence(events),
            occurredAt: occurredAt, matchElapsed: elapsed, type: .scoreEvent,
            sourceDeviceID: sourceDeviceID, createdAt: now, updatedAt: now, authority: .postMatch, goal: goal)
    }

    public static func terminateAbnormally(terminationID: String, descriptor: MatchDescriptor,
        events: [MatchEvent], sourceDeviceID: String, now: Date) throws -> MatchEvent {
        guard !terminationID.isEmpty else { throw MatchCommandError.invalidEvent }
        if let existing = events.first(where: { $0.terminationID == terminationID && $0.type == .matchTerminated }) {
            guard existing.matchID == descriptor.matchID, existing.authority == .abnormalTermination,
                  existing.sourceDeviceID == sourceDeviceID else { throw MatchCommandError.invalidEvent }
            return existing
        }
        try CommandFacts.validateTime(now, events: events)
        let result = MatchReplay.replay(descriptor: descriptor, events: events, now: now)
        let missingStart = result.state == .notStarted && !events.contains(where: { $0.type == .matchStarted })
        guard result.state == .running || result.state == .paused || missingStart else { throw MatchCommandError.requiresActiveMatch }
        let id = "termination-" + terminationID
        try CommandFacts.validateNewID(id, events: events)
        return MatchEvent(eventID: id, matchID: descriptor.matchID, sequence: try CommandFacts.nextSequence(events),
            occurredAt: now, matchElapsed: result.matchDuration, type: .matchTerminated,
            sourceDeviceID: sourceDeviceID, createdAt: now, updatedAt: now,
            authority: .abnormalTermination, terminationID: terminationID)
    }

    public static func preview(descriptor: MatchDescriptor, events: [MatchEvent], adding proposed: [MatchEvent], now: Date) -> ReplayImpact {
        ReplayImpact(before: MatchReplay.replay(descriptor: descriptor, events: events, now: now),
                     after: MatchReplay.replay(descriptor: descriptor, events: events + proposed, now: now))
    }
}
