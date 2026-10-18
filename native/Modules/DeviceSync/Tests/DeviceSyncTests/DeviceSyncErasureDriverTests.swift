import Foundation
import XCTest
import MatchSync
@testable import DeviceSync

actor ErasureDispatchBarrier {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
final class GateDispatchDriver: WCSessionDriving, DeviceSyncErasureDriving, DeviceSyncStorageBoundDriving, @unchecked Sendable {
    enum Phase { case beforeFile, afterFile, afterMessage }
    let context: DeviceSyncStorageContext
    var storageContext: DeviceSyncStorageContext { context }
    let phase: Phase
    let barrier = ErasureDispatchBarrier()
    private let lock = NSLock()
    private var callbacks: DriverCallbacks?
    private var files: [DriverFileTransfer] = []
    private var wires: [Data] = []
    private var cancellations: [String] = []
    init(context: DeviceSyncStorageContext, phase: Phase) { self.context = context; self.phase = phase }
    var originalBytes: [Data] { lock.withLock { wires } }
    var cancelled: [String] { lock.withLock { cancellations } }
    func install(_ callbacks: DriverCallbacks) async { lock.withLock { self.callbacks = callbacks } }
    func activate() async { try? context.withActive {} }
    func snapshot() async -> DriverSnapshot { DriverSnapshot(activated: true, reachable: phase == .afterMessage, counterpartAvailable: true) }
    func outstandingFiles() async -> [DriverFileTransfer] { lock.withLock { files } }
    func sendMessage(_ bytes: Data) async throws -> TransportReply {
        try context.withActive { lock.withLock { wires.append(bytes) } }
        await barrier.pause()
        return .accepted
    }
    func enqueueFile(_ transfer: DriverFileTransfer) async throws {
        if phase == .beforeFile { await barrier.pause() }
        try context.withActive {
            let bytes = try Data(contentsOf: transfer.url)
            lock.withLock { files.append(transfer); wires.append(bytes) }
        }
        if phase == .afterFile { await barrier.pause() }
    }
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus {
        try context.withFenced(request) {
            try lock.withLock {
                for transfer in files {
                    let identity = try DeviceSyncTransferIdentity(deliveryIDHash: digest(Data(transfer.deliveryID.utf8)), checksum: transfer.checksum, token: transfer.token)
                    guard expected.contains(identity) else { throw DeviceSyncErasureError.unknownInventory }
                    cancellations.append(transfer.token)
                }
                files = []
                return .drained
            }
        }
    }
}
actor PendingErasureDriver: DeviceSyncErasureDriving {
    var result: DeviceSyncDrainStatus
    var calls: [[DeviceSyncTransferIdentity]] = []
    init(_ result: DeviceSyncDrainStatus) { self.result = result }
    func set(_ value: DeviceSyncDrainStatus) { result = value }
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { calls.append(expected); return result }
}

final class DeviceSyncErasureDriverTests: XCTestCase, @unchecked Sendable {
    func testTransportDoesNotActivateAfterStorageFence() async throws {
        let f = try ManagedErasureFixture(), driver = FakeWCDriver()
        let transport = try WCSessionTransport(driver: driver, inbox: f.inbox(), outboxDirectory: f.root.appendingPathComponent("outbox"))
        _ = try await f.service().erase(f.request)
        await transport.activate()
        let count = await driver.activations
        XCTAssertEqual(count, 0, "persistent erasure precedes every activation, including a fresh actor")
    }
    func testQueuedActorDeliveryCannotEscapePersistentFence() async throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), driver = FakeWCDriver()
        let transport = try WCSessionTransport(driver: driver, inbox: inbox, outboxDirectory: f.root.appendingPathComponent("outbox"))
        let stream = await transport.deliveries(), frame = try inbox.adoptData(Data("queued-before-fence".utf8))
        _ = try await f.service().erase(f.request)
        await transport.deliver(frame)
        let next = await withTaskGroup(of: Data?.self) { group in
            group.addTask { for await value in stream { return value.bytes }; return nil }
            group.addTask { try? await Task.sleep(for: .milliseconds(30)); return nil }
            let result = await group.next() ?? nil; group.cancelAll(); return result
        }
        XCTAssertNil(next, "queued actor hop must recheck durable gate")
    }
    func testEnqueuePausedBeforeNativeCallCannotResurrect() async throws {
        let f = try ManagedErasureFixture(), driver = GateDispatchDriver(context: f.context, phase: .beforeFile)
        let transport = try WCSessionTransport(driver: driver, inbox: f.inbox(), outboxDirectory: f.root.appendingPathComponent("outbox"))
        await transport.activate()
        let send = Task { try await transport.send(Data("original-file".utf8), deliveryID: "file") }
        try await settle { await driver.barrier.entered }
        guard case .completed = try await f.service(driver: driver).erase(f.request) else { return XCTFail("erase") }
        await driver.barrier.release()
        do { try await send.value; XCTFail("late enqueue") } catch { XCTAssertEqual(error as? DeviceSyncError, .erased) }
        XCTAssertTrue(driver.originalBytes.isEmpty)
    }
    func testAcceptedEnqueueLateCompletionReturnsTerminalAfterFence() async throws {
        let f = try ManagedErasureFixture(), driver = GateDispatchDriver(context: f.context, phase: .afterFile)
        let transport = try WCSessionTransport(driver: driver, inbox: f.inbox(), outboxDirectory: f.root.appendingPathComponent("outbox"))
        await transport.activate()
        let raw = Data("original-file".utf8), send = Task { try await transport.send(raw, deliveryID: "file") }
        try await settle { await driver.barrier.entered }
        guard case .completed = try await f.service(driver: driver).erase(f.request) else { return XCTFail("erase") }
        await driver.barrier.release()
        do { try await send.value; XCTFail("late SDK acceptance cannot succeed after fence") } catch { XCTAssertEqual(error as? DeviceSyncError, .erased) }
        XCTAssertEqual(driver.originalBytes, [raw]); XCTAssertEqual(driver.cancelled.count, 1)
    }
    func testAcceptedMessageLateReplyCannotReturnSuccessAfterFence() async throws {
        let f = try ManagedErasureFixture(), driver = GateDispatchDriver(context: f.context, phase: .afterMessage)
        let transport = try WCSessionTransport(driver: driver, inbox: f.inbox(), outboxDirectory: f.root.appendingPathComponent("outbox"))
        await transport.activate()
        let raw = Data("interactive-original".utf8), send = Task { try await transport.send(raw, deliveryID: "message") }
        try await settle { await driver.barrier.entered }
        _ = try await f.service(driver: driver).erase(f.request)
        await driver.barrier.release()
        do { try await send.value; XCTFail("late reply cannot restore active namespace") } catch { XCTAssertEqual(error as? DeviceSyncError, .erased) }
        XCTAssertEqual(driver.originalBytes, [raw])
    }
    func testPendingAndUnresolvedKeepOriginalAndFrozenIdentityAcrossReopen() async throws {
        for status in [DeviceSyncDrainStatus.pending, .unresolved] {
            let f = try ManagedErasureFixture(), raw = Data("pending-original".utf8), transfer = try f.queue().stage(raw, id: "stable-delivery")
            let driver = PendingErasureDriver(status)
            let result = try await f.service(driver: driver).erase(f.request)
            XCTAssertEqual(result, .pending(status)); XCTAssertEqual(try Data(contentsOf: transfer.url), raw)
            let reopened = try DeviceSyncStorageContext(root: f.root)
            await driver.set(.drained)
            guard case .completed = try await DeviceSyncErasureService(context: reopened, driver: driver).erase(f.request) else { return XCTFail("retry") }
            let calls = await driver.calls
            XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1]); XCTAssertEqual(calls[0].first?.token, transfer.token)
        }
    }
}

