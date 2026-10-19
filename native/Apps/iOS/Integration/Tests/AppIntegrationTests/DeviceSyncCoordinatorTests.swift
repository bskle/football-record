import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSync
import MatchPresentation
import DeviceSync
@testable import AppIntegration

final class DeviceSyncCoordinatorTests: XCTestCase, @unchecked Sendable {
  func testEventsSubscribeBeforeStartAndWakeNeverActsLikeActivation() async throws {
    let events = CoordinatorEvents(), trust = CoordinatorTrust()
    let service = CoordinatorService(events: events)
    let coordinator = DeviceSyncCoordinator(events: events, service: service, trust: trust)
    try await coordinator.start()
    let subscribed = await events.subscribed
    XCTAssertTrue(subscribed)
    let beforeStart = await service.subscribedBeforeStart; XCTAssertTrue(beforeStart)
    await events.emit(.wake); await service.waitForWakes(1)
    let wakes = await service.wakes, activations = await service.activations
    XCTAssertEqual(wakes, 1); XCTAssertEqual(activations, 0)
    await events.emit(.activated); await service.waitForActivation()
    let activated = await service.activations; XCTAssertEqual(activated, 1)
    await coordinator.stop()
  }
  func testConcurrentStartAndRetryRegisterOnlyOneObserver() async throws {
    let events = CoordinatorEvents(gated: true), trust = CoordinatorTrust()
    let service = CoordinatorService(events: events)
    let coordinator = DeviceSyncCoordinator(events: events, service: service, trust: trust)
    let first = Task { try await coordinator.start() }
    await events.waitForRegistration()
    let second = Task { await coordinator.retry() }
    // Both actors have a scheduling barrier; registration remains suspended.
    let third = Task { await coordinator.observe() }
    for _ in 0..<20 { await Task.yield() }
    await events.release()
    await third.value
    try await first.value; await second.value
    let registrations = await events.registrations
    XCTAssertEqual(registrations, 1)
    await coordinator.stop()
  }

  func testInvalidationRevokesBeforeStopWhileStartIsSuspendedAndRetryCannotRestart() async throws {
    let events = CoordinatorEvents(), trace = CoordinatorTrace()
    let trust = CoordinatorTrust(trace: trace), service = CoordinatorService(events: events, trace: trace, holdStart: true)
    let coordinator = DeviceSyncCoordinator(events: events, service: service, trust: trust)
    let starting = Task { try await coordinator.start() }
    await service.waitForStart()
    await events.emit(.trustInvalidated(.pairingChanged))
    await trace.waitForCount(2)
    let order = await trace.values; XCTAssertEqual(Array(order.prefix(2)), ["invalidate", "stop"])
    await service.releaseStart()
    do { try await starting.value; XCTFail("late activation must not survive revocation") } catch {}
    await coordinator.retry()
    let starts = await service.starts; XCTAssertEqual(starts, 1)
    let state = try await coordinator.state(matchID: "match")
    XCTAssertEqual(state.issue, .trustUnavailable); XCTAssertNil(state.lastPeerACKAt)
    await coordinator.stop()
  }
  func testInvalidationIsNotBlockedBySuspendedActivation() async throws {
    let events = CoordinatorEvents(), trace = CoordinatorTrace()
    let trust = CoordinatorTrust(trace: trace), service = CoordinatorService(events: events, trace: trace, holdActivation: true)
    let coordinator = DeviceSyncCoordinator(events: events, service: service, trust: trust)
    try await coordinator.start()
    await events.emit(.activated); await service.waitForActivation()
    let revoked = expectation(description: "revoke before activation returns")
    await trace.notifyRevocation(revoked)
    await events.emit(.trustInvalidated(.companionChanged))
    await fulfillment(of: [revoked], timeout: 1)
    await service.releaseActivation()
    await trace.waitForCount(2)
    let order = await trace.values; XCTAssertEqual(Array(order.prefix(2)), ["invalidate", "stop"])
    await coordinator.stop()
  }

