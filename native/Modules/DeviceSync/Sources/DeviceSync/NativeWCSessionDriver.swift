import Foundation

enum DeviceSyncTransferOwnership { case owned, foreign, unresolved }
func deviceSyncSourceInsideRoot(_ source: URL, root: URL) -> Bool {
    guard let actual = try? DeviceSyncStorageContext.identity(source.deletingLastPathComponent(), directory: true),
          let owned = try? DeviceSyncStorageContext.identity(root.appendingPathComponent("outbox"), directory: true) else { return false }
    return actual == owned
}
func deviceSyncDrainInventory<Handle>(current: () throws -> [Handle], ownership: (Handle) throws -> DeviceSyncTransferOwnership, cancel: (Handle) throws -> Void) throws -> DeviceSyncDrainStatus {
    var unknown = false
    for transfer in try current() {
        switch try ownership(transfer) {
        case .owned: try cancel(transfer)
        case .foreign: break
        case .unresolved: unknown = true
        }
    }
    var pendingOwned = false
    for transfer in try current() {
        switch try ownership(transfer) {
        case .owned: pendingOwned = true
        case .foreign: break
        case .unresolved: unknown = true
        }
    }
    if unknown { return .unresolved }
    return pendingOwned ? .pending : .drained
}

/// The same pure classification runs in host tests and the native cancellation path.
func deviceSyncTransferOwnership(namespaceID: String?, ownerDigest: String?, transfer: DriverFileTransfer?, protocolMatches: Bool, sourceInsideRoot: Bool, request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) throws -> DeviceSyncTransferOwnership {
    let identity = transfer.flatMap { try? DeviceSyncTransferIdentity(deliveryIDHash: digest(Data($0.deliveryID.utf8)), checksum: $0.checksum, token: $0.token) }
    let original = identity.map { expected.contains($0) } ?? false
    let ownDigest = try request.binding.ownerDigest
    let ownNamespace = namespaceID.map { Data($0.utf8) == Data(request.binding.namespaceID.utf8) } ?? false
    guard protocolMatches else { return sourceInsideRoot || original || ownNamespace || ownerDigest == ownDigest ? .unresolved : .foreign }
    guard transfer != nil, identity != nil else { return .unresolved }
    if let namespaceID {
        guard UUID(uuidString: namespaceID) != nil, let ownerDigest, isDigest(ownerDigest) else { return .unresolved }
        if !ownNamespace { return sourceInsideRoot || original || ownerDigest == ownDigest ? .unresolved : .foreign }
        guard ownerDigest == ownDigest else { return .unresolved }
    } else if ownerDigest != nil { return .unresolved }
    return original ? .owned : .unresolved
}

public extension WCSessionTransport {
    /// Application-owned durable storage must be supplied by the assembly owner.
    /// Host platforms do not construct or imitate a WCSession.
    static func system(applicationSupportDirectory: URL) throws -> WCSessionTransport {
        #if os(iOS) || os(watchOS)
        let root = applicationSupportDirectory.appendingPathComponent("DeviceSync", isDirectory: true)
        return try WCSessionTransport(driver: WCSessionDriver(stateDirectory: root.appendingPathComponent("state")), inbox: DurableFileInbox(directory: root.appendingPathComponent("inbox")), outboxDirectory: root.appendingPathComponent("outbox"))
        #else
        throw DeviceSyncError.unavailable
        #endif
    }
}

#if os(iOS) || os(watchOS)
import WatchConnectivity

