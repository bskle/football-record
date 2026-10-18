import Foundation
import XCTest
@testable import DeviceSync

actor FakeWCDriver: WCSessionDriving {
    var callbacks: DriverCallbacks?
    var state = DriverSnapshot(activated: true, reachable: true, counterpartAvailable: true)
    var activations = 0
    var installCalls = 0
    var installGate = false
    var installationWaiter: CheckedContinuation<Void, Never>?
    var messages: [Data] = []
    var files: [(DriverFileTransfer, Data)] = []
    var outstanding: [DriverFileTransfer] = []
    var suspendMessages = false
    var waiting: CheckedContinuation<TransportReply, any Error>?
    var reply: TransportReply = .accepted
    func install(_ callbacks: DriverCallbacks) async {
        installCalls += 1
        if installGate { await withCheckedContinuation { installationWaiter = $0 } }
        self.callbacks = callbacks
    }
    func gateInstallation() { installGate = true }
    func releaseInstallation() { installGate = false; installationWaiter?.resume(); installationWaiter = nil }
    func activate() async { activations += 1; callbacks?.event(.activationCompleted(state, nil)) }
    func snapshot() async -> DriverSnapshot { state }
    func outstandingFiles() async -> [DriverFileTransfer] { outstanding }
    func sendMessage(_ bytes: Data) async throws -> TransportReply {
        messages.append(bytes)
        if suspendMessages {
            return try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { waiting = $0 } }, onCancel: { Task { await self.cancelMessage() } })
        }
        return reply
    }
    func cancelMessage() { waiting?.resume(throwing: CancellationError()); waiting = nil }
    func enqueueFile(_ transfer: DriverFileTransfer) async throws {
        files.append((transfer, try Data(contentsOf: transfer.url))); outstanding.append(transfer)
    }
    func setSnapshot(_ value: DriverSnapshot) { state = value; callbacks?.event(.stateChanged(value)) }
    func emit(_ event: DriverEvent) { callbacks?.event(event) }
    func gateMessages() { suspendMessages = true }
    func receiveMessage(_ bytes: Data) -> TransportReply { callbacks?.message(bytes) ?? .unavailable }
    func receiveFileThenDeleteOriginal(_ url: URL) throws { callbacks?.file(url); try FileManager.default.removeItem(at: url) }
    func finishFile(_ transfer: DriverFileTransfer, error: DeviceSyncError? = nil) {
        outstanding.removeAll { $0.token == transfer.token }; callbacks?.event(.fileCompleted(transfer, error))
    }
}
func settle(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline { if await predicate() { return }; await Task.yield() }
    XCTFail("async condition did not settle")
}
actor EventLog {
    var values: [DeviceSyncEvent] = []
    func append(_ event: DeviceSyncEvent) { values.append(event) }
}
struct TransportFixture: Sendable {
    let root: URL, inbox: DurableFileInbox, driver: FakeWCDriver, transport: WCSessionTransport
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wc-transport-" + UUID().uuidString)
        inbox = try DurableFileInbox(directory: root.appendingPathComponent("inbox")); driver = FakeWCDriver()
        transport = try WCSessionTransport(driver: driver, inbox: inbox, outboxDirectory: root.appendingPathComponent("outbox"))
    }
}

actor CompletionFlag {
    var value = false
    func done() { value = true }
}
