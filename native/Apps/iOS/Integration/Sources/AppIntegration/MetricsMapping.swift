import MatchPresentation
import WorkoutCapture

public enum MetricsMapping {
  public static func presentation(_ value: LiveWorkoutMetrics) -> LiveMetrics {
    var result = LiveMetrics()
    result.heartRate = convert(value.heartRate)
    result.distance = convert(value.distanceMeters, factor: 0.001)
    result.speed = convert(value.speedMetersPerSecond, factor: 3.6)
    switch convert(value.location) {
    case .notRecorded: result.gps = "未记录"
    case .unsupported: result.gps = "不支持"
    case .available(let accuracy): result.gps = "精度 " + MetricValue.available(accuracy).text(unit: "m")
    }
    return result
  }
  private static func convert(_ value: LiveMetric, factor: Double = 1) -> MetricValue {
    switch value {
    case .notRecorded: return .notRecorded
    case .unsupported: return .unsupported
    case .available(let number):
      let converted = number * factor
      guard number.isFinite, number >= 0, converted.isFinite else { return .notRecorded }
      return .available(converted)
    }
  }
}
