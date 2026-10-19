import Foundation
import Observation
import MatchStore
import MatchSession
import AccountKit

public enum AccountPhase: String, Sendable { case unavailable, signedOut, pending, waitingMigration, ready, suspended, unknown }
public enum AccountUserAction: Sendable { case signIn, recover, registerWatch, renew, identityChanged }

struct PresentationAccountAdmissionRead: Sendable {
  let binding: AccountBindingV4?
  let identityGeneration: Int64
  let authIDs, watchIDs: [String]
  static func read(_ repository: SQLiteSessionRepository) async throws -> Self {
    let before = try await repository.identityGenerationV4()
    let binding = try await repository.accountBindingV4()
    let auth = try await repository.pendingAuthAttemptsV4(), watches = try await repository.pendingWatchRegistrationAttemptsV4()
    guard try await repository.identityGenerationV4() == before else { throw AuthorityError.identityChanged }
    return Self(binding: binding, identityGeneration: before, authIDs: auth.map(\.requestID), watchIDs: watches.map(\.requestID))
  }
}

func presentationBindingsEqual(_ lhs: AccountBindingV4, _ rhs: AccountBindingV4) -> Bool {
  Data(lhs.accountID.utf8) == Data(rhs.accountID.utf8) && Data(lhs.cloudSpaceID.utf8) == Data(rhs.cloudSpaceID.utf8)
    && Data(lhs.deviceID.utf8) == Data(rhs.deviceID.utf8) && lhs.activationEpoch == rhs.activationEpoch
    && lhs.role == rhs.role && Data(lhs.environment.rawValue.utf8) == Data(rhs.environment.rawValue.utf8) && lhs.suspended == rhs.suspended
}

