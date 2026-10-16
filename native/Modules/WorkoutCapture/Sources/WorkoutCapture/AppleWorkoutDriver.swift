#if os(iOS) || os(watchOS)
import Foundation
@preconcurrency import HealthKit
@preconcurrency import CoreLocation
import MatchCore

@MainActor class AppleWorkoutDriver: NSObject, WorkoutDriver, CLLocationManagerDelegate {
  let context: WorkoutContext
  let store: HKHealthStore
  let metrics: LiveMetricsChannel
  let timeout: Duration
  var builder: HKWorkoutBuilder!
  var state = DriverState(outcome: .unknown)
  var collectionStarted = false
  var collectionEnded = false
  var collectionEndAttempted = false
  var saveAttempted = false
  var stopRequested = false
  var metadataTask: Task<Bool, Never>?
  let metadataReadiness = MetadataReadiness()
  let acceptance = CaptureAcceptanceTimeline()
  var route: WorkoutRouteWriter?
  var location: CLLocationManager?
  init(context: WorkoutContext, store: HKHealthStore, metrics: LiveMetricsChannel, timeout: Duration) {
    self.context = context; self.store = store; self.metrics = metrics; self.timeout = timeout
    super.init()
  }
  func start() async -> DriverState { state }
  func pause() async -> DriverState { state }
  func resume() async -> DriverState { state }
  func requestStop() { stopRequested = true; location?.stopUpdatingLocation() }
  func stop() async -> DriverState { state }
  func endSession() {}
  func currentState() -> DriverState {
    var result = state
    if route?.failed == true { result.failure = .routeFailed }
    return result
  }
  func apply(_ value: DriverState) {
    state = state.merging(value)
  }
  func begin(at actualStart: Date) async -> Bool {
    acceptance.begin(at: actualStart)
    let builder = builder!
    let result = await sdkBool(timeout: timeout, issue: { done in builder.beginCollection(withStart: actualStart, completion: done) }, actual: { [self] success, _ in
      if success {
        collectionStarted = true
        if !state.saved { if state.outcome == .unknown { state.outcome = .running }; state.start = actualStart }
        metadataTask = Task { @MainActor [self] in
          let added = await sdkBool(timeout: timeout, issue: { [self] done in builder.addMetadata(WorkoutMetadata.values(context: context), completion: done) }, actual: { [self] success, _ in
            metadataReadiness.receive(success: success, terminal: stopRequested,
              startLocation: { [self] in setupLocation() },
              finishOriginal: { [self] in Task { @MainActor in await finishLateCollection() } })
            if !success, !state.saved { state.failure = .captureFailed }
          })
          return added == true
        }
      } else if !state.saved { state.failure = .captureFailed }
    })
    guard result == true else { return false }
    return await metadataTask?.value ?? false
  }
  func endCollection() async -> Bool {
    if collectionEnded { return true }
    guard collectionStarted, WorkoutMetadata.matches(builder.metadata, context: context), !collectionEndAttempted else { return false }
    collectionEndAttempted = true
    await route?.stopAndDrain()
    let actualEnd = state.end ?? Date(); state.end = actualEnd
    let builder = builder!
    let ended = await sdkBool(timeout: timeout, issue: { done in builder.endCollection(withEnd: actualEnd, completion: done) }, actual: { [self] success, _ in
      if success {
        collectionEnded = true
        if stopRequested { Task { @MainActor [self] in _ = await save() } }
      }
    })
    return ended == true
  }
  func save() async -> DriverState {
    if state.saved || saveAttempted { return currentState() }
    guard collectionEnded else { return currentState() }
    saveAttempted = true
    let builder = builder!
    let task = Task { @MainActor [self] in
      await withCheckedContinuation { (c: CheckedContinuation<DriverState, Never>) in
        let first = FirstCallback()
        builder.finishWorkout { workout, error in
          guard first.claim() else { return }
          Task { @MainActor [self] in
            apply(DriverState.savedResult(workoutID: workout?.uuid.uuidString, failed: error != nil,
              start: workout?.startDate ?? state.start, end: workout?.endDate ?? state.end, failure: state.failure))
            if state.saved { endSession() }
            c.resume(returning: currentState())
          }
        }
      }
    }
    if let result = await withDeadline(timeout, operation: { await task.value }) { return result }
    if !state.saved { state.failure = .captureFailed }
    return currentState()
  }
  func finishLateCollection() async {
    requestStop()
    let stopped = await stop()
    if stopped.outcome == .stopped, await endCollection() { _ = await save() }
  }
  func setupLocation() {
    guard !stopRequested, route == nil else { return }
    guard let routeBuilder = builder.seriesBuilder(for: .workoutRoute()) as? HKWorkoutRouteBuilder else { state.failure = .routeFailed; return }
    #if os(iOS)
    let manualDistance = true
    #else
    let manualDistance = false
    #endif
    route = WorkoutRouteWriter(sink: AppleRouteSink(route: routeBuilder, builder: builder, manualDistance: manualDistance, metrics: metrics, timeout: timeout), timeout: timeout, timeline: acceptance)
    let manager = CLLocationManager(); location = manager; manager.delegate = self
    manager.activityType = .fitness; manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = kCLDistanceFilterNone
    #if os(iOS)
    manager.pausesLocationUpdatesAutomatically = false
    // Enable only when NATIVE-010 added the corresponding capability to this actual consumer.
    if (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true { manager.allowsBackgroundLocationUpdates = true }
    #endif
    manager.requestWhenInUseAuthorization(); if !acceptance.paused { manager.startUpdatingLocation() }
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    Task { @MainActor [weak self] in
      guard let self, !self.stopRequested, self.state.outcome == .running else { return }
      for location in locations {
        guard self.state.start.map({ location.timestamp >= $0 }) ?? false else { continue }
        let point = RoutePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, altitude: location.altitude, accuracy: location.horizontalAccuracy, speed: location.speed, timestamp: location.timestamp)
        if self.route?.append(point) == true {
          var value = self.metrics.latest; value.location = .available(location.horizontalAccuracy); value.speedMetersPerSecond = .nonNegative(location.speed); self.metrics.publish(value)
        }
      }
    }
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    let denied = (error as? CLError)?.code == .denied
    Task { @MainActor [weak self] in
      guard let self else { return }; if denied { self.state.failure = .locationDenied }
      var value = self.metrics.latest; value.location = .notRecorded; value.speedMetersPerSecond = .notRecorded; self.metrics.publish(value)
    }
  }
}

