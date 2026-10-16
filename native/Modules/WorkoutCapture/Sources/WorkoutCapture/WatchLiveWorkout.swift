#if os(watchOS)
import Foundation
@preconcurrency import HealthKit
import MatchCore

@MainActor final class WatchLiveWorkout: AppleWorkoutDriver, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  let session: HKWorkoutSession
  var liveBuilder: HKLiveWorkoutBuilder { builder as! HKLiveWorkoutBuilder }
  init(newContext context: WorkoutContext, store: HKHealthStore, metrics: LiveMetricsChannel, timeout: Duration) throws {
    let configuration = HKWorkoutConfiguration(); configuration.activityType = .soccer; configuration.locationType = .outdoor
    session = try HKWorkoutSession(healthStore: store, configuration: configuration)
    super.init(context: context, store: store, metrics: metrics, timeout: timeout)
    builder = session.associatedWorkoutBuilder()
    let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
    liveBuilder.dataSource = source; connect()
    var value = LiveWorkoutMetrics()
    if !source.typesToCollect.contains(HKObjectType.quantityType(forIdentifier: .heartRate)!) { value.heartRate = .unsupported }
    if !source.typesToCollect.contains(HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!) { value.distanceMeters = .unsupported }
    metrics.publish(value)
  }
  init(recovered session: HKWorkoutSession, context: WorkoutContext, store: HKHealthStore, metrics: LiveMetricsChannel, timeout: Duration) {
    self.session = session
    super.init(context: context, store: store, metrics: metrics, timeout: timeout)
    builder = session.associatedWorkoutBuilder(); collectionStarted = true
    // A stopped recovered session may already have an unresolved finish request. Never issue another finish blindly.
    saveAttempted = session.state == .stopped || session.state == .ended
    collectionEnded = builder.endDate != nil
    state = DriverState(outcome: session.state == .paused ? .paused : session.state == .running ? .running : session.state == .stopped || session.state == .ended ? .stopped : .unknown, start: session.startDate, end: session.endDate)
    connect()
    if state.outcome == .running || state.outcome == .paused { setupLocation(); if state.outcome == .paused { route?.setPaused(true); location?.stopUpdatingLocation() } }
  }
  func connect() { session.delegate = self; liveBuilder.delegate = self }
  override func start() async -> DriverState {
    let actual = Date(); session.startActivity(with: actual); _ = await begin(at: actual); return currentState()
  }
  override func pause() async -> DriverState {
    guard !stopRequested, !state.saved else { return currentState() }
    route?.setPaused(true); location?.stopUpdatingLocation(); session.pause()
    return await waitFor(.paused)
  }
  override func resume() async -> DriverState {
    guard !stopRequested, !state.saved else { return currentState() }
    session.resume(); return await waitFor(.running)
  }
  override func requestStop() { super.requestStop(); if session.state != .stopped && session.state != .ended { session.stopActivity(with: Date()) } }
  override func stop() async -> DriverState { requestStop(); return await waitFor(.stopped) }
  override func endSession() { if state.saved { session.end() } }
  func waitFor(_ expected: WorkoutOutcome) async -> DriverState {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
    while state.outcome != expected, !state.saved, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    var result = currentState()
    if result.outcome != expected && !result.saved { result.failure = .captureFailed }
    return result
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
    Task { @MainActor [weak self] in
      guard let self, !self.state.saved else { return }
      switch toState {
      case .running:
        guard !self.stopRequested else { self.session.stopActivity(with: Date()); return }
        self.state.outcome = .running; self.state.start = self.state.start ?? self.session.startDate
        self.route?.setPaused(false); self.location?.startUpdatingLocation()
      case .paused: self.state.outcome = .paused; self.route?.setPaused(true); self.location?.stopUpdatingLocation()
      case .stopped: self.state.outcome = .stopped; self.state.end = date
      default: break
      }
    }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
    Task { @MainActor [weak self] in guard let self, !self.state.saved else { return }; self.state.failure = .captureFailed }
  }
  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
  nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    Task { @MainActor [weak self] in
      guard let self, !self.stopRequested, self.state.outcome == .running else { return }
      var value = self.metrics.latest
      let hr = HKObjectType.quantityType(forIdentifier: .heartRate)!
      let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
      if collectedTypes.contains(hr), let quantity = self.liveBuilder.statistics(for: hr)?.mostRecentQuantity() { value.heartRate = .nonNegative(quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }
      if collectedTypes.contains(distance), let quantity = self.liveBuilder.statistics(for: distance)?.sumQuantity() { value.distanceMeters = .nonNegative(quantity.doubleValue(for: .meter())) }
      self.metrics.publish(value)
    }
  }
}
#endif
