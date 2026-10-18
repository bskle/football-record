import Foundation

public actor CloudSyncService {
    public let scope: CloudScope
    let ledger: any CloudLedger
    let driver: any CloudDriver
    let sink: any CloudCommitSink
    let clock: @Sendable () -> Date
    let retryPolicy = CloudRetryPolicy()
    private var running = false
    public init(scope: CloudScope, ledger: any CloudLedger, driver: any CloudDriver, sink: any CloudCommitSink = UnavailableCloudCommitSink(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope; self.ledger = ledger; self.driver = driver; self.sink = sink; self.clock = clock
    }
    public func synchronize() async throws -> CloudSyncOutcome {
        guard !running else { return CloudSyncOutcome(issue: .unknown) }
        running = true; defer { running = false }
        let scopeState = try await ledger.scopeState(scope: scope)
        if scopeState.issue == .accountChanged { return CloudSyncOutcome(issue: .accountChanged) }
        if let next = scopeState.nextAttemptAt, next > clock() { return CloudSyncOutcome(issue: scopeState.issue) }
        let stages = try await ledger.batches(scope: scope)
        if let blocked = stages.first(where: { $0.state == .blocked && $0.issue != .staleGeneration && $0.issue != .cursorMismatch }) {
            return CloudSyncOutcome(issue: blocked.issue ?? .invalidPayload)
        }
        let pending = stages.filter { $0.state == .pending }
        if !pending.isEmpty {
            var imported: [String] = []
            for entry in pending {
                if let next = entry.nextAttemptAt, next > clock() { return CloudSyncOutcome(importedBatchIDs: imported, issue: entry.issue) }
                let result = try await importStaged(entry.batch)
                if let issue = result.issue { return CloudSyncOutcome(importedBatchIDs: imported, issue: issue) }
                imported.append(entry.batch.batchID)
            }
            return CloudSyncOutcome(importedBatchIDs: imported)
        }
        let uploads = try await ledger.uploads(scope: scope).filter { $0.state == .pending }
        if let entry = uploads.first(where: { $0.nextAttemptAt.map { $0 <= clock() } ?? true }) {
            return try await save(entry)
        }
        do {
            // The business transaction is the sole authority for both token and generation.
            let cursor = try await sink.appliedCursor(scope: scope)
            try await ensureActive()
            let batch: CloudFetchBatch
            do { batch = try await driver.fetch(scope: scope, cursor: cursor) }
            catch {
                if issue(error) == .changeTokenExpired {
                    try await ensureActive()
                    let reset = try await sink.resetCursor(scope: scope, expectedGeneration: cursor.fetchGeneration)
                    guard cursor.fetchGeneration < Int64.max, reset.fetchGeneration == cursor.fetchGeneration + 1, reset.appliedToken == nil else { throw CloudError(.invalidPayload) }
                }
                throw error
            }
            try await ensureActive()
            guard batch.scope == scope, batch.expectedAppliedToken == cursor.appliedToken, batch.fetchGeneration == cursor.fetchGeneration else { throw CloudError(.cursorMismatch) }
            try await ledger.stage(batch)
            return try await importStaged(batch)
        } catch {
            if try await ledger.scopeState(scope: scope).issue == .accountChanged { return CloudSyncOutcome(issue: .accountChanged) }
            let code = issue(error)
            try await persistScopeIssue(code)
            return CloudSyncOutcome(issue: code)
        }
    }
    private func importStaged(_ batch: CloudFetchBatch) async throws -> CloudSyncOutcome {
        do {
            try await ensureActive()
            let acknowledgement = try await sink.importBatch(batch)
            try await ensureActive()
            guard try acknowledgement.matches(batch) else { throw CloudError(.invalidPayload) }
            try await ledger.acknowledge(acknowledgement)
            try await ledger.clearScopeIssue(scope: scope)
            return CloudSyncOutcome(importedBatchIDs: [batch.batchID])
        } catch {
            if try await ledger.scopeState(scope: scope).issue == .accountChanged { return CloudSyncOutcome(issue: .accountChanged) }
            let code = issue(error)
            let entries = try await ledger.batches(scope: scope)
            // A transport COMMIT may have succeeded even if its response was lost.
            if entries.first(where: { $0.batch.batchID == batch.batchID })?.state != .confirmed {
                let attempts = entries.first(where: { $0.batch.batchID == batch.batchID })?.attemptCount ?? 0
                let next = try retryPolicy.nextAttempt(issue: code, attempt: attempts + 1, now: clock())
                try await ledger.failBatch(scope: scope, id: batch.batchID, issue: code, at: clock(), nextAttemptAt: next)
            }
            try await persistScopeIssue(code)
            return CloudSyncOutcome(issue: code)
        }
    }
    public func suspendForAccountChange() async throws { try await ledger.recordScopeIssue(scope: scope, issue: .accountChanged, at: clock(), nextAttemptAt: nil) }
    private func ensureActive() async throws {
        guard try await ledger.scopeState(scope: scope).issue != .accountChanged else { throw CloudError(.accountChanged) }
    }
    private func persistScopeIssue(_ code: CloudIssue) async throws {
        let state = try await ledger.scopeState(scope: scope)
        if state.issue == .accountChanged { return }
        let effective: CloudIssue = state.issue == .accountChanged ? .accountChanged : code
        let next = try retryPolicy.nextAttempt(issue: effective, attempt: state.attemptCount + 1, now: clock())
        try await ledger.recordScopeIssue(scope: scope, issue: effective, at: clock(), nextAttemptAt: next)
    }
    private func save(_ entry: CloudUploadEntry) async throws -> CloudSyncOutcome {
        let upload = entry.upload
        do {
            try await ensureActive()
            let result = try await driver.save(upload)
            try await ensureActive()
            switch result {
            case .partial: throw CloudError(.partialSave)
            case .conflict(let recordID, let remote, let changeTag):
                guard recordID == upload.record.recordID else { throw CloudError(.invalidPayload) }
                try await ledger.retainConflict(CloudConflict(upload: upload, remote: remote, changeTag: changeTag))
                throw CloudError(.conflict)
            case .complete(let readback):
                let evidence = try validate(readback, upload: upload)
                try await ledger.confirmUpload(evidence)
                try await ledger.clearScopeIssue(scope: scope)
                return CloudSyncOutcome()
            }
        } catch {
            if try await ledger.scopeState(scope: scope).issue == .accountChanged { return CloudSyncOutcome(issue: .accountChanged) }
            let code = issue(error), rows = try await ledger.uploads(scope: scope)
            if rows.first(where: { $0.upload.id == upload.id })?.state != .confirmed {
                let next = try retryPolicy.nextAttempt(issue: code, attempt: entry.attemptCount + 1, now: clock())
                try await ledger.failUpload(id: upload.id, issue: code, at: clock(), nextAttemptAt: next)
            }
            try await persistScopeIssue(code)
            return CloudSyncOutcome(issue: code)
        }
    }
    private func validate(_ readback: CloudSaveReadback, upload: CloudUpload) throws -> DevelopmentCloudSaveEvidence {
        guard readback.scope == upload.scope, readback.recordID == upload.record.recordID,
              readback.manifestRecordID == upload.checkpointID, readback.manifestCondition == .ifServerRecordUnchanged,
              readback.recordCondition == .ifServerRecordUnchanged else { throw CloudError(.invalidPayload) }
        try CloudCodec.id(readback.manifestChangeTag); try CloudCodec.id(readback.confirmationID)
        try CloudCodec.id(readback.recordChangeTag)
        let manifest = try CloudCodec.decode(CloudSaveManifest.self, readback.manifestBytes, limit: 1024*1024)
        let expected = try CloudSaveManifest(upload: upload, parts: manifest.parts)
        guard manifest == expected, readback.parts.count == manifest.parts.count else { throw CloudError(.invalidPayload) }
        var original = Data()
        for (index, part) in readback.parts.enumerated() {
            try CloudCodec.id(part.changeTag)
            guard part.reference == manifest.parts[index], part.condition == .ifServerRecordUnchanged,
                  part.readBackBytes.count == part.reference.byteCount, CloudCodec.hash(part.readBackBytes) == part.reference.digest else { throw CloudError(.invalidPayload) }
            original.append(part.readBackBytes)
        }
        guard original == upload.record.canonicalBytes, CloudCodec.hash(original) == upload.record.digest else { throw CloudError(.invalidPayload) }
        return DevelopmentCloudSaveEvidence(upload: upload, readback: readback, manifest: manifest)
    }
    func issue(_ error: any Error) -> CloudIssue { (error as? CloudError)?.issue ?? .unknown }
}
