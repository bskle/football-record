import Foundation
import MatchCore
import MatchStore
import MatchSession

public enum IntegrationMode: Codable, Equatable, Hashable, Sendable {
  case production
  case uiSimulation(dataset: String)
  case deviceAcceptance
  public var dataset: String? {
    switch self { case .production: nil; case .uiSimulation(let dataset): dataset; case .deviceAcceptance: "device-acceptance-v1" }
  }
  public func validate() throws {
    if case .uiSimulation(let dataset) = self {
      guard !dataset.isEmpty, dataset.utf8.count <= 80, dataset.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), dataset != IntegrationMode.deviceAcceptance.dataset else { throw SessionError.invalidRequest }
    }
  }
  public var title: String {
    switch self { case .production: "正式入口"; case .uiSimulation: "纯界面演练"; case .deviceAcceptance: "真实设备验收" }
  }
}
@MainActor public struct EnvironmentPreferences {
  public static let key = "football-record.debug-environment.v1"
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public func load() throws -> IntegrationMode {
    guard defaults.object(forKey: Self.key) != nil else { return .production }
    guard let data = defaults.data(forKey: Self.key) else { throw SessionError.invalidRequest }
    let value = try JSONDecoder().decode(IntegrationMode.self, from: data)
    try value.validate()
    return value
  }
  public func save(_ mode: IntegrationMode) throws { try mode.validate(); defaults.set(try JSONEncoder().encode(mode), forKey: Self.key) }
}
public enum IntegrationSafety {
  public static func permitsLeaving(lockReleased: Bool, active: Bool, capture: CapturePhase, pendingOperations: Bool) -> Bool {
    guard lockReleased, !active, !pendingOperations else { return false }
    switch capture { case .notRequested, .notRecorded, .finished: return true; default: return false }
  }
}
public struct DeviceDatasetGate: Sendable {
  public static let namespace = "ui-simulation-device-acceptance-v1"
  private let rootDirectory: URL?
  public init(rootDirectory: URL? = nil) { self.rootDirectory = rootDirectory }
  public func isSafeToLeave() async throws -> Bool {
    let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record", isDirectory: true)
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: Self.namespace)
    do {
      var safe = true
      for id in try await repo.matchIDs() {
        let s = try await repo.snapshotV2(matchID: id)
        if s.business.diagnostics.contains(where: { $0.severity == .blocking }) { safe = false }
        let replay = MatchReplay.replay(descriptor: s.business.descriptor, events: s.business.events, now: .now, completionEvidence: s.business.completionEvidence)
        let pending = s.captureOperations.contains { [.pending, .needsReconciliation].contains($0.state) }
        let tokens = Dictionary(grouping: s.captureOperations, by: { $0.operation.externalToken })
        let knownClosed = tokens.values.allSatisfy { records in
          if records.contains(where: { if case .linked = $0.observation?.outcome { return true }; return false }) { return true }
          return records.allSatisfy { record in
            if record.state == .cancelled { return true }
            if case .notCreated = record.observation?.outcome { return true }
            return false
          }
        }
        let capture: CapturePhase = knownClosed ? .finished : .needsReconciliation
        if !IntegrationSafety.permitsLeaving(lockReleased: s.business.descriptor.backendLockState == .releasedConfirmed, active: [.notStarted, .running, .paused].contains(replay.state), capture: capture, pendingOperations: pending) || !replay.diagnostics.isEmpty { safe = false }
      }
      try await repo.close()
      return safe
    } catch { try? await repo.close(); throw error }
  }
}
