import Foundation
import XCTest
@testable import DeviceSync

final class MessageReplyTests: XCTestCase, @unchecked Sendable {
    func testMessageReplyOnlyMeansTransportOwnedInputAndPersistsUntilStoreNotification() async throws {
        let f = try TransportFixture(); var deliveries = await f.transport.deliveries().makeAsyncIterator()
        await f.transport.activate()
        let bytes = Data("canonical-frame".utf8), reply = await f.driver.receiveMessage(bytes)
        XCTAssertEqual(reply, .accepted)
        let next = await deliveries.next(); let delivery = try XCTUnwrap(next)
        XCTAssertEqual(delivery.bytes, bytes); XCTAssertEqual(f.inbox.scan().frames, [delivery])
        await f.transport.didPersistDelivery(delivery.transportDeliveryID)
        XCTAssertTrue(f.inbox.scan().frames.isEmpty)
        XCTAssertEqual(try TransportReply(wireBytes: reply.wireBytes), .accepted)
        XCTAssertThrowsError(try TransportReply(wireBytes: Data("business-ack".utf8)))
    }
    func testFileDelegateOwnsInputSynchronouslyAndStartupReplaysWithoutAnotherSDKFrame() async throws {
        let f = try TransportFixture(); await f.transport.activate()
        let source = f.root.appendingPathComponent("sdk-file"), bytes = Data("file-canonical-frame".utf8)
        try bytes.write(to: source); try await f.driver.receiveFileThenDeleteOriginal(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(f.inbox.scan().frames.first?.bytes, bytes)
        let reopened = try WCSessionTransport(driver: f.driver, inbox: DurableFileInbox(directory: f.inbox.directory), outboxDirectory: f.root.appendingPathComponent("outbox"))
        var deliveries = await reopened.deliveries().makeAsyncIterator(); await reopened.activate()
        let next = await deliveries.next(); let delivery = try XCTUnwrap(next); XCTAssertEqual(delivery.bytes, bytes)
        XCTAssertEqual(f.inbox.scan().frames.count, 1, "enqueue does not release Store input")
    }
}
