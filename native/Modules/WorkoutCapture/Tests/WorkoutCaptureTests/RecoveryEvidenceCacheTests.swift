import XCTest
import MatchCore
@testable import WorkoutCapture
@MainActor final class RecoveryEvidenceCacheTests: XCTestCase {
  func context(_ match: String = "match") throws -> WorkoutContext { try WorkoutContext(binding: CaptureBinding(matchID: match, recordingDeviceID: "watch"), externalToken: "token") }
  func testLateNilNilAndLaterUUIDAreRetainedAfterWaitDeadline() async throws {
    let cache = RecoveryEvidenceCache(); let c = try context()
    var callback: ((DriverState) -> Void)?
    let work = Task { @MainActor in
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let first = FirstCallback()
        callback = { value in guard first.claim() else { return }; cache.rememberSaved(value, context: c); continuation.resume(returning: true) }
      }
    }
    let result = await withDeadline(.milliseconds(5)) { await work.value }; XCTAssertNil(result)
    callback?(DriverState(outcome: .savedAwaitingLink))
    guard case .saved(let saved) = cache.lookup(c) else { return XCTFail("late actual proof was lost") }
    XCTAssertEqual(saved.outcome, .savedAwaitingLink)
    cache.rememberSaved(DriverState(outcome: .linked(workoutID: "REAL-UUID")), context: c)
    callback?(DriverState(outcome: .running))
    guard case .saved(let linked) = cache.lookup(c) else { return XCTFail("saved proof regressed") }
    XCTAssertEqual(linked.outcome, .linked(workoutID: "REAL-UUID"))
  }
  func testForeignBindingCannotOverwriteOriginalTokenProof() throws {
    let cache = RecoveryEvidenceCache(); let original = try context(); let foreign = try context("foreign")
    cache.rememberSaved(DriverState(outcome: .linked(workoutID: "ORIGINAL")), context: original)
    cache.rememberSaved(DriverState(outcome: .linked(workoutID: "FOREIGN")), context: foreign)
    XCTAssertNil(cache.lookup(foreign))
    guard case .saved(let saved) = cache.lookup(original) else { return XCTFail("original missing") }
    XCTAssertEqual(saved.outcome, .linked(workoutID: "ORIGINAL"))
  }
  func testLateOriginalSessionIsRetainedAndNeverRestarted() throws {
    let cache = RecoveryEvidenceCache(); let c = try context(); let driver = FakeDriver(); driver.state = DriverState(outcome: .paused)
    cache.rememberActive(driver, context: c)
    guard case .active(let recovered) = cache.lookup(c) else { return XCTFail("original session missing") }
    XCTAssertTrue((recovered as AnyObject) === driver); XCTAssertTrue(driver.calls.isEmpty)
    cache.rememberSaved(DriverState(outcome: .linked(workoutID: "REAL")), context: c)
    cache.rememberActive(driver, context: c)
    guard case .saved = cache.lookup(c) else { return XCTFail("old session overrode save") }
  }
}
