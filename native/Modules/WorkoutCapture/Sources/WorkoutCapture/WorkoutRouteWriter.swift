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
/// Actual acceptance windows, including historical pauses for delayed Core Location batches.
@MainActor public final class CaptureAcceptanceTimeline {
  private var start: Date?
  private var pauses: [(Date, Date?)] = []
  public private(set) var paused = false
  public init(start: Date? = nil) { self.start = start }
  public func begin(at date: Date) { if start == nil { start = date } }
  public func setPaused(_ value: Bool, at date: Date) {
    if value {
      if !paused { pauses.append((date, nil)); paused = true }
      else if let last = pauses.indices.last, date < pauses[last].0 { pauses[last].0 = date }
    } else if paused, let last = pauses.indices.last {
      pauses[last].1 = max(pauses[last].0, date); paused = false
    }
  }
  func continuity(at date: Date) -> Int? {
    guard date.timeIntervalSinceReferenceDate.isFinite, start.map({ date >= $0 }) ?? true else { return nil }
    var epoch = 0
    for (pause, resume) in pauses {
      if date >= pause {
        guard let resume, date >= resume else { return nil }; epoch += 1
      }
    }
    return epoch
  }
}
@MainActor public final class WorkoutRouteWriter {
  public private(set) var failed = false
  private let sink: any RouteSink
  private let timeout: Duration
  private let timeline: CaptureAcceptanceTimeline
  private var tail: Task<Void, Never>?
  private var stopped = false
  private var latestDate: Date?
  public init(sink: any RouteSink, timeout: Duration = .seconds(10), timeline: CaptureAcceptanceTimeline? = nil) { self.sink = sink; self.timeout = timeout; self.timeline = timeline ?? CaptureAcceptanceTimeline() }
  public func setPaused(_ paused: Bool, at date: Date = Date()) { timeline.setPaused(paused, at: date) }
  @discardableResult public func append(_ point: RoutePoint) -> Bool {
    guard !timeline.paused, !stopped, !failed, point.valid, let continuity = timeline.continuity(at: point.timestamp), latestDate.map({ point.timestamp > $0 }) ?? true else { return false }
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
