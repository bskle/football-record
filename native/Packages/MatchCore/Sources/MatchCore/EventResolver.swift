import Foundation

struct EventOrderKey {
    let sequence: Int
    let rootEventID: String
    let sourceDeviceID: String
}
struct ResolvedEvents {
    var events: [MatchEvent]
    var diagnostics: [ReplayDiagnostic]
    var orderKeys: [String: EventOrderKey]
    func ordered(_ lhs: MatchEvent, _ rhs: MatchEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        let left = orderKeys[lhs.eventID] ?? EventOrderKey(sequence: lhs.sequence, rootEventID: lhs.eventID, sourceDeviceID: lhs.sourceDeviceID)
        let right = orderKeys[rhs.eventID] ?? EventOrderKey(sequence: rhs.sequence, rootEventID: rhs.eventID, sourceDeviceID: rhs.sourceDeviceID)
        if left.sequence != right.sequence { return left.sequence < right.sequence }
        if left.sourceDeviceID != right.sourceDeviceID { return left.sourceDeviceID < right.sourceDeviceID }
        return left.rootEventID < right.rootEventID
    }
}

private struct WriterSequence: Hashable {
    let sourceDeviceID: String
    let sequence: Int
}
enum EventResolver {
    static func resolve(_ input: [MatchEvent], descriptor: MatchDescriptor) -> ResolvedEvents {
        var diagnostics: [ReplayDiagnostic] = []
        var unique: [String: MatchEvent] = [:]
        for (id, copies) in Dictionary(grouping: input, by: \.eventID).sorted(by: { $0.key < $1.key }) {
            guard let first = copies.first else { continue }
            if copies.allSatisfy({ $0 == first }) { unique[id] = first }
            else { diagnostics.append(ReplayDiagnostic(.conflictingEventID, [id], conflict: true)) }
        }
        for group in Dictionary(grouping: unique.values, by: { WriterSequence(sourceDeviceID: $0.sourceDeviceID, sequence: $0.sequence) }).values where group.count > 1 {
            diagnostics.append(ReplayDiagnostic(.duplicateSequence, group.map(\.eventID), conflict: true))
        }
        var invalid: Set<String> = []
        for group in Dictionary(grouping: unique.values.filter { $0.terminationID != nil }, by: { $0.terminationID! }).values where group.count > 1 {
            diagnostics.append(ReplayDiagnostic(.duplicateTermination, group.map(\.eventID), conflict: true))
            invalid.formUnion(group.map(\.eventID))
        }
        let hasTerminal = unique.values.contains { ($0.type == .matchEnded || $0.type == .matchTerminated)
            && $0.status == .active && $0.correctionOfEventID == nil }
        for event in unique.values {
            let id = event.eventID
            if id.isEmpty || event.sourceDeviceID.isEmpty || event.matchID != descriptor.matchID || event.sequence < 0
                || !event.occurredAt.timeIntervalSince1970.isFinite
                || (event.matchElapsed == nil && event.type != .matchTerminated)
                || event.matchElapsed.map({ !$0.isFinite || $0 < 0 }) == true || !event.createdAt.timeIntervalSince1970.isFinite
                || !event.updatedAt.timeIntervalSince1970.isFinite || event.updatedAt < event.createdAt
                || (event.type == .scoreEvent) != (event.goal != nil) {
                invalid.insert(id); diagnostics.append(ReplayDiagnostic(.invalidEvent, [id], conflict: true))
            }
            let liveAllowed = event.authority == .live && event.sourceDeviceID == descriptor.recordingDeviceID
                && event.type != .matchTerminated
            let correctionAllowed = event.authority == .postMatch && hasTerminal
                && event.type != .matchTerminated && (event.type != .matchStarted || event.correctionOfEventID != nil)
            let terminationAllowed = event.authority == .abnormalTermination && event.type == .matchTerminated
                && event.terminationID?.isEmpty == false && event.correctionOfEventID == nil && event.revision == 0
            if !(liveAllowed || correctionAllowed || terminationAllowed) {
                invalid.insert(id); diagnostics.append(ReplayDiagnostic(.unauthorizedWriter, [id], conflict: true))
            }
        }
        let children = Dictionary(grouping: unique.values.filter { $0.correctionOfEventID != nil },
                                  by: { $0.correctionOfEventID! })
        for event in unique.values {
            var valid = true
            if let parentID = event.correctionOfEventID {
                if let parent = unique[parentID] {
                    valid = parent.revision < Int.max && event.revision == parent.revision + 1 && event.type == parent.type
                        && parent.type != .matchTerminated
                        && (event.authority == .postMatch || (event.authority == .live
                            && event.type == .scoreEvent && event.status == .deleted))
                } else { valid = false }
            } else { valid = event.revision == 0 && event.status == .active }
            if children[event.eventID, default: []].count > 1 { valid = false }
            if event.status == .deleted && (event.type == .matchStarted || event.type == .matchEnded) { valid = false }
            var visited: Set<String> = []
            var cursor: MatchEvent? = event
            while let node = cursor {
                if !visited.insert(node.eventID).inserted { valid = false; break }
                cursor = node.correctionOfEventID.flatMap { unique[$0] }
            }
            if !valid {
                invalid.insert(event.eventID)
                diagnostics.append(ReplayDiagnostic(.invalidRevision, [event.eventID], conflict: true))
            }
        }
        // A malformed or ambiguous revision invalidates its whole connected lineage; no winner is guessed.
        var pending = Array(invalid)
        while let id = pending.popLast() {
            let neighbors = children[id, default: []].map(\.eventID)
                + (unique[id]?.correctionOfEventID.map { [$0] } ?? [])
            for neighbor in neighbors where invalid.insert(neighbor).inserted { pending.append(neighbor) }
        }
        let effective = unique.values.filter {
            !invalid.contains($0.eventID) && children[$0.eventID, default: []].isEmpty && $0.status == .active
        }
        var orderKeys: [String: EventOrderKey] = [:]
        for event in effective {
            var root = event
            while let parentID = root.correctionOfEventID, let parent = unique[parentID] { root = parent }
            orderKeys[event.eventID] = EventOrderKey(sequence: root.sequence, rootEventID: root.eventID, sourceDeviceID: root.sourceDeviceID)
        }
        var resolved = ResolvedEvents(events: Array(effective), diagnostics: diagnostics, orderKeys: orderKeys)
        resolved.events.sort(by: resolved.ordered)
        return resolved
    }
}
