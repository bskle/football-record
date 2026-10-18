import Foundation
import MatchCore
import MatchSession
import MatchStore

/// Replays committed facts at display time. Ticks never write events or health values.
public struct MatchProjection {
  public let score: String
  public let matchClock: String
  public let fieldClock: String
  public let status: String
  public let onField: Bool
  public let terminal: Bool
  public let paused: Bool
  public let goals: Int
  public let assists: Int
  public let recent: [MatchEvent]
  public let capture: String
  public let captureWarning: String?
  public init(snapshot: SessionSnapshot, now: Date, authorityStatus: AuthorityStatusV4? = nil) {
    if snapshot.store.captureRevisions.max(by: { $0.revision < $1.revision })?.metadata.gaps.isEmpty == false {
      captureWarning = "运动采集存在缺口，未补算缺失数据。"
    } else {
      switch snapshot.captureFailure {
      case .writeDenied: captureWarning = "未获运动写入权限，比赛事实仍已保存。"
      case .locationDenied: captureWarning = "定位不可用，路线未记录。"
      case .routeFailed: captureWarning = "路线记录中断，比赛事实仍已保存。"
      case .recoveryUnavailable: captureWarning = "原运动无法恢复，采集片段需要核对。"
      case .captureFailed: captureWarning = "运动采集失败，等待核对。"
      case .unavailable, nil: captureWarning = nil
      }
    }
    let facts = snapshot.store.business
    let r = MatchReplay.replay(descriptor: facts.descriptor, events: facts.events, now: now, completionEvidence: facts.completionEvidence)
    score = "\(r.score.forTeam) : \(r.score.against)"
    matchClock = Self.clock(r.matchDuration); fieldClock = Self.clock(r.appearanceDuration)
    onField = r.isOnField; paused = r.state == .paused
    terminal = authorityStatus == .releasedAbnormal || authorityStatus == .terminationPending || authorityStatus == .terminal || [.endedPendingSync, .completed, .incomplete, .conflict].contains(r.state)
    goals = r.personalGoals; assists = r.personalAssists
    recent = Array(r.effectiveEvents.sorted { $0.sequence > $1.sequence }.prefix(4))
    if authorityStatus == .releasedAbnormal { status = "记录不完整 · 后台已释放" }
    else if authorityStatus == .terminationPending || authorityStatus == .terminal { status = "后台待终结" }
    else { switch r.state {
    case .notStarted: status = "等待开赛确认"
    case .running: status = "记录中"
    case .paused: status = "已暂停"
    case .endedPendingSync: status = "已结束 · 待同步"
    case .completed: status = "已完整保存"
    case .incomplete: status = "记录不完整"
    case .conflict: status = "记录需核对"
    }
    }
    switch snapshot.capturePhase {
    case .notRequested: capture = "未开始采集"
    case .pending: capture = "采集准备中"
    case .recording: capture = "正在采集"
    case .paused: capture = "采集已暂停"
    case .savedAwaitingLink: capture = "已保存 · 待解锁关联"
    case .finished: capture = "采集已保存"
    case .needsReconciliation: capture = "采集状态待核对"
    case .notRecorded: capture = "未记录运动数据"
    }
  }
  public static func clock(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "未记录" }
    let total = Int(min(seconds, Double(Int.max / 2)))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
  public static func title(_ event: MatchEvent) -> String {
    if let quick = event.quickAction { return title(quick) }
    switch event.type {
    case .matchStarted: return "比赛开始"
    case .matchPaused: return "暂停比赛"
    case .matchResumed: return "继续比赛"
    case .enteredField: return "上场"
    case .leftField: return "下场"
    case .matchEnded: return "结束比赛"
    case .matchTerminated: return "比赛异常结束"
    default: return "比赛记录"
    }
  }
  public static func title(_ quick: QuickRecordAction) -> String {
    switch quick { case .myGoal: return "我进球"; case .myAssist: return "我助攻"; case .teamGoal: return "进球"; case .conceded: return "失球" }
  }
}
/// Transient health channel. Deliberately absent from every business command and snapshot.
public enum MetricValue: Sendable, Equatable {
  case available(Double), notRecorded, unsupported
  public func text(unit: String) -> String {
    switch self {
    case .notRecorded: return "未记录"
    case .unsupported: return "不支持"
    case .available(let n):
      guard n.isFinite, n >= 0 else { return "未记录" }
      let value = n.formatted(.number.precision(.fractionLength(0...1)))
      return unit.isEmpty ? value : value + " " + unit
    }
  }
}
public struct LiveMetrics: Sendable, Equatable {
  public var heartRate: MetricValue = .notRecorded
  public var distance: MetricValue = .notRecorded
  public var speed: MetricValue = .notRecorded
  public var gps: String = "未记录"
  public init() {}
}