extension DeviceSyncErasureDriverTests {
    func testNativeOwnershipRequiresExactNamespaceIntentAndOriginalTransfer() throws {
        let f = try ManagedErasureFixture(), transfer = try f.queue().stage(Data("exact-original".utf8), id: "original")
        let expected = try DeviceSyncTransferIdentity(deliveryIDHash: digest(Data(transfer.deliveryID.utf8)), checksum: transfer.checksum, token: transfer.token)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: f.binding.namespaceID, ownerDigest: f.binding.ownerDigest, transfer: transfer, protocolMatches: true, sourceInsideRoot: true, request: f.request, expected: [expected]), .owned)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: nil, ownerDigest: nil, transfer: transfer, protocolMatches: true, sourceInsideRoot: true, request: f.request, expected: [expected]), .owned, "legacy exact persisted mapping remains cancellable")
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: f.binding.namespaceID, ownerDigest: f.binding.ownerDigest, transfer: transfer, protocolMatches: true, sourceInsideRoot: true, request: f.request, expected: []), .unresolved)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: f.binding.namespaceID, ownerDigest: String(repeating: "c", count: 64), transfer: transfer, protocolMatches: true, sourceInsideRoot: true, request: f.request, expected: [expected]), .unresolved)
    }
    func testNativeForeignAndMalformedInventoryAreNeverSilentlyOwnedOrDropped() throws {
        let f = try ManagedErasureFixture(), transfer = try f.queue().stage(Data("original".utf8), id: "id")
        let other = try ManagedErasureFixture(account: "other-account"), foreign = try other.queue().stage(Data("foreign-original".utf8), id: "foreign-id")
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: other.binding.namespaceID, ownerDigest: other.binding.ownerDigest, transfer: foreign, protocolMatches: true, sourceInsideRoot: false, request: f.request, expected: []), .foreign)
        XCTAssertEqual(try Data(contentsOf: foreign.url), Data("foreign-original".utf8))
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: nil, ownerDigest: nil, transfer: nil, protocolMatches: true, sourceInsideRoot: false, request: f.request, expected: []), .unresolved)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: "bad", ownerDigest: nil, transfer: transfer, protocolMatches: true, sourceInsideRoot: false, request: f.request, expected: []), .unresolved)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: nil, ownerDigest: nil, transfer: nil, protocolMatches: false, sourceInsideRoot: false, request: f.request, expected: []), .foreign)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: nil, ownerDigest: nil, transfer: nil, protocolMatches: false, sourceInsideRoot: true, request: f.request, expected: []), .unresolved)
    }
}

