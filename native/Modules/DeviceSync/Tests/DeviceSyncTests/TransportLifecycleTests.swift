import Foundation
import XCTest
@testable import DeviceSync

final class TransportLifecycleTests: XCTestCase, @unchecked Sendable {
    func testRouteRequiresActivationAndUsesIdenticalBytesAtPolicyBoundary() async throws {
        let f = try TransportFixture(); await f.transport.activate()
        await f.driver.setSnapshot(DriverSnapshot(activated: false, reachable: true, counterpartAvailable: true))
        do { try await f.transport.send(Data([1]), deliveryID: "inactive"); XCTFail("inactive") } catch {}
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: true, counterpartAvailable: true))
        let small = Data(repeating: 1, count: 48 * 1024), large = small + Data([2])
        try await f.transport.send(small, deliveryID: "small")
        try await f.transport.send(large, deliveryID: "large")
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: false, counterpartAvailable: true))
        try await f.transport.send(Data([3]), deliveryID: "offline")
        let messages = await f.driver.messages, files = await f.driver.files
        XCTAssertEqual(messages, [small]); XCTAssertEqual(files.map { $0.1 }, [large, Data([3])])
    }
    func testOfflineRetriesAndRestartKeepOneOutstandingFileAndRejectDifferentBytes() async throws {
        let f = try TransportFixture(); await f.transport.activate()
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: false, counterpartAvailable: true))
        let bytes = Data("original".utf8)
        for _ in 0..<8 { try await f.transport.send(bytes, deliveryID: "stable") }
        var files = await f.driver.files; XCTAssertEqual(files.count, 1)
        let reopened = try WCSessionTransport(driver: f.driver, inbox: f.inbox, outboxDirectory: f.root.appendingPathComponent("outbox"))
        await reopened.activate(); try await reopened.send(bytes, deliveryID: "stable")
        files = await f.driver.files; XCTAssertEqual(files.count, 1)
        do { try await reopened.send(Data("different".utf8), deliveryID: "stable"); XCTFail("rebound ID") } catch let error as DeviceSyncError { XCTAssertEqual(error, .conflictingDelivery) }
        let first = try XCTUnwrap(files.first?.0)
        await f.driver.finishFile(first)
        try await settle { !(FileManager.default.fileExists(atPath: first.url.path)) }
        try await reopened.send(bytes, deliveryID: "stable")
        files = await f.driver.files; XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[1].0.token, first.token)
        await f.driver.emit(.fileCompleted(first, nil))
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].0.url.path), "late old completion cannot delete the new attempt")
    }
    func testMessageTaskCancellationSettlesWithoutSDKReply() async throws {
        let f = try TransportFixture(); await f.transport.activate(); await f.driver.gateMessages()
        let send = Task { try await f.transport.send(Data([1]), deliveryID: "cancel") }
        try await settle { await f.driver.messages.count == 1 }
        send.cancel()
        do { try await send.value; XCTFail("cancelled") } catch is CancellationError {}
    }
    func testActualActivationAndReachabilityHaveDifferentEventsAndIdentityInvalidates() async throws {
        let f = try TransportFixture(), log = EventLog(), stream = await f.transport.events()
        let task = Task { for await event in stream { await log.append(event) } }; defer { task.cancel() }
        await f.transport.activate()
        await f.driver.emit(.activationCompleted(DriverSnapshot(activated: true, reachable: true, counterpartAvailable: true), nil))
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: false, counterpartAvailable: true))
        try await settle { await log.values.contains(.wake) }
        let events = await log.values; XCTAssertEqual(events.filter { $0 == .activated }.count, 1)
        await f.transport.notifyTrustInvalidated(.accountChanged)
        do { try await f.transport.send(Data([1]), deliveryID: "old-epoch"); XCTFail("invalidated") } catch {}
        try await settle { await log.values.contains(.trustInvalidated(.accountChanged)) }
    }
}

extension TransportLifecycleTests {
    func testNativeFactoryIsExplicitlyUnavailableOnHost() throws {
        #if !os(iOS) && !os(watchOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try WCSessionTransport.system(applicationSupportDirectory: root)) { XCTAssertEqual($0 as? DeviceSyncError, .unavailable) }
        #endif
    }
    func testDriverSettlementIgnoresLateDuplicateAndCancellationBeforeContinuation() async throws {
        let settlement = DriverSettlement<TransportReply>()
        XCTAssertTrue(settlement.finish(.failure(CancellationError())))
        do {
            _ = try await withCheckedThrowingContinuation { settlement.install($0) }
            XCTFail("cancelled before continuation install")
        } catch is CancellationError {}
        XCTAssertFalse(settlement.finish(.success(.accepted)))
        let success = DriverSettlement<TransportReply>()
        let value: TransportReply = try await withCheckedThrowingContinuation { continuation in
            success.install(continuation)
            XCTAssertTrue(success.finish(.success(.deferred)))
            XCTAssertFalse(success.finish(.failure(DeviceSyncError.deliveryFailed)))
        }
        XCTAssertEqual(value, .deferred)
    }
}

