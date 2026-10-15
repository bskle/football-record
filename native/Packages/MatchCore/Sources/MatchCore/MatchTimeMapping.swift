import Foundation

public enum RealTimeMapping: Sendable, Equatable { case unique(Date), requiresExplicitOccurredAt, outsideMatch }
public enum MatchTimeMapping {
    /// Pauses create multiple wall-clock instants for the same match time. Never guess which is intended.
    public static func realTime(forElapsed elapsed: TimeInterval, in replay: ReplayResult) -> RealTimeMapping {
        guard let duration = replay.matchDuration, elapsed.isFinite, elapsed >= 0, elapsed <= duration else { return .outsideMatch }
        var accumulated: TimeInterval = 0
        var candidates: Set<Date> = []
        for interval in replay.runningIntervals {
            if elapsed >= accumulated && elapsed <= accumulated + interval.duration {
                candidates.insert(interval.start.addingTimeInterval(elapsed - accumulated))
            }
            accumulated += interval.duration
        }
        for pause in replay.pausedIntervals where pause.duration > 0 {
            if let frozen = replay.elapsed(at: pause.start), abs(frozen - elapsed) < 0.001 { return .requiresExplicitOccurredAt }
        }
        guard candidates.count == 1, let date = candidates.first else {
            return candidates.isEmpty ? .outsideMatch : .requiresExplicitOccurredAt
        }
        return .unique(date)
    }
}
