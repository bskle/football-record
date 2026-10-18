import Foundation

public enum CloudLedgerFault: Sendable { case beforeCommit, afterCommitResponseLost }
public protocol CloudLedger: Sendable {
 func enqueue(_ upload: CloudUpload) async throws
 func uploads(scope: CloudScope) async throws -> [CloudUploadEntry]
 func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws
 func stage(_ batch: CloudFetchBatch) async throws
 func batches(scope: CloudScope) async throws -> [CloudBatchEntry]
 func acknowledge(_ acknowledgement: CloudImportAcknowledgement) async throws
 func failBatch(scope: CloudScope, id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws
 func scopeState(scope: CloudScope) async throws -> CloudScopeState
 func recordScopeIssue(scope: CloudScope, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws
 func clearScopeIssue(scope: CloudScope) async throws
 func retainConflict(_ conflict: CloudConflict) async throws
 func conflicts(scope: CloudScope) async throws -> [CloudConflict]
 func confirmUpload(_ evidence: DevelopmentCloudSaveEvidence) async throws
 func saveEvidence(scope: CloudScope) async throws -> [DevelopmentCloudSaveEvidence]
}
