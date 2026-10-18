import Foundation

public actor CloudSyncService {
    public let scope: CloudScope
    let ledger: any CloudLedger
    let driver: any CloudDriver
    let sink: any CloudCommitSink
    let clock: @Sendable () -> Date
    private var running = false
    public init(scope: CloudScope, ledger: any CloudLedger, driver: any CloudDriver, sink: any CloudCommitSink = UnavailableCloudCommitSink(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope; self.ledger = ledger; self.driver = driver; self.sink = sink; self.clock = clock
    }
    public func synchronize() async throws -> CloudSyncOutcome {
        guard !running else { return CloudSyncOutcome(issue: .unknown) }
        running = true; defer { running = false }
        let pending = try await ledger.batches(scope: scope).filter { $0.state == .pending }
        if !pending.isEmpty {
            var imported: [String] = []
            for entry in pending {
                let result = try await importStaged(entry.batch)
                if let issue = result.issue { return CloudSyncOutcome(importedBatchIDs: imported, issue: issue) }
                imported.append(entry.batch.batchID)
            }
            return CloudSyncOutcome(importedBatchIDs: imported)
        }
        do {
            // The business transaction is the sole authority for both token and generation.
            let cursor = try await sink.appliedCursor(scope: scope)
            let batch = try await driver.fetch(scope: scope, cursor: cursor)
            guard batch.scope == scope, batch.expectedAppliedToken == cursor.appliedToken, batch.fetchGeneration == cursor.fetchGeneration else { throw CloudError(.cursorMismatch) }
            try await ledger.stage(batch)
            return try await importStaged(batch)
        } catch { return CloudSyncOutcome(issue: issue(error)) }
    }
    private func importStaged(_ batch: CloudFetchBatch) async throws -> CloudSyncOutcome {
        do {
            let acknowledgement = try await sink.importBatch(batch)
            guard try acknowledgement.matches(batch) else { throw CloudError(.invalidPayload) }
            try await ledger.acknowledge(acknowledgement)
            return CloudSyncOutcome(importedBatchIDs: [batch.batchID])
        } catch {
            let code = issue(error)
            try await ledger.failBatch(scope: scope, id: batch.batchID, issue: code, at: clock(), nextAttemptAt: nil)
            return CloudSyncOutcome(issue: code)
        }
    }
    func issue(_ error: any Error) -> CloudIssue { (error as? CloudError)?.issue ?? .unknown }
}
