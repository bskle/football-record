import Foundation
import XCTest
@testable import DeviceSync

struct ManagedErasureFixture: Sendable {
    let root: URL
    let context: DeviceSyncStorageContext
    let binding: DeviceSyncNamespaceBinding
    let request: DeviceSyncLocalEraseRequest
    init(root: URL? = nil, account: String = "account-a", space: String = "space-a") throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("erase-" + UUID().uuidString).appendingPathComponent("DeviceSync")
        context = try DeviceSyncStorageContext(root: self.root)
        binding = try DeviceSyncNamespaceBinding(namespaceID: UUID().uuidString, accountID: account, cloudSpaceID: space, zoneID: "zone-a", activationEpoch: 7, catalogRevision: 1, catalogDigest: String(repeating: "a", count: 64), rootIdentity: context.rootIdentity)
        try context.bind(binding)
        request = try DeviceSyncLocalEraseRequest(binding: binding, requestID: "saga/original", requestDigest: String(repeating: "b", count: 64))
    }
    func inbox() throws -> DurableFileInbox { try DurableFileInbox(directory: root.appendingPathComponent("inbox")) }
    func queue() throws -> OutgoingFileQueue { try OutgoingFileQueue(directory: root.appendingPathComponent("outbox")) }
    func service(driver: any DeviceSyncErasureDriving = DrainedErasureDriver(), fault: DeviceSyncErasureFault? = nil) -> DeviceSyncErasureService { DeviceSyncErasureService(context: context, driver: driver, fault: fault) }
}
struct DrainedErasureDriver: DeviceSyncErasureDriving {
    func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .drained }
}

