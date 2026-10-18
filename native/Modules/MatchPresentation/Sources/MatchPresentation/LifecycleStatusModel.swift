import Foundation
import Observation
import MatchStore
import MatchSession
import AccountKit
import CloudSync

public enum LifecycleUserAction: Sendable {
  case synchronize(String), saveCloudOnly(String), retryControls, abnormal(String), analytics(Bool)
  case prepareMigration(String), checkpoint, importMigration, activateMigration, requestLost, confirmLostEnd, forceMigration
  case delete(cloud: ClientDeletionChoiceV4, local: ClientDeletionChoiceV4, health: ClientDeletionChoiceV4, healthConfirmed: Bool)
  case resumeDeletion(String)
}
public struct DeletionStatusRow: Sendable {
  public let id, title: String
  public let progress: ClientDeletionProgressV4
  public var detail: String {
    switch progress { case .pending: "待处理"; case .running: "正在处理"; case .failed: "尚未完成，可重试"; case .completed: "此项已完成"; case .retained: "已按选择保留" }
  }
}
@MainActor @Observable public final class LifecycleStatusModel {
  public private(set) var matchID: String?
  public private(set) var migration: AuthorityMigrationV1?
  public private(set) var deletions: [DeletionSagaV4] = []
  public private(set) var analyticsEnabled: Bool?
  public private(set) var controls: [ControlQueueEntryV4] = []
  public private(set) var backendStatus: AuthorityStatusV4?
  public private(set) var cloudSaved: Bool?
  public private(set) var cloudIssue: CloudIssue?
  public private(set) var issue: String?
  public private(set) var busy = false
  public let development: Bool
  @ObservationIgnored let repository: SQLiteSessionRepository
  @ObservationIgnored private let ledger: (any CloudLedger)?
  @ObservationIgnored private var scope: CloudScope?
  @ObservationIgnored private let action: (@MainActor (LifecycleUserAction) async throws -> Void)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var stopped = false
  public init(repository: SQLiteSessionRepository, development: Bool = false, ledger: (any CloudLedger)? = nil, scope: CloudScope? = nil, action: (@MainActor (LifecycleUserAction) async throws -> Void)? = nil) {
    self.repository = repository; self.development = development; self.ledger = ledger; self.scope = scope; self.action = action
  }
  public var available: Bool { action != nil && !stopped }
  public var cloudLabel: String {
    if cloudIssue != nil { return "云保存待确认" }
    if cloudSaved == true { return "云端已保存当前完整记录" }
    return available ? "等待云保存确认" : "云同步尚未接通"
  }
  public var backendLabel: String {
    switch backendStatus {
    case .held: "后台比赛锁仍持有"
    case .terminationPending: "后台待终结"
    case .releasedNormal: "后台已正常释放"
    case .releasedAbnormal: "后台已异常释放 · 比赛不完整"
    case .terminal: "后台已终结 · 等待核对结果"
    case .unknown, .none: available ? "后台状态待确认" : "后台服务尚未接通"
    }
  }
  public var migrationTitle: String {
    guard let migration else { return "尚未发起迁移" }
    switch migration.state {
    case "waitingNewPhone": return "等待新手机"
    case "oldPhonePrepared": return "旧手机已准备，等待最终云检查点"
    case "finalCheckpointSaved": return "最终检查点已保存"
    case "oldPhoneDeactivated": return "旧手机已停用，等待新手机校验"
    case "newPhoneVerified": return "新手机已校验，等待激活"
    case "activated": return "迁移已激活"
    case "waitingPeriod": return "正在等待后台七天期限"
    default: return "迁移状态待确认"
    }
  }
  public func remainingWait(now: Date) -> TimeInterval? {
    guard let migration, migration.kind == "lost" else { return nil }
    return max(0, Double(migration.eligibleAt) - now.timeIntervalSince1970)
  }
  public static func deletionRows(_ saga: DeletionSagaV4) -> [DeletionStatusRow] {
    [DeletionStatusRow(id: "backend", title: "后台账号与 Apple 撤销", progress: saga.backendDeleted ? .completed : saga.lastIssue == nil ? .pending : .failed),
     DeletionStatusRow(id: "cloud", title: "CloudKit 比赛数据", progress: saga.cloudProgress),
     DeletionStatusRow(id: "local", title: "本地数据", progress: saga.localDataProgress),
     DeletionStatusRow(id: "health", title: "App 创建的健康运动", progress: saga.healthProgress)]
  }
  public func refresh(matchID: String? = nil) async {
    guard !stopped else { return }; let token = UUID(); generation = token; self.matchID = matchID
    await readStatus(matchID: matchID, token: token)
  }
  private func readStatus(matchID: String?, token: UUID) async {
    do {
      let m = try await repository.latestMigrationV4(), d = try await repository.deletionSagasV4()
      let analytics = try await repository.analyticsEnabledV4(), queue = try await repository.controlQueueV4()
      var saved: Bool?, status: AuthorityStatusV4?, cloudError: CloudIssue?
      if let matchID { saved = try await repository.matchingCloudSaveV4(matchID: matchID) != nil; status = try await repository.authorityStateV4(matchID: matchID, now: Date()).status }
      if let ledger, let scope { cloudError = try await ledger.scopeState(scope: scope).issue }
      guard !stopped, generation == token else { return }
      migration = m; deletions = d; analyticsEnabled = analytics; controls = queue
      cloudSaved = saved; backendStatus = status; cloudIssue = cloudError; issue = nil
    } catch {
      guard !stopped, generation == token else { return }
      migration = nil; deletions = []; analyticsEnabled = nil; controls = []
      cloudSaved = nil; backendStatus = nil; cloudIssue = .unknown; issue = AccountMessages.message(error)
    }
  }
  public func perform(_ value: LifecycleUserAction, matchID: String? = nil) async {
    guard !stopped, !busy, let action else { return }; busy = true; defer { busy = false }
    let observation = generation
    var failure: String?
    do { try await action(value) } catch { failure = AccountMessages.message(error) }
    guard !stopped, generation == observation else { return }
    let refresh = UUID(); generation = refresh; self.matchID = matchID
    await readStatus(matchID: matchID, token: refresh)
    guard !stopped, generation == refresh else { return }
    if let failure { issue = failure }
  }
  func setCloudScope(_ value: CloudScope) { scope = value; generation = UUID(); cloudSaved = nil; backendStatus = nil }
  public func stop() { stopped = true; generation = UUID(); cloudSaved = nil; backendStatus = nil; analyticsEnabled = nil }
}
