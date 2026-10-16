#if os(iOS)
import Foundation
@preconcurrency import HealthKit
import MatchCore

@MainActor final class PhoneManualWorkout: AppleWorkoutDriver {
  override init(context: WorkoutContext, store: HKHealthStore, metrics: LiveMetricsChannel, timeout: Duration) {
    super.init(context: context, store: store, metrics: metrics, timeout: timeout)
    let configuration = HKWorkoutConfiguration(); configuration.activityType = .soccer; configuration.locationType = .outdoor
    builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
    var value = LiveWorkoutMetrics(); value.heartRate = .unsupported; metrics.publish(value)
  }
  override func start() async -> DriverState {
    _ = await begin(at: Date())
    return currentState()
  }
  override func pause() async -> DriverState {
    guard !stopRequested, !state.saved else { return currentState() }
    let pauseAt = Date(); acceptance.setPaused(true, at: pauseAt); location?.stopUpdatingLocation()
    let event = HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pauseAt, duration: 0), metadata: nil)
    let added = await sdkBool(timeout: timeout, issue: { [self] done in builder.addWorkoutEvents([event], completion: done) }, actual: { [self] success, _ in
      if success, !stopRequested, !state.saved { state.outcome = .paused } else if !state.saved { state.failure = .captureFailed }
    })
    if added != true, !state.saved { state.failure = .captureFailed }
    return currentState()
  }
  override func resume() async -> DriverState {
    guard !stopRequested, !state.saved else { return currentState() }
    let resumeAt = Date()
    let event = HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: resumeAt, duration: 0), metadata: nil)
    _ = await sdkBool(timeout: timeout, issue: { [self] done in builder.addWorkoutEvents([event], completion: done) }, actual: { [self] success, _ in
      guard !stopRequested, !state.saved else { return }
      if success { state.outcome = .running; acceptance.setPaused(false, at: resumeAt); location?.startUpdatingLocation() } else { state.failure = .captureFailed }
    })
    return currentState()
  }
  override func stop() async -> DriverState {
    requestStop()
    guard collectionStarted, !state.saved else { return currentState() }
    state.outcome = .stopped; state.end = state.end ?? Date(); return currentState()
  }
}
#endif
