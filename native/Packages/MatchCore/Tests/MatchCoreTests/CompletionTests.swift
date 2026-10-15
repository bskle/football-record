import XCTest
@testable import MatchCore

final class CompletionTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func ended(lock: BackendLockState = .unknown) throws -> LiveMatchRecorder {
        let intent = StartIntent(id: "intent", matchID: "match", recordingDeviceID: "watch", requestedAt: t)
        let descriptor = MatchDescriptor(startIntent: intent, starter: true,
            startPermit: .acceptedByTrustedNetworkBoundary(for: intent, permitID: "verified-permit"), backendLockState: lock)
        var recorder = LiveMatchRecorder(descriptor: descriptor)
        _ = try recorder.start(eventID: "start", sourceDeviceID: "watch", now: t)
        _ = try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: t.addingTimeInterval(20))
        return recorder
    }
    func testNormalLocalEndStaysPendingUntilTrustedCurrentVersionCompleteSaveEvidence() throws {
        let recorder = try ended()
        let now = t.addingTimeInterval(30)
        let pending = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events, now: now)
        XCTAssertEqual(pending.state, .endedPendingSync)
        XCTAssertFalse(pending.career.includeRecordedMatch)
        let proof = try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: recorder.descriptor,
            events: recorder.events, confirmationID: "durable-ack-1", now: now)
        let completed = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events, now: now, completionEvidence: proof)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(completed.career.includeAppearance)
        XCTAssertEqual(completed.backendLockState, .unknown)
        XCTAssertEqual(try JSONDecoder().decode(TrustedCompletionEvidence.self,
            from: JSONEncoder().encode(proof)), proof)
    }
    func testOldTimelineEvidenceCannotCompleteChangedFactsEvenIfFinalScoreUnchanged() throws {
        let recorder = try ended()
        let now = t.addingTimeInterval(30)
        let proof = try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: recorder.descriptor,
            events: recorder.events, confirmationID: "old", now: now)
        let end = try PostMatchEditor.revise(eventID: "end", newEventID: "end-v1", descriptor: recorder.descriptor,
            events: recorder.events, occurredAt: t.addingTimeInterval(15), sourceDeviceID: "phone", now: now)
        let result = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events + [end], now: now, completionEvidence: proof)
        XCTAssertEqual(result.state, .endedPendingSync)
        XCTAssertFalse(result.career.includeWinRate)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .staleCompletionEvidence })
        let retransmitted = MatchReplay.replay(descriptor: recorder.descriptor,
            events: recorder.events.reversed() + [recorder.events[0]], now: now, completionEvidence: proof)
        XCTAssertEqual(retransmitted.state, .completed)
    }
    func testBackendReleaseCannotCompleteAndHeldLockDoesNotPreventCompletion() throws {
        let released = try ended(lock: .releasedConfirmed)
        let now = t.addingTimeInterval(30)
        XCTAssertEqual(MatchReplay.replay(descriptor: released.descriptor, events: released.events, now: now).state, .endedPendingSync)
        let held = try ended(lock: .held)
        let proof = try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: held.descriptor,
            events: held.events, confirmationID: "saved", now: now)
        let result = MatchReplay.replay(descriptor: held.descriptor, events: held.events, now: now, completionEvidence: proof)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.backendLockState, .held)
        // The same timeline remains complete when only the independently confirmed backend lock changes.
        XCTAssertEqual(MatchReplay.replay(descriptor: released.descriptor, events: released.events,
            now: now, completionEvidence: proof).state, .completed)
    }
    func testLifecycleDeletionAndReversedTimesAreRejectedAtEditorBoundary() throws {
        let recorder = try ended()
        for id in ["start", "end"] {
            XCTAssertThrowsError(try PostMatchEditor.revise(eventID: id, newEventID: id + "-deleted", descriptor: recorder.descriptor,
                events: recorder.events, delete: true, sourceDeviceID: "phone", now: t.addingTimeInterval(30)))
        }
        XCTAssertThrowsError(try PostMatchEditor.revise(eventID: "end", newEventID: "early", descriptor: recorder.descriptor,
            events: recorder.events, occurredAt: t.addingTimeInterval(-1), sourceDeviceID: "phone", now: t.addingTimeInterval(30)))
        XCTAssertThrowsError(try PostMatchEditor.revise(eventID: "start", newEventID: "late", descriptor: recorder.descriptor,
            events: recorder.events, occurredAt: t.addingTimeInterval(25), sourceDeviceID: "phone", now: t.addingTimeInterval(30)))
    }
    func testImportedLifecycleDeletionOrReversedTimesCannotReactivateRecorder() throws {
        let recorder = try ended()
        let cases: [(String, Date, EventStatus)] = [
            ("start", t, .deleted), ("end", t.addingTimeInterval(20), .deleted),
            ("end", t.addingTimeInterval(-1), .active), ("start", t.addingTimeInterval(25), .active),
            ("end", t.addingTimeInterval(40), .active)
        ]
        for (id, occurredAt, status) in cases {
            let target = try XCTUnwrap(recorder.events.first { $0.eventID == id })
            let correction = MatchEvent(eventID: id + "-v1", matchID: "match", sequence: 2,
                occurredAt: occurredAt, matchElapsed: 0, type: target.type, sourceDeviceID: "phone",
                createdAt: t.addingTimeInterval(30), updatedAt: t.addingTimeInterval(30), status: status,
                correctionOfEventID: id, revision: 1, authority: .postMatch)
            let facts = recorder.events + [correction]
            let result = MatchReplay.replay(descriptor: recorder.descriptor, events: facts, now: t.addingTimeInterval(30))
            XCTAssertEqual(result.state, .conflict, "unsafe correction of " + id)
            var restored = LiveMatchRecorder(descriptor: recorder.descriptor, events: facts)
            XCTAssertThrowsError(try restored.recordQuick(.teamGoal, eventID: "revived", sourceDeviceID: "watch", now: t.addingTimeInterval(50)))
        }
    }
    func testPhonePartialLogTerminationAllowsUnseenWatchSequenceToArriveLater() throws {
        let completedRecorder = try ended()
        let descriptor = completedRecorder.descriptor
        var watch = LiveMatchRecorder(descriptor: descriptor, events: [completedRecorder.events[0]])
        let unseen = try watch.recordQuick(.teamGoal, eventID: "offline-goal", sourceDeviceID: "watch", now: t.addingTimeInterval(5))
        let terminal = try PostMatchEditor.terminateAbnormally(terminationID: "phone-intent", descriptor: descriptor,
            events: [completedRecorder.events[0]], sourceDeviceID: "phone", now: t.addingTimeInterval(10))
        XCTAssertEqual(unseen.sequence, terminal.sequence)
        let result = MatchReplay.replay(descriptor: descriptor, events: [completedRecorder.events[0], terminal, unseen], now: t.addingTimeInterval(20))
        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.score.forTeam, 1)
        XCTAssertEqual(result.recordingDeviceID, "watch")
        XCTAssertFalse(result.diagnostics.contains { $0.code == .duplicateSequence })
        XCTAssertNoThrow(try PostMatchEditor.revise(eventID: unseen.eventID, newEventID: "fixed", descriptor: descriptor,
            events: [completedRecorder.events[0], terminal, unseen], delete: true, sourceDeviceID: "phone", now: t.addingTimeInterval(20)))
    }
    func testMissingStartAbnormalTerminationKeepsUnknownTimingUntilLateFactsArrive() throws {
        let original = try ended()
        let descriptor = original.descriptor
        let terminal = try PostMatchEditor.terminateAbnormally(terminationID: "empty-phone-log", descriptor: descriptor,
            events: [], sourceDeviceID: "phone", now: t.addingTimeInterval(10))
        let incomplete = MatchReplay.replay(descriptor: descriptor, events: [terminal], now: t.addingTimeInterval(20))
        XCTAssertEqual(incomplete.state, .incomplete)
        XCTAssertNil(terminal.matchElapsed)
        var revived = LiveMatchRecorder(descriptor: descriptor, events: [terminal])
        XCTAssertThrowsError(try revived.start(eventID: "restart", sourceDeviceID: "watch", now: t.addingTimeInterval(20)))
        XCTAssertEqual(revived.events, [terminal])
        XCTAssertNil(incomplete.matchDuration)
        XCTAssertNil(incomplete.appearanceDuration)
        XCTAssertTrue(incomplete.diagnostics.contains { $0.code == .missingStart })
        XCTAssertEqual(incomplete.effectiveEvents.map(\.type), [.matchTerminated])
        XCTAssertFalse(incomplete.career.includeRecordedMatch)
        var watch = LiveMatchRecorder(descriptor: descriptor, events: [original.events[0]])
        let lateGoal = try watch.recordQuick(.myGoal, eventID: "late-goal", sourceDeviceID: "watch", now: t.addingTimeInterval(5))
        let restored = MatchReplay.replay(descriptor: descriptor, events: [terminal, lateGoal, original.events[0]], now: t.addingTimeInterval(20))
        XCTAssertEqual(restored.state, .incomplete)
        XCTAssertEqual(restored.matchDuration, 10)
        XCTAssertEqual(restored.appearanceDuration, 10)
        XCTAssertEqual(restored.score.forTeam, 1)
        XCTAssertEqual(restored.recordingDeviceID, "watch")
        XCTAssertNil(terminal.matchElapsed)
        XCTAssertFalse(restored.career.includeAppearance)
        let impact = PostMatchEditor.preview(descriptor: descriptor, events: [terminal], adding: [original.events[0], lateGoal], now: t.addingTimeInterval(20))
        XCTAssertNil(impact.appearanceDurationChange)
        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertEqual(MatchTimeMapping.realTime(forElapsed: 0, in: incomplete), .outsideMatch)
        XCTAssertTrue(PostMatchEditor.preview(descriptor: descriptor, events: [terminal], adding: [], now: t.addingTimeInterval(20)).requiresConfirmation)
    }

}
