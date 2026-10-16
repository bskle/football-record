import Foundation

/// Ephemeral location input; never Codable or part of the business outbox.
public struct RoutePoint: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double
  public let accuracy: Double
  public let speed: Double
  public let timestamp: Date
  public internal(set) var continuity: Int = 0
  public init(latitude: Double, longitude: Double, altitude: Double, accuracy: Double, speed: Double, timestamp: Date) {
    self.latitude = latitude; self.longitude = longitude; self.altitude = altitude; self.accuracy = accuracy; self.speed = speed; self.timestamp = timestamp
  }
  var valid: Bool {
    latitude.isFinite && abs(latitude) <= 90 && longitude.isFinite && abs(longitude) <= 180
      && altitude.isFinite && accuracy.isFinite && accuracy >= 0 && timestamp.timeIntervalSinceReferenceDate.isFinite
  }
}
public protocol RouteSink: Sendable { func insert(_ points: [RoutePoint]) async -> Bool }
@MainActor public final class WorkoutRouteWriter {
  public private(set) var failed = false
  private let sink: any RouteSink
  private let timeout: Duration
  private var tail: Task<Void, Never>?
  private var paused = false
  private var stopped = false
  private var continuity = 0
  private var latestDate: Date?
  public init(sink: any RouteSink, timeout: Duration = .seconds(10)) { self.sink = sink; self.timeout = timeout }
  public func setPaused(_ paused: Bool) { if self.paused != paused { continuity += 1 }; self.paused = paused }
  @discardableResult public func append(_ point: RoutePoint) -> Bool {
    guard !paused, !stopped, !failed, point.valid, latestDate.map({ point.timestamp > $0 }) ?? true else { return false }
    latestDate = point.timestamp; var point = point; point.continuity = continuity
    let acceptedPoint = point
    let previous = tail; let sink = sink; let timeout = timeout
    tail = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.failed else { return }
      let inserted = await withDeadline(timeout) { await sink.insert([acceptedPoint]) }
      if inserted != true { self.failed = true }
    }
    return true
  }
  public func drain() async { await tail?.value }
  public func stopAndDrain() async { stopped = true; await drain() }
}
