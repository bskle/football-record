import Foundation
import MatchCore

/// Only non-health, stable binding metadata is written alongside the real HealthKit workout.
public enum WorkoutMetadata {
  public static let matchKey = "app.football-record.match-id"
  public static let deviceKey = "app.football-record.recording-device-id"
  public static let tokenKey = "app.football-record.segment-token"
  public static func values(context: WorkoutContext) -> [String: String] {
    [matchKey: context.binding.matchID, deviceKey: context.binding.recordingDeviceID, tokenKey: context.externalToken]
  }
  public static func matchesSaved(source: String, expectedSource: String, metadata: [String: Any], context: WorkoutContext) -> Bool {
    !expectedSource.isEmpty && source == expectedSource && matches(metadata, context: context)
  }
  public static func matches(_ metadata: [String: Any], context: WorkoutContext) -> Bool {
    values(context: context).allSatisfy { metadata[$0.key] as? String == $0.value }
  }
}
#if os(iOS) || os(watchOS)
@preconcurrency import HealthKit

@MainActor func querySavedWorkout(store: HKHealthStore, sourceBundleID: String, context: WorkoutContext, timeout: Duration) async -> DriverState? {
  let task = Task { @MainActor in
    await withCheckedContinuation { (c: CheckedContinuation<DriverState?, Never>) in
      let first = FirstCallback()
      let predicate = HKQuery.predicateForObjects(withMetadataKey: WorkoutMetadata.tokenKey, allowedValues: [context.externalToken])
      let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
        guard first.claim() else { return }
        guard error == nil else { c.resume(returning: nil); return }
        let matches = (samples as? [HKWorkout] ?? []).filter {
          WorkoutMetadata.matchesSaved(source: $0.sourceRevision.source.bundleIdentifier, expectedSource: sourceBundleID, metadata: $0.metadata ?? [:], context: context)
        }
        guard matches.count == 1, let workout = matches.first else { c.resume(returning: nil); return }
        c.resume(returning: DriverState(outcome: .linked(workoutID: workout.uuid.uuidString), start: workout.startDate, end: workout.endDate))
      }
      store.execute(query)
    }
  }
  return await withDeadline(timeout) { await task.value } ?? nil
}
#endif