private struct ThrowingErasureDriver: DeviceSyncErasureDriving {
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { throw DeviceSyncError.deliveryFailed }
}
extension DeviceSyncErasureDriverTests {
    func testDriverFailureKeepsCanonicalAndPermanentRequestForRetry() async throws {
        let f = try ManagedErasureFixture(), raw = Data("original".utf8), outgoing = try f.queue().stage(raw, id: "d")
        do { _ = try await f.service(driver: ThrowingErasureDriver()).erase(f.request); XCTFail("driver fault") } catch { XCTAssertEqual(error as? DeviceSyncError, .deliveryFailed) }
        XCTAssertEqual(try Data(contentsOf: outgoing.url), raw)
        XCTAssertThrowsError(try f.queue().stage(Data("late".utf8), id: "new"))
        guard case .completed = try await f.service().erase(f.request) else { return XCTFail("original retry") }
    }
    func testUnsupportedDriverDoesNotManufactureCompletion() async throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), raw = Data("kept".utf8), frame = try inbox.adoptData(raw)
        let transport = try WCSessionTransport(driver: FakeWCDriver(), inbox: inbox, outboxDirectory: f.root.appendingPathComponent("outbox"))
        let result = try await transport.erase(f.request)
        XCTAssertEqual(result, .pending(.unresolved))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
    }
    func testNativeDrainCancelsOnlyOwnedAndPreservesForeign() throws {
        var outstanding = ["owned", "foreign"], cancelled: [String] = []
        let result = try deviceSyncDrainInventory(current: { outstanding }, ownership: { $0 == "owned" ? .owned : .foreign }, cancel: { token in cancelled.append(token); outstanding.removeAll { $0 == token } })
        XCTAssertEqual(result, .drained); XCTAssertEqual(cancelled, ["owned"]); XCTAssertEqual(outstanding, ["foreign"])
    }
    func testNativeDrainUnknownAndStillOutstandingCannotComplete() throws {
        var outstanding = ["owned", "unknown", "foreign"], cancelled: [String] = []
        let unknown = try deviceSyncDrainInventory(current: { outstanding }, ownership: { $0 == "owned" ? .owned : ($0 == "foreign" ? .foreign : .unresolved) }, cancel: { cancelled.append($0) })
        XCTAssertEqual(unknown, .unresolved); XCTAssertEqual(cancelled, ["owned"])
        outstanding.removeAll { $0 == "unknown" }
        let pending = try deviceSyncDrainInventory(current: { outstanding }, ownership: { $0 == "owned" ? .owned : .foreign }, cancel: { _ in })
        XCTAssertEqual(pending, .pending)
        outstanding.removeAll { $0 == "owned" } // controlled late SDK completion, not a business ACK
        let drained = try deviceSyncDrainInventory(current: { outstanding }, ownership: { _ in .foreign }, cancel: { _ in XCTFail("no target left") })
        XCTAssertEqual(drained, .drained); XCTAssertEqual(outstanding, ["foreign"])
    }
}

