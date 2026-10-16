import XCTest
@testable import WorkoutCapture
actor FakeRouteSink: RouteSink {
  var points: [RoutePoint] = []; var success = true
  func insert(_ points: [RoutePoint]) async -> Bool { self.points += points; return success }
  func fail() { success = false }
  func count() -> Int { points.count }
}
@MainActor final class RouteWriterTests: XCTestCase {
  func point(_ time: Double, accuracy: Double = 4, speed: Double = 0) -> RoutePoint {
    RoutePoint(latitude: 30, longitude: 120, altitude: 1, accuracy: accuracy, speed: speed, timestamp: Date(timeIntervalSince1970: time))
  }
  func testPauseRejectsSamplesAndResumeBreaksDistanceContinuity() async {
    let sink = FakeRouteSink(); let writer = WorkoutRouteWriter(sink: sink)
    XCTAssertTrue(writer.append(point(1))); writer.setPaused(true); XCTAssertFalse(writer.append(point(2)))
    writer.setPaused(false); XCTAssertTrue(writer.append(point(3))); await writer.stopAndDrain()
    let points = await sink.points; XCTAssertEqual(points.count, 2); XCTAssertNotEqual(points[0].continuity, points[1].continuity)
    XCTAssertFalse(writer.append(point(4)))
  }
  func testFatalInsertDoesNotBlindlyContinueRoute() async {
    let sink = FakeRouteSink(); await sink.fail(); let writer = WorkoutRouteWriter(sink: sink)
    XCTAssertTrue(writer.append(point(1))); await writer.drain(); XCTAssertTrue(writer.failed)
    XCTAssertFalse(writer.append(point(2))); let count = await sink.count(); XCTAssertEqual(count, 1)
  }
  func testInvalidAccuracyAndOldSamplesRejectedButZeroSpeedAvailable() async {
    let sink = FakeRouteSink(); let writer = WorkoutRouteWriter(sink: sink)
    XCTAssertFalse(writer.append(point(1, accuracy: -1))); XCTAssertTrue(writer.append(point(2)))
    XCTAssertFalse(writer.append(point(1))); XCTAssertEqual(LiveMetric.nonNegative(-1), .notRecorded)
    XCTAssertEqual(LiveMetric.nonNegative(0), .available(0)); XCTAssertEqual(LiveMetric.nonNegative(.nan), .notRecorded)
  }
  func testTimeoutDoesNotConsumeFirstRealCallback() async {
    let first = FirstCallback()
    let result: Int? = await withDeadline(.milliseconds(5)) { try? await Task.sleep(for: .milliseconds(30)); return 7 }
    XCTAssertNil(result); XCTAssertTrue(first.claim()); XCTAssertFalse(first.claim())
  }
}
