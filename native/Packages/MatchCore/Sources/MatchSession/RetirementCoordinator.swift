import Foundation
import MatchCore
import MatchStore

extension MatchSession {
  func requireBusinessActive() throws {
    guard !businessRetired else { throw SessionError.retired }
  }
  func acquireBusinessPermit(for intent: StartIntent) async throws -> TrustedStartPermit {
    try requireBusinessActive()
    let permit = try await permits.acquire(for: intent)
    try requireBusinessActive()
    return permit
  }
  func beginBusiness() throws { try requireBusinessActive(); businessEntries += 1 }
  func endBusiness() {
    businessEntries -= 1
    if businessEntries == 0 {
      let waiting = businessDrainers; businessDrainers.removeAll()
      waiting.forEach { $0.resume() }
    }
  }
  /// Permanent business retirement. The repository and Lifecycle/Saga facade remain open.
  /// In-flight gateway calls are joined, never cancelled or replaced with synthetic results.
  /// A failed drain throws; a later call retries retained observations through SQL only.
  public func retireBusiness() async throws {
    if let retirement { return try await retirement.value }
    businessRetired = true
    captureWakeups.removeAll(); recoveryRequested.removeAll()
    for entries in subscribers.values { for entry in entries.values { entry.continuation.finish() } }
    subscribers.removeAll()
    let task = Task { try await self.drainBusiness() }
    retirement = task
    // Every concurrent caller sees the same task/result. Only a subsequent call may retry SQL.
    defer { retirement = nil }
    try await task.value
  }
  private func drainBusiness() async throws {
    if businessEntries > 0 { await withCheckedContinuation { businessDrainers.append($0) } }
    let drivers = Array(captureTasks.values), reads = Array(initialReads.values)
    for task in drivers { await task.value }
    for task in reads { await task.value }
    if let key = captureErrors.keys.sorted().first, let error = captureErrors.removeValue(forKey: key) {
      throw error
    }
    for key in unsavedObservations.keys.sorted() {
      guard let original = unsavedObservations[key] else { continue }
      try await saveObservation(original.observation, operation: original.operation, retryingRetained: true)
      unsavedObservations.removeValue(forKey: key)
      observationCommits.removeValue(forKey: key)
    }
  }
}
