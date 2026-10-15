import Foundation

public enum MatchReplay {
    /// Pure replay: no timers, storage, health mutation, network calls, or backend lock transitions.
    public static func replay(descriptor: MatchDescriptor, events: [MatchEvent], now: Date,
                              completionEvidence: TrustedCompletionEvidence? = nil) -> ReplayResult {
        var result = ReplayResult(descriptor: descriptor)
        let resolved = EventResolver.resolve(events, descriptor: descriptor)
        result.effectiveEvents = resolved.events
        result.diagnostics = resolved.diagnostics
        let knownAbnormal = resolved.events.first { $0.type == .matchTerminated && $0.occurredAt <= now }
        guard descriptor.startPermit?.matches(descriptor.startIntent) == true else {
            result.diagnostics.append(ReplayDiagnostic(.missingPermit))
            return finishWithoutStart(result, resolved: resolved, abnormal: knownAbnormal, now: now)
        }
        guard let start = resolved.events.first(where: { $0.type == .matchStarted && $0.occurredAt <= now }) else {
            return finishWithoutStart(result, resolved: resolved, abnormal: knownAbnormal, now: now)
        }
        for terminal in resolved.events where (terminal.type == .matchTerminated || terminal.type == .matchEnded)
            && (terminal.occurredAt < start.occurredAt || terminal.occurredAt > now) {
            result.diagnostics.append(ReplayDiagnostic(.invalidEvent, [terminal.eventID, start.eventID], conflict: true))
        }
        // An abnormal termination is an irrevocable incomplete fact in this version. Ordinary late end
        // packets can add history but cannot complete or reactivate it. An explicit future repair flow is separate.
        let abnormal = resolved.events.first { $0.type == .matchTerminated && $0.occurredAt >= start.occurredAt && $0.occurredAt <= now }
        let normalEnd = resolved.events.first { $0.type == .matchEnded && $0.occurredAt >= start.occurredAt && $0.occurredAt <= now }
        let terminal = abnormal ?? normalEnd
        let limit = terminal?.occurredAt ?? max(start.occurredAt, now)
        var runningSince: Date? = start.occurredAt
        var pausedSince: Date?
        var fieldSince: Date? = descriptor.starter ? start.occurredAt : nil
        var onField = descriptor.starter
        for event in resolved.events {
            if event.occurredAt < start.occurredAt || (event.occurredAt == start.occurredAt && resolved.ordered(event, start)) {
                result.diagnostics.append(ReplayDiagnostic(.beforeStart, [event.eventID])); continue
            }
            if event.occurredAt > now {
                result.diagnostics.append(ReplayDiagnostic(.futureEvent, [event.eventID])); continue
            }
            if let terminal, resolved.ordered(terminal, event) {
                result.excludedAfterEndEventIDs.append(event.eventID)
                result.diagnostics.append(ReplayDiagnostic(.afterEnd, [event.eventID])); continue
            }
            switch event.type {
            case .matchStarted:
                if event.eventID != start.eventID {
                    result.diagnostics.append(ReplayDiagnostic(.duplicateStart, [event.eventID], conflict: true))
                }
            case .matchPaused:
                if let since = runningSince {
                    result.runningIntervals.append(MatchInterval(start: since, end: event.occurredAt))
                    runningSince = nil; pausedSince = event.occurredAt
                } else { result.diagnostics.append(ReplayDiagnostic(.duplicatePauseTransition, [event.eventID])) }
            case .matchResumed:
                if let since = pausedSince {
                    result.pausedIntervals.append(MatchInterval(start: since, end: event.occurredAt))
                    pausedSince = nil; runningSince = event.occurredAt
                } else { result.diagnostics.append(ReplayDiagnostic(.duplicatePauseTransition, [event.eventID])) }
            case .enteredField:
                if onField { result.diagnostics.append(ReplayDiagnostic(.duplicateFieldTransition, [event.eventID])) }
                else { onField = true; fieldSince = event.occurredAt }
            case .leftField:
                if let since = fieldSince, onField {
                    result.fieldIntervals.append(MatchInterval(start: since, end: event.occurredAt))
                    onField = false; fieldSince = nil
                } else { result.diagnostics.append(ReplayDiagnostic(.duplicateFieldTransition, [event.eventID])) }
            case .scoreEvent:
                if let goal = event.goal {
                    result.score.add(goal.scoreImpact)
                    if onField { result.onFieldScore.add(goal.scoreImpact) }
                    if goal.goalKind == .normal && goal.scoreImpact == .forTeam {
                        if goal.scorerSnapshot?.isSelf == true { result.personalGoals += 1 }
                        if goal.assisterSnapshot?.isSelf == true { result.personalAssists += 1 }
                    }
                }
            case .matchEnded, .matchTerminated, .warmupStarted, .warmupEnded, .stretchingStarted, .stretchingEnded:
                break
            }
        }
        if let since = runningSince { result.runningIntervals.append(MatchInterval(start: since, end: limit)) }
        if let since = pausedSince { result.pausedIntervals.append(MatchInterval(start: since, end: limit)) }
        if let since = fieldSince { result.fieldIntervals.append(MatchInterval(start: since, end: limit)) }
        result.matchDuration = result.runningIntervals.reduce(0) { $0 + $1.duration }
        result.appearanceDuration = result.fieldIntervals.reduce(0) { total, field in
            total + result.runningIntervals.reduce(0) { sum, running in
                sum + max(0, min(field.end, running.end).timeIntervalSince(max(field.start, running.start)))
            }
        }
        result.isOnField = terminal == nil && onField
        result.state = abnormal != nil ? .incomplete : normalEnd != nil ? .endedPendingSync : pausedSince != nil ? .paused : .running
        if result.state == .endedPendingSync, let normalEnd, let completionEvidence {
            if completionEvidence.matches(descriptor: descriptor, events: events, terminal: normalEnd) {
                result.state = .completed
            } else { result.diagnostics.append(ReplayDiagnostic(.staleCompletionEvidence)) }
        }
        // Stored matchElapsed remains an audit snapshot; corrections change derived elapsed without rewriting it.
        for event in resolved.events where event.occurredAt >= start.occurredAt && event.occurredAt <= limit {
            if let snapshot = event.matchElapsed, let derived = result.elapsed(at: event.occurredAt), abs(snapshot - derived) > 0.001 {
                result.diagnostics.append(ReplayDiagnostic(.elapsedMismatch, [event.eventID]))
            }
        }
        return finish(result)
    }

