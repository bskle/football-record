import Foundation

/// Retained cross-callback evidence, independent of a caller's timed-out await. Not a business database.
@MainActor final class RecoveryEvidenceCache {
  private var records: [String: (WorkoutContext, RecoveryLookup)] = [:]
  func lookup(_ context: WorkoutContext) -> RecoveryLookup? {
    guard let entry = records[context.externalToken], entry.0 == context else { return nil }
    if case .active(let driver) = entry.1, driver.currentState().saved { return .saved(driver.currentState()) }
    return entry.1
  }
  func resolveSaved(_ context: WorkoutContext, query: @MainActor () async -> DriverState?) async -> RecoveryLookup? {
    guard case .saved(let proof) = lookup(context) else { return nil }
    if case .linked = proof.outcome { return .saved(proof) }
    if let actual = await query() { rememberSaved(actual, context: context) }
    // Empty or locked query cannot erase the first nil,nil saved proof.
    return lookup(context)
  }
  func rememberSaved(_ value: DriverState, context: WorkoutContext) {
    guard value.saved else { return }
    if let old = records[context.externalToken] {
      guard old.0 == context else { return }
      if case .saved(let previous) = old.1 { records[context.externalToken] = (context, .saved(previous.merging(value))); return }
    }
    records[context.externalToken] = (context, .saved(value))
  }
  func rememberActive(_ driver: any WorkoutDriver, context: WorkoutContext) {
    if let old = records[context.externalToken] {
      guard old.0 == context else { return }
      if case .saved = old.1 { return }
      return // Keep the first original driver and its delegates; never reattach a duplicate wrapper.
    }
    records[context.externalToken] = (context, .active(driver))
  }
}
