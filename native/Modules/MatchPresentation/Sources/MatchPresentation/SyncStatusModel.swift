import Foundation
import Observation
import MatchStore
import MatchSync

public protocol SyncStatusServing: Sendable {
  func start() async throws
  func stop() async
  func wake() async
  func retry() async
  func state(matchID: String) async throws -> SyncState
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate>
}
public extension SyncStatusServing {
  func retry() async { try? await start(); await wake() }
}
extension MatchSyncService: SyncStatusServing {}

/// This projection never treats an empty ledger or a read failure as a peer receipt.
public struct SyncStatusProjection: Sendable, Equatable {
  public let peer: String
  public let pendingCount: Int?
  public let peerPersisted: Bool
  public let issue: String?
  public let cloud = "云同步尚未接通"
  public let backend: String?
  public init(state: SyncState?, unavailable: SyncIssue?, terminal: Bool) {
    backend = terminal ? "后台待终结" : nil
    let failure = unavailable ?? state?.issue
    issue = failure.map(Self.message)
    if unavailable != nil || state == nil {
      pendingCount = nil; peerPersisted = false; peer = "同步状态待确认"
      return
    }
    let state = state!
    pendingCount = state.unroutedCount + state.pendingACKCount
    peerPersisted = state.lastPeerACKAt != nil && state.unroutedCount == 0 && state.pendingACKCount == 0 && state.receivedGapCount == 0 && failure == nil
    if peerPersisted { peer = "对端已保存" }
    else if state.receivedGapCount > 0 { peer = "同步缺口待补齐" }
    else if state.unroutedCount > 0 { peer = "待传另一台设备" }
    else if state.pendingACKCount > 0 { peer = "等待对端保存确认" }
    else { peer = "尚无对端保存确认" }
  }
  static func message(_ issue: SyncIssue) -> String {
    switch issue {
    case .trustUnavailable: return "尚未建立可信配对，本机记录已保留。"
    case .peerUnavailable: return "对端暂不可用，本机记录已保留。"
    case .transportUnavailable: return "传输暂不可用，可重试同步。"
    case .retryScheduled: return "稍后将重试同步。"
    case .ancestryIncomplete: return "同步事实尚不完整，等待补齐。"
    case .invalidPayload, .blockedIntegrity: return "同步记录需要核对，保存状态未知。"
    case .quotaExceeded: return "同步暂存已满，请保留本机记录后重试。"
    }
  }
}

@MainActor @Observable public final class SyncStatusModel {
  public private(set) var state: SyncState?
  public private(set) var unavailable: SyncIssue?
  public private(set) var matchID: String?
  public private(set) var retrying = false
  @ObservationIgnored let service: (any SyncStatusServing)?
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var lifecycle = UUID()
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var shuttingDown = false
  public init(service: (any SyncStatusServing)?) { self.service = service }
  /// Scheduling sync cannot hold the local recovery/recording path behind a transport await.
  public func start() async {
    guard !started, startup == nil, !shuttingDown, let service else { return }
    let lifetime = lifecycle
    startup = Task { [weak self] in
      guard !Task.isCancelled else { return }
      do {
        try await service.start()
        guard !Task.isCancelled, let self, self.lifecycle == lifetime else {
          // shutdown joins this task before permitting a new lifecycle to start;
          // a non-cooperative late activation therefore cannot outlive the old instance.
          await service.stop()
          return
        }
        self.started = true
        defer { if self.lifecycle == lifetime { self.startup = nil } }
        if let match = self.matchID {
          let observationGeneration = self.generation
          do {
            let value = try await service.state(matchID: match)
            guard !Task.isCancelled, self.lifecycle == lifetime, self.generation == observationGeneration else { return }
            self.accept(.state(value), expectedMatchID: match)
          } catch {
            guard !Task.isCancelled, self.lifecycle == lifetime, self.generation == observationGeneration else { return }
            self.accept(.unavailable(matchID: match, issue: .blockedIntegrity), expectedMatchID: match)
          }
        }
      } catch {
        guard !Task.isCancelled, let self, self.lifecycle == lifetime else { return }
        self.startup = nil; self.unavailable = .blockedIntegrity; self.state = nil
      }
    }
  }
  public func observe(matchID: String) {
    guard self.matchID != matchID else { return }
    observation?.cancel(); generation = UUID(); self.matchID = matchID
    state = nil; unavailable = nil
    guard let service else { unavailable = .transportUnavailable; return }
    let generation = generation
    observation = Task { [weak self] in
      let stream = await service.states(matchID: matchID)
      for await update in stream {
        guard !Task.isCancelled, let self, self.generation == generation else { return }
        self.accept(update, expectedMatchID: matchID)
      }
    }
  }
  func accept(_ update: SyncStateUpdate, expectedMatchID: String) {
    guard matchID == expectedMatchID else { return }
    switch update {
    case .state(let value):
      guard value.matchID == expectedMatchID else { return }
      state = value; unavailable = nil
    case .unavailable(let id, let issue):
      guard id == expectedMatchID else { return }
      state = nil; unavailable = issue
    }
  }
  public func retry() async {
    guard !retrying, !shuttingDown else { return }; retrying = true; defer { retrying = false }
    let lifetime = lifecycle, observationGeneration = generation
    await service?.retry()
    guard lifecycle == lifetime, generation == observationGeneration, !shuttingDown, let matchID, let service else { return }
    do {
      let value = try await service.state(matchID: matchID)
      guard lifecycle == lifetime, generation == observationGeneration, !shuttingDown else { return }
      accept(.state(value), expectedMatchID: matchID)
    } catch {
      guard lifecycle == lifetime, generation == observationGeneration, !shuttingDown else { return }
      accept(.unavailable(matchID: matchID, issue: .blockedIntegrity), expectedMatchID: matchID)
    }
  }
  public func wake() async { await service?.wake() }
  public func shutdown() async {
    shuttingDown = true; lifecycle = UUID(); generation = UUID()
    let starting = startup; startup = nil; started = false; starting?.cancel()
    observation?.cancel(); observation = nil
    matchID = nil; state = nil; unavailable = nil
    await service?.stop()
    await starting?.value
    shuttingDown = false
  }
  public func projection(terminal: Bool) -> SyncStatusProjection { SyncStatusProjection(state: state, unavailable: unavailable, terminal: terminal) }
}
