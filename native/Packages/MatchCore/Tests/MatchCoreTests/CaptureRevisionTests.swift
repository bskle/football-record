import Foundation
import XCTest
@testable import MatchCore
final class CaptureRevisionTests: XCTestCase {
 let t = Date(timeIntervalSince1970: 1_800_000_000)
 func testRevisionAndObservationValidateConstructionAndDecoding() throws {
  let b = try CaptureBinding(matchID: "match", recordingDeviceID: "watch")
  let m = try CaptureMetadata(binding: b, segments: [], gaps: [])
  XCTAssertThrowsError(try CaptureRevision(id: " ", binding: b, parentID: nil, revision: 1, observedAt: t, metadata: m))
  XCTAssertThrowsError(try CaptureRevision(id: "r", binding: b, parentID: nil, revision: 0, observedAt: t, metadata: m))
  XCTAssertThrowsError(try CaptureOperation(id: "op", binding: b, associatedCommandID: "c", action: .start, requestedAt: Date(timeIntervalSince1970: .infinity), externalToken: "op"))
  let r = try CaptureRevision(id: "r", binding: b, parentID: nil, revision: 1, observedAt: t, metadata: m)
  let bytes = try JSONEncoder().encode(r)
  XCTAssertEqual(try JSONDecoder().decode(CaptureRevision.self, from: bytes), r)
  var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); object["revision"] = -1
  XCTAssertThrowsError(try JSONDecoder().decode(CaptureRevision.self, from: JSONSerialization.data(withJSONObject: object)))
  XCTAssertThrowsError(try WorkoutObservation(operationID: "op", binding: b, externalToken: "op", observedAt: t, outcome: .linked(workoutID: " "), window: CaptureWindow(start: nil, end: nil)))
 }
 func testDigestHasExplicitEmptyDomainAndStableOrdering() throws {
  let b = try CaptureBinding(matchID: "match", recordingDeviceID: "watch")
  let m = try CaptureMetadata(binding: b, segments: [], gaps: [])
  let a = try CaptureRevision(id: "a", binding: b, parentID: nil, revision: 1, observedAt: t, metadata: m)
  let z = try CaptureRevision(id: "z", binding: b, parentID: "a", revision: 2, observedAt: t, metadata: m)
  XCTAssertEqual(try CaptureRevision.digest([a,z]), try CaptureRevision.digest([z,a]))
  XCTAssertNotEqual(try CaptureRevision.digest([]), try CaptureRevision.digest([a]))
  XCTAssertNotEqual(try CaptureRevision.digest([]), "")
 }
 func testFailurePreservesActualWorkoutOutcomeAndNilFailureIsOmitted() throws {
  let b = try CaptureBinding(matchID:"match",recordingDeviceID:"watch")
  let op = try CaptureOperation(id:"op",binding:b,associatedCommandID:"c",action:.start,requestedAt:t,externalToken:"op")
  let window = try CaptureWindow(start:nil,end:nil)
  let route = try WorkoutObservation(operationID:"op",binding:b,externalToken:"op",observedAt:t,outcome:.running,window:window,failure:.routeFailed)
  XCTAssertEqual(try CaptureOperationRecord(operation:op,state:.settled,observation:route).observation?.failure,.routeFailed)
  let stop = try WorkoutObservation(operationID:"op",binding:b,externalToken:"op",observedAt:t,outcome:.stopped,window:window,failure:.captureFailed)
  XCTAssertNoThrow(try CaptureOperationRecord(operation:op,state:.needsReconciliation,observation:stop))
  XCTAssertThrowsError(try CaptureOperationRecord(operation:op,state:.settled,observation:stop))
  let plain = try WorkoutObservation(operationID:"op",binding:b,externalToken:"op",observedAt:t,outcome:.running,window:window)
  let json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(plain)) as? [String:Any])
  XCTAssertNil(json["failure"])
 }

}