final class DeviceSyncErasureTests: XCTestCase, @unchecked Sendable {
    func testBoundNamespaceErasesCanonicalAndReplaysOriginalAfterReopen() async throws {
        let f = try ManagedErasureFixture(), raw = Data("business-original".utf8)
        let frame = try f.inbox().adoptData(raw)
        let transfer = try f.queue().stage(raw, id: "delivery/original")
        let result = try await f.service().erase(f.request)
        guard case .completed(let receipt) = result else { return XCTFail("must complete owned namespace") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame").path))
        let reopened = try DeviceSyncStorageContext(root: f.root)
        let replay = try await DeviceSyncErasureService(context: reopened, driver: DrainedErasureDriver()).erase(f.request)
        XCTAssertEqual(replay, .completed(receipt))
        XCTAssertThrowsError(try f.inbox().adoptData(raw))
        XCTAssertThrowsError(try f.queue().stage(raw, id: "new"))
        XCTAssertThrowsError(try reopened.bind(f.binding))
    }
    func testEmptyNamespaceOnlyLeavesRetainedControl() async throws {
        let f = try ManagedErasureFixture()
        guard case .completed = try await f.service().erase(f.request) else { return XCTFail("empty owned root") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".control/.owner").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".control/control.sqlite").path))
    }
    func testUnknownEntryFailsWithoutDeletingOriginalOrCompleting() async throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), raw = Data("keep".utf8)
        let frame = try inbox.adoptData(raw)
        let unknown = f.root.appendingPathComponent("inbox/unknown.bin")
        try Data("unknown".utf8).write(to: unknown)
        do { _ = try await f.service().erase(f.request); XCTFail("unknown inventory") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("unknown".utf8))
    }
    func testUnboundLegacyPreservesOriginalAndCannotBeBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("DeviceSync")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("inbox/legacy.frame"), raw = Data("legacy".utf8)
        try raw.write(to: file)
        let context = try DeviceSyncStorageContext(root: root)
        let binding = try DeviceSyncNamespaceBinding(namespaceID: UUID().uuidString, accountID: "a", cloudSpaceID: "s", zoneID: "z", activationEpoch: 1, catalogRevision: 1, catalogDigest: String(repeating: "c", count: 64), rootIdentity: context.rootIdentity)
        XCTAssertThrowsError(try context.bind(binding))
        XCTAssertThrowsError(try DurableFileInbox(directory: root.appendingPathComponent("inbox")).adoptData(Data("new".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), raw)
    }
    func testOtherNamespaceAndRawScopeArePreserved() async throws {
        let first = try ManagedErasureFixture(space: "space-é"), other = try ManagedErasureFixture(space: "space-e\u{301}")
        let raw = Data("other-account-canonical".utf8), frame = try other.inbox().adoptData(raw)
        guard case .completed = try await first.service().erase(first.request) else { return XCTFail("first") }
        XCTAssertEqual(try other.inbox().scan().frames.first?.bytes, raw)
        XCTAssertEqual(try Data(contentsOf: other.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
        let wrong = try DeviceSyncLocalEraseRequest(binding: other.binding, requestID: first.request.requestID, requestDigest: first.request.requestDigest)
        do { _ = try await first.service().erase(wrong); XCTFail("cross owner") } catch {}
    }
    func testChangedIntentCannotReplayReceipt() async throws {
        let f = try ManagedErasureFixture()
        _ = try await f.service().erase(f.request)
        let changed = try DeviceSyncLocalEraseRequest(binding: f.binding, requestID: f.request.requestID, requestDigest: String(repeating: "c", count: 64))
        do { _ = try await f.service().erase(changed); XCTFail("same ID changed digest") } catch {}
    }
}

extension DeviceSyncErasureTests {
    func testEveryFenceAndReceiptFaultReopensSameIntent() async throws {
        let faults: [DeviceSyncErasureFault] = [.beforeFenceCommit, .afterFenceCommit, .afterUnlink(1), .afterUnlink(2), .afterUnlink(3), .beforeReceiptCommit, .afterReceiptCommit]
        for fault in faults {
            let f = try ManagedErasureFixture(), inbox = try f.inbox(), queue = try f.queue(), raw = Data("original-\(fault)".utf8)
            let frame = try inbox.adoptData(raw), outgoing = try queue.stage(raw, id: "delivery")
            do { _ = try await f.service(fault: fault).erase(f.request); XCTFail("fault must execute: \(fault)") } catch { XCTAssertEqual(error as? DeviceSyncErasureError, .faultInjected) }
            if fault == .beforeFenceCommit {
                XCTAssertEqual(try Data(contentsOf: outgoing.url), raw)
                XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
            } else { XCTAssertThrowsError(try inbox.adoptData(Data("late".utf8))) }
            let reopened = try DeviceSyncStorageContext(root: f.root)
            let result = try await DeviceSyncErasureService(context: reopened, driver: DrainedErasureDriver()).erase(f.request)
            guard case .completed = result else { XCTFail("recovery \(fault)"); continue }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outgoing.url.path))
        }
    }
    func testOldHandlesCannotMutateAnyCollectionAfterAnotherHandleErases() async throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), queue = try f.queue()
        let pairing = try PairingBaseline(directory: f.root.appendingPathComponent("state"))
        _ = try pairing.observe("paired")
        let frame = try inbox.adoptData(Data("incoming".utf8)), outgoing = try queue.stage(Data("outgoing".utf8), id: "d")
        let second = try DeviceSyncStorageContext(root: f.root)
        _ = try await DeviceSyncErasureService(context: second, driver: DrainedErasureDriver()).erase(f.request)
        XCTAssertThrowsError(try inbox.adoptData(Data("late".utf8)))
        XCTAssertThrowsError(try inbox.didPersist(frame.transportDeliveryID))
        XCTAssertThrowsError(try queue.stage(Data("late".utf8), id: "new"))
        XCTAssertThrowsError(try queue.completed(outgoing))
        XCTAssertThrowsError(try queue.recoverOrphans(outstanding: []))
        XCTAssertThrowsError(try pairing.observe("late-pair"))
        XCTAssertTrue(pairing.isInvalidated)
        XCTAssertTrue(inbox.scan().frames.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("inbox/last-error.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state/pairing-baseline.json").path))
        XCTAssertThrowsError(try DurableFileInbox(directory: f.root.appendingPathComponent("inbox/nested")))
        let epoch = try DeviceSyncNamespaceBinding(namespaceID: f.binding.namespaceID, accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, zoneID: f.binding.zoneID, activationEpoch: 8, catalogRevision: 2, catalogDigest: f.binding.catalogDigest, rootIdentity: f.binding.rootIdentity)
        XCTAssertThrowsError(try second.bind(epoch))
    }
    func testUnknownOutboxMetadataKeepsEveryCanonicalByte() async throws {
        let f = try ManagedErasureFixture(), transfer = try f.queue().stage(Data("original".utf8), id: "d")
        let metadata = transfer.url.deletingPathExtension().appendingPathExtension("json")
        let corrupt = Data("{\"unknown\":true}".utf8); try corrupt.write(to: metadata)
        do { _ = try await f.service().erase(f.request); XCTFail("unknown metadata") } catch {}
        XCTAssertEqual(try Data(contentsOf: metadata), corrupt)
        XCTAssertEqual(try Data(contentsOf: transfer.url), Data("original".utf8))
    }
}