private struct ConflictingNativeOwnerDriver: DeviceSyncErasureDriving {
    let transfer: DriverFileTransfer
    let otherNamespace: String
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus {
        try deviceSyncDrainInventory(current: { [transfer] }, ownership: {
            try deviceSyncTransferOwnership(namespaceID: otherNamespace, ownerDigest: String(repeating: "c", count: 64), transfer: $0, protocolMatches: true, sourceInsideRoot: true, request: request, expected: expected)
        }, cancel: { _ in XCTFail("contradictory metadata must not expand cancellation") })
    }
}
extension DeviceSyncErasureDriverTests {
    func testNativeForeignTagCannotHideRootOrFrozenTransferEvidence() throws {
        let f = try ManagedErasureFixture(), transfer = try f.queue().stage(Data("ours".utf8), id: "original")
        let expected = try DeviceSyncTransferIdentity(deliveryIDHash: digest(Data(transfer.deliveryID.utf8)), checksum: transfer.checksum, token: transfer.token), other = UUID().uuidString
        for (inside, original) in [(true, [DeviceSyncTransferIdentity]()), (false, [expected]), (true, [expected])] {
            XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: other, ownerDigest: String(repeating: "c", count: 64), transfer: transfer, protocolMatches: true, sourceInsideRoot: inside, request: f.request, expected: original), .unresolved)
        }
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: other, ownerDigest: String(repeating: "c", count: 64), transfer: transfer, protocolMatches: false, sourceInsideRoot: false, request: f.request, expected: [expected]), .unresolved)
        XCTAssertEqual(try deviceSyncTransferOwnership(namespaceID: other, ownerDigest: f.binding.ownerDigest, transfer: transfer, protocolMatches: true, sourceInsideRoot: false, request: f.request, expected: []), .unresolved)
    }
    func testContradictoryNativeOwnerCannotCompleteOrDeleteCanonical() async throws {
        let f = try ManagedErasureFixture(), raw = Data("must-stay-until-native-owned-state-known".utf8), transfer = try f.queue().stage(raw, id: "original")
        let result = try await f.service(driver: ConflictingNativeOwnerDriver(transfer: transfer, otherNamespace: UUID().uuidString)).erase(f.request)
        XCTAssertEqual(result, .pending(.unresolved))
        XCTAssertEqual(try Data(contentsOf: transfer.url), raw)
        XCTAssertNil(try f.context.withLocked { try f.context.ledger.state().receipt })
    }
    func testNativeSourceOwnershipUsesActualParentDirectoryIdentity() throws {
        let f = try ManagedErasureFixture(), other = try ManagedErasureFixture(account: "other"), transfer = try f.queue().stage(Data("ours".utf8), id: "d"), foreign = try other.queue().stage(Data("foreign".utf8), id: "d")
        XCTAssertTrue(deviceSyncSourceInsideRoot(transfer.url, root: f.context.root), "system /var alias still names the owned directory")
        XCTAssertFalse(deviceSyncSourceInsideRoot(foreign.url, root: f.context.root))
        let alias = f.root.deletingLastPathComponent().appendingPathComponent("devicesync/outbox/" + transfer.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: alias.path) { XCTAssertTrue(deviceSyncSourceInsideRoot(alias, root: f.context.root), "case alias is the same actual owned outbox") }
    }
}


