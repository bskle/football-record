import Foundation
import MatchCore
import MatchStore

extension MatchSession {
  public func recover() async throws -> RecoverySelection {
    try beginBusiness(); defer { endBusiness() }
    try await validateEnvironment()
    let device = try await identity()
    var candidates: [StoreSnapshotV2] = []
    for match in try await store.matchIDs() {
      var s = try await store.snapshotV2(matchID: match)
      if s.business.descriptor.recordingDeviceID == device {
        try await learnAuthorityForRecovery(s)
        s = try await store.snapshotV2(matchID: match)
        try await updateAuthorityFence(s)
      }
      try requireBusinessActive()
      guard !s.business.diagnostics.contains(where: { $0.severity == .blocking }) else {
        throw SessionError.blockedDiagnostics
      }
      if !terminal(s) {
        candidates.append(s)
      } else if s.business.descriptor.recordingDeviceID == device {
        scheduleCapture(match)
      }
    }
    try requireBusinessActive()
    guard candidates.count <= 1 else { throw SessionError.multipleCandidates }
    guard let candidate = candidates.first else { return .none }
    try requireWritable(candidate, device: device)
    if candidate.business.descriptor.startPermit == nil {
      return .intentAwaitingPermit(candidate.business.descriptor.startIntent)
    }
    let value = try projected(candidate)
    recoveryRequested.insert(candidate.business.descriptor.matchID)
    scheduleCapture(candidate.business.descriptor.matchID)
    return .active(value)
  }
}
