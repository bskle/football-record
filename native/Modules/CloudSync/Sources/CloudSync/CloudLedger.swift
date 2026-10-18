import Foundation

public enum CloudLedgerFault: Sendable { case beforeCommit, afterCommitResponseLost }
public protocol CloudLedger: Sendable {
 func enqueue(_ upload: CloudUpload) async throws
 func uploads(scope: CloudScope) async throws -> [CloudUploadEntry]
 func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws
}
