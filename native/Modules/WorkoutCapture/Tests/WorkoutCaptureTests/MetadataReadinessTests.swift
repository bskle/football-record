import XCTest
@testable import WorkoutCapture
@MainActor final class MetadataReadinessTests: XCTestCase {
  func testLateActualMetadataSuccessStartsLocationOnceAfterDeadline() async {
    let readiness = MetadataReadiness(); var starts = 0; var finishes = 0
    let actual = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(20))
      readiness.receive(success: true, terminal: false, startLocation: { starts += 1 }, finishOriginal: { finishes += 1 })
      return true
    }
    let wait = await withDeadline(.milliseconds(2)) { await actual.value }; XCTAssertNil(wait); XCTAssertFalse(readiness.confirmed)
    _ = await actual.value; XCTAssertTrue(readiness.confirmed); XCTAssertEqual(starts, 1); XCTAssertEqual(finishes, 0)
    readiness.receive(success: true, terminal: false, startLocation: { starts += 1 }, finishOriginal: { finishes += 1 })
    XCTAssertEqual(starts, 1)
  }
  func testLateMetadataAfterTerminalOnlyFinishesOriginal() async {
    let readiness = MetadataReadiness(); var starts = 0; var finishes = 0
    let status = TestTerminalStatus()
    let actual = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(20))
      readiness.receive(success: true, terminal: status.terminal, startLocation: { starts += 1 }, finishOriginal: { finishes += 1 })
      return true
    }
    _ = await withDeadline(.milliseconds(2)) { await actual.value }; status.terminal = true
    _ = await actual.value; XCTAssertEqual(starts, 0); XCTAssertEqual(finishes, 1)
  }
}

@MainActor private final class TestTerminalStatus { var terminal = false }
