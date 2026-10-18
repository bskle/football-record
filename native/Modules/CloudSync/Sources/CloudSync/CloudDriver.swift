import Foundation

public protocol CloudDriver: Sendable {
 func fetch(scope: CloudScope, cursor: CloudCursor) async throws -> CloudFetchBatch
}
/// 023 supplies a same-facade bridge. This module never writes MatchStore directly.
public protocol CloudCommitSink: Sendable {
 func importBatch(_ batch: CloudFetchBatch) async throws -> CloudImportAcknowledgement
 func appliedCursor(scope: CloudScope) async throws -> CloudCursor
 func resetCursor(scope: CloudScope, expectedGeneration: Int64) async throws -> CloudCursor
}
public struct UnavailableCloudCommitSink: CloudCommitSink {
 public init() {}
 public func importBatch(_ batch: CloudFetchBatch) async throws -> CloudImportAcknowledgement { throw CloudError(.awaitingBusinessImport) }
 public func appliedCursor(scope: CloudScope) async throws -> CloudCursor { throw CloudError(.awaitingBusinessImport) }
 public func resetCursor(scope: CloudScope, expectedGeneration: Int64) async throws -> CloudCursor { throw CloudError(.awaitingBusinessImport) }
}
