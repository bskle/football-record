import Foundation
import XCTest
@testable import HealthKitDeletion
let deletionTime: Int64 = 1_792_343_200
func target(_ uuid: String = "00000000-0000-0000-0000-000000000001", match: String = "match-a", recorder: String = "watch-a", segment: String = "segment-a", source: String = "test.football.phone") throws -> WorkoutDeletionTargetV1 {
 try WorkoutDeletionTargetV1(workoutUUID: UUID(uuidString: uuid)!, matchID: match, recordingDeviceID: recorder, segmentToken: segment, expectedSourceBundleID: source)
}
func request(_ id: UUID = UUID(), targets: [WorkoutDeletionTargetV1]? = nil) throws -> WorkoutDeletionRequestV1 {
 try WorkoutDeletionRequestV1(requestID: id, createdAt: deletionTime, targets: targets ?? [target()])
}
func deletionPaths() throws -> (control: URL, business: URL) {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("health-deletion-"+UUID().uuidString)
 try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
 return (root.appendingPathComponent("control/deletion.sqlite"), root.appendingPathComponent("business"))
}
func expectIssue(_ issue: HealthDeletionIssue, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
 do { try await operation(); XCTFail("Expected \(issue)", file: file, line: line) } catch { XCTAssertEqual(error as? HealthDeletionIssue, issue, file: file, line: line) }
}

func confirmation(_ r: WorkoutDeletionRequestV1, id: UUID = UUID()) throws -> WorkoutDeletionConfirmationV1 {
 try WorkoutDeletionConfirmationV1(confirmationID:id,requestID:r.requestID,selectionDigest:r.selectionDigest(),confirmedAt:deletionTime,explicitHealthDeletion:true)
}