extension DeviceSyncErasureDriverTests {
    func testAssemblyRejectsTwoManagedRoots() throws {
        let first = try ManagedErasureFixture(), second = try ManagedErasureFixture(account: "second")
        XCTAssertThrowsError(try WCSessionTransport(driver: FakeWCDriver(), inbox: first.inbox(), outboxDirectory: second.root.appendingPathComponent("outbox")))
    }
    func testAssemblyRejectsManagedAndStandaloneMixInBothDirections() throws {
        let f = try ManagedErasureFixture()
        let standalone = FileManager.default.temporaryDirectory.appendingPathComponent("standalone-" + UUID().uuidString)
        XCTAssertThrowsError(try WCSessionTransport(driver: FakeWCDriver(), inbox: f.inbox(), outboxDirectory: standalone.appendingPathComponent("outgoing")))
        let inbox = try DurableFileInbox(directory: standalone.appendingPathComponent("incoming"))
        XCTAssertThrowsError(try WCSessionTransport(driver: FakeWCDriver(), inbox: inbox, outboxDirectory: f.root.appendingPathComponent("outbox")))
    }
    func testAssemblyRejectsThirdRootBoundDriverButAcceptsSameActualGate() throws {
        let first = try ManagedErasureFixture(), third = try ManagedErasureFixture(account: "third")
        XCTAssertThrowsError(try WCSessionTransport(driver: GateDispatchDriver(context: third.context, phase: .beforeFile), inbox: first.inbox(), outboxDirectory: first.root.appendingPathComponent("outbox")))
        let reopened = try DeviceSyncStorageContext(root: first.root)
        XCTAssertNoThrow(try WCSessionTransport(driver: GateDispatchDriver(context: reopened, phase: .beforeFile), inbox: first.inbox(), outboxDirectory: first.root.appendingPathComponent("outbox")))
    }
    func testUnboundCustomDriverCannotClaimErasureCompletion() async throws {
        let f = try ManagedErasureFixture(), raw = Data("unbound-driver-original".utf8)
        let transfer = try f.queue().stage(raw, id: "original")
        let transport = try WCSessionTransport(driver: UnboundDrainedWCDriver(), inbox: f.inbox(), outboxDirectory: f.root.appendingPathComponent("outbox"))
        let result = try await transport.erase(f.request)
        XCTAssertEqual(result, .pending(.unresolved))
        XCTAssertEqual(try Data(contentsOf: transfer.url), raw)
        XCTAssertNil(try f.context.withLocked { try f.context.ledger.state().receipt })
    }
}
private struct UnboundDrainedWCDriver: WCSessionDriving, DeviceSyncErasureDriving {
    func install(_ callbacks: DriverCallbacks) async {}
    func activate() async {}
    func snapshot() async -> DriverSnapshot { DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false) }
    func sendMessage(_ bytes: Data) async throws -> TransportReply { .unavailable }
    func outstandingFiles() async -> [DriverFileTransfer] { [] }
    func enqueueFile(_ transfer: DriverFileTransfer) async throws { throw DeviceSyncError.unavailable }
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .drained }
}


