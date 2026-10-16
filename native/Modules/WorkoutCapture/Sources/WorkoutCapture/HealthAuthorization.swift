#if os(iOS) || os(watchOS)
import Foundation
@preconcurrency import HealthKit
@preconcurrency import CoreLocation
import MatchCore

@MainActor func sdkBool(timeout: Duration,
  issue: @escaping @MainActor (@escaping @Sendable (Bool, (any Error)?) -> Void) -> Void,
  actual: @escaping @MainActor (Bool, (any Error)?) -> Void = { _, _ in }) async -> Bool? {
  let task = Task { @MainActor in
    await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let first = FirstCallback()
      issue { success, error in
        guard first.claim() else { return }
        Task { @MainActor in actual(success, error); c.resume(returning: success) }
      }
    }
  }
  return await withDeadline(timeout) { await task.value }
}

@MainActor public final class AppleWorkoutDriverFactory: WorkoutDriverFactory {
  public let metrics: LiveMetricsChannel
  let store: HKHealthStore
  let sourceBundleID: String
  let timeout: Duration
  private let locationAuthorization = CLLocationManager()
  #if os(watchOS)
  private var recovered: [String: WatchLiveWorkout] = [:]
  #endif
  public init(metrics: LiveMetricsChannel, timeout: Duration = .seconds(10)) {
    self.metrics = metrics; self.store = HKHealthStore(); self.sourceBundleID = HKSource.default().bundleIdentifier; self.timeout = timeout
  }
  public func requestAuthorization() async -> HealthAuthorization {
    guard HKHealthStore.isHealthDataAvailable(), !sourceBundleID.isEmpty else {
      return HealthAuthorization(available: false, write: .unknown, location: .unknown)
    }
    let workout = HKObjectType.workoutType()
    let route = HKSeriesType.workoutRoute()
    let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
    let hr = HKObjectType.quantityType(forIdentifier: .heartRate)!
    _ = await sdkBool(timeout: timeout, issue: { [store] done in
      store.requestAuthorization(toShare: [workout, route, distance], read: [workout, route, distance, hr], completion: done)
    })
    // Completing the sheet does not disclose read authorization. Only write status is inspected.
    let write: WriteAuthorization
    switch store.authorizationStatus(for: workout) {
    case .sharingAuthorized: write = .allowed
    case .sharingDenied: write = .denied
    default: write = .unknown
    }
    locationAuthorization.requestWhenInUseAuthorization()
    return HealthAuthorization(available: true, write: write, location: locationStatus(locationAuthorization.authorizationStatus))
  }
  public func makeDriver(context: WorkoutContext) throws -> any WorkoutDriver {
    #if os(watchOS)
    return try WatchLiveWorkout(newContext: context, store: store, metrics: metrics, timeout: timeout)
    #else
    return PhoneManualWorkout(context: context, store: store, metrics: metrics, timeout: timeout)
    #endif
  }
  public func recover(context: WorkoutContext) async -> RecoveryLookup {
    if let saved = await querySavedWorkout(store: store, sourceBundleID: sourceBundleID, context: context, timeout: timeout) { return .saved(saved) }
    #if os(watchOS)
    if let driver = recovered[context.externalToken], driver.context == context { return .active(driver) }
    let task = Task { @MainActor [store] in
      await withCheckedContinuation { (c: CheckedContinuation<HKWorkoutSession?, Never>) in
        let first = FirstCallback()
        store.recoverActiveWorkoutSession { session, _ in
          guard first.claim() else { return }; c.resume(returning: session)
        }
      }
    }
    guard let result = await withDeadline(timeout, operation: { await task.value }), let session = result else { return .unknown }
    let builder = session.associatedWorkoutBuilder()
    guard WorkoutMetadata.matches(builder.metadata, context: context) else { return .unknown }
    let driver = WatchLiveWorkout(recovered: session, context: context, store: store, metrics: metrics, timeout: timeout)
    recovered[context.externalToken] = driver
    return .active(driver)
    #else
    // iOS17 has no original manual-builder recovery API. An empty/hidden query cannot prove it was never saved.
    return .unknown
    #endif
  }
}
func locationStatus(_ value: CLAuthorizationStatus) -> LocationAuthorization {
  switch value { case .authorizedAlways, .authorizedWhenInUse: .allowed; case .denied, .restricted: .denied; default: .unknown }
}
#endif
