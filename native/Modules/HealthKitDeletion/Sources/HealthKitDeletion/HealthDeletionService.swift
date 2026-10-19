import Foundation

/// A timeout stops waiting, never pretends the SDK operation was cancelled.
public actor HealthDeletionService {
    private let ledger: any HealthDeletionLedger
    private let driver: any HealthDeletionDriver
    private let clock: @Sendable () -> Int64
    private var active: [UUID: UUID]=[:]
    private var waiters: [UUID: CheckedContinuation<Void,Never>]=[:]
    private var deadlines: [UUID: Task<Void,Never>]=[:]
    private var closed=false
    public init(ledger: any HealthDeletionLedger,driver: any HealthDeletionDriver = UnavailableHealthDeletionDriver(),clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.ledger=ledger;self.driver=driver;self.clock=clock
    }
    public func resume(_ requestID: UUID,timeout: Duration = .seconds(5)) async throws -> HealthDeletionEntry {
        guard !closed else { throw HealthDeletionIssue.closed }
        guard timeout > .zero,timeout <= .seconds(60) else { throw HealthDeletionIssue.invalidRequest }
        let prior=try await ledger.entry(requestID)
        guard prior.confirmation != nil else { throw HealthDeletionIssue.unconfirmed }
        if prior.phase == .succeededLocally || prior.phase == .executing || prior.phase == .awaitingOutcome { return prior }
        let attemptID=UUID(),started: HealthDeletionEntry
        do { started=try await ledger.beginAttempt(requestID,attemptID:attemptID) }
        catch HealthDeletionIssue.outcomeUnknown { return try await ledger.entry(requestID) }
        guard !closed else { throw HealthDeletionIssue.closed }
        let attempt=HealthDeletionDriverAttempt(request:started.request,selectionDigest:started.selectionDigest,attemptID:attemptID)
        active[requestID]=attemptID
        await withCheckedContinuation { continuation in
            waiters[attemptID]=continuation
            deadlines[attemptID]=Task { [weak self] in
                do { try await Task.sleep(for:timeout) } catch { return }
                await self?.deadline(requestID,digest:attempt.selectionDigest,attemptID:attemptID)
            }
            driver.delete(attempt) { [weak self] outcome in
                Task { await self?.receive(requestID,digest:attempt.selectionDigest,attemptID:attemptID,outcome:outcome) }
            }
        }
        guard !closed else { throw HealthDeletionIssue.closed }
        return try await ledger.entry(requestID)
    }
    private func wake(_ attemptID: UUID) { waiters.removeValue(forKey:attemptID)?.resume() }
    private func deadline(_ requestID: UUID,digest: String,attemptID: UUID) async {
        guard !closed,active[requestID] == attemptID else { return }
        try? await ledger.markAwaitingOutcome(requestID,digest:digest,attemptID:attemptID)
        deadlines.removeValue(forKey:attemptID)
        wake(attemptID)
    }
    private func receive(_ requestID: UUID,digest: String,attemptID: UUID,outcome: HealthDeletionDriverOutcome) async {
        guard !closed,active[requestID] == attemptID else { return }
        do { try await ledger.finish(requestID,digest:digest,attemptID:attemptID,outcome:outcome,now:clock()) }
        catch {
            // COMMIT may have succeeded; the ledger preserves the first receipt if present.
            try? await ledger.markAwaitingOutcome(requestID,digest:digest,attemptID:attemptID)
        }
        if active[requestID] == attemptID { active.removeValue(forKey:requestID) }
        deadlines.removeValue(forKey:attemptID)?.cancel()
        wake(attemptID)
    }
    public func close() async throws {
        guard !closed else { return };closed=true
        for task in deadlines.values { task.cancel() };deadlines.removeAll();active.removeAll()
        let pending=Array(waiters.values);waiters.removeAll();for continuation in pending { continuation.resume() }
        try await ledger.close()
    }
}
