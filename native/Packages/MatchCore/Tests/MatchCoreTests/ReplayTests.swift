import XCTest
@testable import MatchCore

final class ReplayTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    func descriptor(starter: Bool = true) -> MatchDescriptor {
        let intent = StartIntent(id: "intent", matchID: "match", recordingDeviceID: "watch", requestedAt: epoch)
        return MatchDescriptor(startIntent: intent, starter: starter,
            startPermit: DevelopmentStartFixture.permit(for: intent))
    }
    func event(_ id: String, _ sequence: Int, _ seconds: Double, _ type: MatchEventType,
               goal: GoalPayload? = nil, authority: EventAuthority = .live,
               source: String = "watch", revision: Int = 0, correction: String? = nil,
               status: EventStatus = .active, terminationID: String? = nil) -> MatchEvent {
        MatchEvent(eventID: id, matchID: "match", sequence: sequence,
            occurredAt: epoch.addingTimeInterval(seconds), matchElapsed: seconds, type: type,
            sourceDeviceID: source, createdAt: epoch.addingTimeInterval(200),
            updatedAt: epoch.addingTimeInterval(200), status: status,
            correctionOfEventID: correction, revision: revision, authority: authority,
            goal: goal, terminationID: terminationID)
    }
    func replay(_ events: [MatchEvent], starter: Bool = true, now: Double = 100) -> ReplayResult {
        let match = descriptor(starter: starter)
        let date = epoch.addingTimeInterval(now)
        let proof = try? TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: match,
            events: events, confirmationID: "test-complete-save-boundary", now: date)
        return MatchReplay.replay(descriptor: match, events: events, now: date, completionEvidence: proof)
    }
    var start: MatchEvent { event("start", 0, 0, .matchStarted) }
    func goal(_ side: ScoreImpact = .forTeam, selfScorer: Bool = false,
              selfAssist: Bool = false, kind: GoalKind = .normal) -> GoalPayload {
        GoalPayload(scoreImpact: side, goalKind: kind, scoringTeamSnapshot: "A",
                    scorerSnapshot: selfScorer ? .selfPlayer : nil,
                    assisterSnapshot: selfAssist ? .selfPlayer : nil)
    }

    func testStarterPauseResumeAndFieldIntervalsUseWallClockIntersection() {
        let result = replay([start, event("pause", 1, 20, .matchPaused),
            event("resume", 2, 50, .matchResumed), event("off", 3, 70, .leftField),
            event("on", 4, 80, .enteredField), event("end", 5, 100, .matchEnded)])
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.matchDuration, 70)
        XCTAssertEqual(result.appearanceDuration, 60)
        XCTAssertEqual(result.runningIntervals.count, 2)
        XCTAssertEqual(result.pausedIntervals.count, 1)
        XCTAssertEqual(result.fieldIntervals.count, 2)
        XCTAssertFalse(result.isOnField)
        XCTAssertTrue(result.career.includeWinRate)
        XCTAssertNil(result.health)
    }

    func testSubstituteDuplicateTransitionsPreserveFactsWithoutResettingClock() {
        let events = [start, event("off0", 1, 1, .leftField),
            event("on", 2, 10, .enteredField), event("on2", 3, 20, .enteredField),
            event("off", 4, 40, .leftField), event("off2", 5, 41, .leftField),
            event("on3", 6, 50, .enteredField), event("end", 7, 60, .matchEnded)]
        let result = replay(events, starter: false)
        XCTAssertEqual(result.appearanceDuration, 40)
        XCTAssertEqual(result.effectiveEvents.count, events.count)
        XCTAssertEqual(result.diagnostics.filter { $0.code == .duplicateFieldTransition }.count, 3)
    }

    func testCrossDayOpenAppearanceAndPauseFreezeWithoutTimers() {
        let result = replay([start, event("pause", 1, 90_000, .matchPaused)], now: 100_000)
        XCTAssertEqual(result.state, .paused)
        XCTAssertEqual(result.matchDuration, 90_000)
        XCTAssertEqual(result.appearanceDuration, 90_000)
        XCTAssertTrue(result.isOnField)
        XCTAssertFalse(result.career.includeRecordedMatch)
    }

    func testOnAndOffFieldScoresOwnGoalAndSameTimeSequence() {
        let result = replay([start, event("off", 1, 10, .leftField),
            event("bench", 2, 10, .scoreEvent, goal: goal()),
            event("on", 3, 20, .enteredField),
            event("mine", 4, 20, .scoreEvent, goal: goal(selfScorer: true)),
            event("assist", 5, 30, .scoreEvent, goal: goal(selfAssist: true)),
            event("own", 6, 35, .scoreEvent, goal: goal(.against, selfScorer: true, kind: .ownGoal)),
            event("end", 7, 40, .matchEnded)])
        XCTAssertEqual(result.score, Score(forTeam: 3, against: 1))
        XCTAssertEqual(result.onFieldScore, Score(forTeam: 2, against: 1))
        XCTAssertEqual(result.personalGoals, 1)
        XCTAssertEqual(result.personalAssists, 1)
        XCTAssertEqual(result.onFieldGoalDifference, 1)
    }

    func testPausedGoalsKeepFieldStateAndFrozenElapsed() {
        let result = replay([start, event("pause", 1, 10, .matchPaused),
            event("goal", 2, 20, .scoreEvent, goal: goal()), event("end", 3, 30, .matchEnded)])
        XCTAssertEqual(result.matchDuration, 10)
        XCTAssertEqual(result.appearanceDuration, 10)
        XCTAssertEqual(result.onFieldScore.forTeam, 1)
        XCTAssertEqual(result.elapsed(at: epoch.addingTimeInterval(25)), 10)
    }

    func testShuffledRetransmissionsReplayIdenticallyAndRoundTripCodable() throws {
        let events = [start, event("goal", 1, 10, .scoreEvent, goal: goal()), event("end", 2, 20, .matchEnded)]
        let baseline = replay(events)
        let shuffled = replay([events[2], events[1], events[0], events[1]])
        XCTAssertEqual(shuffled, baseline)
        XCTAssertEqual(try JSONDecoder().decode([MatchEvent].self, from: JSONEncoder().encode(events)), events)
        XCTAssertEqual(try JSONDecoder().decode(MatchDescriptor.self,
            from: JSONEncoder().encode(descriptor())), descriptor())
    }

    func testConflictingEventIDsAndSequenceAreExplicitAndExcludeCareer() {
        let result = replay([start, event("dup", 1, 10, .scoreEvent, goal: goal()),
            event("dup", 1, 10, .scoreEvent, goal: goal(.against)), event("end", 1, 20, .matchEnded)])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .conflictingEventID })
        XCTAssertEqual(result.score, Score())
        XCTAssertFalse(result.career.includeRecordedMatch)
    }

    func testAppendOnlyCorrectionDeletionAndEndMovedEarlierRecomputeImpact() {
        let original = event("goal", 1, 60, .scoreEvent, goal: goal())
        let corrected = event("goal-v1", 4, 40, .scoreEvent, goal: goal(.against),
            authority: .postMatch, source: "phone", revision: 1, correction: "goal")
        let end = event("end", 2, 100, .matchEnded)
        let earlyEnd = event("end-v1", 5, 50, .matchEnded, authority: .postMatch,
            source: "phone", revision: 1, correction: "end")
        let late = event("late", 3, 70, .scoreEvent, goal: goal())
        let result = replay([start, original, end, corrected, earlyEnd, late])
        XCTAssertEqual(result.matchDuration, 50)
        XCTAssertEqual(result.appearanceDuration, 50)
        XCTAssertEqual(result.score, Score(forTeam: 0, against: 1))
        XCTAssertEqual(result.excludedAfterEndEventIDs, ["late"])
        let deleted = event("goal-v2", 6, 40, .scoreEvent, goal: goal(.against),
            authority: .postMatch, source: "phone", revision: 2, correction: "goal-v1", status: .deleted)
        XCTAssertEqual(replay([start, original, end, corrected, deleted]).score, Score())
        XCTAssertEqual(original.status, .active)
    }

    func testRevisionForkCycleAndMissingParentDoNotSelectAnArbitraryWinner() {
        let base = event("g", 1, 10, .scoreEvent, goal: goal())
        let first = event("g1", 3, 10, .scoreEvent, goal: goal(.against), authority: .postMatch,
            source: "phone", revision: 1, correction: "g")
        let fork = event("g2", 4, 10, .scoreEvent, goal: goal(), authority: .postMatch,
            source: "phone", revision: 1, correction: "g")
        let end = event("end", 2, 20, .matchEnded)
        let result = replay([start, base, first, fork, end])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .invalidRevision })
        XCTAssertEqual(result.score, Score())
        let cycleA = event("a", 5, 10, .scoreEvent, goal: goal(), authority: .postMatch,
            source: "phone", revision: 1, correction: "b")
        let cycleB = event("b", 6, 10, .scoreEvent, goal: goal(), authority: .postMatch,
            source: "phone", revision: 2, correction: "a")
        XCTAssertEqual(replay([start, end, cycleA, cycleB]).state, .conflict)
        XCTAssertEqual(replay([start, end, first]).state, .conflict)
    }

    func testCompletedNoAppearanceOnlyRecordsMatchAndDrawEntersWinRateDenominator() {
        let ended = [start, event("end", 1, 20, .matchEnded)]
        let bench = replay(ended, starter: false)
        XCTAssertTrue(bench.career.includeRecordedMatch)
        XCTAssertFalse(bench.career.includeAppearance)
        let draw = replay(ended)
        XCTAssertTrue(draw.career.includeWinRate)
        XCTAssertEqual(draw.career.result, .draw)
        XCTAssertFalse(replay([start]).career.includeAppearance)
    }

    func testExceptionalPhoneTerminationCannotBeRevivedByLateNormalEnd() {
        let terminated = event("terminate", 2, 30, .matchTerminated, authority: .abnormalTermination,
            source: "phone", terminationID: "terminal-1")
        let result = replay([start, terminated, terminated, event("late-end", 3, 40, .matchEnded),
            event("late-goal", 1, 20, .scoreEvent, goal: goal())])
        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.matchDuration, 30)
        XCTAssertEqual(result.score.forTeam, 1)
        XCTAssertEqual(result.recordingDeviceID, "watch")
        XCTAssertEqual(result.backendLockState, .unknown)
        XCTAssertFalse(result.career.includeRecordedMatch)
    }

    func testMissingStartOrUntrustedPermitCannotStartAndForeignWriterIsRejected() {
        XCTAssertEqual(replay([event("g", 1, 10, .scoreEvent, goal: goal())]).state, .notStarted)
        let intent = descriptor().startIntent
        let unpermitted = MatchDescriptor(startIntent: intent, starter: true)
        XCTAssertEqual(MatchReplay.replay(descriptor: unpermitted, events: [start], now: epoch).state, .notStarted)
        let result = replay([start, event("foreign", 1, 10, .scoreEvent, goal: goal(), source: "other")])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertEqual(result.score.forTeam, 0)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .unauthorizedWriter })
    }
    func testConflictingSequencesAreDiagnosedAndZeroLengthAppearanceIsNotCareerEligible() {
        let result = replay([start, event("one", 1, 10, .scoreEvent, goal: goal()),
            event("two", 1, 10, .scoreEvent, goal: goal(.against)), event("end", 2, 20, .matchEnded)])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .duplicateSequence })
        let zero = replay([start, event("end", 1, 0, .matchEnded)])
        XCTAssertTrue(zero.career.includeRecordedMatch)
        XCTAssertFalse(zero.career.includeAppearance)
        XCTAssertFalse(zero.career.includeFitness)
    }

    func testMovingStartPastAbnormalTerminationCannotReactivateMatch() {
        let termination = event("terminal", 1, 20, .matchTerminated, authority: .abnormalTermination,
            source: "phone", terminationID: "intent")
        let movedStart = event("start-v1", 2, 30, .matchStarted, authority: .postMatch,
            source: "phone", revision: 1, correction: "start")
        let result = replay([start, termination, movedStart])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertFalse(result.career.includeRecordedMatch)
    }

    func testConflictingTerminationIntentCannotSilentlyChooseOneTime() {
        let first = event("terminal1", 1, 20, .matchTerminated, authority: .abnormalTermination,
            source: "phone", terminationID: "same-intent")
        let second = event("terminal2", 2, 30, .matchTerminated, authority: .abnormalTermination,
            source: "phone", terminationID: "same-intent")
        let result = replay([start, first, second])
        XCTAssertEqual(result.state, .conflict)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .duplicateTermination })
    }

    func testRevisionIntegerOverflowIsDiagnosedRatherThanCrashing() {
        let badParent = event("bad", 1, 10, .scoreEvent, goal: goal(), revision: Int.max)
        let child = event("child", 3, 10, .scoreEvent, goal: goal(), authority: .postMatch,
            source: "phone", revision: 0, correction: "bad")
        let result = replay([start, badParent, child, event("end", 2, 20, .matchEnded)])
        XCTAssertEqual(result.state, .conflict)
    }

    func testSameTimeCorrectionsPreserveRootFactOrderForFieldAndEndBoundaries() {
        let enter = event("on", 1, 10, .enteredField)
        let scored = event("goal", 2, 10, .scoreEvent, goal: goal())
        let ended = event("end", 3, 10, .matchEnded)
        let changedEnter = event("on-v1", 4, 10, .enteredField, authority: .postMatch,
            source: "phone", revision: 1, correction: "on")
        let changedGoal = event("goal-v1", 5, 10, .scoreEvent, goal: goal(.against), authority: .postMatch,
            source: "phone", revision: 1, correction: "goal")
        let result = replay([start, enter, scored, ended, changedEnter, changedGoal], starter: false)
        XCTAssertEqual(result.score, Score(forTeam: 0, against: 1))
        XCTAssertEqual(result.onFieldScore, Score(forTeam: 0, against: 1))
        XCTAssertTrue(result.excludedAfterEndEventIDs.isEmpty)
        XCTAssertEqual(result.effectiveEvents.map(\.eventID), ["start", "on-v1", "goal-v1", "end"])
        XCTAssertEqual(changedEnter.sequence, 4)
        XCTAssertEqual(changedGoal.sequence, 5)
    }

}