/// SDK objects stay in this synchronous owner. Lock order is storage -> driver;
/// no WC object or native reply closure crosses an actor/Task boundary.
public final class WCSessionDriver: WCSessionDriving, DeviceSyncErasureDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let session: WCSession?
    private let proxy: WCDelegateProxy
    private let storage: DeviceSyncStorageContext
    private var callbacks: DriverCallbacks?
    private var pending: [UUID: DriverSettlement<TransportReply>] = [:]
    private var activating = false
    private let pairing: PairingBaseline
    private var activationAccepted = false
    public init(stateDirectory: URL) throws {
        storage = try DeviceSyncStorageContext.component(stateDirectory, role: "state")
        pairing = try PairingBaseline(directory: stateDirectory)
        session = try storage.withActive { WCSession.isSupported() ? WCSession.default : nil }
        proxy = WCDelegateProxy(); proxy.owner = self
    }
    public func install(_ callbacks: DriverCallbacks) async {
        do { try storage.withActive { lock.withLock { self.callbacks = callbacks } } }
        catch { callbacks.event(.activationCompleted(DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false), error as? DeviceSyncError ?? .unavailable)) }
    }
    private func values(_ session: WCSession) -> DriverSnapshot {
        let active = session.activationState == .activated && activationAccepted && !pairing.isInvalidated
        #if os(iOS)
        let counterpart = active && session.isPaired && session.isWatchAppInstalled
        #else
        let counterpart = active && session.isCompanionAppInstalled
        #endif
        return DriverSnapshot(activated: active, reachable: active && session.isReachable, counterpartAvailable: counterpart)
    }
    private func fingerprint(_ session: WCSession) -> String {
        #if os(iOS)
        return "\(session.isPaired):\(session.isWatchAppInstalled):" + (session.watchDirectoryURL?.path ?? "none")
        #else
        return "\(session.isCompanionAppInstalled)"
        #endif
    }
    private var inactiveSnapshot: DriverSnapshot { DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false) }
    public func snapshot() async -> DriverSnapshot {
        (try? storage.withActive { lock.withLock { session.map(values) ?? inactiveSnapshot } }) ?? inactiveSnapshot
    }
    public func activate() async {
        do {
            try storage.withActive {
                let native: WCSession? = try lock.withLock {
                    guard let session else { throw DeviceSyncError.unavailable }
                    guard !activating else { return nil }
                    activating = true; return session
                }
                if let native { native.delegate = proxy; native.activate() }
            }
        } catch { lock.withLock { callbacks }?.event(.activationCompleted(inactiveSnapshot, error as? DeviceSyncError ?? .unavailable)) }
    }
    public func sendMessage(_ bytes: Data) async throws -> TransportReply {
        guard !bytes.isEmpty, bytes.count <= DeviceSyncPolicy.interactiveBytes else { throw DeviceSyncError.invalidFrame }
        let id = UUID(), result = DriverSettlement<TransportReply>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                do {
                    try storage.withActive {
                        let native: WCSession = try lock.withLock {
                            guard !Task.isCancelled else { throw CancellationError() }
                            guard let session else { throw DeviceSyncError.unavailable }
                            let status = values(session)
                            guard status.activated, status.counterpartAvailable else { throw DeviceSyncError.inactive }
                            guard status.reachable else { throw DeviceSyncError.unavailable }
                            pending[id] = result; return session
                        }
                        // Synchronous SDK call shares the fence gate, outside driver lock.
                        native.sendMessageData(bytes, replyHandler: { [weak self, result] bytes in
                            let reply: Result<TransportReply, any Error>
                            do { reply = .success(try TransportReply(wireBytes: bytes)) }
                            catch { reply = .failure(DeviceSyncError.invalidReply) }
                            self?.complete(id, with: reply); result.finish(reply)
                        }, errorHandler: { [weak self, result] _ in
                            let failure: Result<TransportReply, any Error> = .failure(DeviceSyncError.deliveryFailed)
                            self?.complete(id, with: failure); result.finish(failure)
                        })
                    }
                } catch { self.complete(id, with: .failure(error)); result.finish(.failure(error)) }
            }
        }, onCancel: { [weak self, result] in
            // sendMessageData returns void: no SDK cancellation handle exists.
            self?.complete(id, with: .failure(CancellationError()))
            result.finish(.failure(CancellationError()))
        })
    }
    private func complete(_ id: UUID, with result: Result<TransportReply, any Error>) {
        let value = lock.withLock { pending.removeValue(forKey: id) }; value?.finish(result)
    }
    private func fileValue(_ file: WCSessionFile, requireProtocol: Bool = true) -> DriverFileTransfer? {
        guard let metadata = file.metadata, (!requireProtocol || metadata["protocol"] as? String == "football-record.sync-fragment.v2"),
              let id = metadata["deliveryID"] as? String, validOpaqueID(id), let checksum = metadata["checksum"] as? String, isDigest(checksum),
              let token = metadata["token"] as? String, UUID(uuidString: token) != nil else { return nil }
        return DriverFileTransfer(deliveryID: id, checksum: checksum, token: token, url: file.fileURL)
    }
    public func outstandingFiles() async -> [DriverFileTransfer] {
        (try? storage.withActive { lock.withLock { session?.outstandingFileTransfers.compactMap { fileValue($0.file) } ?? [] } }) ?? []
    }
    public func enqueueFile(_ transfer: DriverFileTransfer) async throws {
        try Task.checkCancellation()
        try storage.withActive {
            guard storage.managed, let owner = try storage.ledger.state().owner else { throw DeviceSyncError.unavailable }
            let expectedURL = storage.root.appendingPathComponent("outbox/" + digest(Data(transfer.deliveryID.utf8)) + ".frame")
            guard Data(transfer.url.resolvingSymlinksInPath().path.utf8) == Data(expectedURL.resolvingSymlinksInPath().path.utf8) else { throw DeviceSyncError.conflictingDelivery }
            let bytes = try DeviceSyncStorageContext.readRegular(transfer.url, limit: DeviceSyncPolicy.maximumFrameBytes)
            let queue = try OutgoingFileQueue(directory: storage.root.appendingPathComponent("outbox"))
            guard let saved = try queue.existing(transfer.deliveryID, bytes: bytes), saved.checksum == transfer.checksum, saved.token == transfer.token else { throw DeviceSyncError.conflictingDelivery }
            let native: WCSession? = try lock.withLock {
                guard let session else { throw DeviceSyncError.unavailable }
                let state = values(session)
                guard state.activated, state.counterpartAvailable else { throw DeviceSyncError.inactive }
                let existing = session.outstandingFileTransfers.compactMap { fileValue($0.file) }.filter { Data($0.deliveryID.utf8) == Data(transfer.deliveryID.utf8) }
                if !existing.isEmpty {
                    guard existing.count == 1, existing[0].checksum == transfer.checksum, existing[0].token == transfer.token else { throw DeviceSyncError.conflictingDelivery }
                    return nil
                }
                return session
            }
            if let native {
                try Task.checkCancellation()
                _ = native.transferFile(transfer.url, metadata: ["protocol": "football-record.sync-fragment.v2", "deliveryID": transfer.deliveryID, "checksum": transfer.checksum, "token": transfer.token, "storageNamespace": owner.namespaceID, "storageOwner": try owner.ownerDigest])
            }
        }
    }
    public func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus {
        try storage.withFenced(request) {
            let values = lock.withLock { () -> (WCSession?, [DriverSettlement<TransportReply>]) in
                activationAccepted = false; activating = false
                let results = Array(pending.values); pending = [:]; return (session, results)
            }
            for result in values.1 { result.finish(.failure(DeviceSyncError.erased)) }
            guard let native = values.0 else { return .unresolved }
            return try deviceSyncDrainInventory(current: { native.outstandingFileTransfers }, ownership: { try self.ownership($0, request: request, expected: expected) }, cancel: { $0.cancel() })
        }
    }
    private func ownership(_ transfer: WCSessionFileTransfer, request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) throws -> DeviceSyncTransferOwnership {
        let metadata = transfer.file.metadata
        // Present-but-wrong-type storage tags cannot silently become legacy nil/nil.
        if let metadata {
            if metadata["storageNamespace"] != nil && !(metadata["storageNamespace"] is String) { return .unresolved }
            if metadata["storageOwner"] != nil && !(metadata["storageOwner"] is String) { return .unresolved }
        }
        return try deviceSyncTransferOwnership(namespaceID: metadata?["storageNamespace"] as? String, ownerDigest: metadata?["storageOwner"] as? String, transfer: fileValue(transfer.file, requireProtocol: false), protocolMatches: metadata?["protocol"] as? String == "football-record.sync-fragment.v2", sourceInsideRoot: deviceSyncSourceInsideRoot(transfer.file.fileURL, root: storage.root), request: request, expected: expected)
    }
    fileprivate func receivedMessage(_ bytes: Data) -> TransportReply {
        (try? storage.withActive {
            guard bytes.count <= DeviceSyncPolicy.maximumFrameBytes else { return TransportReply.unavailable }
            let receiver = lock.withLock { callbacks }; return receiver?.message(bytes) ?? .unavailable
        }) ?? .unavailable
    }
    fileprivate func receivedFile(_ url: URL) {
        // Fence precedes stat/read/copy and failure audit in the synchronous inbox callback.
        try? storage.withActive { let receiver = lock.withLock { callbacks }; receiver?.file(url) }
    }
    fileprivate func activated(_ active: Bool, failed: Bool) {
        let value: (DriverCallbacks?, DriverSnapshot, Bool, DeviceSyncError?)
        do {
            value = try storage.withActive { lock.withLock {
                activating = false; activationAccepted = false
                var changed = pairing.isInvalidated, issue: DeviceSyncError? = failed || !active ? .activationFailed : nil
                if active, let session, session.activationState == .activated {
                    do { changed = try pairing.observe(fingerprint(session)) }
                    catch { issue = error as? DeviceSyncError ?? .fileIO; changed = true }
                    activationAccepted = !changed && issue == nil
                }
                return (callbacks, session.map(values) ?? inactiveSnapshot, changed, issue)
            } }
        } catch { lock.withLock { callbacks }?.event(.activationCompleted(inactiveSnapshot, error as? DeviceSyncError ?? .unavailable)); return }
        if value.2 {
            #if os(iOS)
            value.0?.event(.pairingChanged)
            #else
            value.0?.event(.companionChanged)
            #endif
        }
        value.0?.event(.activationCompleted(value.1, value.3))
    }
    fileprivate func changedReachability() {
        guard let value = try? storage.withActive({ lock.withLock { (callbacks, session.map(values) ?? inactiveSnapshot) } }) else { return }
        value.0?.event(.stateChanged(value.1))
    }
    fileprivate func changedCounterpart() {
        guard let value = try? storage.withActive({ lock.withLock { () -> (DriverCallbacks?, Bool) in
            guard let session, session.activationState == .activated else { return (callbacks, false) }
            let changed: Bool
            do { changed = try pairing.observe(fingerprint(session)) }
            catch { activationAccepted = false; return (callbacks, true) }
            if changed { activationAccepted = false }; return (callbacks, changed)
        } }) else { return }
        #if os(iOS)
        if value.1 { value.0?.event(.pairingChanged) }
        #else
        if value.1 { value.0?.event(.companionChanged) }
        #endif
        changedReachability()
    }
    fileprivate func inactive() {
        let values = lock.withLock { () -> (DriverCallbacks?, [DriverSettlement<TransportReply>]) in
            let results = Array(pending.values); pending = [:]; activating = false; activationAccepted = false; return (callbacks, results)
        }
        for value in values.1 { value.finish(.failure(DeviceSyncError.inactive)) }
        values.0?.event(.inactive)
    }
    fileprivate func deactivated() { let receiver = lock.withLock { activating = false; activationAccepted = false; return callbacks }; receiver?.event(.deactivated) }
    fileprivate func fileCompleted(_ transfer: WCSessionFileTransfer, failed: Bool) {
        let value = lock.withLock { (callbacks, fileValue(transfer.file)) }
        if let file = value.1 { value.0?.event(.fileCompleted(file, failed ? .deliveryFailed : nil)) }
    }
}

/// SDK callbacks use a serial background queue, not an actor. This proxy synchronously
/// replies/adopts; only the copied value types in DriverCallbacks subsequently hop.
private final class WCDelegateProxy: NSObject, WCSessionDelegate {
    weak var owner: WCSessionDriver?
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) { owner?.activated(activationState == .activated, failed: error != nil) }
    func sessionReachabilityDidChange(_ session: WCSession) { owner?.changedReachability() }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) { _ = owner?.receivedMessage(messageData) }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let reply = owner?.receivedMessage(messageData) ?? .unavailable
        replyHandler(reply.wireBytes) // Invoke the non-Sendable SDK closure in this callback.
    }
    func session(_ session: WCSession, didReceive file: WCSessionFile) { owner?.receivedFile(file.fileURL) }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) { owner?.fileCompleted(fileTransfer, failed: error != nil) }
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) { owner?.inactive() }
    func sessionDidDeactivate(_ session: WCSession) { owner?.deactivated() }
    func sessionWatchStateDidChange(_ session: WCSession) { owner?.changedCounterpart() }
    #else
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { owner?.changedCounterpart() }
    #endif
}
#endif
