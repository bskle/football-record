import Foundation
import XCTest
@testable import DeviceSync

final class PairingBaselineTests: XCTestCase, @unchecked Sendable {
    func testPairChangeWhileAppClosedPersistsInvalidationBeforeSendingIsAllowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-baseline-" + UUID().uuidString)
        let first = try PairingBaseline(directory: root)
        XCTAssertFalse(try first.observe("ios-watch-directory:original")); XCTAssertFalse(first.isInvalidated)
        let reopened = try PairingBaseline(directory: root)
        XCTAssertTrue(try reopened.observe("ios-watch-directory:new-watch")); XCTAssertTrue(reopened.isInvalidated)
        let again = try PairingBaseline(directory: root)
        XCTAssertTrue(again.isInvalidated); XCTAssertTrue(try again.observe("ios-watch-directory:original"), "activation cannot reset trust invalidation")
    }
    func testCorruptPairingBaselineFailsClosedWithoutReplacingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-corrupt-" + UUID().uuidString)
        let first = try PairingBaseline(directory: root); _ = try first.observe("first")
        let url = root.appendingPathComponent("pairing-baseline.json"), bad = Data("corrupt-original".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try PairingBaseline(directory: root)); XCTAssertEqual(try Data(contentsOf: url), bad)
    }
}
