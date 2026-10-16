import Foundation

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

/// The SDK objects stay in this lock-protected nonactor owner and its delegate proxy.
/// No non-Sendable WC object, metadata dictionary, or native reply closure crosses a Task.
public final class WCSessionDriver: WCSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let session: WCSession?
    private let proxy: WCDelegateProxy
    private var callbacks: DriverCallbacks?
    private var pending: [UUID: DriverSettlement<TransportReply>] = [:]
    private var activating = false
    private let pairing: PairingBaseline
    private var activationAccepted = false
    public init(stateDirectory: URL) throws {
        pairing = try PairingBaseline(directory: stateDirectory)
        session = WCSession.isSupported() ? WCSession.default : nil
        proxy = WCDelegateProxy()
        proxy.owner = self // Strong owner retains the SDK's weak delegate.
    }
    public func install(_ callbacks: DriverCallbacks) async { lock.withLock { self.callbacks = callbacks } }
    func values(_ session: WCSession) -> DriverSnapshot {
        let active = session.activationState == .activated && activationAccepted && !pairing.isInvalidated
        #if os(iOS)
        let counterpart = active && session.isPaired && session.isWatchAppInstalled
        #else
        let counterpart = active && session.isCompanionAppInstalled
        #endif
        return DriverSnapshot(activated: active, reachable: active && session.isReachable, counterpartAvailable: counterpart)
    }
    func fingerprint(_ session: WCSession) -> String {
        #if os(iOS)
        return "\(session.isPaired):\(session.isWatchAppInstalled):" + (session.watchDirectoryURL?.path ?? "none")
        #else
        return "\(session.isCompanionAppInstalled)"
        #endif
    }
    public func snapshot() async -> DriverSnapshot {
        lock.withLock { session.map(values) ?? DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false) }
    }
    public func activate() async {
        let error: DriverCallbacks? = lock.withLock {
            guard let session else { return callbacks }
            guard !activating else { return nil }
            activating = true
            session.delegate = proxy
            session.activate()
            return nil
        }
        error?.event(.activationCompleted(DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false), .unavailable))
    }
    public func sendMessage(_ bytes: Data) async throws -> TransportReply {
        guard !bytes.isEmpty, bytes.count <= DeviceSyncPolicy.interactiveBytes else { throw DeviceSyncError.invalidFrame }
        let id = UUID(), result = DriverSettlement<TransportReply>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let failure: DeviceSyncError? = lock.withLock {
                    guard !Task.isCancelled else { return .unavailable }
                    guard let session else { return .unavailable }
                    let status = values(session)
                    guard status.activated, status.counterpartAvailable else { return .inactive }
                    guard status.reachable else { return .unavailable }
                    pending[id] = result
                    session.sendMessageData(bytes, replyHandler: { [weak self, result] bytes in
                        let reply: Result<TransportReply, any Error>
                        do { reply = .success(try TransportReply(wireBytes: bytes)) }
                        catch { reply = .failure(DeviceSyncError.invalidReply) }
                        self?.complete(id, with: reply); result.finish(reply)
                    }, errorHandler: { [weak self, result] _ in
                        let failure: Result<TransportReply, any Error> = .failure(DeviceSyncError.deliveryFailed)
                        self?.complete(id, with: failure); result.finish(failure)
                    })
                    return nil
                }
                if let failure { result.finish(.failure(failure)) }
            }
        }, onCancel: { [weak self, result] in
            // sendMessageData has no SDK cancel handle. End local waiting now; a late
            // native reply/error can only attempt the same exactly-once settlement.
            self?.complete(id, with: .failure(CancellationError()))
            result.finish(.failure(CancellationError()))
        })
    }
    private func complete(_ id: UUID, with result: Result<TransportReply, any Error>) {
        let value = lock.withLock { pending.removeValue(forKey: id) }; value?.finish(result)
    }
    func fileValue(_ file: WCSessionFile) -> DriverFileTransfer? {
        guard let metadata = file.metadata,
              metadata["protocol"] as? String == "football-record.sync-fragment.v2",
              let id = metadata["deliveryID"] as? String, !id.isEmpty, id.utf8.count <= 4096,
              let checksum = metadata["checksum"] as? String, isDigest(checksum),
              let token = metadata["token"] as? String, UUID(uuidString: token) != nil else { return nil }
        return DriverFileTransfer(deliveryID: id, checksum: checksum, token: token, url: file.fileURL)
    }
    public func outstandingFiles() async -> [DriverFileTransfer] {
        lock.withLock { session?.outstandingFileTransfers.compactMap { fileValue($0.file) } ?? [] }
    }
    public func enqueueFile(_ transfer: DriverFileTransfer) async throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard let session else { throw DeviceSyncError.unavailable }
            let state = values(session)
            guard state.activated, state.counterpartAvailable else { throw DeviceSyncError.inactive }
            let existing = session.outstandingFileTransfers.compactMap { fileValue($0.file) }.filter { $0.deliveryID == transfer.deliveryID }
            if !existing.isEmpty {
                guard existing.count == 1, existing[0].checksum == transfer.checksum, existing[0].token == transfer.token else { throw DeviceSyncError.conflictingDelivery }
                return
            }
            _ = session.transferFile(transfer.url, metadata: ["protocol": "football-record.sync-fragment.v2", "deliveryID": transfer.deliveryID, "checksum": transfer.checksum, "token": transfer.token])
            // Queue acceptance is enough to return to the service drain. A later native
            // completion releases only this owned outgoing file, never a business ACK.
        }
    }
    fileprivate func receivedMessage(_ bytes: Data) -> TransportReply {
        let receiver = lock.withLock { callbacks }
        guard bytes.count <= DeviceSyncPolicy.maximumFrameBytes else { return .unavailable }
        return receiver?.message(bytes) ?? .unavailable
    }
    fileprivate func receivedFile(_ url: URL) { lock.withLock { callbacks }?.file(url) }
    fileprivate func activated(_ active: Bool, failed: Bool) {
        let value = lock.withLock { () -> (DriverCallbacks?, DriverSnapshot, Bool, DeviceSyncError?) in
            activating = false; activationAccepted = false
            var changed = pairing.isInvalidated, issue: DeviceSyncError? = failed || !active ? .activationFailed : nil
            if active, let session, session.activationState == .activated {
                do { changed = try pairing.observe(fingerprint(session)) }
                catch { issue = error as? DeviceSyncError ?? .fileIO; changed = true }
                activationAccepted = !changed && issue == nil
            }
            let snapshot = session.map(values) ?? DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false)
            return (callbacks, snapshot, changed, issue)
        }
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
        let value = lock.withLock { (callbacks, session.map(values) ?? DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false)) }
        value.0?.event(.stateChanged(value.1))
    }
    fileprivate func changedCounterpart() {
        let value = lock.withLock { () -> (DriverCallbacks?, Bool) in
            guard let session, session.activationState == .activated else { return (callbacks, false) }
            let changed: Bool
            do { changed = try pairing.observe(fingerprint(session)) }
            catch { activationAccepted = false; return (callbacks, true) }
            if changed { activationAccepted = false }; return (callbacks, changed)
        }
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
