import Foundation
import XCTest
import MatchCore
import MatchSession
@testable import MatchPresentation
struct Identity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "ui-test" } }
final class Clock: SessionClock, @unchecked Sendable {
  private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { value } }
  func advance(_ n: Double) { lock.withLock { value.addTimeInterval(n) } }
}
struct Fixture {
  let repository: SQLiteSessionRepository; let clock: Clock; let session: MatchSession
  init() throws {
    repository = try SQLiteSessionRepository(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), databaseNamespace: "presentation-test")
    clock = Clock()
    session = MatchSession(store: repository, deviceIdentity: Identity(), clock: clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "presentation-test"))
  }
  func start(_ starter: Bool = true) async throws -> SessionSnapshot { try await session.execute(session.prepareStart(starter: starter)).snapshot }
  func act(_ a: SessionAction, _ m: String) async throws -> SessionSnapshot {
    // Unavailable capture finishes before each next business request in these value tests.
    try await Task.sleep(for: .milliseconds(30))
    return try await session.execute(session.prepare(a, matchID: m)).snapshot
  }
}
final class ProjectionTests: XCTestCase, @unchecked Sendable {
  func testFactsDrivePauseAndBenchClocks() async throws {
    let f = try Fixture(); var s = try await f.start(); let id = s.replay.matchID
    f.clock.advance(20); s = try await f.act(.leaveField, id)
    f.clock.advance(10)
    var p = MatchProjection(snapshot: s, now: f.clock.now())
    XCTAssertEqual(p.matchClock, "00:30"); XCTAssertEqual(p.fieldClock, "00:20")
    s = try await f.act(.pause, id); f.clock.advance(30)
    p = MatchProjection(snapshot: s, now: f.clock.now())
    XCTAssertEqual(p.matchClock, "00:30"); XCTAssertEqual(p.fieldClock, "00:20")
  }
  func testEndedIsPendingSyncAndCannotOfferStart() async throws {
    let f = try Fixture(); let s = try await f.start(); f.clock.advance(4)
    let ended = try await f.act(.end, s.replay.matchID)
    let p = MatchProjection(snapshot: ended, now: f.clock.now())
    XCTAssertTrue(p.terminal); XCTAssertEqual(p.status, "已结束 · 待同步")
  }
  func testMissingMetricsAreNeverZero() {
    XCTAssertEqual(MetricValue.notRecorded.text(unit: "bpm"), "未记录")
    XCTAssertEqual(MetricValue.unsupported.text(unit: "bpm"), "不支持")
    XCTAssertEqual(MetricValue.available(0).text(unit: "km"), "0 km")
    XCTAssertEqual(MetricValue.available(.nan).text(unit: "bpm"), "未记录")
  }
}
