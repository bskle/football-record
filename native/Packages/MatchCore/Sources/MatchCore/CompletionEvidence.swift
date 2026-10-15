import CryptoKit
import Foundation

public enum CompletionEvidenceError: Error, Sendable { case requiresNormallyEndedTimeline, invalidConfirmation }

/// Assertion from a trusted complete-save / durable ACK adapter. MatchCore does not perform the
/// save or ACK verification. Never accept an unverified decoded object as evidence.
public struct TrustedCompletionEvidence: Codable, Sendable, Equatable {
    public let matchID: String
    public let terminalEventID: String
    public let timelineVersion: String
    public let confirmationID: String
    public static func acceptedByCompleteSaveBoundary(descriptor: MatchDescriptor, events: [MatchEvent],
        confirmationID: String, now: Date) throws -> Self {
        guard !confirmationID.isEmpty else { throw CompletionEvidenceError.invalidConfirmation }
        let replay = MatchReplay.replay(descriptor: descriptor, events: events, now: now)
        guard replay.state == .endedPendingSync,
              let terminal = replay.effectiveEvents.first(where: { $0.type == .matchEnded }),
              let version = version(descriptor: descriptor, events: events) else {
            throw CompletionEvidenceError.requiresNormallyEndedTimeline
        }
        return Self(matchID: descriptor.matchID, terminalEventID: terminal.eventID,
                    timelineVersion: version, confirmationID: confirmationID)
    }
    func matches(descriptor: MatchDescriptor, events: [MatchEvent], terminal: MatchEvent) -> Bool {
        matchID == descriptor.matchID && terminalEventID == terminal.eventID && !confirmationID.isEmpty
            && timelineVersion == Self.version(descriptor: descriptor, events: events)
    }
    private struct Timeline: Encodable {
        let intent: StartIntent
        let starter: Bool
        let permit: TrustedStartPermit?
        let events: [MatchEvent]
    }
    private static func version(descriptor: MatchDescriptor, events: [MatchEvent]) -> String? {
        // Retransmission and arrival order do not alter the version; every immutable revision does.
        var byID: [String: MatchEvent] = [:]
        for event in events {
            if let existing = byID[event.eventID], existing != event { return nil }
            byID[event.eventID] = event
        }
        let timeline = Timeline(intent: descriptor.startIntent, starter: descriptor.starter,
            permit: descriptor.startPermit, events: byID.values.sorted { $0.eventID < $1.eventID })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(timeline) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
