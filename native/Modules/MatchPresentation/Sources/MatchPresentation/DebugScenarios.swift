#if DEBUG
import Foundation
import MatchCore
import MatchStore
import MatchSession

/// Explicit isolated UI datasets. These are never a real device, lock or HealthKit acceptance.
public enum DebugRecordingScenario: String {
  case syncPending = "sync-pending", syncRetry = "sync-retry", syncSaved = "sync-saved", syncTerminal = "sync-terminal"
  case otherDevice = "other-device", captureGap = "capture-gap"
  case multipleCandidates = "multiple-candidates", identityUnavailable = "identity-unavailable", blockedDiagnostics = "blocked-diagnostics"
}
extension AppBootstrap {
  @MainActor public static func developmentScenario(_ scenario: DebugRecordingScenario, dataset: String) async throws -> RecordingModel {
    if [.syncPending, .syncRetry, .syncSaved, .syncTerminal].contains(scenario) {
      let mode: DevelopmentSyncPair.Mode = scenario == .syncPending ? .queued : scenario == .syncRetry ? .failed : .online
      let pair = try await DevelopmentSyncPair.make(dataset: dataset, mode: mode)
      await pair.model.load()
      if pair.model.snapshot == nil { await pair.model.start(starter: true) }
      if scenario == .syncTerminal, pair.model.canRecord { await pair.model.perform(.end) }
      await pair.settle()
      return pair.model
    }
    let original = try development(dataset: dataset)
    switch scenario {
    case .syncPending, .syncRetry, .syncSaved, .syncTerminal: throw SessionError.invalidRequest
    case .multipleCandidates, .identityUnavailable, .blockedDiagnostics:
      let error: SessionError = scenario == .multipleCandidates ? .multipleCandidates : scenario == .identityUnavailable ? .identityUnavailable : .blockedDiagnostics
      return RecordingModel(session: DebugRecoveryFailure(original.session, error: error), repository: original.repository, development: true, sync: original.syncStatus.service)
    case .otherDevice, .captureGap:
      let request = try await original.session.prepareStart(starter: true)
      let start = try await original.session.execute(request)
      // Wait only for the unavailable adapter's local ledger, never manufacture a Workout UUID.
      for _ in 0..<100 {
        if try await original.repository.pendingCaptureOperations(matchID: request.matchID).isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      if scenario == .otherDevice {
        let namespace = await original.repository.databaseNamespace()
        let other = MatchSession(store: original.repository, deviceIdentity: DebugOtherIdentity(), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: namespace))
        return RecordingModel(session: other, repository: original.repository, development: true, sync: original.syncStatus.service)
      }
      let s = try await original.repository.snapshotV2(matchID: request.matchID)
      let descriptor = s.business.descriptor
      let binding = try CaptureBinding(matchID: request.matchID, recordingDeviceID: descriptor.recordingDeviceID)
      let revision = try CaptureRevision(id: "ui-fixture-gap-revision", binding: binding, parentID: nil, revision: 1, observedAt: Date(), metadata: CaptureMetadata(binding: binding, segments: [], gaps: [CaptureGap(id: "ui-fixture-gap", binding: binding, window: CaptureWindow(start: nil, end: nil))]))
      let item = try BusinessOutboxItem(id: "ui-fixture-gap-outbox", matchID: request.matchID, sourceDeviceID: descriptor.recordingDeviceID, payload: BusinessDeltaV2(descriptor: descriptor, events: [], captureRevisions: [revision]))
      _ = try await original.repository.commitV2(StoreCommitV2(commandID: "ui-fixture-gap-command", expectedGeneration: s.business.generation, descriptor: descriptor, events: [], captureRevisions: [revision], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: [item]))
      _ = start // The committed start is the sole owner of this explicitly synthetic gap dataset.
      return original
    }
  }
}
private struct DebugOtherIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "ui-fixture-other-device" } }
private actor DebugRecoveryFailure: SessionCommanding {
  let underlying: any SessionCommanding; let error: SessionError
  init(_ underlying: any SessionCommanding, error: SessionError) { self.underlying = underlying; self.error = error }
  func prepareStart(starter: Bool) async throws -> SessionRequest { try await underlying.prepareStart(starter: starter) }
  func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest { try await underlying.prepare(action, matchID: matchID) }
  func execute(_ request: SessionRequest) async throws -> SessionReceipt { try await underlying.execute(request) }
  func recover() async throws -> RecoverySelection { throw error }
  func snapshot(matchID: String) async throws -> SessionSnapshot { try await underlying.snapshot(matchID: matchID) }
  func updates(matchID: String) async -> AsyncStream<SessionSnapshot> { await underlying.updates(matchID: matchID) }
}
#endif
