import Foundation
import XCTest
@testable import CloudSync

final class CloudErasureRetryRaceTests: XCTestCase, @unchecked Sendable {
 func testEraseBetweenFailureCheckAndRetryPersistenceReturnsTerminalIssue() async throws {
  let url = try tempCloudURL(),scope = try cloudScope(),base = try SQLiteCloudLedger(url:url),other = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
  try await base.enqueue(eraseUpload(scope)); await driver.configureSave(issue:.networkUnavailable)
  let proxy = EraseBeforeRetryLedger(base:base,other:other)
  let result = try await CloudSyncService(scope:scope,ledger:proxy,driver:driver).synchronize()
  XCTAssertEqual(result.issue,.accountChanged); XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty))
  try await base.close(); try await other.close()
 }
}

/// Force erase after the service's error-path scope check, before retry persistence.
private actor EraseBeforeRetryLedger: CloudLedger {
 let base,other:SQLiteCloudLedger
 var reads = 0
 init(base:SQLiteCloudLedger,other:SQLiteCloudLedger) { self.base = base; self.other = other }
 func uploads(scope:CloudScope) async throws -> [CloudUploadEntry] {
  reads += 1
  if reads == 2 { _ = try await other.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"retry-race",scope:scope)) }
  return try await base.uploads(scope:scope)
 }
 func enqueue(_ upload:CloudUpload) async throws { try await base.enqueue(upload) }
 func failUpload(id:String,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.failUpload(id:id,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func stage(_ batch:CloudFetchBatch) async throws { try await base.stage(batch) }
 func batches(scope:CloudScope) async throws -> [CloudBatchEntry] { try await base.batches(scope:scope) }
 func acknowledge(_ ack:CloudImportAcknowledgement) async throws { try await base.acknowledge(ack) }
 func failBatch(scope:CloudScope,id:String,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.failBatch(scope:scope,id:id,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func scopeState(scope:CloudScope) async throws -> CloudScopeState { try await base.scopeState(scope:scope) }
 func recordScopeIssue(scope:CloudScope,issue:CloudIssue,at:Date,nextAttemptAt:Date?) async throws { try await base.recordScopeIssue(scope:scope,issue:issue,at:at,nextAttemptAt:nextAttemptAt) }
 func clearScopeIssue(scope:CloudScope) async throws { try await base.clearScopeIssue(scope:scope) }
 func retainConflict(_ conflict:CloudConflict) async throws { try await base.retainConflict(conflict) }
 func conflicts(scope:CloudScope) async throws -> [CloudConflict] { try await base.conflicts(scope:scope) }
 func confirmUpload(_ evidence:DevelopmentCloudSaveEvidence) async throws { try await base.confirmUpload(evidence) }
 func saveEvidence(scope:CloudScope) async throws -> [DevelopmentCloudSaveEvidence] { try await base.saveEvidence(scope:scope) }
}
