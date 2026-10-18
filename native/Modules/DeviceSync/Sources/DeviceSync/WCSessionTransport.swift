import Foundation
import MatchSync

private final class InvalidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var invalid = false
    var isInvalidated: Bool { lock.withLock { invalid } }
    func invalidate() { lock.withLock { invalid = true } }
}

public actor WCSessionTransport: SyncTransport, DeviceSyncLocalTransportErasing {
    let driver: any WCSessionDriving
    let inbox: DurableFileInbox
    let outgoing: OutgoingFileQueue
    private let gate = InvalidationGate()
    var installed = false
    var activation: (UUID, Task<Void, Never>)?
    var active = false
    var invalidation: TrustInvalidationReason?
    var deliveriesSubscribers: [UUID: AsyncStream<SyncDelivery>.Continuation] = [:]
    var eventSubscribers: [UUID: AsyncStream<DeviceSyncEvent>.Continuation] = [:]
    var sends: [String: (String, UUID, Task<Void, any Error>)] = [:]
    public init(driver: any WCSessionDriving, inbox: DurableFileInbox, outboxDirectory: URL) throws {
        guard inbox.directory != outboxDirectory.standardizedFileURL else { throw DeviceSyncError.fileIO }
        let outgoing = try OutgoingFileQueue(directory: outboxDirectory)
        guard inbox.storage.managed == outgoing.storage.managed else { throw DeviceSyncErasureError.unsupportedLayout }
        if inbox.storage.managed { try inbox.storage.requireSameGate(as: outgoing.storage) }
        if let bound = driver as? any DeviceSyncStorageBoundDriving {
            try inbox.storage.requireSameGate(as: bound.storageContext)
        }
        self.driver = driver; self.inbox = inbox; self.outgoing = outgoing
    }
    public func deliveries() -> AsyncStream<SyncDelivery> {
        let id = UUID(), (stream, continuation) = AsyncStream<SyncDelivery>.makeStream(bufferingPolicy: .bufferingNewest(256))
        deliveriesSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeDeliverySubscriber(id) } }
        return stream
    }
    public func events() -> AsyncStream<DeviceSyncEvent> {
        let id = UUID(), (stream, continuation) = AsyncStream<DeviceSyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        eventSubscribers[id] = continuation
        if let invalidation { continuation.yield(.trustInvalidated(invalidation)) }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeEventSubscriber(id) } }
        return stream
    }
    func removeDeliverySubscriber(_ id: UUID) { deliveriesSubscribers[id] = nil }
    func removeEventSubscriber(_ id: UUID) { eventSubscribers[id] = nil }
    func publish(_ event: DeviceSyncEvent) { for c in eventSubscribers.values { c.yield(event) } }
    func deliver(_ frame: SyncDelivery) {
        guard !gate.isInvalidated else { return }
        try? inbox.storage.withActive { for c in deliveriesSubscribers.values { c.yield(frame) } }
    }
    func storageIsActive() -> Bool {
        do { try inbox.storage.withActive {}; return true }
        catch { active = false; publish(.failure(error as? DeviceSyncError ?? .unavailable)); return false }
    }
    public func erase(_ request: DeviceSyncLocalEraseRequest) async throws -> DeviceSyncEraseResult {
        guard inbox.storage.managed, outgoing.storage.managed, inbox.storage.rootIdentity == outgoing.storage.rootIdentity else { throw DeviceSyncErasureError.unsupportedLayout }
        notifyTrustInvalidated(.accountChanged)
        let erasureDriver: any DeviceSyncErasureDriving
        if let bound = driver as? any DeviceSyncStorageBoundDriving, let capable = driver as? any DeviceSyncErasureDriving {
            try inbox.storage.requireSameGate(as: bound.storageContext)
            erasureDriver = capable
        } else { erasureDriver = UnavailableDeviceSyncErasureDriver() }
        return try await DeviceSyncErasureService(context: inbox.storage, driver: erasureDriver).erase(request)
    }
    public func activate() async {
        guard storageIsActive() else { return }
        if let activation { await activation.1.value; return }
        let id = UUID(), task = Task { await self.installAndActivate() }
        activation = (id, task)
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if activation?.0 == id { activation = nil }
    }
    func installAndActivate() async {
        guard storageIsActive() else { return }
        if !installed {
            let inbox = inbox, gate = gate
            let callbacks = DriverCallbacks(message: { [weak self] bytes in
                guard !gate.isInvalidated else { return .unavailable }
                do {
                    let frame = try inbox.adoptData(bytes)
                    guard !gate.isInvalidated else { return .deferred }
                    Task { await self?.deliver(frame) }; return .accepted
                } catch {
                    let issue = error as? DeviceSyncError ?? .fileIO
                    Task { await self?.publish(.failure(issue)) }
                    return issue == .quotaExceeded ? .deferred : .unavailable
                }
            }, file: { [weak self] source in
                guard !gate.isInvalidated else { return }
                do {
                    let frame = try inbox.adoptFile(source)
                    Task { await self?.deliver(frame) }
                } catch { let issue = error as? DeviceSyncError ?? .fileIO; Task { await self?.publish(.failure(issue)) } }
            }, event: { [weak self] event in
                switch event {
                case .inactive, .pairingChanged, .companionChanged: gate.invalidate()
                default: break
                }
                Task { await self?.handle(event) }
            })
            await driver.install(callbacks)
            guard !Task.isCancelled, storageIsActive() else { return }
            installed = true
            await driver.activate()
        } else if !(await driver.snapshot()).activated { await driver.activate() }
        guard !Task.isCancelled, storageIsActive() else { return }
        if (await driver.snapshot()).activated {
            do { try outgoing.recoverOrphans(outstanding: await driver.outstandingFiles()) }
            catch { publish(.failure(error as? DeviceSyncError ?? .fileIO)) }
        }
        let recovered = inbox.scan()
        for failure in recovered.failures { publish(.failure(failure.issue)) }
        for frame in recovered.frames { deliver(frame) }
    }
    /// App account/local UUID changes are explicit upper-layer notifications.
    /// SDK pairing/lifecycle notifications use separate reasons; neither authorizes a peer.
    public func notifyTrustInvalidated(_ reason: TrustInvalidationReason) {
        gate.invalidate(); invalidation = reason; active = false
        for send in sends.values { send.2.cancel() }
        publish(.trustInvalidated(reason))
    }
    func handle(_ event: DriverEvent) async {
        guard storageIsActive() else { return }
        switch event {
        case .activationCompleted(let snapshot, let error):
            if let error { active = false; publish(.failure(error)); return }
            let was = active; active = snapshot.activated && snapshot.counterpartAvailable
            if active && !was && invalidation == nil { publish(.activated) }
            if active {
                do { try outgoing.recoverOrphans(outstanding: await driver.outstandingFiles()) }
                catch { publish(.failure(error as? DeviceSyncError ?? .fileIO)) }
            }
        case .stateChanged: publish(.wake)
        case .inactive: notifyTrustInvalidated(.sessionInactive)
        case .deactivated:
            active = false; await driver.activate()
        case .pairingChanged: notifyTrustInvalidated(.pairingChanged)
        case .companionChanged: notifyTrustInvalidated(.companionChanged)
        case .fileCompleted(let transfer, let error):
            do { try outgoing.completed(transfer) } catch { publish(.failure(error as? DeviceSyncError ?? .fileIO)) }
            if let error { publish(.failure(error)) }; publish(.wake)
        }
    }
    public func send(_ fragmentBytes: Data, deliveryID: String) async throws {
        guard !fragmentBytes.isEmpty, fragmentBytes.count <= DeviceSyncPolicy.maximumFrameBytes else { throw DeviceSyncError.quotaExceeded }
        _ = try outgoing.key(deliveryID)
        let checksum = digest(fragmentBytes)
        if let existing = sends[deliveryID] {
            guard existing.0 == checksum else { throw DeviceSyncError.conflictingDelivery }
            return try await awaitSend(existing.2)
        }
        let id = UUID(), task = Task { try await self.performSend(fragmentBytes, id: deliveryID) }
        sends[deliveryID] = (checksum, id, task)
        defer { if sends[deliveryID]?.1 == id { sends[deliveryID] = nil } }
        try await awaitSend(task)
    }
    func awaitSend(_ task: Task<Void, any Error>) async throws {
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func performSend(_ bytes: Data, id: String) async throws {
        try Task.checkCancellation()
        try inbox.storage.withActive {}
        guard installed else { throw DeviceSyncError.inactive }
        let state = await driver.snapshot()
        try inbox.storage.withActive {}
        guard invalidation == nil, !gate.isInvalidated else { throw DeviceSyncError.unavailable }
        guard state.activated else { throw DeviceSyncError.inactive }
        guard state.counterpartAvailable else { throw DeviceSyncError.unavailable }
        let existing = try outgoing.existing(id, bytes: bytes), outstanding = await driver.outstandingFiles().filter { $0.deliveryID == id }
        try inbox.storage.withActive {}
        try Task.checkCancellation(); guard invalidation == nil, !gate.isInvalidated else { throw DeviceSyncError.unavailable }
        if !outstanding.isEmpty {
            guard outstanding.count == 1, let saved = existing, outstanding[0].checksum == saved.checksum, outstanding[0].token == saved.token else { throw DeviceSyncError.conflictingDelivery }
            return // already accepted by SDK; do not enqueue or send a parallel fast path
        }
        if existing == nil, state.reachable, bytes.count <= DeviceSyncPolicy.interactiveBytes {
            let reply = try await driver.sendMessage(bytes)
            try inbox.storage.withActive {}
            guard reply != .unavailable else { throw DeviceSyncError.unavailable }
        } else {
            let transfer = try outgoing.stage(bytes, id: id)
            try Task.checkCancellation()
            try await driver.enqueueFile(transfer)
            try inbox.storage.withActive {}
        }
    }
    public func didPersistDelivery(_ transportDeliveryID: String) async {
        do { try inbox.didPersist(transportDeliveryID) }
        catch { publish(.failure(error as? DeviceSyncError ?? .fileIO)) }
    }
}
