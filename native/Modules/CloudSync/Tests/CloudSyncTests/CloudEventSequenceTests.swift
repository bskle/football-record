import CryptoKit
import Foundation
import XCTest
import MatchCore
@testable import CloudSync

final class CloudEventSequenceTests: XCTestCase, @unchecked Sendable {
 private func liveRecorder() throws -> LiveMatchRecorder {
  let intent = StartIntent(id:"live-intent",matchID:"live-match",recordingDeviceID:"watch",requestedAt:cloudTime)
  let descriptor = MatchDescriptor(startIntent:intent,starter:true,startPermit:DevelopmentStartFixture.permit(for:intent))
  var recorder = LiveMatchRecorder(descriptor:descriptor)
  try recorder.start(eventID:"live-start",sourceDeviceID:"watch",now:cloudTime)
  return recorder
 }

 func testRealLiveRecorderFirstEventCanBecomeCloudFacts() throws {
  let recorder = try liveRecorder(),started = try XCTUnwrap(recorder.events.first)
  XCTAssertEqual(started.type,.matchStarted); XCTAssertEqual(started.sequence,0)
  let facts = try CloudMatchFacts(startIntent:recorder.descriptor.startIntent,starter:true,events:recorder.events,captureRevisions:[])
  XCTAssertEqual(facts.events,recorder.events)
 }

 func testRealRecordedMatchSurvivesCloudEnqueueReopenWithOriginalBytesAndDigest() async throws {
  var recorder = try liveRecorder()
  try recorder.recordQuick(.myGoal,eventID:"live-goal",sourceDeviceID:"watch",now:cloudTime.addingTimeInterval(2))
  try recorder.transition(.matchEnded,eventID:"live-end",sourceDeviceID:"watch",now:cloudTime.addingTimeInterval(10))
  XCTAssertEqual(recorder.events.map(\.sequence),[0,1,2])
  let facts = try CloudMatchFacts(startIntent:recorder.descriptor.startIntent,starter:true,events:recorder.events,captureRevisions:[])
  let scope = try cloudScope(),record = try CloudRecord(scope:scope,payload:.matchFacts(facts)),upload = try CloudUpload(scope:scope,record:record)
  let original = try upload.canonicalBytes(),url = try tempCloudURL("zero-sequence")
  let ledger = try SQLiteCloudLedger(url:url); try await ledger.enqueue(upload); try await ledger.close()
  let reopened = try SQLiteCloudLedger(url:url),entries = try await reopened.uploads(scope:scope)
  let entry = try XCTUnwrap(entries.first); XCTAssertEqual(entries.count,1)
  XCTAssertEqual(entry.originalBytes,original); XCTAssertEqual(entry.upload.record.canonicalBytes,record.canonicalBytes)
  XCTAssertEqual(entry.upload.record.recordID,record.recordID); XCTAssertEqual(entry.upload.record.digest,record.digest)
  XCTAssertEqual(record.digest,SHA256.hash(data:record.canonicalBytes).map { String(format:"%02x",$0) }.joined())
  guard case .matchFacts(let restored) = try entry.upload.record.payload else { return XCTFail("expected original match facts") }
  XCTAssertEqual(restored.events,facts.events); XCTAssertEqual(try restored.factDigest,try facts.factDigest)
  try await reopened.close()
 }

 func testLegacyOneBasedEventsRemainAcceptedWithoutRewriting() throws {
  let legacy = try cloudFacts(),record = try CloudRecord(scope:cloudScope(),payload:.matchFacts(legacy))
  XCTAssertEqual(legacy.events.map(\.sequence).sorted(),[1,2])
  let decoded = try CloudRecord(scope:cloudScope(),canonicalBytes:record.canonicalBytes)
  XCTAssertEqual(decoded.canonicalBytes,record.canonicalBytes); XCTAssertEqual(decoded.digest,record.digest); XCTAssertEqual(decoded.recordID,record.recordID)
 }

 func testNegativeEventSequenceIsStillRejected() throws {
  let recorder = try liveRecorder(),started = try XCTUnwrap(recorder.events.first)
  var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(started)) as? [String:Any])
  object["sequence"] = -1
  let negative = try JSONDecoder().decode(MatchEvent.self,from:JSONSerialization.data(withJSONObject:object))
  XCTAssertThrowsError(try CloudMatchFacts(startIntent:recorder.descriptor.startIntent,starter:true,events:[negative],captureRevisions:[])) { error in
   XCTAssertEqual((error as? CloudError)?.issue,.invalidPayload)
  }
 }

 func testDuplicateZeroSequenceFromSameRecorderRemainsRejected() throws {
  var recorder = try liveRecorder()
  let goal = try recorder.recordQuick(.myGoal,eventID:"duplicate-goal",sourceDeviceID:"watch",now:cloudTime.addingTimeInterval(2))
  var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(goal)) as? [String:Any])
  object["sequence"] = try XCTUnwrap(recorder.events.first).sequence
  let duplicate = try JSONDecoder().decode(MatchEvent.self,from:JSONSerialization.data(withJSONObject:object))
  XCTAssertThrowsError(try CloudMatchFacts(startIntent:recorder.descriptor.startIntent,starter:true,events:[recorder.events[0],duplicate],captureRevisions:[])) { error in
   XCTAssertEqual((error as? CloudError)?.issue,.invalidPayload)
  }
 }
}
