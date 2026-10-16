import Foundation
import XCTest
import SQLite3
import MatchCore
import MatchStore
import MatchSession
@testable import MatchSync

final class SyncTestClock: SyncClock, SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
actor FakeSyncTransport: SyncTransport {
    let stream: AsyncStream<SyncDelivery>
    let continuation: AsyncStream<SyncDelivery>.Continuation
    var peer: FakeSyncTransport?
    var sent: [Data] = []
    var persisted: [String] = []
    var activations = 0
    var deliveryCalls = 0
    var deliveryGate = false
    var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func activate() async { activations += 1 }
    func deliveries() async -> AsyncStream<SyncDelivery> {
        deliveryCalls += 1
        if deliveryGate { await withCheckedContinuation { deliveryWaiters.append($0) } }
        return stream
    }
    func gateDeliveries() { deliveryGate = true }
    func releaseDeliveries() { deliveryGate = false; let waiters = deliveryWaiters; deliveryWaiters = []; waiters.forEach { $0.resume() } }
    func link(_ other: FakeSyncTransport) { peer = other }
    func receive(_ bytes: Data, id: String) { continuation.yield(try! SyncDelivery(bytes: bytes, transportDeliveryID: id)) }
    func send(_ bytes: Data, deliveryID: String) async throws {
        sent.append(bytes)
        if let peer { await peer.receive(bytes, id: deliveryID) }
    }
    func values() -> [Data] { sent }
    func didPersistDelivery(_ transportDeliveryID: String) async { persisted.append(transportDeliveryID) }
}
final class ServiceFixture: @unchecked Sendable {
    let root: URL
    let repository: SQLiteSessionRepository
    let identity: PersistentDeviceIdentityProvider
    let clock: SyncTestClock
    let session: MatchSession
    let transport = FakeSyncTransport()
    let namespace: String
    init(namespace: String, clock: SyncTestClock = SyncTestClock(), existingRoot: URL? = nil) throws {
        root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("sync-service-" + UUID().uuidString)
        self.namespace = namespace; self.clock = clock
        repository = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: namespace)
        identity = PersistentDeviceIdentityProvider(url: root.appendingPathComponent(namespace).appendingPathComponent("device.identity"), repository: repository)
        session = MatchSession(store: repository, deviceIdentity: identity, clock: clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: namespace))
    }
    func startMatch() async throws -> String { try await session.execute(session.prepareStart(starter: true)).receipt.matchID }
}
final class SyncServiceTests: XCTestCase, @unchecked Sendable {
    func testCommitWithoutTransportKeepsOutbox() async throws {
        let f = try ServiceFixture(namespace: "watch-test"), match = try await f.startMatch()
        let service = MatchSyncService(repository: f.repository, inbound: f.session, clock: f.clock)
        try await service.start(); await service.wake()
        let state = try await service.state(matchID: match)
        XCTAssertGreaterThan(state.unroutedCount, 0); XCTAssertEqual(state.issue, .trustUnavailable)
        await service.stop(); try await f.repository.close()
    }
    func testRepositoryMismatchRefusesActivation() async throws {
        let a = try ServiceFixture(namespace: "same-namespace"), b = try ServiceFixture(namespace: "same-namespace")
        let service = MatchSyncService(repository: a.repository, inbound: b.session, transport: a.transport, clock: a.clock)
        do { try await service.start(); XCTFail("different facade") } catch {}
        let activated = await a.transport.activations; XCTAssertEqual(activated, 0)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
}

actor ToggleTrust: PeerTrustProvider {
    let base: any PeerTrustProvider
    var available = false
    init(_ base: any PeerTrustProvider) { self.base = base }
    func enable() { available = true }
    func disable() { available = false }
    func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization {
        guard available else { throw StoreError.trustUnavailable }; return try await base.authorize(operation, remoteDeviceID: remoteDeviceID)
    }
    func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws {
        guard available else { throw StoreError.trustUnavailable }; try await base.validate(authorization, for: operation)
    }
}
extension SyncServiceTests {
    func trust(_ local: ServiceFixture, _ remote: ServiceFixture) async throws -> DevelopmentPeerTrustProvider {
        let localID = try await local.identity.localDeviceID(), remoteID = try await remote.identity.localDeviceID()
        return try DevelopmentPeerTrustProvider(localIdentityURL: local.root.appendingPathComponent(local.namespace).appendingPathComponent("device.identity"), remoteIdentityURL: remote.root.appendingPathComponent(remote.namespace).appendingPathComponent("device.identity"), localDeviceID: localID, remoteDeviceID: remoteID, databaseNamespace: local.namespace, accountSubject: "fixture-account", pairingID: "fixture-pair", trustEpoch: "fixture-epoch", clock: local.clock)
    }
    func waitUntil(_ condition: @Sendable () async throws -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < limit {
            if try await condition() { return }; await Task.yield()
        }
        XCTFail("condition did not settle")
    }
    func testTransferSuccessWithoutDurableACKStaysPending() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(a, b)
        let match = try await a.startMatch(), service = MatchSyncService(repository: a.repository, inbound: a.session, transport: a.transport, trust: provider, clock: a.clock)
        try await service.start()
        let sent = await a.transport.values(); XCTAssertFalse(sent.isEmpty)
        let state = try await service.state(matchID: match); XCTAssertGreaterThan(state.pendingACKCount, 0)
        XCTAssertNil(state.lastPeerACKAt); await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testTwoIndependentDatabasesReachExactDurableACKWithoutPeerOperations() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test")
        let pa = try await trust(a, b), pb = try await trust(b, a)
        await a.transport.link(b.transport); await b.transport.link(a.transport)
        let match = try await a.startMatch()
        let sa = MatchSyncService(repository: a.repository, inbound: a.session, transport: a.transport, trust: pa, clock: a.clock)
        let sb = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: pb, clock: b.clock)
        try await sb.start(); try await sa.start()
        try await waitUntil { try await a.repository.syncStateV3(matchID: match).pendingACKCount == 0 }
        let received = try await b.repository.snapshotV2(matchID: match); XCTAssertTrue(received.captureOperations.isEmpty)
        let state = try await sa.state(matchID: match); XCTAssertEqual(state.unroutedCount, 0); XCTAssertNotNil(state.lastPeerACKAt)
        let aURL = await a.repository.databaseURL, bURL = await b.repository.databaseURL; XCTAssertNotEqual(aURL, bURL)
        await sa.stop(); await sb.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testStartupTrustFailureRecoversOnOrdinaryWakeWithoutRestart() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test")
        let pa = try await trust(a, b), pb = try await trust(b, a), gate = ToggleTrust(pa)
        await a.transport.link(b.transport); await b.transport.link(a.transport)
        let match = try await a.startMatch(), sa = MatchSyncService(repository: a.repository, inbound: a.session, transport: a.transport, trust: gate, clock: a.clock), sb = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: pb, clock: b.clock)
        try await sb.start(); try await sa.start()
        let blocked = try await sa.state(matchID: match); XCTAssertEqual(blocked.issue, .trustUnavailable)
        await gate.enable(); await sa.wake()
        try await waitUntil { try await a.repository.syncStateV3(matchID: match).pendingACKCount == 0 }
        let recovered = try await sa.state(matchID: match); XCTAssertNil(recovered.issue)
        let activations = await a.transport.activations; XCTAssertEqual(activations, 1)
        await sa.stop(); await sb.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testEncodedFrameLimitIsCheckedAtConstruction() throws {
        XCTAssertThrowsError(try SyncDelivery(bytes: Data(count: SyncFragment.maximumEncodedBytes + 1), transportDeliveryID: "large"))
        XCTAssertEqual(SyncFragment.maximumEncodedBytes, 16 * 1024 * 1024)
        XCTAssertEqual((0..<10).map(SyncRetryPolicy.delay(afterAttempts:)), [1, 2, 4, 8, 16, 32, 60, 120, 300, 300])
    }
}


