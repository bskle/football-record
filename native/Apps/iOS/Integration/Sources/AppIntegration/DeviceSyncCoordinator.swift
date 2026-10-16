import Foundation
import MatchStore
import MatchSync
import MatchPresentation
import DeviceSync

protocol DeviceSyncEventSource: Sendable { func events() async -> AsyncStream<DeviceSyncEvent> }
extension WCSessionTransport: DeviceSyncEventSource {}
protocol DeviceSyncServiceControl: SyncStatusServing { func connectionDidActivate() async }
extension MatchSyncService: DeviceSyncServiceControl {}
protocol RevocablePeerTrust: PeerTrustProvider { func invalidate(_ reason: TrustInvalidationReason) async }

/// One device event observer around the same Core service/facade. It is also the
/// model's lifecycle boundary, so a retry cannot restart a revoked installation.
actor DeviceSyncCoordinator: SyncStatusServing {
  let events: any DeviceSyncEventSource
  let service: any DeviceSyncServiceControl
  let trust: any RevocablePeerTrust
  var observer: Task<Void,Never>?
  var registration: Task<Void,Never>?
  var startup: Task<Void,Error>?
  enum EventWork: Hashable { case activation, wake, publish }
  var work: [EventWork:(UUID,Task<Void,Never>)] = [:]
  var lifetime = UUID()
  var invalidated: TrustInvalidationReason?
  var stopping = false
  var subscribers: [UUID:(String, AsyncStream<SyncStateUpdate>.Continuation)] = [:]
  var forwards: [UUID:Task<Void,Never>] = [:]
  init(events: any DeviceSyncEventSource, service: any DeviceSyncServiceControl, trust: any RevocablePeerTrust) { self.events = events; self.service = service; self.trust = trust }
  func observe() async {
    guard !stopping else { return }
    if let registration { await registration.value; return }
    guard observer == nil else { return }
    let token = lifetime
    let task = Task { [weak self, events] in
      let stream = await events.events()
      guard !Task.isCancelled else { return }
      await self?.install(stream, token: token)
    }
    registration = task
    await task.value
    if token == lifetime { registration = nil }
  }
  private func install(_ stream: AsyncStream<DeviceSyncEvent>, token: UUID) {
    guard token == lifetime, !stopping, observer == nil else { return }
    observer = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled else { return }
        await self?.handle(event, token: token)
      }
    }
  }
  func start() async throws {
    guard !stopping, invalidated == nil else { throw StoreError.trustUnavailable }
    if let startup { return try await startup.value }
    let token = lifetime
    let task = Task { try await self.activate(token: token) }
    startup = task
    do { try await task.value; if token == lifetime { startup = nil } }
    catch { if token == lifetime { startup = nil }; throw error }
  }
  private func activate(token: UUID) async throws {
    await observe()
    guard !Task.isCancelled, lifetime == token, !stopping, invalidated == nil else { throw CancellationError() }
    try await service.start()
    guard !Task.isCancelled, lifetime == token, !stopping, invalidated == nil else {
      await service.stop(); throw CancellationError()
    }
  }
  func stop() async {
    // A composition is single-use. Its model has also been permanently shut down;
    // a new environment owns a new coordinator, transport and SDK delegate.
    stopping = true; lifetime = UUID()
    let old = observer, registering = registration, starting = startup
    observer = nil; registration = nil; startup = nil
    old?.cancel(); registering?.cancel(); starting?.cancel()
    let pending = Array(forwards.values) + work.values.map(\.1); forwards = [:]; work = [:]
    for task in pending { task.cancel() }
    for (_, continuation) in subscribers.values { continuation.finish() }; subscribers = [:]
    await service.stop(); await registering?.value; _ = try? await starting?.value
    await old?.value
    for task in pending { await task.value }
  }
  func handle(_ event: DeviceSyncEvent, token: UUID) async {
    guard lifetime == token, !stopping else { return }
    switch event {
    case .trustInvalidated(let reason):
      invalidated = reason
      let active = work.values.map(\.1); work = [:]; for task in active { task.cancel() }
      await trust.invalidate(reason) // Revoke before stop, including a suspended start/activation.
      await service.stop()
      for task in active { await task.value }
      guard lifetime == token, !stopping else { return }
      await publishAll()
    case .activated:
      guard invalidated == nil else { return }
      enqueue(.activation, token: token)
    case .wake:
      enqueue(.wake, token: token)
    case .failure:
      // Core delivery attempts preserve the actual error/backoff; a callback is no ACK.
      enqueue(.publish, token: token)
    }
  }
  private func enqueue(_ kind: EventWork, token: UUID) {
    guard work[kind] == nil, !stopping, invalidated == nil else { return }
    let id = UUID()
    let task = Task { [weak self] in guard let self else { return }; await self.perform(kind, id: id, token: token) }
    work[kind] = (id,task)
  }
  private func perform(_ kind: EventWork, id: UUID, token: UUID) async {
    defer { if work[kind]?.0 == id { work[kind] = nil } }
    guard !Task.isCancelled, token == lifetime, !stopping, invalidated == nil else { return }
    switch kind { case .activation: await service.connectionDidActivate(); case .wake: await wake(); case .publish: await publishAll() }
  }
  func wake() async {
    guard !stopping else { return }
    if invalidated == nil { await service.wake() }
    else { await publishAll() }
  }
  func retry() async {
    guard !stopping else { return }
    do { try await start(); await wake() } catch { await publishAll() }
  }
  func state(matchID: String) async throws -> SyncState {
    let value = try await service.state(matchID: matchID)
    return try projected(value)
  }
  func projected(_ value: SyncState) throws -> SyncState {
    guard invalidated != nil else { return value }
    return try SyncState(matchID: value.matchID, unroutedCount: value.unroutedCount, pendingACKCount: value.pendingACKCount, receivedGapCount: value.receivedGapCount, lastPeerACKAt: value.lastPeerACKAt, issue: .trustUnavailable)
  }
  func states(matchID: String) -> AsyncStream<SyncStateUpdate> {
    guard !stopping else { return AsyncStream { $0.finish() } }
    let id = UUID(), token = lifetime
    let (stream, continuation) = AsyncStream<SyncStateUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
    subscribers[id] = (matchID, continuation)
    continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
    forwards[id] = Task { [weak self, service] in
      let updates = await service.states(matchID: matchID)
      for await update in updates {
        guard !Task.isCancelled else { return }
        await self?.forward(update, id: id, token: token)
      }
    }
    Task { await self.publish(matchID: matchID, token: token) }
    return stream
  }
  func remove(_ id: UUID) { subscribers.removeValue(forKey: id); forwards.removeValue(forKey: id)?.cancel() }
  func forward(_ update: SyncStateUpdate, id: UUID, token: UUID) {
    guard token == lifetime, !stopping, let entry = subscribers[id] else { return }
    switch update {
    case .state(let value):
      do { entry.1.yield(.state(try projected(value))) }
      catch { entry.1.yield(.unavailable(matchID: entry.0, issue: .blockedIntegrity)) }
    case .unavailable: entry.1.yield(update)
    }
  }
  func publishAll() async {
    let token = lifetime
    for match in Set(subscribers.values.map(\.0)) { await publish(matchID: match, token: token) }
  }
  func publish(matchID: String, token: UUID) async {
    let update: SyncStateUpdate
    do { update = .state(try await state(matchID: matchID)) }
    catch { update = .unavailable(matchID: matchID, issue: .blockedIntegrity) }
    guard token == lifetime, !stopping else { return }
    for (match, continuation) in subscribers.values where match == matchID { continuation.yield(update) }
  }
}

actor UnavailableRevocableTrust: RevocablePeerTrust {
  func invalidate(_ reason: TrustInvalidationReason) async {}
  func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization { throw StoreError.trustUnavailable }
  func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws { throw StoreError.trustUnavailable }
}
