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

final class ControlledDeletionDriver: HealthDeletionDriver, @unchecked Sendable {
 let lock=NSLock()
 private var stored: [HealthDeletionDriverAttempt]=[]
 private var callbacks: [@Sendable (HealthDeletionDriverOutcome) -> Void]=[]
 let onCall: (@Sendable (HealthDeletionDriverAttempt) -> Void)?
 init(onCall: (@Sendable (HealthDeletionDriverAttempt) -> Void)? = nil) { self.onCall=onCall }
 func delete(_ attempt: HealthDeletionDriverAttempt,completion: @escaping @Sendable (HealthDeletionDriverOutcome) -> Void) {
  lock.withLock { stored.append(attempt);callbacks.append(completion) };onCall?(attempt)
 }
 var calls: [HealthDeletionDriverAttempt] { lock.withLock { stored } }
 func answer(_ outcome: HealthDeletionDriverOutcome,index: Int = 0) {
  let callback=lock.withLock { callbacks.indices.contains(index) ? callbacks[index]:nil };callback?(outcome)
 }
 func waitForCalls(_ count: Int) async throws {
  for _ in 0..<300 { if calls.count >= count { return };try await Task.sleep(for:.milliseconds(1)) }
  throw HealthDeletionIssue.unavailable
 }
}
final class DeletionFaultSwitch: @unchecked Sendable {
 private let lock=NSLock()
 private var operation: DeletionWrite?
 private var point: DeletionFault?
 func arm(_ operation: DeletionWrite,_ point: DeletionFault) { lock.withLock { self.operation=operation;self.point=point } }
 func take(_ operation: DeletionWrite) -> DeletionFault? { lock.withLock {
  guard self.operation == operation else { return nil };let value=point;self.operation=nil;point=nil;return value
 } }
}
func confirmedLedger(_ paths: (control: URL,business: URL),_ r: WorkoutDeletionRequestV1) async throws -> SQLiteHealthDeletionLedger {
 let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
 _=try await ledger.submit(r);_=try await ledger.confirm(confirmation(r),now:deletionTime);return ledger
}
func eventually(_ condition: () async throws -> Bool) async throws {
 for _ in 0..<300 { if try await condition() { return };try await Task.sleep(for:.milliseconds(1)) }
 XCTFail("Expected durable callback outcome")
}

import SQLite3
func editControlDB(_ url: URL,_ sql: String) throws {
 var db: OpaquePointer?;guard sqlite3_open(url.path,&db) == SQLITE_OK else { throw HealthDeletionIssue.storageUnavailable }
 defer { sqlite3_close(db) }
 guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw HealthDeletionIssue.storageUnavailable }
}