extension SyncServiceTests {
    func storedPacket(_ source: ServiceFixture, _ receiver: ServiceFixture) async throws -> (String, Data, PeerAuthorization) {
        let match = try await source.startMatch(), provider = try await trust(source, receiver)
        let peer = try await provider.authorize(.route, remoteDeviceID: nil)
        let items = try await source.repository.unroutedBusinessOutboxV3(matchID: match)
        let route = try await source.repository.routeBusinessOutboxV3(outboxID: XCTUnwrap(items.first).id, peer: peer, now: source.clock.now())
        let receiving = try await trust(receiver, source).authorize(.receive, remoteDeviceID: nil)
        return (match, try route.packet.canonicalBytes(), receiving)
    }
    func testStopDuringSuspendedDeliveriesCannotInstallAnOldListener() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(b, a)
        let (match, bytes, _) = try await storedPacket(a, b)
        await b.transport.gateDeliveries()
        let service = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: provider, clock: b.clock)
        let first = Task { try await service.start() }
        try await waitUntil { await b.transport.deliveryCalls == 1 }
        let stopping = Task { await service.stop() }
        try await waitUntil { await !service.running }
        await b.transport.releaseDeliveries(); await stopping.value
        do { try await first.value; XCTFail("cancelled startup") } catch {}
        try await service.start()
        let activations = await b.transport.activations, listeners = await b.transport.deliveryCalls
        XCTAssertEqual(activations, 1); XCTAssertEqual(listeners, 2)
        for fragment in try SyncFragment.fragments(bytes: bytes, kind: .packet) { try await b.transport.receive(fragment.canonicalBytes(), id: fragment.fragmentID) }
        try await waitUntil { (try? await b.repository.snapshotV2(matchID: match)) != nil }
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testACKBudgetOnlyCountsSendAndNewActivationWakesSameInstance() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test")
        let (match, bytes, peer) = try await storedPacket(a, b)
        _ = try await b.repository.receiveV2(bytes, peer: peer, expectedMatchID: match, now: b.clock.now())
        let gate = ToggleTrust(try await trust(b, a)), service = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: gate, clock: b.clock)
        try await service.start()
        for _ in 0..<8 { b.clock.advance(300); await service.wake() }
        let blockedSends = await b.transport.values(); XCTAssertTrue(blockedSends.isEmpty)
        await gate.enable(); await service.wake()
        let first = await b.transport.values(); XCTAssertEqual(first.count, 1)
        for _ in 1..<8 { b.clock.advance(300); await service.wake() }
        let sleeping = await b.transport.values(); XCTAssertEqual(sleeping.count, 8)
        b.clock.advance(300); await service.wake(); let ordinary = await b.transport.values(); XCTAssertEqual(ordinary.count, 8)
        await service.connectionDidActivate()
        let reactivated = await b.transport.values(); XCTAssertEqual(reactivated.count, 9); XCTAssertEqual(Set(reactivated).count, 1)
        let activations = await b.transport.activations, listeners = await b.transport.deliveryCalls
        XCTAssertEqual(activations, 1); XCTAssertEqual(listeners, 1)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testCompleteAssemblySurvivesLongRestartAndTrustRecoversOnOrdinaryWake() async throws {
        let clock = SyncTestClock(), a = try ServiceFixture(namespace: "watch-test", clock: clock), b = try ServiceFixture(namespace: "phone-test", clock: clock)
        let (match, bytes, peer) = try await storedPacket(a, b)
        for fragment in try SyncFragment.fragments(bytes: bytes, kind: .packet) { _ = try await b.repository.acceptSyncFragmentV3(fragment.canonicalBytes(), peer: peer, now: clock.now()) }
        try await b.repository.close(); clock.advance(86_401)
        let reopened = try ServiceFixture(namespace: b.namespace, clock: clock, existingRoot: b.root)
        let gate = ToggleTrust(try await trust(reopened, a)), service = MatchSyncService(repository: reopened.repository, inbound: reopened.session, transport: reopened.transport, trust: gate, clock: clock)
        try await service.start()
        do { _ = try await reopened.repository.snapshotV2(matchID: match); XCTFail("trust unavailable") } catch {}
        await gate.enable(); await service.wake()
        let restored = try await reopened.repository.snapshotV2(matchID: match); XCTAssertEqual(restored.business.descriptor.matchID, match)
        let current = try await gate.authorize(.receive, remoteDeviceID: nil)
        let pending = try await reopened.repository.pendingSyncAssembliesV3(peer: current, now: clock.now()); XCTAssertTrue(pending.isEmpty)
        let sent = await reopened.transport.values(); XCTAssertEqual(sent.count, 1)
        await service.stop(); try await a.repository.close(); try await reopened.repository.close()
    }
    func executeSQLite(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw StoreError.invalidRequest }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.invalidRequest }
    }
    func testStateSubscriberReceivesReadFailureAndRecovery() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(a, b)
        let match = try await a.startMatch(), service = MatchSyncService(repository: a.repository, inbound: a.session, transport: a.transport, trust: provider, clock: a.clock)
        try await service.start()
        var updates = await service.states(matchID: match).makeAsyncIterator()
        guard case .state = await updates.next() else { return XCTFail("initial authoritative state") }
        let url = await a.repository.databaseURL
        try executeSQLite(url, sql: "ALTER TABLE sync_routes_v3 RENAME COLUMN record TO missing_record")
        await service.wake()
        guard case .unavailable(let received, .blockedIntegrity) = await updates.next() else { return XCTFail("explicit unknown state") }
        XCTAssertEqual(received, match)
        try executeSQLite(url, sql: "ALTER TABLE sync_routes_v3 RENAME COLUMN missing_record TO record")
        await service.wake()
        guard case .state(let recovered) = await updates.next() else { return XCTFail("recovered authoritative state") }
        XCTAssertEqual(recovered.matchID, match); XCTAssertGreaterThan(recovered.pendingACKCount, 0)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func testTransportFailurePersistsAcrossBackoffWakeAndReopen() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(a, b)
        let match = try await a.startMatch(), service = MatchSyncService(repository: a.repository, inbound: a.session, trust: provider, clock: a.clock)
        try await service.start()
        let failed = try await service.state(matchID: match); XCTAssertEqual(failed.issue, .transportUnavailable)
        await service.wake(); let backoff = try await service.state(matchID: match); XCTAssertEqual(backoff.issue, .transportUnavailable)
        await service.stop(); try await a.repository.close()
        let reopened = try ServiceFixture(namespace: a.namespace, clock: a.clock, existingRoot: a.root)
        let stored = try await reopened.repository.syncStateV3(matchID: match); XCTAssertEqual(stored.issue, .transportUnavailable)
        try await reopened.repository.close(); try await b.repository.close()
    }
}