extension DeviceSyncErasureDriverTests {
    func testFencedReopenAdmissionOnlyAcceptsOriginalErasureRequest() async throws {
        let f = try ManagedErasureFixture()
        _ = try await f.service(driver: UnavailableDeviceSyncErasureDriver()).erase(f.request)
        let reopened = try DeviceSyncStorageContext(root: f.root)
        XCTAssertThrowsError(try DeviceSyncNativeStorageAdmission(context: reopened))
        let admission = try DeviceSyncNativeStorageAdmission(context: reopened, erasureRequest: f.request)
        XCTAssertEqual(try admission.withAccess { "control-only" }, "control-only")
        let changed = try DeviceSyncLocalEraseRequest(binding: f.binding, requestID: f.request.requestID, requestDigest: String(repeating: "d", count: 64))
        XCTAssertThrowsError(try DeviceSyncNativeStorageAdmission(context: reopened, erasureRequest: changed))
        XCTAssertThrowsError(try PairingBaseline(directory: f.root.appendingPathComponent("state")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state").path), "erasure admission cannot create pairing/canonical state")
    }
    func testNativeInventoryReadinessRejectsEmptyBeforeActivationAndAfterInvalidation() throws {
        var readiness = DeviceSyncNativeErasureReadiness()
        var reads = 0
        func status(_ activated: Bool) throws -> DeviceSyncDrainStatus {
            try readiness.drain(nativeActivated: activated, current: { reads += 1; return [String]() }, ownership: { _ in .foreign }, cancel: { _ in })
        }
        XCTAssertEqual(try status(false), .pending)
        XCTAssertEqual(try status(true), .pending, "native state alone cannot replace this owner's activation callback")
        XCTAssertEqual(reads, 0)
        readiness.completed(active: true, failed: true)
        XCTAssertEqual(try status(true), .pending)
        readiness.completed(active: true, failed: false)
        XCTAssertEqual(try status(false), .pending)
        XCTAssertEqual(try status(true), .drained)
        XCTAssertEqual(reads, 2, "trusted inventory is checked before and after cancellation")
        readiness.invalidate()
        XCTAssertEqual(try status(true), .pending)
        XCTAssertEqual(reads, 2)
    }
    func testFencedNativeReopenStaysPendingUntilReadyAndOwnedInventoryActuallyDrains() async throws {
        let f = try ManagedErasureFixture(), raw = Data("reopened-native-original".utf8)
        let transfer = try f.queue().stage(raw, id: "reopened-original")
        _ = try await f.service(driver: UnavailableDeviceSyncErasureDriver()).erase(f.request)
        let reopened = try DeviceSyncStorageContext(root: f.root)
        let driver = try ReopenedNativeHostDriver(context: reopened, request: f.request, transfers: [transfer])
        let service = DeviceSyncErasureService(context: reopened, driver: driver)
        let pending = try await service.erase(f.request)
        XCTAssertEqual(pending, .pending(.pending))
        XCTAssertEqual(driver.inventoryReads, 0)
        driver.activationCompleted()
        let ownedPending = try await service.erase(f.request)
        XCTAssertEqual(ownedPending, .pending(.pending))
        XCTAssertEqual(driver.cancelled, [transfer.token])
        XCTAssertEqual(try Data(contentsOf: transfer.url), raw)
        driver.finishOriginal()
        guard case .completed(let receipt) = try await service.erase(f.request) else { return XCTFail("ready SDK inventory now drained") }
        XCTAssertEqual(receipt.request, f.request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.url.path))
        XCTAssertThrowsError(try reopened.withActive {})
        let replay = try await service.erase(f.request)
        XCTAssertEqual(replay, .completed(receipt))
    }
}
private final class ReopenedNativeHostDriver: DeviceSyncErasureDriving, @unchecked Sendable {
    private let admission: DeviceSyncNativeStorageAdmission
    private let lock = NSLock()
    private var readiness = DeviceSyncNativeErasureReadiness()
    private var activated = false
    private var transfers: [DriverFileTransfer]
    private var reads = 0
    private var cancellations: [String] = []
    init(context: DeviceSyncStorageContext, request: DeviceSyncLocalEraseRequest, transfers: [DriverFileTransfer]) throws {
        admission = try DeviceSyncNativeStorageAdmission(context: context, erasureRequest: request); self.transfers = transfers
    }
    var inventoryReads: Int { lock.withLock { reads } }
    var cancelled: [String] { lock.withLock { cancellations } }
    func activationCompleted() { lock.withLock { activated = true; readiness.completed(active: true, failed: false) } }
    func finishOriginal() { lock.withLock { transfers = [] } }
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus {
        try admission.withAccess { try lock.withLock {
            try readiness.drain(nativeActivated: activated, current: { reads += 1; return transfers }, ownership: {
                try deviceSyncTransferOwnership(namespaceID: request.binding.namespaceID, ownerDigest: request.binding.ownerDigest, transfer: $0, protocolMatches: true, sourceInsideRoot: true, request: request, expected: expected)
            }, cancel: { cancellations.append($0.token) })
        } }
    }
}
