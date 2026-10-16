import Foundation
import MatchStore

/// One scheduler and receive stream per facade. Callback success never confirms business data.
public actor MatchSyncService {
    let repository: any SyncRepository
    let inbound: any SyncInboundCoordinator
    let transport: any SyncTransport
    let trust: any PeerTrustProvider
    let clock: any SyncClock
    var running = false
    var epoch = UUID()
    var starting: Task<Void, Error>?
    var draining: Task<Void, Never>?
    var activating: Task<Void, Never>?
    var listening: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var requested = false
    var needsReplay = true
    var replayRevision = UUID()
    var issues: [String: SyncIssue] = [:]
    var globalIssue: SyncIssue?
    var subscribers: [String: [UUID: AsyncStream<SyncStateUpdate>.Continuation]] = [:]
    public init(repository: any SyncRepository, inbound: any SyncInboundCoordinator, transport: any SyncTransport = UnavailableSyncTransport(), trust: any PeerTrustProvider = UnavailablePeerTrustProvider(), clock: any SyncClock = SystemSyncClock()) {
        self.repository = repository; self.inbound = inbound; self.transport = transport; self.trust = trust; self.clock = clock
    }
    public func start() async throws {
        if let starting { return try await starting.value }
        if running { return }
        let generation = UUID(); epoch = generation
        needsReplay = true; replayRevision = UUID()
        let task = Task { try await self.activate(generation) }; starting = task
        do { try await task.value; if epoch == generation { starting = nil } }
        catch { if epoch == generation { starting = nil; running = false }; throw error }
    }
    func activate(_ generation: UUID) async throws {
        guard await repository.syncRepositoryIdentity() == inbound.syncRepositoryIdentity() else { throw StoreError.invalidRequest }
        try Task.checkCancellation(); guard epoch == generation else { throw CancellationError() }
        running = true
        let stream = await transport.deliveries()
        try Task.checkCancellation(); guard running, epoch == generation else { throw CancellationError() }
        listening = Task { [weak self] in
            for await delivery in stream {
                guard !Task.isCancelled else { break }
                await self?.accept(delivery, generation: generation)
            }
        }
        await transport.activate()
        try Task.checkCancellation(); guard running, epoch == generation else { throw CancellationError() }
        await connectionDidActivate()
        await wake()
        guard running, epoch == generation, !Task.isCancelled else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.wake()
            }
        }
    }
    /// Call once for an actual new transport activation. Timer ticks and ordinary wake
    /// never reset the ACK sleep budget or create another receive/drain loop.
    public func connectionDidActivate() async {
        guard running else { return }
        if let activating { await activating.value; return }
        let generation = epoch, task = Task { await self.restoreActivation(generation) }
        activating = task; await task.value
        if epoch == generation { activating = nil }
        await wake()
    }
    func restoreActivation(_ generation: UUID) async {
        needsReplay = true; replayRevision = UUID()
        do {
            let peer = try await trust.authorize(.receive, remoteDeviceID: nil)
            try await trust.validate(peer, for: .receive)
            guard running, epoch == generation, !Task.isCancelled else { return }
            try await repository.reactivateSyncACKsV3()
            try await replayPending(peer: peer, generation: generation)
            if globalIssue == .trustUnavailable { globalIssue = nil }
        } catch { globalIssue = issue(error) }
    }
    func replayPending(peer: PeerAuthorization, generation: UUID) async throws {
        try await repository.expireSyncAssembliesV3(now: clock.now())
        let revision = replayRevision
        let pending = try await repository.pendingSyncAssembliesV3(peer: peer, now: clock.now())
        var failed = false
        for assembly in pending {
            guard running, epoch == generation, !Task.isCancelled else { return }
            do { try await process(assembly, peer: peer) }
            catch { failed = true } // One quarantined match cannot block another complete message.
        }
        guard running, epoch == generation, !Task.isCancelled else { return }
        needsReplay = failed || replayRevision != revision
    }
    public func stop() async {
        running = false; epoch = UUID(); requested = false
        let tasks = (starting, draining, listening, timer, activating)
        starting = nil; draining = nil; listening = nil; timer = nil; activating = nil
        tasks.0?.cancel(); tasks.1?.cancel(); tasks.2?.cancel(); tasks.3?.cancel(); tasks.4?.cancel()
        _ = try? await tasks.0?.value
        await tasks.1?.value; await tasks.2?.value; await tasks.3?.value; await tasks.4?.value
    }
    public func wake() async {
        guard running else { return }; requested = true
        if let draining { await draining.value; return }
        let generation = epoch, task = Task { await self.drain(generation) }
        draining = task; await task.value
    }
    func drain(_ generation: UUID) async {
        defer { if epoch == generation { draining = nil } }
        while running, epoch == generation, requested, !Task.isCancelled {
            requested = false
            do {
                if needsReplay {
                    do {
                        let peer = try await trust.authorize(.receive, remoteDeviceID: nil)
                        try await trust.validate(peer, for: .receive)
                        guard running, epoch == generation, !Task.isCancelled else { return }
                        try await replayPending(peer: peer, generation: generation)
                        if globalIssue == .trustUnavailable { globalIssue = nil }
                    } catch { globalIssue = issue(error) }
                }
                try await repository.expireSyncAssembliesV3(now: clock.now())
                let matches = try await repository.matchIDs()
                for match in matches {
                    guard running, epoch == generation, !Task.isCancelled else { return }
                    do {
                        for item in try await repository.unroutedBusinessOutboxV3(matchID: match) {
                            let peer = try await trust.authorize(.route, remoteDeviceID: nil)
                            try await trust.validate(peer, for: .route)
                            _ = try await repository.routeBusinessOutboxV3(outboxID: item.id, peer: peer, now: clock.now())
                        }
                        try await repository.ensureSyncDeliveriesV3(matchID: match)
                        if issues[match] == .ancestryIncomplete { issues.removeValue(forKey: match) }
                    } catch { issues[match] = issue(error) }
                }
                let due = try await repository.dueSyncDeliveriesV3(now: clock.now(), limit: 32)
                for delivery in due {
                    guard running, epoch == generation, !Task.isCancelled else { return }
                    var failure: SyncIssue?, enteredSend = false
                    do {
                        let peer = try await trust.authorize(.send, remoteDeviceID: delivery.targetDeviceID)
                        guard peer.localDeviceID == delivery.sourceDeviceID, peer.remoteDeviceID == delivery.targetDeviceID else { throw StoreError.invalidPeerAuthorization }
                        try await repository.validateSyncDeliveryV3(deliveryID: delivery.deliveryID, peer: peer, now: clock.now())
                        try await trust.validate(peer, for: .send)
                        guard running, epoch == generation, !Task.isCancelled else { return }
                        enteredSend = true
                        try await transport.send(delivery.fragmentBytes, deliveryID: delivery.deliveryID)
                        issues.removeValue(forKey: delivery.matchID); globalIssue = nil
                    } catch { failure = issue(error); issues[delivery.matchID] = failure }
                    // Unavailable/expired authorization pauses delivery without spending the
                    // eight actual ACK send attempts. Original bytes and epoch stay bound.
                    guard enteredSend else { continue }
                    let now = clock.now()
                    try await repository.recordSyncAttemptV3(deliveryID: delivery.deliveryID, nextAttemptAt: now.addingTimeInterval(SyncRetryPolicy.delay(afterAttempts: delivery.attemptCount)), issue: failure, now: now)
                }
                for match in matches { await publish(match) }
            } catch {
                globalIssue = issue(error)
                for match in Array(subscribers.keys) { await publish(match) }
            }
        }
    }
    func accept(_ delivery: SyncDelivery, generation: UUID) async {
        guard running, epoch == generation else { return }
        guard delivery.bytes.count <= SyncFragment.maximumEncodedBytes else { globalIssue = .quotaExceeded; return }
        var match: String?
        do {
            let fragment = try? JSONDecoder().decode(SyncFragment.self, from: delivery.bytes)
            match = fragment?.body.matchID
            let operation: PeerOperation = fragment?.body.kind == .ack ? .acknowledge : .receive
            let peer = try await trust.authorize(operation, remoteDeviceID: fragment?.body.sourceDeviceID)
            try await trust.validate(peer, for: operation)
            guard running, epoch == generation else { return }
            let result = try await repository.acceptSyncFragmentV3(delivery.bytes, peer: peer, now: clock.now())
            await transport.didPersistDelivery(delivery.transportDeliveryID)
            try await process(result, peer: peer)
            globalIssue = nil
        } catch {
            if let match { issues[match] = issue(error); await publish(match) } else { globalIssue = issue(error) }
        }
        await wake()
    }
    func process(_ result: FragmentAssemblyResult, peer: PeerAuthorization) async throws {
        guard running, !Task.isCancelled else { throw CancellationError() }
        guard case .complete(let messageID, let kind, let match, let checksum, let bytes) = result else { return }
        do {
            try await trust.validate(peer, for: kind == .packet ? .receive : .acknowledge)
            switch kind {
            case .packet: _ = try await inbound.receiveSyncPacket(bytes, peer: peer, matchID: match)
            case .ack: try await inbound.receiveSyncACK(bytes, peer: peer)
            }
            try await repository.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: checksum)
            issues.removeValue(forKey: match)
        } catch {
            issues[match] = issue(error); needsReplay = true; replayRevision = UUID()
            // A business COMMIT may precede a lost reload/cleanup result. Its original ACK
            // remains eligible; the unconsumed assembly replays through Session on restart.
            try? await repository.ensureSyncDeliveriesV3(matchID: match)
            await publish(match); throw error
        }
        try await repository.ensureSyncDeliveriesV3(matchID: match)
        await publish(match)
    }
    public func state(matchID: String) async throws -> SyncState {
        let stored = try await repository.syncStateV3(matchID: matchID)
        return try SyncState(matchID: stored.matchID, unroutedCount: stored.unroutedCount, pendingACKCount: stored.pendingACKCount, receivedGapCount: stored.receivedGapCount, lastPeerACKAt: stored.lastPeerACKAt, issue: stored.issue ?? issues[matchID] ?? globalIssue)
    }
    public func states(matchID: String) -> AsyncStream<SyncStateUpdate> {
        let id = UUID(), (stream, continuation) = AsyncStream<SyncStateUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[matchID, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(matchID, id: id) } }
        Task { await self.publish(matchID) }; return stream
    }
    func removeSubscriber(_ match: String, id: UUID) { subscribers[match]?[id] = nil }
    func publish(_ match: String) async {
        let update: SyncStateUpdate
        do { update = .state(try await state(matchID: match)) }
        catch { update = .unavailable(matchID: match, issue: .blockedIntegrity) }
        for continuation in subscribers[match, default: [:]].values { continuation.yield(update) }
    }
    func issue(_ error: any Error) -> SyncIssue {
        guard let error = error as? StoreError else { return .transportUnavailable }
        switch error {
        case .trustUnavailable, .invalidPeerAuthorization: return .trustUnavailable
        case .syncTransportUnavailable: return .transportUnavailable
        case .ancestryIncomplete: return .ancestryIncomplete
        case .syncQuotaExceeded: return .quotaExceeded
        case .corruptPayload, .unresolvedDiagnostics: return .blockedIntegrity
        case .injectedFailure, .responseLost, .sqlite, .closed: return .retryScheduled
        default: return .invalidPayload
        }
    }
}
