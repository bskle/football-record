import Foundation
import MatchCore

public enum WriteAuthorization: Sendable, Equatable { case unknown, allowed, denied }
public enum LocationAuthorization: Sendable, Equatable { case unknown, allowed, denied }
public struct HealthAuthorization: Sendable, Equatable {
  public let available: Bool
  public let write: WriteAuthorization
  public let location: LocationAuthorization
  public init(available: Bool, write: WriteAuthorization, location: LocationAuthorization) {
    self.available = available; self.write = write; self.location = location
  }
}
public enum HealthReadState: Sendable, Equatable { case notRecorded, unsupported; public static let fromEmptyQuery = Self.notRecorded }
/// Intentionally not Codable: samples and live values never enter business persistence or transport.
public enum LiveMetric: Sendable, Equatable {
  case available(Double), notRecorded, unsupported
  public static func nonNegative(_ value: Double?) -> Self {
    guard let value, value.isFinite, value >= 0 else { return .notRecorded }; return .available(value)
  }
}
public struct LiveWorkoutMetrics: Sendable, Equatable {
  public var heartRate: LiveMetric = .notRecorded
  public var distanceMeters: LiveMetric = .notRecorded
  public var speedMetersPerSecond: LiveMetric = .notRecorded
  public var location: LiveMetric = .notRecorded
  public init() {}
}
@MainActor public final class LiveMetricsChannel {
  public private(set) var latest = LiveWorkoutMetrics()
  private var listeners: [UUID: AsyncStream<LiveWorkoutMetrics>.Continuation] = [:]
  public init() {}
  public func updates() -> AsyncStream<LiveWorkoutMetrics> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
      listeners[id] = c; c.yield(latest)
      c.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners.removeValue(forKey: id) } }
    }
  }
  public func publish(_ value: LiveWorkoutMetrics) { latest = value; for c in listeners.values { c.yield(value) } }
}
public struct WorkoutContext: Sendable, Equatable {
  public let binding: CaptureBinding
  public let externalToken: String
  public init(binding: CaptureBinding, externalToken: String) { self.binding = binding; self.externalToken = externalToken }
}
public struct DriverState: Sendable, Equatable {
  public var outcome: WorkoutOutcome
  public var start: Date?
  public var end: Date?
  public var failure: CaptureFailure?
  public init(outcome: WorkoutOutcome, start: Date? = nil, end: Date? = nil, failure: CaptureFailure? = nil) {
    self.outcome = outcome; self.start = start; self.end = end; self.failure = failure
  }
  var saved: Bool { switch outcome { case .linked, .savedAwaitingLink: true; default: false } }
}
@MainActor public protocol WorkoutDriver: AnyObject, Sendable {
  func start() async -> DriverState
  func pause() async -> DriverState
  func resume() async -> DriverState
  func requestStop()
  func stop() async -> DriverState
  func endCollection() async -> Bool
  func save() async -> DriverState
  func endSession()
  func currentState() -> DriverState
}
public enum RecoveryLookup: Sendable {
  case active(any WorkoutDriver), saved(DriverState), unknown
}
@MainActor public protocol WorkoutDriverFactory: AnyObject, Sendable {
  func requestAuthorization() async -> HealthAuthorization
  func makeDriver(context: WorkoutContext) throws -> any WorkoutDriver
  func recover(context: WorkoutContext) async -> RecoveryLookup
}

extension DriverState {
  func merging(_ next: DriverState) -> DriverState {
    if case .linked = outcome { return self }
    if case .savedAwaitingLink = outcome, !next.saved { return self }
    var result = next
    if result.start == nil { result.start = start }
    if result.end == nil { result.end = end }
    if result.failure == nil, failure == .routeFailed { result.failure = .routeFailed }
    return result
  }
  static func savedResult(workoutID: String?, failed: Bool, start: Date?, end: Date?, failure: CaptureFailure? = nil) -> DriverState {
    if let workoutID, !workoutID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return DriverState(outcome: .linked(workoutID: workoutID), start: start, end: end, failure: failure)
    }
    return DriverState(outcome: failed ? .stopped : .savedAwaitingLink, start: start, end: end, failure: failed ? .captureFailed : failure)
  }
}
