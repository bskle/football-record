import Foundation
import MatchCore
import MatchStore

public enum SessionError: Error, Sendable, Equatable {
  case permitUnavailable, identityUnavailable, wrongRecordingDevice, multipleCandidates,
    terminalMatch
  case blockedDiagnostics, requestInFlight, invalidRequest, developmentIsolationRequired
}
public enum SessionAction: Codable, Sendable, Equatable {
  case start(starter: Bool)
  case quick(QuickRecordAction)
  case undoLastQuick, enterField, leaveField, pause, resume, end
}
public enum SessionEnvironment: Sendable, Equatable {
  case production
  case development(databaseNamespace: String)
}
public struct SessionRequest: Codable, Sendable, Equatable {
  public let commandID: String
  public let matchID: String
  public let requestedAt: Date
  public let expectedGeneration: Int64
  public let action: SessionAction
  public let eventIDs: [String]
  public let captureOperationID: String?
  public let startIntent: StartIntent?
  public init(
    commandID: String, matchID: String, requestedAt: Date, expectedGeneration: Int64,
    action: SessionAction, eventIDs: [String], captureOperationID: String?,
    startIntent: StartIntent? = nil
  ) throws {
    let ids = [commandID, matchID] + eventIDs + [captureOperationID].compactMap { $0 }
    guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
      requestedAt.timeIntervalSinceReferenceDate.isFinite, expectedGeneration >= 0,
      expectedGeneration < Int64.max,
      eventIDs.count == 1
    else { throw SessionError.invalidRequest }
    if case .start = action {
      guard let intent = startIntent, intent.id == commandID, intent.matchID == matchID,
        intent.requestedAt == requestedAt,
        !intent.recordingDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        expectedGeneration == 0, eventIDs == [commandID + "/event/start"],
        captureOperationID == commandID + "/capture/start"
      else { throw SessionError.invalidRequest }
    } else if startIntent != nil {
      throw SessionError.invalidRequest
    }
    self.commandID = commandID
    self.matchID = matchID
    self.requestedAt = requestedAt
    self.expectedGeneration = expectedGeneration
    self.action = action
    self.eventIDs = eventIDs
    self.captureOperationID = captureOperationID
    self.startIntent = startIntent
  }
  /// Reconstruct a persisted, unpermitted start without allocating IDs or replacing its time.
  public static func start(intent: StartIntent, starter: Bool) throws -> Self {
    try Self(
      commandID: intent.id, matchID: intent.matchID, requestedAt: intent.requestedAt,
      expectedGeneration: 0,
      action: .start(starter: starter), eventIDs: [intent.id + "/event/start"],
      captureOperationID: intent.id + "/capture/start", startIntent: intent)
  }
  private enum CodingKeys: String, CodingKey {
    case commandID, matchID, requestedAt, expectedGeneration, action, eventIDs, captureOperationID,
      startIntent
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      commandID: c.decode(String.self, forKey: .commandID),
      matchID: c.decode(String.self, forKey: .matchID),
      requestedAt: c.decode(Date.self, forKey: .requestedAt),
      expectedGeneration: c.decode(Int64.self, forKey: .expectedGeneration),
      action: c.decode(SessionAction.self, forKey: .action),
      eventIDs: c.decode([String].self, forKey: .eventIDs),
      captureOperationID: c.decodeIfPresent(String.self, forKey: .captureOperationID),
      startIntent: c.decodeIfPresent(StartIntent.self, forKey: .startIntent))
  }
}
public enum CapturePhase: Sendable, Equatable {
  case notRequested, pending, recording, paused, savedAwaitingLink, finished, needsReconciliation
  case notRecorded(CaptureFailure)
}
public struct SessionSnapshot: Sendable {
  public let store: StoreSnapshotV2
  public let replay: ReplayResult
  public let capturePhase: CapturePhase
  public let captureFailure: CaptureFailure?
  public let lastUndoableQuickEventID: String?
}
public struct SessionReceipt: Sendable {
  public let receipt: CommitReceiptV2
  public let snapshot: SessionSnapshot
}
public enum RecoverySelection: Sendable {
  case none
  case intentAwaitingPermit(StartIntent)
  case active(SessionSnapshot)
}