  func testStopJoinsSuspendedRegistrationWithoutStartingService() async throws {
    let events = CoordinatorEvents(gated: true), trust = CoordinatorTrust()
    let service = CoordinatorService(events: events)
    let coordinator = DeviceSyncCoordinator(events: events, service: service, trust: trust)
    let starting = Task { try await coordinator.start() }
    await events.waitForRegistration()
    let stopping = Task { await coordinator.stop() }
    await service.waitForStop()
    await events.release()
    await stopping.value
    do { try await starting.value; XCTFail() } catch {}
    let starts = await service.starts, registrations = await events.registrations
    XCTAssertEqual(starts, 0); XCTAssertEqual(registrations, 1)
    do { try await coordinator.start(); XCTFail("a shut down composition is never reused") } catch {}
  }

}
private actor CoordinatorEvents: DeviceSyncEventSource {
  var subscribed = false
  var registrations = 0
  var gated: Bool
  var gate: [CheckedContinuation<Void,Never>] = []
  var registered: CheckedContinuation<Void,Never>?
  let stream: AsyncStream<DeviceSyncEvent>
  let continuation: AsyncStream<DeviceSyncEvent>.Continuation
  init(gated: Bool = false) { self.gated = gated; (stream, continuation) = AsyncStream.makeStream() }
  func events() async -> AsyncStream<DeviceSyncEvent> {
    subscribed = true; registrations += 1; registered?.resume(); registered = nil
    if gated { await withCheckedContinuation { gate.append($0) } }
    return stream
  }
  func waitForRegistration() async { if registrations == 0 { await withCheckedContinuation { registered = $0 } } }
  func release() { gated = false; let pending = gate; gate = []; for waiter in pending { waiter.resume() } }
  func emit(_ event: DeviceSyncEvent) { continuation.yield(event) }
}
private actor CoordinatorService: DeviceSyncServiceControl {
  let events: CoordinatorEvents
  let trace: CoordinatorTrace?
  var holdStart: Bool
  var holdActivation: Bool
  var activationGate: CheckedContinuation<Void,Never>?
  var startGate: CheckedContinuation<Void,Never>?
  var startWaiter: CheckedContinuation<Void,Never>?
  var stopWaiter: CheckedContinuation<Void,Never>?
  var subscribedBeforeStart = false
  var wakeWaiter: CheckedContinuation<Void,Never>?
  var activationWaiter: CheckedContinuation<Void,Never>?
  var wakes = 0, activations = 0, starts = 0, stops = 0
  init(events: CoordinatorEvents, trace: CoordinatorTrace? = nil, holdStart: Bool = false, holdActivation: Bool = false) { self.events = events; self.trace = trace; self.holdStart = holdStart; self.holdActivation = holdActivation }
  func start() async throws {
    subscribedBeforeStart = await events.subscribed; starts += 1
    startWaiter?.resume(); startWaiter = nil
    if holdStart { await withCheckedContinuation { startGate = $0 } }
  }
  func waitForStart() async { if starts == 0 { await withCheckedContinuation { startWaiter = $0 } } }
  func releaseStart() { holdStart = false; startGate?.resume(); startGate = nil }
  func waitForStop() async { if stops == 0 { await withCheckedContinuation { stopWaiter = $0 } } }
  func waitForWakes(_ count: Int) async { if wakes < count { await withCheckedContinuation { wakeWaiter = $0 } } }
  func waitForActivation() async { if activations == 0 { await withCheckedContinuation { activationWaiter = $0 } } }
  func stop() async { stops += 1; await trace?.append("stop"); stopWaiter?.resume(); stopWaiter = nil }
  func wake() async { wakes += 1; wakeWaiter?.resume(); wakeWaiter = nil }
  func connectionDidActivate() async { activations += 1; activationWaiter?.resume(); activationWaiter = nil; if holdActivation { await withCheckedContinuation { activationGate = $0 } } }
  func releaseActivation() { holdActivation = false; activationGate?.resume(); activationGate = nil }
  func state(matchID: String) async throws -> SyncState { try SyncState(matchID: matchID, unroutedCount: 1, pendingACKCount: 0, receivedGapCount: 0, lastPeerACKAt: nil, issue: nil) }
  func states(matchID: String) async -> AsyncStream<SyncStateUpdate> { AsyncStream { $0.finish() } }
}
private actor CoordinatorTrust: RevocablePeerTrust {
  var invalidated = false
  let trace: CoordinatorTrace?
  init(trace: CoordinatorTrace? = nil) { self.trace = trace }
  func invalidate(_ reason: TrustInvalidationReason) async { invalidated = true; await trace?.append("invalidate") }
  func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization { throw StoreError.trustUnavailable }
  func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws { throw StoreError.trustUnavailable }
}

private actor CoordinatorTrace {
  var values: [String] = []
  var revocation: XCTestExpectation?
  func notifyRevocation(_ value: XCTestExpectation) { revocation = value }
  var waiter: (Int, CheckedContinuation<Void,Never>)?
  func append(_ value: String) { values.append(value); if value == "invalidate" { revocation?.fulfill(); revocation = nil }; if let (count, pending) = waiter, values.count >= count { waiter = nil; pending.resume() } }
  func waitForCount(_ count: Int) async { if values.count < count { await withCheckedContinuation { waiter = (count,$0) } } }
}