    private static func finishWithoutStart(_ input: ReplayResult, resolved: ResolvedEvents,
                                           abnormal: MatchEvent?, now: Date) -> ReplayResult {
        var result = input
        result.diagnostics.append(ReplayDiagnostic(.missingStart))
        if let abnormal {
            result.state = .incomplete
            for event in resolved.events {
                if resolved.ordered(abnormal, event) {
                    result.excludedAfterEndEventIDs.append(event.eventID)
                    result.diagnostics.append(ReplayDiagnostic(.afterEnd, [event.eventID]))
                } else if event.occurredAt <= now, let goal = event.goal {
                    // Known score facts survive a missing start; timing and on-field attribution stay unknown.
                    result.score.add(goal.scoreImpact)
                    if goal.goalKind == .normal && goal.scoreImpact == .forTeam {
                        if goal.scorerSnapshot?.isSelf == true { result.personalGoals += 1 }
                        if goal.assisterSnapshot?.isSelf == true { result.personalAssists += 1 }
                    }
                }
            }
        } else if resolved.events.contains(where: { $0.type == .matchEnded }) {
            result.diagnostics.append(ReplayDiagnostic(.invalidEvent, conflict: true))
        }
        return finish(result)
    }

    private static func finish(_ input: ReplayResult) -> ReplayResult {
        var result = input
        if result.diagnostics.contains(where: \.isConflict) { result.state = .conflict }
        result.diagnostics.sort {
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            return $0.eventIDs.lexicographicallyPrecedes($1.eventIDs)
        }
        return result
    }
}
