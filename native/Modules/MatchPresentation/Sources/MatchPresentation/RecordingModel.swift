import Foundation
import Observation
import MatchCore
import MatchSession
import MatchStore

public protocol SessionCommanding: Sendable {
  func prepareStart(starter: Bool) async throws -> SessionRequest
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest
  func execute(_ request: SessionRequest) async throws -> SessionReceipt
  func recover() async throws -> RecoverySelection
  func snapshot(matchID: String) async throws -> SessionSnapshot
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot>
}
extension MatchSession: SessionCommanding {}
@MainActor @Observable public final class RecordingModel {
  public private(set) var snapshot: SessionSnapshot?
  public private(set) var pendingRequest: SessionRequest?
  public private(set) var issue: String?
  public private(set) var busy = false
  public private(set) var readOnly = false
  public private(set) var feedbackCount = 0
  public private(set) var authorityStatus: AuthorityStatusV4?
  @ObservationIgnored private var authorityRead = UUID()
  public var authorityTerminal: Bool { authorityStatus == .releasedAbnormal || authorityStatus == .releasedNormal || authorityStatus == .terminationPending || authorityStatus == .terminal }
  public private(set) var history: [SessionSnapshot] = []
  public var metrics = LiveMetrics()
  public let development: Bool
  public let developmentPair: Bool
  public let syncStatus: SyncStatusModel
  let session: any SessionCommanding
  let repository: any SessionRepository
  public init(session: any SessionCommanding, repository: any SessionRepository, development: Bool, sync: (any SyncStatusServing)? = nil, developmentPair: Bool = false) {
    self.session = session; self.repository = repository; self.development = development
    self.developmentPair = developmentPair; syncStatus = SyncStatusModel(service: sync)
  }
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var observedMatch: String?
  @ObservationIgnored private var lifecycle = UUID()
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var acknowledged = Set<String>()
  public var canRecord: Bool {
    guard !stopped, let snapshot else { return false }
    return !authorityTerminal && !busy && !readOnly && pendingRequest == nil && [.running, .paused].contains(snapshot.replay.state)
  }
  public func load() async {
    guard !busy, !stopped else { return }; busy = true; defer { busy = false }
    let lifetime = lifecycle
    await syncStatus.start()
    do {
      try await refreshHistory()
      var recoveredIssue: String? = readOnly ? nil : issue
      let recovery = try await session.recover()
      guard lifecycle == lifetime, !stopped else { return }
      switch recovery {
      case .none:
        // An ended match with an unreleased lock still owns this installation's record screen.
        if let held = history.first(where: { $0.store.business.descriptor.backendLockState != .releasedConfirmed }) { accept(held) }
      case .active(let value): accept(value)
      case .intentAwaitingPermit(let intent):
        let value = try await session.snapshot(matchID: intent.matchID)
        guard lifecycle == lifetime, !stopped else { return }
        accept(value)
        if pendingRequest == nil {
          pendingRequest = try .start(intent: intent, starter: value.store.business.descriptor.starter)
        }
        recoveredIssue = "开赛服务尚未就绪，开赛请求已保留。"
      }
      if pendingRequest != nil, recoveredIssue == nil {
        recoveredIssue = Self.message(StoreError.responseLost)
      }
      // Only a complete successful recovery may clear a previous recovery failure.
      readOnly = false
      issue = recoveredIssue
      await refreshAuthority()
    } catch {
      guard lifecycle == lifetime, !stopped else { return }
      issue = Self.message(error)
      readOnly = true
      // Only a unique candidate may be displayed; never pick one from an ambiguous set.
      if error as? SessionError == .wrongRecordingDevice {
        let candidates = history.filter { [.running, .paused, .notStarted].contains($0.replay.state) }
        if candidates.count == 1 { accept(candidates[0]) }
      }
    }
  }
  public var canStartNext: Bool {
    guard !stopped, let snapshot else { return false }
    return snapshot.replay.state == .completed || authorityStatus == .releasedAbnormal || (snapshot.replay.state == .incomplete && snapshot.store.business.descriptor.backendLockState == .releasedConfirmed)
  }
  public func start(starter: Bool) async {
    guard !stopped, !busy, !readOnly, snapshot == nil || canStartNext, pendingRequest == nil else { return }
    busy = true; defer { busy = false }
    do { pendingRequest = try await session.prepareStart(starter: starter); await submit() }
    catch { issue = Self.message(error) }
  }
  public func perform(_ action: SessionAction) async {
    guard canRecord, let snapshot else { return }
    busy = true; defer { busy = false }
    do {
      pendingRequest = try await session.prepare(action, matchID: snapshot.replay.matchID)
      await submit()
    } catch { issue = Self.message(error) }
  }
  public func retry() async {
    guard !busy, !readOnly, pendingRequest != nil else { return }
    busy = true; defer { busy = false }; await submit()
  }
  private func submit() async {
    guard let original = pendingRequest else { return }
    do { acknowledge(try await session.execute(original)) }
    catch {
      if error as? StoreError == .staleGeneration, original.startIntent == nil {
        do {
          // Only an explicit stale CAS and a validated lookup miss permit a fresh command.
          guard try await repository.committedCommandV2(commandID: original.commandID) == nil else {
            acknowledge(try await session.execute(original)); return
          }
          accept(try await session.snapshot(matchID: original.matchID))
          let replacement = try await session.prepare(original.action, matchID: original.matchID)
          pendingRequest = replacement
          acknowledge(try await session.execute(replacement)); return
        } catch {
          handleFailure(error)
          return
        }
      }
      handleFailure(error)
    }
  }
  private func handleFailure(_ error: any Error) {
    if error as? MatchCommandError == .debounced { pendingRequest = nil }
    // Do not restore a click-time snapshot: a newer committed capture update may already be visible.
    issue = Self.message(error)
  }
  private func acknowledge(_ result: SessionReceipt) {
    guard !stopped else { return }
    accept(result.snapshot); pendingRequest = nil; issue = nil
    if acknowledged.insert(result.receipt.commandID).inserted { feedbackCount += 1 }
    Task { try? await refreshHistory(); await syncStatus.wake() }
  }
  func accept(_ value: SessionSnapshot) {
    guard !stopped else { return }
    if let snapshot, snapshot.replay.matchID == value.replay.matchID,
       snapshot.store.business.generation > value.store.business.generation { return }
    if snapshot?.replay.matchID != value.replay.matchID { authorityStatus = nil; authorityRead = UUID() }
    snapshot = value
    guard observedMatch != value.replay.matchID else { return }
    observation?.cancel(); observedMatch = value.replay.matchID
    syncStatus.observe(matchID: value.replay.matchID)
    let session = session; let id = value.replay.matchID
    observation = Task { [weak self] in
      let stream = await session.updates(matchID: id)
      for await next in stream {
        guard !Task.isCancelled else { return }
        self?.accept(next)
      }
    }
  }
  public func refreshAuthority() async {
    guard !stopped, let id = snapshot?.replay.matchID, let authority = repository as? any AuthorityRepository else { return }
    let token = UUID(); authorityRead = token
    do {
      let state = try await authority.authorityStateV4(matchID: id, now: Date())
      guard !stopped, authorityRead == token, snapshot?.replay.matchID == id else { return }
      authorityStatus = state.status
    } catch { /* A failed sync query cannot revoke a persisted terminal fence or a legal local command. */ }
  }
  public func shutdown() async {
    stopped = true; lifecycle = UUID(); readOnly = true
    observation?.cancel(); observation = nil; observedMatch = nil
    await syncStatus.shutdown()
  }
  private func refreshHistory() async throws {
    var values: [SessionSnapshot] = []
    for id in try await repository.matchIDs() { values.append(try await session.snapshot(matchID: id)) }
    history = values.sorted { $0.store.business.descriptor.startIntent.requestedAt > $1.store.business.descriptor.startIntent.requestedAt }
  }
  public static func message(_ error: any Error) -> String {
    switch error {
    case SessionError.permitUnavailable: return "开赛服务尚未就绪，开赛请求已保留。"
    case SessionError.wrongRecordingDevice, MatchCommandError.wrongRecordingDevice: return "此比赛由另一台设备记录，本机仅可查看。"
    case SessionError.multipleCandidates: return "发现多场未完成比赛，请先核对记录。"
    case SessionError.identityUnavailable: return "无法确认本机身份，请保留记录并检查设备。"
    case SessionError.blockedDiagnostics: return "记录需要核对，已暂停修改。"
    case SessionError.terminalMatch: return "比赛已结束，等待完整同步后才能开始新比赛。"
    case MatchCommandError.debounced: return "刚刚已记录，稍后可再次快记。"
    case StoreError.staleGeneration: return "记录状态正在更新，请重试。"
    default: return "尚未确认保存成功，已保留原操作，请重试。"
    }
  }
}
