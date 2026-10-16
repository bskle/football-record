import CryptoKit
import Foundation
import MatchCore
import MatchStore

extension MatchSession {
  func scheduleCapture(_ match: String) {
    captureWakeups.insert(match)
    guard captureDrivers.insert(match).inserted else { return }
    Task { await self.driveCapture(match) }
  }
  func driveCapture(_ match: String) async {
    defer {
      captureDrivers.remove(match)
      // Error reporting also awaits a snapshot. Hand off work committed during that
      // await before retiring, exactly as the normal empty-scan path does.
      if captureWakeups.remove(match) != nil { scheduleCapture(match) }
    }
    var attempted = Set<String>()
    var attemptedFinishes = Set<String>()
    do {
      while true {
        captureWakeups.remove(match)
        let snapshot = try await store.snapshotV2(matchID: match)
        let pending = snapshot.captureOperations.first {
          ($0.state == .pending || $0.state == .needsReconciliation)
            && !attempted.contains($0.operation.id)
        }
        if let pending {
          attempted.insert(pending.operation.id)
          if pending.operation.action == .finish {
            attemptedFinishes.insert(pending.operation.externalToken)
          }
          if let dispatch = try await planDispatch(pending.operation, match: match) {
            // Gateway work is outside both SQL and the business queue. End can commit here.
            let observation =
              dispatch.perform
              ? await workout.perform(dispatch.operation)
              : await workout.reconcile(dispatch.operation)
            try await saveObservation(observation, operation: dispatch.operation)
            if dispatch.perform, dispatch.operation.action == .start,
              observation.outcome == .running || observation.outcome == .paused
            {
              recoveredTokens.insert(dispatch.operation.externalToken)
            }
          }
        } else if let token = try await planTerminalCleanup(match, excluding: attemptedFinishes) {
          attemptedFinishes.insert(token)
        } else if recoveryRequested.remove(match) != nil {
          try await planRecovery(match)
        } else {
          // New business work may have committed during the asynchronous empty scan.
          // Consume that wakeup before retiring the only driver for this match.
          if captureWakeups.remove(match) != nil { continue }
          break
        }
      }
    } catch {
      // Durable pending/needsReconciliation survives every failure. A later recover retries
      // from that ledger and never infers that a failed database response means no side effect.
      if let value = try? await self.snapshot(matchID: match) { publish(value) }
    }
  }
  struct Dispatch {
    let operation: CaptureOperation
    let perform: Bool
  }
  func planDispatch(_ operation: CaptureOperation, match: String) async throws -> Dispatch? {
    await acquire(match)
    defer { release(match) }
    var s = try await store.snapshotV2(matchID: match)
    let device = try await identity()
    try requireWritable(s, device: device)
    guard let current = s.captureOperations.first(where: { $0.operation.id == operation.id }),
      current.operation == operation,
      current.state == .pending || current.state == .needsReconciliation
    else { return nil }
    if current.state == .pending {
      let start = s.captureOperations.first { $0.operation.id == operation.externalToken }
      let neverCreated: Bool
      if case .notCreated = start?.observation?.outcome {
        neverCreated = true
      } else {
        neverCreated = start?.state == .cancelled
      }
      if (terminal(s) && operation.action != .finish)
        || (operation.action == .finish && neverCreated)
      {
        let update = try CaptureOperationUpdate(
          operationID: operation.id, expectedState: .pending, state: .cancelled, observation: nil)
        let commit = try makeCommit(
          command: operation.id + "/cancel", generation: s.business.generation,
          descriptor: s.business.descriptor, updates: [update])
        _ = try await store.commitV2(commit)
        publish(try await snapshot(matchID: match))
        return nil
      }
      let marker = try CaptureOperationUpdate(
        operationID: operation.id, expectedState: .pending, state: .needsReconciliation,
        observation: nil)
      let commit = try makeCommit(
        command: operation.id + "/dispatch", generation: s.business.generation,
        descriptor: s.business.descriptor, updates: [marker])
      _ = try await store.commitV2(commit)
      s = try await store.snapshotV2(matchID: match)
      publish(try projected(s))
      // Holding the match queue across this final read establishes dispatch-before-end order.
      // If end already won, reconcile the original token instead of issuing a new start/resume.
      return Dispatch(operation: operation, perform: !terminal(s) || operation.action == .finish)
    }
    return Dispatch(operation: operation, perform: false)
  }
  func normalized(
    _ observation: WorkoutObservation, operation: CaptureOperation, current: CaptureOperationRecord
  ) throws -> WorkoutObservation {
    guard observation.operationID == operation.id, observation.binding == operation.binding,
      observation.externalToken == operation.externalToken
    else { throw CaptureValueError.invalidObservation }
    let outcome = observation.outcome
    var failure = observation.failure
    if current.observation?.failure == .routeFailed { failure = .routeFailed }
    if case .savedAwaitingLink = current.observation?.outcome {
      switch outcome {
      case .linked, .savedAwaitingLink: break
      default: return current.observation!
      }
    }
    if case .stopped = current.observation?.outcome, current.observation?.failure == .captureFailed
    {
      switch outcome {
      case .linked, .savedAwaitingLink: break
      default: return current.observation!
      }
    }
    if case .notCreated = outcome, operation.action != .start {
      throw CaptureValueError.invalidObservation
    }
    if case .stopped = outcome, operation.action == .finish { failure = .captureFailed }
    let agrees: Bool
    switch (operation.action, outcome) {
    case (_, .linked), (.start, .running), (.start, .paused), (.pause, .paused),
      (.resume, .running), (.recover, .running), (.recover, .paused):
      agrees = true
    default: agrees = false
    }
    if !agrees {
      switch outcome {
      case .running, .paused: failure = failure ?? .captureFailed
      case .stopped: failure = failure ?? .captureFailed
      default: break
      }
    }
    // Preserve actual lifecycle. unknown is never converted to a claim of no creation.
    return try WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: observation.observedAt, outcome: outcome, window: observation.window,
      failure: failure)
  }
  func observationState(_ observation: WorkoutObservation, operation: CaptureOperation)
    -> CaptureOperationState
  {
    switch observation.outcome {
    case .unknown, .savedAwaitingLink: return .needsReconciliation
    case .stopped where observation.failure == .captureFailed: return .needsReconciliation
    case .notCreated: return .failed
    case .linked: return .settled
    case .running
    where operation.action == .start || operation.action == .resume || operation.action == .recover:
      return .settled
    case .paused
    where operation.action == .start || operation.action == .pause || operation.action == .recover:
      return .settled
    default: return .failed
    }
  }
  func saveObservation(_ observation: WorkoutObservation, operation: CaptureOperation) async throws
  {
    let match = operation.binding.matchID
    await acquire(match)
    defer { release(match) }
    let s = try await store.snapshotV2(matchID: match)
    guard let current = s.captureOperations.first(where: { $0.operation.id == operation.id }),
      current.operation == operation
    else { throw StoreError.operationConflict }
    guard current.state == .needsReconciliation else { return }
    let normalized = try normalized(observation, operation: operation, current: current)
    if normalized == current.observation { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(normalized)).map {
      String(format: "%02x", $0)
    }.joined()
    let command = operation.id + "/observation/" + digest + "/" + String(s.business.generation)
    let state = observationState(normalized, operation: operation)
    let update = try CaptureOperationUpdate(
      operationID: operation.id, expectedState: .needsReconciliation, state: state,
      observation: normalized)
    var revisions: [CaptureRevision] = []
    var successors: [CaptureOperation] = []
    if case .linked(let workoutID) = normalized.outcome {
      let head = s.captureRevisions.max { $0.revision < $1.revision }
      var segments = head?.metadata.segments ?? []
      if !segments.contains(where: { $0.workoutID == workoutID }) {
        let segment = try CaptureSegment(
          id: operation.externalToken + "/segment", binding: operation.binding,
          workoutID: workoutID, window: normalized.window)
        segments.append(segment)
        revisions = [
          try CaptureRevision(
            id: command + "/revision", binding: operation.binding, parentID: head?.id,
            revision: (head?.revision ?? 0) + 1,
            observedAt: normalized.observedAt,
            metadata: CaptureMetadata(
              binding: operation.binding, segments: segments, gaps: head?.metadata.gaps ?? []))
        ]
      }
    }
    if !terminal(s), operation.action == .recover, normalized.failure == .recoveryUnavailable,
      normalized.outcome == .stopped
    {
      let restart = operation.id + "/restart"
      let head = s.captureRevisions.max { $0.revision < $1.revision }
      var gaps = head?.metadata.gaps ?? []
      gaps.append(
        try CaptureGap(
          id: restart + "/gap", binding: operation.binding,
          window: CaptureWindow(start: normalized.window.end, end: nil)))
      revisions = [
        try CaptureRevision(
          id: restart + "/revision", binding: operation.binding, parentID: head?.id,
          revision: (head?.revision ?? 0) + 1, observedAt: normalized.observedAt,
          metadata: CaptureMetadata(
            binding: operation.binding, segments: head?.metadata.segments ?? [], gaps: gaps))
      ]
      successors = [
        try CaptureOperation(
          id: restart + "/start", binding: operation.binding, associatedCommandID: command,
          action: .start, requestedAt: clock.now(), externalToken: restart + "/start")
      ]
    }
    // The failure observation, gap and replacement intent share one COMMIT. A failed
    // response cannot strand a terminal recover record without its durable successor.
    let commit = try makeCommit(
      command: command, generation: s.business.generation, descriptor: s.business.descriptor,
      revisions: revisions, operations: successors, updates: [update],
      outboxID: revisions.isEmpty ? nil : command + "/outbox")
    _ = try await store.commitV2(commit)
    publish(try projected(await store.snapshotV2(matchID: match)))
  }
  /// One finish attempt per token in each driver run. A confirmed failed action may be
  /// retried by recovery, while unknown/saved results must reconcile the existing operation.
  func planTerminalCleanup(_ match: String, excluding attempted: Set<String>) async throws
    -> String?
  {
    await acquire(match)
    defer { release(match) }
    let s = try await store.snapshotV2(matchID: match)
    guard terminal(s) else { return nil }
    for start in s.captureOperations
    where start.operation.action == .start && !attempted.contains(start.operation.externalToken) {
      let token = start.operation.externalToken
      let records = s.captureOperations.filter { $0.operation.externalToken == token }
      guard !records.contains(where: { $0.state == .pending || $0.state == .needsReconciliation }),
        let latest = records.compactMap(\.observation).last,
        latest.outcome == .running || latest.outcome == .paused
      else { continue }
      let command = token + "/terminal-finish/" + String(s.business.generation)
      let finish = try CaptureOperation(
        id: command + "/operation", binding: start.operation.binding, associatedCommandID: command,
        action: .finish,
        requestedAt: clock.now(), externalToken: token)
      _ = try await store.commitV2(
        makeCommit(
          command: command, generation: s.business.generation, descriptor: s.business.descriptor,
          operations: [finish]))
      publish(try await snapshot(matchID: match))
      return token
    }
    return nil
  }
  func planRecovery(_ match: String) async throws {
    await acquire(match)
    defer { release(match) }
    let s = try await store.snapshotV2(matchID: match)
    guard !terminal(s), let start = currentStart(s),
      !recoveredTokens.contains(start.operation.externalToken),
      !s.captureOperations.contains(where: {
        $0.state == .pending || $0.state == .needsReconciliation
      })
    else { return }
    let command = ids.nextID() + "/recover"
    let operation = try CaptureOperation(
      id: command + "/operation", binding: start.operation.binding, associatedCommandID: command,
      action: .recover,
      requestedAt: clock.now(), externalToken: start.operation.externalToken)
    _ = try await store.commitV2(
      makeCommit(
        command: command, generation: s.business.generation, descriptor: s.business.descriptor,
        operations: [operation]))
    recoveredTokens.insert(start.operation.externalToken)
    publish(try await snapshot(matchID: match))
  }
}
