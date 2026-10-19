import Foundation
import XCTest
@testable import DeviceSync

final class FileInboxTests: XCTestCase, @unchecked Sendable {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("device-sync-" + UUID().uuidString) }
    func testDelegateTakeoverSurvivesSDKDeletingOriginalAndRestart() throws {
        let root = directory(), inbox = try DurableFileInbox(directory: root.appendingPathComponent("inbox"))
        let source = root.appendingPathComponent("sdk-temporary"), raw = Data("canonical-original-frame".utf8)
        try raw.write(to: source)
        let saved = try inbox.adoptFile(source)
        try FileManager.default.removeItem(at: source)
        let reopened = try DurableFileInbox(directory: inbox.directory)
        let scan = reopened.scan()
        XCTAssertEqual(scan.frames.map(\.transportDeliveryID), [saved.transportDeliveryID]); XCTAssertEqual(scan.frames.first?.bytes, raw)
        XCTAssertTrue(scan.failures.isEmpty)
        try reopened.didPersist(saved.transportDeliveryID)
        XCTAssertTrue(reopened.scan().frames.isEmpty)
        try reopened.didPersist(saved.transportDeliveryID)
    }
    func testDuplicateAndQuotaKeepOriginalUntilStorePersistence() throws {
        let inbox = try DurableFileInbox(directory: directory(), limits: InboxLimits(maximumFrameBytes: 16, maximumBytes: 16, maximumFrames: 1))
        let first = try inbox.adoptData(Data("same".utf8)), duplicate = try inbox.adoptData(Data("same".utf8))
        XCTAssertEqual(first, duplicate)
        XCTAssertThrowsError(try inbox.adoptData(Data("other".utf8))) { XCTAssertEqual($0 as? DeviceSyncError, .quotaExceeded) }
        XCTAssertEqual(inbox.scan().frames, [first])
        XCTAssertThrowsError(try inbox.didPersist("../not-owned"))
        XCTAssertEqual(inbox.scan().frames, [first])
    }
}

extension FileInboxTests {
    func testOversizeSourceAndSymlinkAreRejectedBeforeReadingAndLeaveNoReceipt() throws {
        let root = directory(), inbox = try DurableFileInbox(directory: root.appendingPathComponent("inbox"), limits: InboxLimits(maximumFrameBytes: 8, maximumBytes: 16, maximumFrames: 2))
        let source = root.appendingPathComponent("source"), link = root.appendingPathComponent("link")
        try Data(count: 9).write(to: source)
        XCTAssertThrowsError(try inbox.adoptFile(source)) { XCTAssertEqual($0 as? DeviceSyncError, .quotaExceeded) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.adoptFile(link)) { XCTAssertEqual($0 as? DeviceSyncError, .corruptFile) }
        XCTAssertTrue(inbox.scan().frames.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.directory.appendingPathComponent("last-error.json").path))
    }
    func testCorruptOwnedFileSurvivesScanAndCannotBeReleasedAsPersisted() throws {
        let inbox = try DurableFileInbox(directory: directory()), original = try inbox.adoptData(Data("original".utf8))
        let url = inbox.directory.appendingPathComponent(original.transportDeliveryID + ".frame")
        try Data("corrupt!".utf8).write(to: url)
        let scan = inbox.scan(); XCTAssertTrue(scan.frames.isEmpty); XCTAssertEqual(scan.failures.first?.issue, .corruptFile)
        XCTAssertThrowsError(try inbox.didPersist(original.transportDeliveryID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(try Data(contentsOf: url), Data("corrupt!".utf8))
    }
    func testCopyFailureRetainsEarlierOwnedFrameAndReportsUnavailable() throws {
        let inbox = try DurableFileInbox(directory: directory()), original = try inbox.adoptData(Data("kept".utf8))
        XCTAssertThrowsError(try inbox.adoptFile(inbox.directory.appendingPathComponent("missing-sdk-file"))) { XCTAssertEqual($0 as? DeviceSyncError, .fileIO) }
        XCTAssertEqual(inbox.scan().frames, [original])
    }
}
