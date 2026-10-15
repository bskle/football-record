import Foundation

public enum MatchCommandError: Error, Sendable, Equatable {
    case wrongRecordingDevice, startPermitRequired, alreadyStarted, requiresActiveMatch, requiresEndedMatch
    case debounced, noUndoableQuickRecord, duplicateEventID, invalidEvent, invalidTime, staleRevision
    case immutableAbnormalTermination, immutableLifecycleDeletion
}

/// A staging value, not a repository. Mutate a copy, persist its new facts transactionally, then adopt
/// the copy and give success feedback. A thrown command never changes this value.
public struct LiveMatchRecorder: Sendable {
    public let descriptor: MatchDescriptor
    public private(set) var events: [MatchEvent]
    public private(set) var lastUndoableQuickEventID: String?
    private var lastQuickAt: Date?
    public init(descriptor: MatchDescriptor, events: [MatchEvent] = []) {
        self.descriptor = descriptor; self.events = events
        // Restore only the last quick intent. Undo never reveals an older quick record to undo.
        let terminalExists = events.contains { $0.type == .matchEnded || $0.type == .matchTerminated }
        let latestQuick = events.filter { $0.quickAction != nil && $0.correctionOfEventID == nil }
            .max { $0.sequence < $1.sequence }
        if !terminalExists, let latestQuick,
           EventResolver.resolve(events, descriptor: descriptor).events.contains(where: { $0.eventID == latestQuick.eventID }) {
            lastUndoableQuickEventID = latestQuick.eventID; lastQuickAt = latestQuick.createdAt
        }
    }

    @discardableResult public mutating func start(eventID: String, sourceDeviceID: String, now: Date) throws -> MatchEvent {
        try requireDevice(sourceDeviceID)
        guard descriptor.startPermit?.matches(descriptor.startIntent) == true else { throw MatchCommandError.startPermitRequired }
        guard !events.contains(where: { $0.type == .matchEnded || $0.type == .matchTerminated }) else {
            throw MatchCommandError.requiresActiveMatch
        }
        guard !events.contains(where: { $0.type == .matchStarted }) else { throw MatchCommandError.alreadyStarted }
        let event = try make(eventID: eventID, type: .matchStarted, source: sourceDeviceID, now: now, elapsed: 0)
        events.append(event); return event
    }

    @discardableResult public mutating func recordQuick(_ action: QuickRecordAction, eventID: String,
        sourceDeviceID: String, now: Date, scoringTeamSnapshot: String? = nil) throws -> MatchEvent {
        let result = try requireActive(source: sourceDeviceID, now: now)
        if let lastQuickAt, now.timeIntervalSince(lastQuickAt) < 1 { throw MatchCommandError.debounced }
        guard let elapsed = result.matchDuration else { throw MatchCommandError.invalidTime }
        let payload = GoalPayload(scoreImpact: action == .conceded ? .against : .forTeam,
            scoringTeamSnapshot: scoringTeamSnapshot ?? (action == .conceded ? "对方" : "我方"),
            scorerSnapshot: action == .myGoal ? .selfPlayer : nil,
            assisterSnapshot: action == .myAssist ? .selfPlayer : nil)
        let event = try make(eventID: eventID, type: .scoreEvent, source: sourceDeviceID, now: now,
            elapsed: elapsed, goal: payload, quickAction: action)
        events.append(event); lastUndoableQuickEventID = eventID; lastQuickAt = now
        return event
    }

    @discardableResult public mutating func transition(_ type: MatchEventType, eventID: String,
        sourceDeviceID: String, now: Date) throws -> MatchEvent {
        guard [.matchPaused, .matchResumed, .enteredField, .leftField, .matchEnded].contains(type) else {
            throw MatchCommandError.invalidEvent
        }
        let result = try requireActive(source: sourceDeviceID, now: now)
        guard let elapsed = result.matchDuration else { throw MatchCommandError.invalidTime }
        let event = try make(eventID: eventID, type: type, source: sourceDeviceID, now: now, elapsed: elapsed)
        events.append(event)
        if type == .matchEnded { lastUndoableQuickEventID = nil; lastQuickAt = nil }
        return event
    }

    @discardableResult public mutating func undoLastQuick(eventID: String, sourceDeviceID: String, now: Date) throws -> MatchEvent {
        _ = try requireActive(source: sourceDeviceID, now: now)
        guard let targetID = lastUndoableQuickEventID, let target = events.first(where: { $0.eventID == targetID }) else {
            throw MatchCommandError.noUndoableQuickRecord
        }
        try CommandFacts.validateNewID(eventID, events: events)
        let deletion = MatchEvent(eventID: eventID, matchID: descriptor.matchID,
            sequence: try CommandFacts.nextSequence(events), occurredAt: target.occurredAt,
            matchElapsed: target.matchElapsed, type: .scoreEvent, sourceDeviceID: sourceDeviceID,
            createdAt: now, updatedAt: now, status: .deleted, correctionOfEventID: target.eventID,
            revision: target.revision + 1, goal: target.goal, quickAction: target.quickAction)
        events.append(deletion); lastUndoableQuickEventID = nil; lastQuickAt = nil
        return deletion
    }

    private func requireDevice(_ source: String) throws {
        guard source == descriptor.recordingDeviceID else { throw MatchCommandError.wrongRecordingDevice }
    }
    private func requireActive(source: String, now: Date) throws -> ReplayResult {
        try requireDevice(source)
        try CommandFacts.validateTime(now, events: events)
        let result = MatchReplay.replay(descriptor: descriptor, events: events, now: now)
        guard result.state == .running || result.state == .paused else { throw MatchCommandError.requiresActiveMatch }
        return result
    }
    private func make(eventID: String, type: MatchEventType, source: String, now: Date,
                      elapsed: TimeInterval, goal: GoalPayload? = nil, quickAction: QuickRecordAction? = nil) throws -> MatchEvent {
        try CommandFacts.validateNewID(eventID, events: events)
        try CommandFacts.validateTime(now, events: events)
        return MatchEvent(eventID: eventID, matchID: descriptor.matchID, sequence: try CommandFacts.nextSequence(events),
            occurredAt: now, matchElapsed: elapsed, type: type, sourceDeviceID: source,
            createdAt: now, updatedAt: now, goal: goal, quickAction: quickAction)
    }
}

enum CommandFacts {
    static func nextSequence(_ events: [MatchEvent]) throws -> Int {
        let maximum = events.map(\.sequence).max() ?? -1
        guard maximum < Int.max else { throw MatchCommandError.invalidEvent }
        return maximum + 1
    }
    static func validateNewID(_ id: String, events: [MatchEvent]) throws {
        guard !id.isEmpty else { throw MatchCommandError.invalidEvent }
        guard !events.contains(where: { $0.eventID == id }) else { throw MatchCommandError.duplicateEventID }
    }
    static func validateTime(_ now: Date, events: [MatchEvent]) throws {
        guard now.timeIntervalSince1970.isFinite,
              events.allSatisfy({ $0.createdAt <= now && $0.occurredAt <= now }) else {
            throw MatchCommandError.invalidTime
        }
    }
    static func requireEnded(descriptor: MatchDescriptor, events: [MatchEvent], now: Date) throws -> ReplayResult {
        try validateTime(now, events: events)
        let result = MatchReplay.replay(descriptor: descriptor, events: events, now: now)
        guard result.state == .endedPendingSync || result.state == .completed || result.state == .incomplete else { throw MatchCommandError.requiresEndedMatch }
        return result
    }
}
