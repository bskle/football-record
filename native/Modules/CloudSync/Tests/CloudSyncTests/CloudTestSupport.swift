import Foundation
import XCTest
import MatchCore
@testable import CloudSync

let cloudTime = Date(timeIntervalSince1970: 1_700_000_000)
func tempCloudURL(_ name: String = "ledger") throws -> URL {
 let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-022-" + UUID().uuidString)
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 return directory.appendingPathComponent(name + ".sqlite")
}
func cloudScope(epoch: Int64 = 1) throws -> CloudScope { try CloudScope(accountID: "account", cloudSpaceID: "space", zoneID: "zone", activationEpoch: epoch) }
func cloudFacts(match: String = "match", deleted: Bool = false) throws -> CloudMatchFacts {
 let intent = StartIntent(id: "intent-" + match, matchID: match, recordingDeviceID: "watch", requestedAt: cloudTime)
 let start = MatchEvent(eventID: "start-" + match, matchID: match, sequence: 1, occurredAt: cloudTime, matchElapsed: 0, type: .matchStarted, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime)
 let end = MatchEvent(eventID: "end-" + match, matchID: match, sequence: 2, occurredAt: cloudTime.addingTimeInterval(10), matchElapsed: 10, type: .matchEnded, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime)
 let tombstone = MatchEvent(eventID: "deleted-" + match, matchID: match, sequence: 3, occurredAt: cloudTime.addingTimeInterval(10), matchElapsed: 10, type: .matchEnded, sourceDeviceID: "watch", createdAt: cloudTime, updatedAt: cloudTime, status: .deleted, correctionOfEventID: end.eventID, revision: 1, authority: .postMatch)
 return try CloudMatchFacts(startIntent: intent, starter: true, events: deleted ? [start,end,tombstone] : [start,end], captureRevisions: [])
}
func cloudRecord(match: String = "match") throws -> CloudRecord { try CloudRecord(scope: cloudScope(), payload: .matchFacts(cloudFacts(match: match))) }
func cloudUpload(id: String? = nil, match: String = "match") throws -> CloudUpload { try CloudUpload(id: id, scope: cloudScope(), record: cloudRecord(match: match), expectedChangeTag: nil) }
func expectCloudError(_ expected: CloudIssue, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
 do { try await operation(); XCTFail("expected " + expected.rawValue, file: file, line: line) } catch let error as CloudError { XCTAssertEqual(error.issue, expected, file: file, line: line) } catch { XCTFail("unexpected \(error)", file: file, line: line) }
}