extension SyncServiceTests {
    func testPersistentIdentityLossAndReplacementCannotSilentlyReauthorize() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(a, b)
        let authorization = try await provider.authorize(.send, remoteDeviceID: nil)
        let url = b.root.appendingPathComponent(b.namespace).appendingPathComponent("device.identity"), original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        do { try await provider.validate(authorization, for: .send); XCTFail("lost peer identity") } catch let error as StoreError { XCTAssertEqual(error, .trustUnavailable) }
        try Data(("football-record.identity.v1:" + UUID().uuidString).utf8).write(to: url)
        do { _ = try await provider.authorize(.send, remoteDeviceID: nil); XCTFail("replacement peer identity") } catch let error as StoreError { XCTAssertEqual(error, .trustUnavailable) }
        try original.write(to: url); try await provider.validate(authorization, for: .send)
        try await a.repository.close(); try await b.repository.close()
    }
    func testMalformedGlobalIssueDoesNotDisappearDuringEmptyDrain() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(b, a)
        let (match, bytes, peer) = try await storedPacket(a, b)
        _ = try await b.repository.receiveV2(bytes, peer: peer, expectedMatchID: match, now: b.clock.now())
        let service = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: provider, clock: b.clock)
        try await service.start()
        await service.accept(try SyncDelivery(bytes: Data("{}".utf8), transportDeliveryID: "malformed"), generation: await service.epoch)
        let first = try await service.state(matchID: match); XCTAssertEqual(first.issue, .invalidPayload)
        await service.wake(); let second = try await service.state(matchID: match); XCTAssertEqual(second.issue, .invalidPayload)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
}