/// A query projection, never an authentication or activation authority.
@MainActor @Observable public final class AccountStatusModel {
  public private(set) var phase: AccountPhase = .unavailable
  public private(set) var binding: AccountBindingV4?
  public private(set) var pendingAuthIDs: [String] = []
  public private(set) var pendingWatchIDs: [String] = []
  public private(set) var issue: String?
  public private(set) var busy = false
  public private(set) var requiresReload = false
  public let development: Bool
  @ObservationIgnored let repository: SQLiteSessionRepository
  private var identityVerified: Bool
  @ObservationIgnored private let action: (@MainActor (AccountUserAction) async throws -> Void)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var checkedIdentity: (AccountBindingV4, Int64)?
  public convenience init(repository: SQLiteSessionRepository, development: Bool = false, action: (@MainActor (AccountUserAction) async throws -> Void)? = nil) {
    self.init(repository: repository, development: development, identityVerified: false, action: action)
  }
  init(repository: SQLiteSessionRepository, development: Bool = false, identityVerified: Bool, action: (@MainActor (AccountUserAction) async throws -> Void)? = nil) {
    self.repository = repository; self.development = development; self.identityVerified = identityVerified; self.action = action
  }
  public var canEnterRecording: Bool { !stopped && !requiresReload && identityVerified && phase == .ready }
  public var title: String {
    if requiresReload && identityVerified { return "身份已验证，请重新载入记录" }
    return switch phase {
    case .unavailable: "账号服务尚未接通"
    case .signedOut: "登录后开始记录"
    case .pending: "正在确认原登录或登记"
    case .waitingMigration: "这台手机正在等待迁移"
    case .ready: "当前设备已验证"
    case .suspended: "账号或 iCloud 身份需要重新核对"
    case .unknown: "账号状态待确认"
    }
  }
  public var detail: String {
    if requiresReload && identityVerified { return "请使用下方“重新载入本机记录”，再继续录制。原记录会保留。" }
    return switch phase {
    case .unavailable: "本机数据会保留。真实账号与云服务将在完成环境验证后接通。"
    case .waitingMigration: "完成正常迁移，或按丢失设备流程验证后，才能在这台手机录制。"
    case .suspended: "旧数据已保留；核对当前 Apple 与 iCloud 身份后再继续。"
    case .pending: "将使用原请求继续确认，请勿新建请求绕过未知结果。"
    case .signedOut: "球历需要 Apple 与 iCloud 双身份一致。"
    case .ready: development ? "开发账号演练，不代表真实 Apple 或设备验收。" : "账号、设备与云空间已匹配。"
    case .unknown: "无法读取当前状态，暂不进入录制。"
    }
  }
  public func refresh() async {
    guard !stopped else { return }
    let token = UUID(); generation = token
    await readStatus(token: token)
  }
  private func readStatus(token: UUID) async {
    do {
      let value = try await repository.accountBindingV4()
      let auth = try await repository.pendingAuthAttemptsV4()
      let watches = try await repository.pendingWatchRegistrationAttemptsV4()
      var stillVerified = true
      if let checkedIdentity {
        let durableGeneration = try await repository.identityGenerationV4()
        stillVerified = durableGeneration == checkedIdentity.1 && value.map { presentationBindingsEqual($0, checkedIdentity.0) } == true
      }
      guard !stopped, generation == token else { return }
      if !stillVerified { identityVerified = false; checkedIdentity = nil }
      apply(value, authIDs: auth.map(\.requestID), watchIDs: watches.map(\.requestID))
    } catch {
      guard !stopped, generation == token else { return }
      binding = nil; pendingAuthIDs = []; pendingWatchIDs = []; phase = .unknown
      issue = AccountMessages.message(error)
    }
  }
  private func apply(_ value: AccountBindingV4?, authIDs: [String], watchIDs: [String]) {
    binding = value; pendingAuthIDs = authIDs; pendingWatchIDs = watchIDs; issue = nil
    if action == nil { phase = .unavailable }
    else if value == nil && authIDs.isEmpty && watchIDs.isEmpty { phase = .signedOut }
    else if !identityVerified || value?.suspended == true { phase = .suspended }
    else if !authIDs.isEmpty || !watchIDs.isEmpty { phase = .pending }
    else if value?.role == .waiting { phase = .waitingMigration }
    else if value != nil { phase = .ready }
    else { phase = .signedOut }
  }
  public func perform(_ value: AccountUserAction) async {
    guard !stopped, !busy, let action else { return }; busy = true
    defer { busy = false }
    let observation = generation
    var failure: String?
    do { try await action(value) } catch { failure = AccountMessages.message(error) }
    guard !stopped, generation == observation else { return }
    let refresh = UUID(); generation = refresh
    await readStatus(token: refresh)
    guard !stopped, generation == refresh else { return }
    if let failure { issue = failure }
  }
  /// Called only after the identity service has admitted the current identity.
  /// This checks its projection against durable truth; it does not authenticate.
  public func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64) async throws {
    try await admitIdentity(binding, expectedIdentityGeneration: expectedIdentityGeneration, read: { try await PresentationAccountAdmissionRead.read(self.repository) })
  }
  func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64, read: @MainActor () async throws -> PresentationAccountAdmissionRead) async throws {
    guard !stopped else { throw AuthorityError.identityChanged }
    let token = UUID(); generation = token; identityVerified = false; checkedIdentity = nil; phase = .suspended
    let value = try await read()
    let durableGeneration = try await repository.identityGenerationV4()
    guard !stopped, generation == token, expectedIdentityGeneration >= 0,
          value.identityGeneration == expectedIdentityGeneration, durableGeneration == expectedIdentityGeneration,
          let current = value.binding, !current.suspended, !binding.suspended,
          presentationBindingsEqual(current, binding) else { throw AuthorityError.identityChanged }
    checkedIdentity = (current, expectedIdentityGeneration); identityVerified = true
    apply(current, authIDs: value.authIDs, watchIDs: value.watchIDs)
  }
  public func requireReload() { requiresReload = true; generation = UUID() }
  func confirmIdentity() { guard !stopped else { return }; checkedIdentity = nil; identityVerified = true }
  public func pauseIdentity() { checkedIdentity = nil; identityVerified = false; phase = .suspended; generation = UUID() }
  public func stop() { stopped = true; checkedIdentity = nil; generation = UUID(); binding = nil; phase = .unavailable }

}

enum AccountMessages {
  static func message(_ error: any Error) -> String {
    if let value = error as? AuthorityError {
      switch value {
      case .identityChanged: return "账号或云身份已变化，请重新核对。"
      case .staleAttestation: return "原验证已过期，请明确重新验证。"
      case .unavailable: return "服务暂不可用，原请求和本机数据已保留。"
      default: return "返回记录需要核对，状态尚未确认。"
      }
    }
    if let value = error as? LifecycleClientError {
      switch value {
      case .pendingBusiness: return "仍有比赛或采集待终结，请先处理。"
      case .pendingCloud: return "仍有数据等待云保存，请稍后重试。"
      case .cloudConflict: return "云数据有冲突，迁移暂未继续。"
      case .reauthenticationRequired: return "此操作需要重新验证 Apple 身份。"
      case .receiptExpired: return "原恢复凭据已过期，需要重新验证。"
      default: return "原步骤尚未确认，请继续核对。"
      }
    }
    if let value = error as? AuthorityHTTPFailure {
      switch value.code {
      case "waitingPeriod": return "后台等待期尚未结束，请保留原迁移请求。"
      case "reauthenticationRequired": return "此操作需要重新验证 Apple 身份。"
      case "activeMatchExists", "migrationBlocked": return "后台仍有待处理比赛，尚不能继续。"
      default: return "网络结果尚未确认，原请求已保留。"
      }
    }
    if (error as? WatchRegistrationError) == .knownAbandoned { return "原登记已验证关闭；可明确开始新的登记。" }
    return "暂未确认操作结果，原请求和数据已保留。"
  }
}