@MainActor private final class AppleRouteSink: RouteSink {
  let route: HKWorkoutRouteBuilder
  let builder: HKWorkoutBuilder
  let manualDistance: Bool
  let metrics: LiveMetricsChannel
  let timeout: Duration
  var previous: RoutePoint?
  var distance = 0.0
  init(route: HKWorkoutRouteBuilder, builder: HKWorkoutBuilder, manualDistance: Bool, metrics: LiveMetricsChannel, timeout: Duration) {
    self.route = route; self.builder = builder; self.manualDistance = manualDistance; self.metrics = metrics; self.timeout = timeout
  }
  func insert(_ points: [RoutePoint]) async -> Bool {
    let locations = points.map { CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), altitude: $0.altitude, horizontalAccuracy: $0.accuracy, verticalAccuracy: -1, course: -1, speed: $0.speed, timestamp: $0.timestamp) }
    let inserted = await sdkBool(timeout: timeout, issue: { [route] done in route.insertRouteData(locations, completion: done) })
    guard inserted == true else { return false }
    if manualDistance {
      for point in points {
        if let previous, previous.continuity == point.continuity {
          let delta = CLLocation(latitude: previous.latitude, longitude: previous.longitude).distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
          let type = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
          let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: delta), start: previous.timestamp, end: point.timestamp)
          let added = await sdkBool(timeout: timeout, issue: { [builder] done in builder.add([sample], completion: done) })
          if added == true { distance += delta; var value = metrics.latest; value.distanceMeters = .available(distance); metrics.publish(value) }
        }
        previous = point
      }
    }
    return true
  }
}
#endif