actor LostPublishCoordinator: SyncInboundCoordinator {
    let repository: SQLiteSessionRepository
    let session: MatchSession
    let clock: SyncTestClock
    var lose = true
    var calls = 0
    init(_ fixture: ServiceFixture) { repository = fixture.repository; session = fixture.session; clock = fixture.clock }
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await repository.syncRepositoryIdentity() }
    func receiveSyncPacket(_ bytes: Data, peer: PeerAuthorization, matchID: String) async throws -> InboundReceiptV3 {
        calls += 1
        if lose {
            lose = false
            _ = try await repository.receiveV2(bytes, peer: peer, expectedMatchID: matchID, now: clock.now())
            throw StoreError.responseLost
        }
        return try await session.receiveSyncPacket(bytes, peer: peer, matchID: matchID)
    }
    func receiveSyncACK(_ bytes: Data, peer: PeerAuthorization) async throws { try await session.receiveSyncACK(bytes, peer: peer) }
}
actor ReopenedGateway: WorkoutGateway {
    var performed: [CaptureOperation] = []
    var reconciled: [CaptureOperation] = []
    func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
        performed.append(operation)
        return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: operation.requestedAt.addingTimeInterval(0.1), outcome: .linked(workoutID: "actual-seed-workout"), window: CaptureWindow(start: nil, end: nil))
    }
    func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
        reconciled.append(operation)
        return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: operation.requestedAt.addingTimeInterval(0.1), outcome: .running, window: CaptureWindow(start: nil, end: nil))
    }
}
extension SyncServiceTests {
    func testRunningServiceReplaysCommittedButUnpublishedPacketWithoutNewFrame() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(b, a)
        let (match, bytes, peer) = try await storedPacket(a, b), inbound = LostPublishCoordinator(b)
        let service = MatchSyncService(repository: b.repository, inbound: inbound, transport: b.transport, trust: provider, clock: b.clock)
        try await service.start() // Initial recovery is complete before the frame arrives.
        for fragment in try SyncFragment.fragments(bytes: bytes, kind: .packet) {
            let generation = await service.epoch
            await service.accept(try SyncDelivery(bytes: fragment.canonicalBytes(), transportDeliveryID: fragment.fragmentID), generation: generation)
        }
        await service.wake()
        let calls = await inbound.calls; XCTAssertEqual(calls, 2)
        let snapshot = try await b.session.snapshot(matchID: match); XCTAssertEqual(snapshot.store.business.descriptor.matchID, match)
        let pending = try await b.repository.pendingSyncAssembliesV3(peer: peer, now: b.clock.now()); XCTAssertTrue(pending.isEmpty)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
    func seedRequest(_ id: String, _ generation: Int64, _ descriptor: MatchDescriptor, events: [MatchEvent] = [], operations: [CaptureOperation] = [], updates: [CaptureOperationUpdate] = [], outbox: [BusinessOutboxItem] = []) throws -> StoreCommitV2 {
        try StoreCommitV2(commandID: id, expectedGeneration: generation, descriptor: descriptor, events: events, captureRevisions: [], newCaptureOperations: operations, captureOperationUpdates: updates, businessOutbox: outbox)
    }
    func testReopenAfterBusinessCommitBeforePublicationFinishesOnlyOriginalToken() async throws {
        let clock = SyncTestClock(), local = try ServiceFixture(namespace: "watch-test", clock: clock), remote = try ServiceFixture(namespace: "phone-test", clock: clock)
        let device = try await local.identity.localDeviceID(), remoteID = try await remote.identity.localDeviceID()
        let intent = StartIntent(id: "seed-intent", matchID: "seed-match", recordingDeviceID: device, requestedAt: clock.now())
        let pending = MatchDescriptor(startIntent: intent, starter: true), active = MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
        var recorder = LiveMatchRecorder(descriptor: active)
        let event = try recorder.start(eventID: "seed-event", sourceDeviceID: device, now: clock.now())
        let operation = try CaptureOperation(id: "seed-op", binding: CaptureBinding(matchID: intent.matchID, recordingDeviceID: device), associatedCommandID: "seed-start", action: .start, requestedAt: clock.now(), externalToken: "seed-op")
        let outbox = try BusinessOutboxItem(id: "seed-outbox", matchID: intent.matchID, sourceDeviceID: device, payload: BusinessDeltaV2(descriptor: active, events: [event], captureRevisions: []))
        _ = try await local.repository.commitV2(seedRequest("seed-intent", 0, pending))
        _ = try await local.repository.commitV2(seedRequest("seed-start", 1, active, events: [event], operations: [operation], outbox: [outbox]))
        _ = try await local.repository.commitV2(seedRequest("seed-dispatch", 2, active, updates: [CaptureOperationUpdate(operationID: operation.id, expectedState: .pending, state: .needsReconciliation, observation: nil)]))
        clock.advance(10)
        let terminal = try PostMatchEditor.terminateAbnormally(terminationID: "seed-terminal", descriptor: active, events: [event], sourceDeviceID: remoteID, now: clock.now())
        let packet = try MatchPacketV2(packetID: "seed-packet", idempotencyKey: "seed-key", sequence: 1, sourceDeviceID: remoteID, targetDeviceID: device, descriptor: active, events: [event, terminal], captureRevisions: []), bytes = try packet.canonicalBytes()
        let provider = try await trust(local, remote), peer = try await provider.authorize(.receive, remoteDeviceID: nil)
        for fragment in try SyncFragment.fragments(bytes: bytes, kind: .packet) { _ = try await local.repository.acceptSyncFragmentV3(fragment.canonicalBytes(), peer: peer, now: clock.now()) }
        let first = try await local.repository.receiveV2(bytes, peer: peer, expectedMatchID: intent.matchID, now: clock.now())
        let oldIdentity = await local.repository.syncRepositoryIdentity()
        try await local.repository.close(); clock.advance(86_401)
        let reopened = try ServiceFixture(namespace: local.namespace, clock: clock, existingRoot: local.root), gateway = ReopenedGateway()
        let session = MatchSession(store: reopened.repository, deviceIdentity: reopened.identity, clock: clock, ids: UUIDSessionIDFactory(), permits: DevelopmentStartPermitProvider(), workout: gateway, environment: .development(databaseNamespace: reopened.namespace))
        let current = try await trust(reopened, remote), auth = try await current.authorize(.receive, remoteDeviceID: nil)
        let service = MatchSyncService(repository: reopened.repository, inbound: session, transport: reopened.transport, trust: current, clock: clock)
        try await service.start()
        try await waitUntil {
            let snapshot = try await reopened.repository.snapshotV2(matchID: intent.matchID)
            return snapshot.captureOperations.contains { $0.operation.action == .finish && $0.state == .settled }
        }
        let final = try await session.snapshot(matchID: intent.matchID), newIdentity = await reopened.repository.syncRepositoryIdentity()
        XCTAssertNotEqual(newIdentity, oldIdentity)
        XCTAssertEqual(final.replay.state, .incomplete); XCTAssertEqual(final.replay.backendLockState, .held)
        XCTAssertEqual(final.store.captureOperations.filter { $0.operation.action == .start }.count, 1)
        let finishes = final.store.captureOperations.filter { $0.operation.action == .finish }
        XCTAssertEqual(finishes.count, 1); XCTAssertEqual(finishes[0].operation.externalToken, "seed-op")
        let calls = await gateway.performed; XCTAssertEqual(calls.map(\.action), [.finish])
        let repeated = try await session.receiveSyncPacket(bytes, peer: auth, matchID: intent.matchID); XCTAssertEqual(repeated, first)
        let assemblies = try await reopened.repository.pendingSyncAssembliesV3(peer: auth, now: clock.now()); XCTAssertTrue(assemblies.isEmpty)
        await service.stop(); try await reopened.repository.close(); try await remote.repository.close()
    }
    func testTransportInputReleasedOnlyAfterFragmentPersistence() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), provider = try await trust(b, a)
        let (_, bytes, _) = try await storedPacket(a, b)
        let service = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: provider, clock: b.clock)
        try await service.start(); let generation = await service.epoch, url = await b.repository.databaseURL
        let fragment = try XCTUnwrap(SyncFragment.fragments(bytes: bytes, kind: .packet).first), delivery = try SyncDelivery(bytes: fragment.canonicalBytes(), transportDeliveryID: "owned-input")
        try executeSQLite(url, sql: "ALTER TABLE sync_fragments_v3 RENAME COLUMN record TO unavailable_record")
        await service.accept(delivery, generation: generation)
        let failed = await b.transport.persisted; XCTAssertTrue(failed.isEmpty)
        try executeSQLite(url, sql: "ALTER TABLE sync_fragments_v3 RENAME COLUMN unavailable_record TO record")
        await service.accept(delivery, generation: generation)
        let saved = await b.transport.persisted; XCTAssertEqual(saved, ["owned-input"])
        await service.accept(delivery, generation: generation)
        let duplicate = await b.transport.persisted; XCTAssertEqual(duplicate, ["owned-input", "owned-input"])
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
}


