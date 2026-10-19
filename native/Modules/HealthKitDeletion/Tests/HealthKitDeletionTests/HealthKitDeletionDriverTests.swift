import Foundation
import XCTest
@testable import HealthKitDeletion
final class HealthKitDeletionDriverTests: XCTestCase {
 func testTupleCrossMatchesNeverExpandSelection() throws {
  let a=try target(),b=try target("00000000-0000-0000-0000-000000000002",match:"match-b",recorder:"watch-b",segment:"segment-b")
  let plan=try HealthDeletionPredicatePlan(request:request(targets:[a,b]),currentSourceBundleID:"test.football.phone")
  XCTAssertTrue(plan.matches(a));XCTAssertTrue(plan.matches(b))
  XCTAssertFalse(plan.matches(try target(match:b.matchID,recorder:a.recordingDeviceID,segment:b.segmentToken)))
  XCTAssertFalse(plan.matches(try target("00000000-0000-0000-0000-000000000003")))
  XCTAssertFalse(plan.matches(try target(source:"test.football.watch")))
 }
 func testEveryExpectedSourceMustMatchCurrentCallingApp() throws {
  let phone=try target(),watch=try target("00000000-0000-0000-0000-000000000002",source:"test.football.watch")
  XCTAssertThrowsError(try HealthDeletionPredicatePlan(request:request(targets:[phone,watch]),currentSourceBundleID:"test.football.phone"))
  XCTAssertThrowsError(try HealthDeletionPredicatePlan(request:request(targets:[phone]),currentSourceBundleID:"test.football.watch"))
  let valid=try HealthDeletionPredicatePlan(request:request(targets:[watch]),currentSourceBundleID:"test.football.watch")
  XCTAssertTrue(valid.matches(watch))
 }
}
