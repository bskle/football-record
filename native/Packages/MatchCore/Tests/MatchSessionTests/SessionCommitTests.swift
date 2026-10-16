import Foundation
import MatchCore
import MatchSession
import XCTest

@testable import MatchStore

final class SessionCommitTests: XCTestCase, @unchecked Sendable {
  func testCancelPreparationWritesNothingAndStartUsesOriginalTimeAndIDs() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: false)
    let empty = try await h.repo.matchIDs()
    XCTAssertTrue(empty.isEmpty)
    h.clock.advance(20)
    let saved = try await h.session.execute(r)
    XCTAssertEqual(saved.receipt.commandID, r.commandID + "/start")
    XCTAssertEqual(saved.snapshot.replay.state, .running)
    XCTAssertFalse(saved.snapshot.replay.isOnField)
    XCTAssertEqual(saved.snapshot.store.business.events.first?.occurredAt, r.requestedAt)
    XCTAssertEqual(saved.snapshot.store.business.events.first?.eventID, r.eventIDs.first)
    let outbox = try await h.repo.store.pendingBusinessOutbox(matchID: r.matchID)
    XCTAssertEqual(outbox.count, 1)
  }
  func testFirstCommitFailureHasNoSuccessOrWorkout() async throws {
    let h = try Harness()
    await h.repo.failNextCommit()
    let r = try await h.session.prepareStart(starter: true)
    do {
      _ = try await h.session.execute(r)
      XCTFail("must fail before intent exists")
    } catch let e as StoreError { XCTAssertEqual(e, .injectedFailure) }
    let matches = try await h.repo.matchIDs()
    XCTAssertTrue(matches.isEmpty)
    let calls = await h.gateway.performed
    XCTAssertTrue(calls.isEmpty)
  }
  func testResponseLostRetryAfterLaterEventsAndEndReturnsFirstReceipt() async throws {
    let h = try Harness()
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    await h.gateway.waitForPerform(1)
    try await h.waitCaptureSettled(start.matchID)
    h.clock.advance(2)
    let quick = try await h.session.prepare(.quick(.myGoal), matchID: start.matchID)
    await h.repo.loseNextResponse()
    do {
      _ = try await h.session.execute(quick)
      XCTFail("lost response")
    } catch let e as StoreError { XCTAssertEqual(e, .responseLost) }
    h.clock.advance(2)
    let end = try await h.session.prepare(.end, matchID: start.matchID)
    _ = try await h.session.execute(end)
    let retried = try await h.session.execute(quick)
    XCTAssertEqual(retried.receipt.eventIDs, quick.eventIDs)
    XCTAssertEqual(retried.snapshot.replay.state, .endedPendingSync)
    XCTAssertEqual(retried.snapshot.replay.score.forTeam, 1)
    let original = try await h.repo.committedCommandV2(commandID: quick.commandID)
    XCTAssertEqual(retried.receipt, original?.receipt)
    let startAgain = try await h.session.execute(start)
    XCTAssertEqual(startAgain.receipt.generation, 2)
    XCTAssertEqual(startAgain.snapshot.replay.state, .endedPendingSync)
  }
  func testSameCommandChangedActionIsConflictEvenAfterTerminal() async throws {
    let h = try Harness()
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    try await h.waitCaptureSettled(start.matchID)
    h.clock.advance(2)
    let q = try await h.session.prepare(.quick(.myGoal), matchID: start.matchID)
    _ = try await h.session.execute(q)
    let changed = try SessionRequest(
      commandID: q.commandID, matchID: q.matchID, requestedAt: q.requestedAt,
      expectedGeneration: q.expectedGeneration, action: .quick(.conceded), eventIDs: q.eventIDs,
      captureOperationID: q.captureOperationID)
    do {
      _ = try await h.session.execute(changed)
      XCTFail("same command different action")
    } catch let e as StoreError { XCTAssertEqual(e, .commandConflict) }
  }
  func testFourButtonsShareDebounceAndUndoNeverExposesOlderQuick() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    h.clock.advance(2)
    _ = try await h.session.execute(h.session.prepare(.quick(.myGoal), matchID: r.matchID))
    h.clock.advance(0.5)
    do {
      _ = try await h.session.execute(h.session.prepare(.quick(.conceded), matchID: r.matchID))
      XCTFail("cross button debounce")
    } catch let e as MatchCommandError { XCTAssertEqual(e, .debounced) }
    h.clock.advance(1)
    _ = try await h.session.execute(h.session.prepare(.quick(.myAssist), matchID: r.matchID))
    h.clock.advance(1)
    let undo = try await h.session.execute(h.session.prepare(.undoLastQuick, matchID: r.matchID))
    XCTAssertEqual(undo.snapshot.replay.personalGoals, 1)
    XCTAssertEqual(undo.snapshot.replay.personalAssists, 0)
    XCTAssertNil(undo.snapshot.lastUndoableQuickEventID)
    h.clock.advance(1)
    do {
      _ = try await h.session.execute(h.session.prepare(.undoLastQuick, matchID: r.matchID))
      XCTFail("no older undo")
    } catch let e as MatchCommandError { XCTAssertEqual(e, .noUndoableQuickRecord) }
  }
  func testPermitUnavailablePersistsRecoverableOriginalIntent() async throws {
    let h = try Harness(permits: UnavailableStartPermitProvider())
    let request = try await h.session.prepareStart(starter: true)
    do {
      _ = try await h.session.execute(request)
      XCTFail("production permit unavailable")
    } catch let e as SessionError { XCTAssertEqual(e, .permitUnavailable) }
    let new = h.newSession(permits: UnavailableStartPermitProvider())
    let recovery = try await new.recover()
    guard case .intentAwaitingPermit(let intent) = recovery else {
      return XCTFail("recover original intent")
    }
    XCTAssertEqual(intent, request.startIntent)
    let other = try await new.prepareStart(starter: true)
    do {
      _ = try await new.execute(other)
      XCTFail("cannot bypass pending lock")
    } catch let e as SessionError { XCTAssertEqual(e, .multipleCandidates) }
  }
  func testTerminalMatchWithUnreleasedLockStillBlocksNewStart() async throws {
    let h = try Harness()
    let original = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(original)
    try await h.waitCaptureSettled(original.matchID)
    h.clock.advance(10)
    _ = try await h.session.execute(h.session.prepare(.end, matchID: original.matchID))
    let next = try await h.session.prepareStart(starter: true)
    do {
      _ = try await h.session.execute(next)
      XCTFail("local end is not backend release")
    } catch let e as SessionError { XCTAssertEqual(e, .multipleCandidates) }
    let matches = try await h.repo.matchIDs()
    XCTAssertEqual(matches, [original.matchID])
  }

}