extension TransportLifecycleTests {
    func testInactiveDeactivationReactivatesSDKButCannotRestoreInvalidTrust() async throws {
        let f = try TransportFixture(), log = EventLog(), stream = await f.transport.events()
        let collector = Task { for await value in stream { await log.append(value) } }; defer { collector.cancel() }
        await f.transport.activate(); await f.driver.emit(.inactive); await f.driver.emit(.deactivated)
        try await settle { await f.driver.activations == 2 }
        try await settle { await log.values.contains(.trustInvalidated(.sessionInactive)) }
        do { try await f.transport.send(Data([1]), deliveryID: "after-switch"); XCTFail("SDK activation cannot authorize a changed peer") } catch {}
        let messages = await f.driver.messages, files = await f.driver.files
        XCTAssertTrue(messages.isEmpty); XCTAssertTrue(files.isEmpty)
    }
    func testActivationFailureAndMissingCompanionCannotSend() async throws {
        let f = try TransportFixture(), log = EventLog(), stream = await f.transport.events()
        let collector = Task { for await event in stream { await log.append(event) } }; defer { collector.cancel() }
        await f.driver.setSnapshot(DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false))
        await f.transport.activate(); await f.driver.emit(.activationCompleted(DriverSnapshot(activated: false, reachable: false, counterpartAvailable: false), .activationFailed))
        try await settle { await log.values.contains(.failure(.activationFailed)) }
        do { try await f.transport.send(Data([1]), deliveryID: "failed"); XCTFail("failed activation") } catch {}
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: true, counterpartAvailable: false))
        do { try await f.transport.send(Data([1]), deliveryID: "uninstalled"); XCTFail("missing companion") } catch {}
    }
    func testConcurrentOfflineRetriesShareOneSDKEnqueue() async throws {
        let f = try TransportFixture(); await f.transport.activate()
        await f.driver.setSnapshot(DriverSnapshot(activated: true, reachable: false, counterpartAvailable: true))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { try await f.transport.send(Data("same".utf8), deliveryID: "same") } }
            try await group.waitForAll()
        }
        let files = await f.driver.files; XCTAssertEqual(files.count, 1)
    }
    func testCrashAfterCompletionMetadataRemovalCanReclaimOrphanAndResendOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing-fault-" + UUID().uuidString)
        let queue = try OutgoingFileQueue(directory: root, fault: .afterRecordRemoval), bytes = Data("original".utf8)
        let transfer = try queue.stage(bytes, id: "original")
        XCTAssertThrowsError(try queue.completed(transfer))
        let metadata = transfer.url.deletingPathExtension().appendingPathExtension("json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transfer.url.path), "actual fault occurs after record invalidation, before payload unlink")
        let reopened = try OutgoingFileQueue(directory: root)
        try reopened.recoverOrphans(outstanding: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.url.path))
        let retry = try reopened.stage(bytes, id: "original")
        XCTAssertEqual(try Data(contentsOf: retry.url), bytes); XCTAssertNotEqual(retry.token, transfer.token)
    }
}

extension TransportLifecycleTests {
    func testConcurrentActivationCannotPassSuspendedCallbackInstallation() async throws {
        let f = try TransportFixture(), flag = CompletionFlag()
        await f.driver.setSnapshot(DriverSnapshot(activated: false, reachable: false, counterpartAvailable: true))
        await f.driver.gateInstallation()
        let first = Task { await f.transport.activate() }
        try await settle { await f.driver.installCalls == 1 }
        let second = Task { await f.transport.activate(); await flag.done() }
        for _ in 0..<30 { await Task.yield() }
        let early = await flag.value, activatedEarly = await f.driver.activations
        XCTAssertFalse(early); XCTAssertEqual(activatedEarly, 0)
        await f.driver.releaseInstallation(); await first.value; await second.value
        let installed = await f.driver.installCalls, activations = await f.driver.activations
        XCTAssertEqual(installed, 1); XCTAssertEqual(activations, 1)
    }
}

extension TransportLifecycleTests {
    func testExplicitInvalidationRefusesNewInteractiveInput() async throws {
        let f = try TransportFixture(); await f.transport.activate()
        await f.transport.notifyTrustInvalidated(.remoteIdentityChanged)
        let reply = await f.driver.receiveMessage(Data("new-incoming".utf8))
        XCTAssertEqual(reply, .unavailable); XCTAssertTrue(f.inbox.scan().frames.isEmpty)
    }
}
