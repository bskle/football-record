import XCTest
import MatchCore
@testable import WorkoutCapture
final class WorkoutRecoveryTests: XCTestCase {
  func context() throws -> WorkoutContext { try WorkoutContext(binding: CaptureBinding(matchID: "match", recordingDeviceID: "device"), externalToken: "segment-1") }
  func testSavedQueryRequiresSourceAndEveryBindingValue() throws {
    let c = try context(); let metadata = WorkoutMetadata.values(context: c)
    XCTAssertTrue(WorkoutMetadata.matchesSaved(source: "own.app", expectedSource: "own.app", metadata: metadata, context: c))
    XCTAssertFalse(WorkoutMetadata.matchesSaved(source: "other.app", expectedSource: "own.app", metadata: metadata, context: c))
    for key in [WorkoutMetadata.matchKey, WorkoutMetadata.deviceKey, WorkoutMetadata.tokenKey] {
      var wrong = metadata; wrong[key] = "different"
      XCTAssertFalse(WorkoutMetadata.matchesSaved(source: "own.app", expectedSource: "own.app", metadata: wrong, context: c))
    }
  }
  func testFirstNilNilSaveIsProofButNoInventedUUID() {
    let result = DriverState.savedResult(workoutID: nil, failed: false, start: nil, end: nil)
    XCTAssertEqual(result.outcome, .savedAwaitingLink); XCTAssertNil(result.start); XCTAssertNil(result.end)
    let failed = DriverState.savedResult(workoutID: nil, failed: true, start: nil, end: nil)
    XCTAssertEqual(failed.outcome, .stopped); XCTAssertEqual(failed.failure, .captureFailed)
  }
  func testSavedEvidenceMonotonicAcrossLateOrOldCallbacks() {
    let saved = DriverState(outcome: .savedAwaitingLink)
    XCTAssertEqual(saved.merging(DriverState(outcome: .running)).outcome, .savedAwaitingLink)
    let linked = saved.merging(DriverState.savedResult(workoutID: "REAL-UUID", failed: false, start: nil, end: nil))
    XCTAssertEqual(linked.merging(DriverState(outcome: .paused)).outcome, .linked(workoutID: "REAL-UUID"))
    XCTAssertEqual(linked.merging(saved).outcome, .linked(workoutID: "REAL-UUID"))
  }
  func testRouteWarningSurvivesUnrelatedSuccessfulControl() {
    let old = DriverState(outcome: .running, failure: .routeFailed)
    XCTAssertEqual(old.merging(DriverState(outcome: .paused)).failure, .routeFailed)
  }
}