extension SyncServiceTests {
    func testSameInstanceRestartWithUnavailableTrustStillRetriesPendingAssembly() async throws {
        let a = try ServiceFixture(namespace: "watch-test"), b = try ServiceFixture(namespace: "phone-test"), gate = ToggleTrust(try await trust(b, a))
        let (match, bytes, peer) = try await storedPacket(a, b)
        await gate.enable()
        let service = MatchSyncService(repository: b.repository, inbound: b.session, transport: b.transport, trust: gate, clock: b.clock)
        try await service.start(); await service.stop()
        // Simulate the durable fragment COMMIT whose Session processing was interrupted.
        for fragment in try SyncFragment.fragments(bytes: bytes, kind: .packet) { _ = try await b.repository.acceptSyncFragmentV3(fragment.canonicalBytes(), peer: peer, now: b.clock.now()) }
        await gate.disable(); try await service.start()
        do { _ = try await b.repository.snapshotV2(matchID: match); XCTFail("trust unavailable") } catch {}
        await gate.enable(); await service.wake()
        let snapshot = try await b.repository.snapshotV2(matchID: match); XCTAssertEqual(snapshot.business.descriptor.matchID, match)
        let pending = try await b.repository.pendingSyncAssembliesV3(peer: peer, now: b.clock.now()); XCTAssertTrue(pending.isEmpty)
        await service.stop(); try await a.repository.close(); try await b.repository.close()
    }
}
