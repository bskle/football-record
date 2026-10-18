import Foundation
import MatchCore
import MatchStore

/// One session coordinator per database. Only Store commits are facts; every await may reenter this actor.
public actor MatchSession {
  let store: any SessionRepository
  let deviceIdentity: any DeviceIdentityProvider
  let clock: any SessionClock
  let ids: any SessionIDFactory
  let permits: any StartPermitProvider
  let workout: any WorkoutGateway
  let environment: SessionEnvironment
  var inFlight = Set<String>()
  var startAdmission: String?
  var busy = Set<String>()
  var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  var captureDrivers = Set<String>()
  var captureWakeups = Set<String>()
  var recoveryRequested = Set<String>()
  var recoveredTokens = Set<String>()
  var authorityTerminalMatches = Set<String>()
  struct Subscriber {
    let continuation: AsyncStream<SessionSnapshot>.Continuation
    var generation: Int64 = -1
  }
  var subscribers: [String: [String: Subscriber]] = [:]

  public init(
    store: any SessionRepository, deviceIdentity: any DeviceIdentityProvider,
    clock: any SessionClock,
    ids: any SessionIDFactory, permits: any StartPermitProvider, workout: any WorkoutGateway,
    environment: SessionEnvironment
  ) {
    self.store = store
    self.deviceIdentity = deviceIdentity
    self.clock = clock
    self.ids = ids
    self.permits = permits
    self.workout = workout
    self.environment = environment
  }
  func validateEnvironment() async throws {
    let namespace = await store.databaseNamespace()
    if let authority = store as? any AuthorityRepository, let binding = try await authority.accountBindingV4(), binding.suspended { throw AuthorityError.identityChanged }
    guard SQLiteSessionRepository.isCanonicalNamespace(namespace) else {
      throw SessionError.developmentIsolationRequired
    }
    switch environment {
    case .production:
      guard namespace == SQLiteSessionRepository.productionNamespace else {
        throw SessionError.developmentIsolationRequired
      }
    case .development(let expected):
      guard SQLiteSessionRepository.isCanonicalNamespace(expected),
        expected != SQLiteSessionRepository.productionNamespace, namespace == expected
      else { throw SessionError.developmentIsolationRequired }
    }
  }
  func identity() async throws -> String {
    do {
      let value = try await deviceIdentity.localDeviceID()
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SessionError.identityUnavailable
      }
      return value
    } catch { throw SessionError.identityUnavailable }
  }
  func acquire(_ match: String) async {
    if busy.insert(match).inserted { return }
    await withCheckedContinuation { waiters[match, default: []].append($0) }
  }
  func release(_ match: String) {
    if var list = waiters[match], !list.isEmpty {
      let first = list.removeFirst()
      waiters[match] = list
      first.resume()
    } else {
      busy.remove(match)
      waiters.removeValue(forKey: match)
    }
  }
  func requireWritable(_ s: StoreSnapshotV2, device: String) throws {
    guard s.business.descriptor.recordingDeviceID == device else {
      throw SessionError.wrongRecordingDevice
    }
    guard !s.business.diagnostics.contains(where: { $0.severity == .blocking }) else {
      throw SessionError.blockedDiagnostics
    }
    guard
      !MatchReplay.replay(
        descriptor: s.business.descriptor, events: s.business.events, now: clock.now()
      ).diagnostics.contains(where: \.isConflict)
    else { throw SessionError.blockedDiagnostics }
  }
  func terminal(_ s: StoreSnapshotV2) -> Bool {
    authorityTerminalMatches.contains(s.business.descriptor.matchID) || s.business.events.contains { $0.type == .matchEnded || $0.type == .matchTerminated }
  }
  func captureAction(_ action: SessionAction, snapshot: StoreSnapshotV2) -> CaptureAction? {
    // No physical instance exists while its start is still pending. Its first dispatch
    // follows the latest business pause/resume state instead of replaying old controls.
    if currentStart(snapshot)?.state == .pending {
      switch action {
      case .pause, .resume: return nil
      default: break
      }
    }
    switch action {
    case .start: return .start
    case .pause: return .pause
    case .resume: return .resume
    case .end: return .finish
    default: return nil
    }
  }
  func currentStart(_ s: StoreSnapshotV2) -> CaptureOperationRecord? {
    s.captureOperations.last {
      $0.operation.action == .start && $0.state != .failed && $0.state != .cancelled
    }
  }
  /// Save proof is monotonic across every operation for one physical Workout token.
  /// Operation creation order is not observation order (an older start may reconcile last).
  func tokenObservation(_ snapshot: StoreSnapshotV2, token: String) -> WorkoutObservation? {
    let observations = snapshot.captureOperations.filter { $0.operation.externalToken == token }
      .compactMap(\.observation)
    let newest: (WorkoutObservation, WorkoutObservation) -> Bool = { $0.observedAt < $1.observedAt }
    if let linked = observations.filter({
      if case .linked = $0.outcome { return true }
      return false
    }).max(by: newest) {
      return linked
    }
    if let awaiting = observations.filter({ $0.outcome == .savedAwaitingLink }).max(by: newest) {
      return awaiting
    }
    return observations.max(by: newest)
  }
  func tokenHasSaveProof(_ snapshot: StoreSnapshotV2, token: String) -> Bool {
    switch tokenObservation(snapshot, token: token)?.outcome {
    case .linked, .savedAwaitingLink: return true
    default: return false
    }
  }
  func tokenWasReplaced(_ snapshot: StoreSnapshotV2, token: String) -> Bool {
    let starts = snapshot.captureOperations.filter { $0.operation.action == .start }
    guard let index = starts.firstIndex(where: { $0.operation.externalToken == token }) else {
      return false
    }
    return index < starts.count - 1
  }
  public func prepareStart(starter: Bool) async throws -> SessionRequest {
    try await validateEnvironment()
    let device = try await identity()
    let now = clock.now()
    let command = ids.nextID()
    let match = ids.nextID()
    let intent = StartIntent(
      id: command, matchID: match, recordingDeviceID: device, requestedAt: now)
    return try .start(intent: intent, starter: starter)
  }
  public func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest {
    if case .start = action { throw SessionError.invalidRequest }
    try await validateEnvironment()
    let device = try await identity()
    let s = try await store.snapshotV2(matchID: matchID)
    try requireWritable(s, device: device)
    if terminal(s) { throw SessionError.terminalMatch }
    let command = ids.nextID()
    return try SessionRequest(
      commandID: command, matchID: matchID, requestedAt: clock.now(),
      expectedGeneration: s.business.generation,
      action: action, eventIDs: [command + "/event"],
      captureOperationID: captureAction(action, snapshot: s) != nil && currentStart(s) != nil
        ? command + "/capture" : nil)
  }
  public func execute(_ request: SessionRequest) async throws -> SessionReceipt {
    guard inFlight.insert(request.commandID).inserted else { throw SessionError.requestInFlight }
    let isStart: Bool
    if case .start = request.action { isStart = true } else { isStart = false }
    if isStart {
      guard startAdmission == nil else {
        inFlight.remove(request.commandID)
        throw SessionError.multipleCandidates
      }
      startAdmission = request.commandID
    }
    defer {
      inFlight.remove(request.commandID)
      if isStart { startAdmission = nil }
    }
    try await validateEnvironment()
    let device = try await identity()
    if isStart { return try await executeStart(request, device: device) }
    await acquire(request.matchID)
    defer { release(request.matchID) }
    if let saved = try await store.committedCommandV2(commandID: request.commandID) {
      try validateSaved(saved.request, for: request, device: device)
      let receipt = try await store.commitV2(saved.request)
      let snapshot = try await snapshot(matchID: request.matchID)
      publish(snapshot)
      scheduleCapture(request.matchID)
      return SessionReceipt(receipt: receipt, snapshot: snapshot)
    }
    let s = try await store.snapshotV2(matchID: request.matchID)
    try await updateAuthorityFence(s)
    try requireWritable(s, device: device)
    guard s.business.generation == request.expectedGeneration else {
      throw StoreError.staleGeneration
    }
    if terminal(s) { throw SessionError.terminalMatch }
    var recorder = LiveMatchRecorder(descriptor: s.business.descriptor, events: s.business.events)
    let event: MatchEvent
    switch request.action {
    case .quick(let action):
      event = try recorder.recordQuick(
        action, eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt)
    case .undoLastQuick:
      event = try recorder.undoLastQuick(
        eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt)
    case .enterField:
      event = try recorder.transition(
        .enteredField, eventID: request.eventIDs[0], sourceDeviceID: device,
        now: request.requestedAt)
    case .leaveField:
      event = try recorder.transition(
        .leftField, eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt)
    case .pause:
      event = try recorder.transition(
        .matchPaused, eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt
      )
    case .resume:
      event = try recorder.transition(
        .matchResumed, eventID: request.eventIDs[0], sourceDeviceID: device,
        now: request.requestedAt)
    case .end:
      event = try recorder.transition(
        .matchEnded, eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt)
    case .start: throw SessionError.invalidRequest
    }
    var operations: [CaptureOperation] = []
    if let action = captureAction(request.action, snapshot: s), let start = currentStart(s) {
      guard let id = request.captureOperationID else { throw SessionError.invalidRequest }
      operations = [
        try CaptureOperation(
          id: id, binding: start.operation.binding, associatedCommandID: request.commandID,
          action: action, requestedAt: request.requestedAt,
          externalToken: start.operation.externalToken)
      ]
    } else if request.captureOperationID != nil {
      throw SessionError.invalidRequest
    }
    let commit = try makeCommit(
      command: request.commandID, generation: request.expectedGeneration,
      descriptor: s.business.descriptor,
      events: [event], operations: operations, outboxID: request.commandID + "/outbox")
    let receipt = try await store.commitV2(commit)
    let snapshot = try await snapshot(matchID: request.matchID)
    publish(snapshot)
    scheduleCapture(request.matchID)
    return SessionReceipt(receipt: receipt, snapshot: snapshot)
  }
  func executeStart(_ request: SessionRequest, device: String) async throws -> SessionReceipt {
    guard let intent = request.startIntent, intent.recordingDeviceID == device,
      case .start(let starter) = request.action
    else { throw SessionError.wrongRecordingDevice }
    let managed = try await authorityManaged()
    await acquire(request.matchID)
    do {
      if !managed, let saved = try await store.committedCommandV2(commandID: request.commandID + "/start") {
        try validateSaved(saved.request, for: request, device: device)
        let receipt = try await store.commitV2(saved.request)
        let snapshot = try await snapshot(matchID: request.matchID)
        publish(snapshot)
        scheduleCapture(request.matchID)
        release(request.matchID)
        return SessionReceipt(receipt: receipt, snapshot: snapshot)
      }
      // A previously persisted intent is still subject to unique admission. It cannot
      // bypass a second candidate discovered after an earlier permit failure.
      for match in try await store.matchIDs() {
        let other = try await store.snapshotV2(matchID: match)
        guard !other.business.diagnostics.contains(where: { $0.severity == .blocking }) else {
          throw SessionError.blockedDiagnostics
        }
        try await updateAuthorityFence(other)
        let released = try await authorityReleased(match)
        if match != request.matchID
          && (!terminal(other) || (other.business.descriptor.backendLockState != .releasedConfirmed && !released))
        {
          throw SessionError.multipleCandidates
        }
      }
      let descriptor = MatchDescriptor(startIntent: intent, starter: starter)
      let intentCommit = try makeCommit(
        command: request.commandID + "/intent", generation: 0, descriptor: descriptor)
      if let saved = try await store.committedCommandV2(commandID: intentCommit.commandID) {
        guard saved.request == intentCommit else { throw StoreError.commandConflict }
        _ = try await store.commitV2(saved.request)
      } else {
        _ = try await store.commitV2(intentCommit)
        publish(try await snapshot(matchID: request.matchID))
      }
      release(request.matchID)
    } catch {
      release(request.matchID)
      throw error
    }
    let permit = try await permits.acquire(for: intent)
    guard permit.intentID == intent.id, permit.matchID == intent.matchID,
      permit.recordingDeviceID == device, !permit.permitID.isEmpty
    else { throw SessionError.invalidRequest }
    if environment == .production, permit.evidence == .developmentSimulation {
      throw SessionError.developmentIsolationRequired
    }
    await acquire(request.matchID)
    defer { release(request.matchID) }
    try await requireAuthorityStart(intent)
    if managed {
      let fresh = try await store.snapshotV2(matchID: request.matchID)
      if terminal(fresh) { throw SessionError.terminalMatch }
      if case .development = environment, permit != DevelopmentStartFixture.permit(for: intent) { throw SessionError.developmentIsolationRequired }
    }
    if let saved = try await store.committedCommandV2(commandID: request.commandID + "/start") {
      try validateSaved(saved.request, for: request, device: device)
      let receipt = try await store.commitV2(saved.request)
      let snapshot = try await snapshot(matchID: request.matchID)
      publish(snapshot)
      scheduleCapture(request.matchID)
      return SessionReceipt(receipt: receipt, snapshot: snapshot)
    }
    let current = try await store.snapshotV2(matchID: request.matchID)
    try requireWritable(current, device: device)
    if terminal(current) { throw SessionError.terminalMatch }
    guard current.business.generation == 1 else { throw StoreError.staleGeneration }
    let descriptor = MatchDescriptor(
      startIntent: intent, starter: starter, startPermit: permit, backendLockState: .held)
    var recorder = LiveMatchRecorder(descriptor: descriptor)
    let event = try recorder.start(
      eventID: request.eventIDs[0], sourceDeviceID: device, now: request.requestedAt)
    let operation = try CaptureOperation(
      id: request.captureOperationID!,
      binding: CaptureBinding(matchID: request.matchID, recordingDeviceID: device),
      associatedCommandID: request.commandID + "/start", action: .start,
      requestedAt: request.requestedAt, externalToken: request.captureOperationID!)
    let commit = try makeCommit(
      command: request.commandID + "/start", generation: 1, descriptor: descriptor, events: [event],
      operations: [operation], outboxID: request.commandID + "/outbox/start")
    let receipt = try await store.commitV2(commit)
    let snapshot = try await snapshot(matchID: request.matchID)
    publish(snapshot)
    scheduleCapture(request.matchID)
    return SessionReceipt(receipt: receipt, snapshot: snapshot)
  }
  func validateSaved(_ saved: StoreCommitV2, for request: SessionRequest, device: String) throws {
    let start: Bool
    if case .start = request.action { start = true } else { start = false }
    guard saved.commandID == request.commandID + (start ? "/start" : ""),
      saved.descriptor.matchID == request.matchID,
      saved.descriptor.recordingDeviceID == device,
      saved.expectedGeneration == (start ? 1 : request.expectedGeneration),
      saved.events.map(\.eventID) == request.eventIDs, saved.events.count == 1,
      saved.events[0].createdAt == request.requestedAt, saved.events[0].sourceDeviceID == device,
      saved.newCaptureOperations.map(\.id) == [request.captureOperationID].compactMap({ $0 }),
      saved.captureRevisions.isEmpty, saved.captureOperationUpdates.isEmpty
    else { throw StoreError.commandConflict }
    let event = saved.events[0]
    let matches: Bool
    switch request.action {
    case .start(let starter):
      matches =
        event.type == .matchStarted && saved.descriptor.startIntent == request.startIntent
        && saved.descriptor.starter == starter
    case .quick(let action):
      matches =
        event.type == .scoreEvent && event.quickAction == action && event.status == .active
        && event.correctionOfEventID == nil
    case .undoLastQuick:
      matches =
        event.type == .scoreEvent && event.status == .deleted && event.correctionOfEventID != nil
    case .enterField: matches = event.type == .enteredField
    case .leaveField: matches = event.type == .leftField
    case .pause: matches = event.type == .matchPaused
    case .resume: matches = event.type == .matchResumed
    case .end: matches = event.type == .matchEnded
    }
    guard matches else { throw StoreError.commandConflict }
  }
  func makeCommit(
    command: String, generation: Int64, descriptor: MatchDescriptor, events: [MatchEvent] = [],
    revisions: [CaptureRevision] = [], operations: [CaptureOperation] = [],
    updates: [CaptureOperationUpdate] = [], outboxID: String? = nil
  ) throws -> StoreCommitV2 {
    let outbox =
      try outboxID.map {
        [
          try BusinessOutboxItem(
            id: $0, matchID: descriptor.matchID, sourceDeviceID: descriptor.recordingDeviceID,
            payload: BusinessDeltaV2(
              descriptor: descriptor, events: events, captureRevisions: revisions))
        ]
      } ?? []
    return try StoreCommitV2(
      commandID: command, expectedGeneration: generation, descriptor: descriptor, events: events,
      captureRevisions: revisions,
      newCaptureOperations: operations, captureOperationUpdates: updates, businessOutbox: outbox)
  }
  public func snapshot(matchID: String) async throws -> SessionSnapshot {
    try await validateEnvironment()
    return try projected(await store.snapshotV2(matchID: matchID))
  }
  func projected(_ s: StoreSnapshotV2) throws -> SessionSnapshot {
    guard !s.business.diagnostics.contains(where: { $0.severity == .blocking }) else {
      throw SessionError.blockedDiagnostics
    }
    let replay = try s.business.replay(now: clock.now())
    let observations = s.captureOperations.compactMap(\.observation)
    let failure =
      observations.first(where: { $0.failure == .routeFailed })?.failure
      ?? observations.reversed().compactMap { o in
        if case .notCreated(let f) = o.outcome { return f }
        return o.failure
      }.first
    // The newest start selects the current token, while its physical phase is aggregated
    // from all operations for that token. A linked proof outranks stale running siblings.
    let token = s.captureOperations.last(where: { $0.operation.action == .start })?.operation
      .externalToken
    let records = s.captureOperations.filter { $0.operation.externalToken == token }
    let pending = records.filter { $0.state == .pending || $0.state == .needsReconciliation }
    let physical = token.flatMap { tokenObservation(s, token: $0) }
    let phase: CapturePhase
    if case .linked = physical?.outcome {
      phase = .finished
    } else if physical?.outcome == .savedAwaitingLink {
      phase = .savedAwaitingLink
    } else if pending.contains(where: { $0.state == .needsReconciliation }) {
      phase = .needsReconciliation
    } else if !pending.isEmpty {
      phase = .pending
    } else if let original = records.first(where: { $0.operation.action == .start }),
      original.state == .failed, case .notCreated(let failure) = original.observation?.outcome
    {
      // A cancelled absent finish's earlier unknown observation does not overturn the
      // original start's fully persisted negative proof. Pending cleanup still wins above.
      phase = .notRecorded(failure)
    } else if let physical {
      switch physical.outcome {
      case .running: phase = terminal(s) ? .needsReconciliation : .recording
      case .paused: phase = terminal(s) ? .needsReconciliation : .paused
      case .linked: phase = .finished
      case .savedAwaitingLink: phase = .savedAwaitingLink
      case .notCreated(let failure): phase = .notRecorded(failure)
      case .stopped, .unknown: phase = .needsReconciliation
      }
    } else {
      phase = .notRequested
    }
    return SessionSnapshot(
      store: s, replay: replay, capturePhase: phase, captureFailure: failure,
      lastUndoableQuickEventID: LiveMatchRecorder(
        descriptor: s.business.descriptor, events: s.business.events
      ).lastUndoableQuickEventID)
  }
  public func updates(matchID: String) -> AsyncStream<SessionSnapshot> {
    let id = UUID().uuidString
    let (stream, continuation) = AsyncStream<SessionSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    subscribers[matchID, default: [:]][id] = Subscriber(continuation: continuation)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(match: matchID, id: id) }
    }
    Task { if let value = try? await self.snapshot(matchID: matchID) { self.publish(value) } }
    return stream
  }
  func removeSubscriber(match: String, id: String) { subscribers[match]?.removeValue(forKey: id) }
  func publish(_ snapshot: SessionSnapshot) {
    let match = snapshot.store.business.descriptor.matchID
    for (id, var subscriber) in subscribers[match] ?? [:]
    where subscriber.generation <= snapshot.store.business.generation {
      subscriber.generation = snapshot.store.business.generation
      subscriber.continuation.yield(snapshot)
      subscribers[match]?[id] = subscriber
    }
  }
}
