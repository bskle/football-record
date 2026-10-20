import CryptoKit
import Foundation
import MatchCore
import MatchStore

extension MatchSession {
  func scheduleCapture(_ match: String) {
    guard !businessRetired else { return }
    captureWakeups.insert(match)
    guard captureDrivers.insert(match).inserted else { return }
    captureTasks[match] = Task { await self.driveCapture(match) }
  }
  func driveCapture(_ match: String) async {
    defer {
      captureDrivers.remove(match)
      captureTasks.removeValue(forKey: match)
      // Error reporting also awaits a snapshot. Hand off work committed during that
      // await before retiring, exactly as the normal empty-scan path does.
      if captureWakeups.remove(match) != nil { scheduleCapture(match) }
    }
    var attempted = Set<String>()
    var attemptedFinishes = Set<String>()
    do {
      // A failed SQL save does not authorize another SDK result to replace the original.
      // Replay its exact retained fact through SQL before planning any more gateway work.
      for id in unsavedObservations.keys.sorted() {
        guard let original = unsavedObservations[id],
          Data(original.operation.binding.matchID.utf8) == Data(match.utf8) else { continue }
        try await saveObservation(original.observation, operation: original.operation, retryingRetained: true)
        unsavedObservations.removeValue(forKey: id); observationCommits.removeValue(forKey: id)
        captureErrors.removeValue(forKey: match)
      }
      while !businessRetired {
        if captureWakeups.remove(match) != nil {
          // A deferred pending start must be reconsidered after a new resume fact.
          attempted.removeAll()
          attemptedFinishes.removeAll()
        }
        // The ordinary empty scan stays outside the queue. Only a terminal hint enters
        // the locked preflight, which rechecks current facts before any SDK dispatch.
        let hint = try await store.snapshotV2(matchID: match)
        try await updateAuthorityFence(hint)
        try requireBusinessActive()
        if terminal(hint) {
          while let token = try await planTerminalCleanup(match, excluding: attemptedFinishes) { attemptedFinishes.insert(token) }
        }
        let snapshot = terminal(hint) ? try await store.snapshotV2(matchID: match) : hint
        // Keep original uncertain operations ahead of a newly planned finish. A saved
        // original token proof may make that finish unnecessary on reopening.
        let pending = snapshot.captureOperations.first {
          ($0.state == .pending || $0.state == .needsReconciliation)
            && !attempted.contains($0.operation.id)
        }
        if let pending {
          attempted.insert(pending.operation.id)
          if pending.operation.action == .finish {
            attemptedFinishes.insert(pending.operation.externalToken)
          }
          if terminal(snapshot),pending.state == .needsReconciliation,pending.operation.action != .start,pending.operation.action != .finish { continue }
          if let dispatch = try await planDispatch(pending.operation, match: match) {
            try requireBusinessActive()
            // Gateway work is outside both SQL and the business queue. End can commit here.
            let observation =
              dispatch.perform
              ? await workout.perform(dispatch.operation)
              : await workout.reconcile(dispatch.operation)
            guard unsavedObservations[dispatch.operation.id] == nil else { throw StoreError.operationConflict }
            unsavedObservations[dispatch.operation.id] = UnsavedObservation(observation: observation, operation: dispatch.operation)
            try await saveObservation(observation, operation: dispatch.operation)
            unsavedObservations.removeValue(forKey: dispatch.operation.id)
            observationCommits.removeValue(forKey: dispatch.operation.id)
            captureErrors.removeValue(forKey: match)
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
          if captureWakeups.remove(match) != nil {
            attempted.removeAll()
            attemptedFinishes.removeAll()
            continue
          }
          break
        }
      }
    } catch {
      if error as? SessionError != .retired { captureErrors[match] = error }
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
    try requireBusinessActive()
    var s = try await store.snapshotV2(matchID: match)
    try await updateAuthorityFence(s)
    let device = try await identity()
    try requireWritable(s, device: device)
    guard let current = s.captureOperations.first(where: { $0.operation.id == operation.id }),
      current.operation == operation,
      current.state == .pending || current.state == .needsReconciliation
    else { return nil }
    if current.state == .needsReconciliation, operation.action == .finish,
      let start = s.captureOperations.first(where: { $0.operation.id == operation.externalToken }),
      start.state == .failed, case .notCreated = start.observation?.outcome,
      !s.captureOperations.contains(where: {
        $0.operation.externalToken == operation.externalToken
          && ($0.operation.action == .recover || $0.observation?.hasPositiveCaptureEvidence == true)
      }),
      !s.captureRevisions.contains(where: {
        !$0.metadata.segments.isEmpty
          || $0.metadata.gaps.contains(where: { $0.window.start != nil || $0.window.end != nil })
      })
    {
      // Snapshot is only a candidate hint. Store checks the canonical start and all
      // historical/segment evidence atomically before allowing this sole exception.
      let update = try CaptureOperationUpdate(
        operationID: operation.id, expectedState: .needsReconciliation, state: .cancelled,
        observation: nil)
      let command = operation.id + "/cancel-absent/" + String(s.business.generation)
      _ = try await store.commitV2(
        makeCommit(
          command: command, generation: s.business.generation, descriptor: s.business.descriptor,
          updates: [update]))
      publish(try await snapshot(matchID: match))
      return nil
    }
    if current.state == .pending {
      let start = s.captureOperations.first { $0.operation.id == operation.externalToken }
      let neverCreated: Bool
      if case .notCreated = start?.observation?.outcome {
        neverCreated = true
      } else {
        neverCreated = start?.state == .cancelled
      }
      let business = try s.business.replay(now: clock.now()).state
      let controls = operation.action == .pause || operation.action == .resume
      let tokenRecords = s.captureOperations.filter {
        $0.operation.externalToken == operation.externalToken
      }
      let lifecycle = tokenObservation(s, token: operation.externalToken)?.outcome
      let obsolete =
        (operation.action == .pause && business != .paused)
        || (operation.action == .resume && business != .running)
      let redundant =
        controls && !tokenRecords.contains(where: { $0.state == .needsReconciliation })
        && ((operation.action == .pause && lifecycle == .paused)
          || (operation.action == .resume && lifecycle == .running))
      if (terminal(s) && operation.action != .finish)
        || (operation.action == .finish && neverCreated)
        || (controls
          && (neverCreated || start?.state == .pending || obsolete || redundant
            || tokenHasSaveProof(s, token: operation.externalToken)
            || tokenWasReplaced(s, token: operation.externalToken)))
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
      if operation.action == .start, business == .paused {
        // A replacement/first Workout stays unstarted until a real resume fact commits.
        return nil
      }
      if operation.action == .start, !s.captureOperations.contains(where: { $0.observation?.hasPositiveCaptureEvidence == true }) { try await requireAuthorityStart(s.business.descriptor.startIntent) }
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
      return Dispatch(
        operation: operation,
        perform: !tokenHasSaveProof(s, token: operation.externalToken)
          && (!terminal(s) || operation.action == .finish))
    }
    try requireBusinessActive()
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
  func saveObservation(_ observation: WorkoutObservation, operation: CaptureOperation, retryingRetained: Bool = false) async throws
  {
    let match = operation.binding.matchID
    await acquire(match)
    defer { release(match) }
    if let retained = observationCommits[operation.id],
      let original = try await store.committedCommandV2(commandID: retained.commandID) {
      guard try sameObservationCommit(original.request, retained) else { throw StoreError.commandConflict }
      return
    }
    let s = try await store.snapshotV2(matchID: match)
    try await updateAuthorityFence(s)
    guard let current = s.captureOperations.first(where: { $0.operation.id == operation.id }),
      current.operation == operation
    else { throw StoreError.operationConflict }
    let absentStart = s.captureOperations.first {
      $0.operation.id == operation.externalToken && $0.operation.action == .start
        && $0.state == .failed
    }
    let contradictsAbsence: Bool
    if case .notCreated = absentStart?.observation?.outcome {
      contradictsAbsence = observation.hasPositiveCaptureEvidence
    } else {
      contradictsAbsence = false
    }
    // Ordinary settled-operation idempotency is unchanged. A late positive fact that
    // contradicts persisted absence must reach Store's raw-byte quarantine, not vanish.
    guard current.state == .needsReconciliation || contradictsAbsence else {
      // A later settled sibling is not evidence that our earlier failed fact was saved.
      // Store validates this snapshot's immutable operation history; only the exact
      // normalized observation (or the original command above) can satisfy readback.
      let expected = try self.normalized(observation, operation: operation, current: current)
      if retryingRetained { try verifyRetainedObservation(expected, raw: observation, operation: operation) }
      guard let saved = current.observation, try observationBytes(saved) == observationBytes(expected)
      else { throw StoreError.operationConflict }
      return
    }
    let normalized: WorkoutObservation
    if contradictsAbsence {
      guard observation.operationID == operation.id, observation.binding == operation.binding,
        observation.externalToken == operation.externalToken
      else { throw CaptureValueError.invalidObservation }
      // Preserve the gateway value exactly for Store's contradiction quarantine. Normal
      // lifecycle/failure normalization would replace the evidence we must retain.
      normalized = observation
    } else {
      normalized = try self.normalized(observation, operation: operation, current: current)
      if retryingRetained { try verifyRetainedObservation(normalized, raw: observation, operation: operation) }
      if normalized == current.observation { return }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(normalized)).map {
      String(format: "%02x", $0)
    }.joined()
    let command = operation.id + "/observation/" + digest + "/" + String(s.business.generation)
    let state = observationState(normalized, operation: operation)
    let update = try CaptureOperationUpdate(
      operationID: operation.id, expectedState: current.state, state: state,
      observation: normalized)
    let head = s.captureRevisions.max { $0.revision < $1.revision }
    var segments = head?.metadata.segments ?? []
    var gaps = head?.metadata.gaps ?? []
    var changed = false
    if case .linked(let workoutID) = normalized.outcome,
      !segments.contains(where: { $0.workoutID == workoutID })
    {
      segments.append(
        try CaptureSegment(
          id: operation.externalToken + "/segment", binding: operation.binding,
          workoutID: workoutID, window: normalized.window))
      changed = true
    }
    let oldInstanceClosed: Bool
    switch normalized.outcome {
    case .linked: oldInstanceClosed = true
    case .stopped: oldInstanceClosed = normalized.failure == .recoveryUnavailable
    default: oldInstanceClosed = false
    }
    var successors: [CaptureOperation] = []
    let restart = operation.id + "/restart"
    if !terminal(s), operation.action == .recover, oldInstanceClosed {
      // A returned UUID is retained while the same transaction records the genuine gap
      // and replacement token. Paused business state defers that pending start's dispatch.
      gaps.append(
        try CaptureGap(
          id: restart + "/gap", binding: operation.binding,
          window: CaptureWindow(start: normalized.window.end, end: nil)))
      changed = true
      successors = [
        try CaptureOperation(
          id: restart + "/start", binding: operation.binding, associatedCommandID: command,
          action: .start, requestedAt: clock.now(), externalToken: restart + "/start")
      ]
    }
    let revisions: [CaptureRevision] =
      changed
      ? [
        try CaptureRevision(
          id: successors.isEmpty ? command + "/revision" : restart + "/revision",
          binding: operation.binding, parentID: head?.id, revision: (head?.revision ?? 0) + 1,
          observedAt: normalized.observedAt,
          metadata: CaptureMetadata(binding: operation.binding, segments: segments, gaps: gaps))
      ] : []
    // The failure observation, gap and replacement intent share one COMMIT. A failed
    // response cannot strand a terminal recover record without its durable successor.
    let commit = try makeCommit(
      command: command, generation: s.business.generation, descriptor: s.business.descriptor,
      revisions: revisions, operations: successors, updates: [update],
      outboxID: revisions.isEmpty ? nil : command + "/outbox", retainingObservation: true)
    observationCommits[operation.id] = commit
    do { _ = try await store.commitV2(commit) }
    catch {
      // A lost response is success only after the complete canonical request and its
      // first receipt have passed Store's immutable fact/history checks.
      guard error as? StoreError == .responseLost,
        let original = try await store.committedCommandV2(commandID: commit.commandID),
        try sameObservationCommit(original.request, commit) else { throw error }
    }
    publish(try projected(await store.snapshotV2(matchID: match)))
    if case .notCreated = normalized.outcome { scheduleCapture(match) }
  }
  private func verifyRetainedObservation(_ normalized: WorkoutObservation, raw: WorkoutObservation, operation: CaptureOperation) throws {
    // Monotonic saved/stopped evidence may prevent replacing B, but cannot stand in
    // for an uncommitted original A. Preserve A and block retirement in that case.
    let original = try observationCommits[operation.id]?.captureOperationUpdates.first(where: { $0.operationID == operation.id })?.observation
      ?? self.normalized(raw, operation: operation, current: CaptureOperationRecord(operation: operation, state: .needsReconciliation, observation: nil))
    guard try observationBytes(original) == observationBytes(normalized) else { throw StoreError.operationConflict }
  }
  private func observationBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private func sameObservationCommit(_ lhs: StoreCommitV2, _ rhs: StoreCommitV2) throws -> Bool {
    try observationBytes(lhs) == observationBytes(rhs)
  }
  /// One finish attempt per token in each driver run. A confirmed failed action may be
  /// retried by recovery, while unknown/saved results must reconcile the existing operation.
  func planTerminalCleanup(_ match: String, excluding attempted: Set<String>) async throws
    -> String?
  {
    await acquire(match)
    defer { release(match) }
    return try await planTerminalCleanupLocked(match, excluding: attempted)
  }
  /// Caller owns the same-match queue. No SDK or network await occurs in this planner.
  func planTerminalCleanupLocked(_ match: String, excluding attempted: Set<String>) async throws -> String? {
    guard !businessRetired else { return nil }
    var s = try await store.snapshotV2(matchID: match)
    try await updateAuthorityFence(s)
    guard !businessRetired, terminal(s), s.business.descriptor.recordingDeviceID == (try await identity()) else { return nil }
    try requireWritable(s, device: s.business.descriptor.recordingDeviceID)
    let pendingControls = s.captureOperations.filter { $0.state == .pending && $0.operation.action != .finish }
    if let first = pendingControls.first {
      let command = first.operation.id + "/terminal-cancel"
      if let original = try await store.committedCommandV2(commandID: command) { _ = try await store.commitV2(original.request) }
      else {
        let updates = try pendingControls.map { try CaptureOperationUpdate(operationID: $0.operation.id, expectedState: .pending, state: .cancelled, observation: nil) }
        _ = try await store.commitV2(makeCommit(command: command, generation: s.business.generation, descriptor: s.business.descriptor, updates: updates))
      }
      s = try await store.snapshotV2(matchID: match); publish(try projected(s))
    }
    for start in s.captureOperations where start.operation.action == .start && !attempted.contains(start.operation.externalToken) {
      let token = start.operation.externalToken, records = s.captureOperations.filter { $0.operation.externalToken == token }
      guard !tokenHasSaveProof(s, token: token), start.state != .cancelled,
            !records.contains(where: { $0.operation.action == .finish && ($0.state == .pending || $0.state == .needsReconciliation) }) else { continue }
      if case .notCreated = start.observation?.outcome, start.state == .failed { continue }
      let latest = tokenObservation(s, token: token)
      guard start.state == .needsReconciliation || latest?.outcome == .running || latest?.outcome == .paused else { continue }
      let failed = records.last { $0.operation.action == .finish && $0.state == .failed }
      let command = failed.map { $0.operation.id + "/terminal-retry" } ?? token + "/terminal-finish"
      if let original = try await store.committedCommandV2(commandID: command) { _ = try await store.commitV2(original.request) }
      else {
        let date = s.business.events.filter { $0.type == .matchEnded || $0.type == .matchTerminated }.map(\.createdAt).min() ?? start.operation.requestedAt
        let finish = try CaptureOperation(id: command + "/operation", binding: start.operation.binding, associatedCommandID: command, action: .finish, requestedAt: date, externalToken: token)
        _ = try await store.commitV2(makeCommit(command: command, generation: s.business.generation, descriptor: s.business.descriptor, operations: [finish]))
      }
      publish(try projected(await store.snapshotV2(matchID: match)))
      return token
    }
    return nil
  }
  func planRecovery(_ match: String) async throws {
    await acquire(match)
    defer { release(match) }
    let s = try await store.snapshotV2(matchID: match)
    try await updateAuthorityFence(s)
    guard !businessRetired, !terminal(s), let start = currentStart(s),
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
