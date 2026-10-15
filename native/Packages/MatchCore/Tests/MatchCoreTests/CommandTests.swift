import XCTest
@testable import MatchCore

final class CommandTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func descriptor(permit: Bool = true, matchID: String = "match") -> MatchDescriptor {
        let intent = StartIntent(id: "intent-" + matchID, matchID: matchID, recordingDeviceID: "watch", requestedAt: t)
        return MatchDescriptor(startIntent: intent, starter: true,
            startPermit: permit ? DevelopmentStartFixture.permit(for: intent) : nil)
    }
    func started() throws -> LiveMatchRecorder {
        var recorder = LiveMatchRecorder(descriptor: descriptor())
        _ = try recorder.start(eventID: "start", sourceDeviceID: "watch", now: t)
        return recorder
    }
    func testStartRequiresPermitAndOnlyBoundDeviceMayWrite() throws {
        var pending = LiveMatchRecorder(descriptor: descriptor(permit: false))
        XCTAssertThrowsError(try pending.start(eventID: "s", sourceDeviceID: "watch", now: t)) {
            XCTAssertEqual($0 as? MatchCommandError, .startPermitRequired)
        }
        var recorder = try started()
        XCTAssertThrowsError(try recorder.recordQuick(.myGoal, eventID: "g", sourceDeviceID: "phone", now: t)) {
            XCTAssertEqual($0 as? MatchCommandError, .wrongRecordingDevice)
        }
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.descriptor.startPermit?.evidence, .developmentSimulation)
    }
    func testFourQuickActionsAndCrossButtonOneSecondBoundary() throws {
        var recorder = try started()
        _ = try recorder.recordQuick(.myGoal, eventID: "g", sourceDeviceID: "watch", now: t.addingTimeInterval(1))
        XCTAssertThrowsError(try recorder.recordQuick(.myAssist, eventID: "too-soon", sourceDeviceID: "watch", now: t.addingTimeInterval(1.999))) {
            XCTAssertEqual($0 as? MatchCommandError, .debounced)
        }
        _ = try recorder.recordQuick(.myAssist, eventID: "a", sourceDeviceID: "watch", now: t.addingTimeInterval(2))
        _ = try recorder.recordQuick(.teamGoal, eventID: "team", sourceDeviceID: "watch", now: t.addingTimeInterval(3))
        _ = try recorder.recordQuick(.conceded, eventID: "against", sourceDeviceID: "watch", now: t.addingTimeInterval(4))
        let result = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events, now: t.addingTimeInterval(5))
        XCTAssertEqual(result.score, Score(forTeam: 3, against: 1))
        XCTAssertEqual(result.personalGoals, 1)
        XCTAssertEqual(result.personalAssists, 1)
        XCTAssertEqual(recorder.events.count, 5)
        XCTAssertEqual(recorder.events.last?.goal?.scoringTeamSnapshot, "对方")
    }
    func testUndoPersistsAcrossTimeAndReconstructionThenAllowsImmediateCorrection() throws {
        var recorder = try started()
        _ = try recorder.recordQuick(.myGoal, eventID: "wrong", sourceDeviceID: "watch", now: t.addingTimeInterval(1))
        recorder = LiveMatchRecorder(descriptor: recorder.descriptor, events: recorder.events)
        XCTAssertEqual(recorder.lastUndoableQuickEventID, "wrong")
        let deletion = try recorder.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: t.addingTimeInterval(100))
        XCTAssertEqual(deletion.correctionOfEventID, "wrong")
        XCTAssertEqual(deletion.status, .deleted)
        _ = try recorder.recordQuick(.myAssist, eventID: "fixed", sourceDeviceID: "watch", now: t.addingTimeInterval(100))
        let result = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events, now: t.addingTimeInterval(100))
        XCTAssertEqual(result.personalGoals, 0)
        XCTAssertEqual(result.personalAssists, 1)
        XCTAssertEqual(recorder.events.count, 4)
    }
    func testUndoWithinDebounceClearsGateAndEndOrNewMatchClearsUndo() throws {
        var recorder = try started()
        _ = try recorder.recordQuick(.teamGoal, eventID: "g", sourceDeviceID: "watch", now: t.addingTimeInterval(1))
        _ = try recorder.undoLastQuick(eventID: "u", sourceDeviceID: "watch", now: t.addingTimeInterval(1.1))
        _ = try recorder.recordQuick(.conceded, eventID: "g2", sourceDeviceID: "watch", now: t.addingTimeInterval(1.1))
        _ = try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: t.addingTimeInterval(2))
        XCTAssertNil(recorder.lastUndoableQuickEventID)
        XCTAssertThrowsError(try recorder.undoLastQuick(eventID: "u2", sourceDeviceID: "watch", now: t.addingTimeInterval(3)))
        XCTAssertThrowsError(try recorder.recordQuick(.teamGoal, eventID: "late", sourceDeviceID: "watch", now: t.addingTimeInterval(3)))
        XCTAssertNil(LiveMatchRecorder(descriptor: descriptor(matchID: "new")).lastUndoableQuickEventID)
    }
    func testPostMatchInsertionRevisionDeletionAndEarlierEndPreviewAreAppendOnly() throws {
        var recorder = try started()
        let goal = try recorder.recordQuick(.myGoal, eventID: "g", sourceDeviceID: "watch", now: t.addingTimeInterval(50))
        let end = try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: t.addingTimeInterval(100))
        let correction = try PostMatchEditor.revise(eventID: end.eventID, newEventID: "early", descriptor: recorder.descriptor,
            events: recorder.events, occurredAt: t.addingTimeInterval(40), sourceDeviceID: "phone", now: t.addingTimeInterval(120))
        let preview = PostMatchEditor.preview(descriptor: recorder.descriptor, events: recorder.events, adding: [correction], now: t.addingTimeInterval(120))
        XCTAssertEqual(preview.before.score.forTeam, 1)
        XCTAssertEqual(preview.after.score.forTeam, 0)
        XCTAssertEqual(preview.after.excludedAfterEndEventIDs, ["g"])
        XCTAssertEqual(preview.appearanceDurationChange, -60)
        XCTAssertTrue(preview.requiresConfirmation)
        let removed = try PostMatchEditor.revise(eventID: goal.eventID, newEventID: "deleted", descriptor: recorder.descriptor,
            events: recorder.events, delete: true, sourceDeviceID: "phone", now: t.addingTimeInterval(120))
        XCTAssertEqual(removed.status, .deleted)
        let inserted = try PostMatchEditor.insertScore(eventID: "inserted", descriptor: recorder.descriptor, events: recorder.events,
            occurredAt: t.addingTimeInterval(30), goal: GoalPayload(scoreImpact: .against, scoringTeamSnapshot: "B"),
            sourceDeviceID: "phone", now: t.addingTimeInterval(120))
        XCTAssertEqual(inserted.matchElapsed, 30)
        XCTAssertEqual(inserted.authority, .postMatch)
        XCTAssertEqual(recorder.events.count, 3)
    }
    func testPhoneCannotUsePostMatchEditingToTakeOverActiveRecording() throws {
        let recorder = try started()
        XCTAssertThrowsError(try PostMatchEditor.insertScore(eventID: "g", descriptor: recorder.descriptor, events: recorder.events,
            occurredAt: t, goal: GoalPayload(scoreImpact: .forTeam, scoringTeamSnapshot: "A"), sourceDeviceID: "phone", now: t)) {
            XCTAssertEqual($0 as? MatchCommandError, .requiresEndedMatch)
        }
    }
    func testAbnormalTerminationIntentIsIdempotentAndKeepsDeviceAndLockIndependent() throws {
        let recorder = try started()
        let terminal = try PostMatchEditor.terminateAbnormally(terminationID: "intent", descriptor: recorder.descriptor,
            events: recorder.events, sourceDeviceID: "phone", now: t.addingTimeInterval(10))
        let again = try PostMatchEditor.terminateAbnormally(terminationID: "intent", descriptor: recorder.descriptor,
            events: recorder.events + [terminal], sourceDeviceID: "phone", now: t.addingTimeInterval(20))
        XCTAssertEqual(terminal, again)
        let result = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events + [terminal], now: t.addingTimeInterval(20))
        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.backendLockState, .unknown)
        var restored = LiveMatchRecorder(descriptor: recorder.descriptor, events: recorder.events + [terminal])
        XCTAssertThrowsError(try restored.transition(.matchResumed, eventID: "resume", sourceDeviceID: "watch", now: t.addingTimeInterval(20)))
        XCTAssertThrowsError(try PostMatchEditor.revise(eventID: terminal.eventID, newEventID: "repair", descriptor: recorder.descriptor,
            events: recorder.events + [terminal], sourceDeviceID: "phone", now: t.addingTimeInterval(20)))
    }
    func testPauseElapsedMappingRequiresExplicitWallTimeAtPlateau() throws {
        var recorder = try started()
        _ = try recorder.transition(.matchPaused, eventID: "p", sourceDeviceID: "watch", now: t.addingTimeInterval(10))
        _ = try recorder.transition(.matchResumed, eventID: "r", sourceDeviceID: "watch", now: t.addingTimeInterval(30))
        _ = try recorder.transition(.matchEnded, eventID: "e", sourceDeviceID: "watch", now: t.addingTimeInterval(40))
        let result = MatchReplay.replay(descriptor: recorder.descriptor, events: recorder.events, now: t.addingTimeInterval(50))
        XCTAssertEqual(MatchTimeMapping.realTime(forElapsed: 10, in: result), .requiresExplicitOccurredAt)
        XCTAssertEqual(MatchTimeMapping.realTime(forElapsed: 15, in: result), .unique(t.addingTimeInterval(35)))
    }
    func testCorrectedTimelineStoresDerivedElapsedForMovedResumeAndLaterEnd() throws {
        var recorder = try started()
        _ = try recorder.transition(.matchPaused, eventID: "p", sourceDeviceID: "watch", now: t.addingTimeInterval(10))
        _ = try recorder.transition(.matchResumed, eventID: "r", sourceDeviceID: "watch", now: t.addingTimeInterval(20))
        _ = try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: t.addingTimeInterval(40))
        let resume = try PostMatchEditor.revise(eventID: "r", newEventID: "r-v1", descriptor: recorder.descriptor,
            events: recorder.events, occurredAt: t.addingTimeInterval(30), sourceDeviceID: "phone", now: t.addingTimeInterval(60))
        XCTAssertEqual(resume.matchElapsed, 10)
        let end = try PostMatchEditor.revise(eventID: "end", newEventID: "end-v1", descriptor: recorder.descriptor,
            events: recorder.events + [resume], occurredAt: t.addingTimeInterval(50), sourceDeviceID: "phone", now: t.addingTimeInterval(60))
        XCTAssertEqual(end.matchElapsed, 30)
    }

}
