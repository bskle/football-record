import Foundation
import XCTest
@testable import DeviceSync

final class DeviceSyncStorageFenceTests: XCTestCase, @unchecked Sendable {
    func testInvalidatedFileCallbackDoesNotAdoptOrAudit() async throws {
        let f = try TransportFixture()
        await f.transport.activate()
        await f.transport.notifyTrustInvalidated(.accountChanged)
        let source = f.root.appendingPathComponent("late-sdk-file")
        try Data("late-canonical".utf8).write(to: source)
        try await f.driver.receiveFileThenDeleteOriginal(source)
        XCTAssertTrue(f.inbox.scan().frames.isEmpty, "late callback must not preserve canonical after invalidation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.inbox.directory.appendingPathComponent("last-error.json").path))
    }
}

import CSQLite

private func controlSQL(_ root: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent(".control/control.sqlite").path, &db) == SQLITE_OK else { throw DeviceSyncErasureError.fileIO }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DeviceSyncErasureError.fileIO }
}

extension DeviceSyncStorageFenceTests {
    func testFutureControlStopsOldHandleAndPreservesDatabaseOnFailedOpen() throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), raw = Data("original".utf8)
        let frame = try inbox.adoptData(raw)
        try controlSQL(f.root, "PRAGMA user_version=99")
        let database = f.root.appendingPathComponent(".control/control.sqlite"), before = try Data(contentsOf: database)
        XCTAssertThrowsError(try inbox.adoptData(Data("late".utf8)))
        XCTAssertThrowsError(try DeviceSyncStorageContext(root: f.root))
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
    }
    func testUnknownControlTypesNULAndInvalidUTF8RemainFailClosed() throws {
        for value in ["CAST(X'610062' AS TEXT)", "CAST(X'FFFE' AS TEXT)", "X'FFFE'"] {
            let f = try ManagedErasureFixture(), inbox = try f.inbox(), raw = Data("preserve".utf8)
            let frame = try inbox.adoptData(raw)
            try controlSQL(f.root, "UPDATE control SET owner=\(value)")
            let database = f.root.appendingPathComponent(".control/control.sqlite"), before = try Data(contentsOf: database)
            XCTAssertThrowsError(try inbox.adoptData(Data("late".utf8)))
            XCTAssertThrowsError(try DeviceSyncStorageContext(root: f.root))
            XCTAssertEqual(try Data(contentsOf: database), before)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("inbox/" + frame.transportDeliveryID + ".frame")), raw)
        }
    }
    func testReplacedOwnerInodeBlocksExistingAndNewHandle() throws {
        let f = try ManagedErasureFixture(), inbox = try f.inbox(), owner = f.root.appendingPathComponent(".control/.owner")
        let original = try Data(contentsOf: owner)
        try FileManager.default.moveItem(at: owner, to: f.root.deletingLastPathComponent().appendingPathComponent("retained-owner"))
        try original.write(to: owner)
        XCTAssertThrowsError(try inbox.adoptData(Data("late".utf8)))
        XCTAssertThrowsError(try DeviceSyncStorageContext(root: f.root))
    }
    func testRawEquivalentScopeIsNotThePersistedOwner() throws {
        let f = try ManagedErasureFixture(space: "space-é")
        let different = try DeviceSyncNamespaceBinding(namespaceID: f.binding.namespaceID, accountID: f.binding.accountID, cloudSpaceID: "space-e\u{301}", zoneID: f.binding.zoneID, activationEpoch: f.binding.activationEpoch, catalogRevision: f.binding.catalogRevision, catalogDigest: f.binding.catalogDigest, rootIdentity: f.binding.rootIdentity)
        XCTAssertNotEqual(f.binding, different)
        XCTAssertThrowsError(try f.context.bind(different))
    }
    #if os(macOS)
    func testSeparateProcessUsesRetainedOwnerGateAndSeesFence() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FOOTBALL_037_CHILD_ROOT"], let markers = environment["FOOTBALL_037_CHILD_MARKERS"] {
            let root = URL(fileURLWithPath: path), directory = URL(fileURLWithPath: markers)
            let inbox = try DurableFileInbox(directory: root.appendingPathComponent("inbox"))
            try Data().write(to: directory.appendingPathComponent("ready"))
            try waitForFile(directory.appendingPathComponent("go"))
            try Data().write(to: directory.appendingPathComponent("attempt"))
            XCTAssertThrowsError(try inbox.adoptData(Data("child-late".utf8)))
            try Data("blocked".utf8).write(to: directory.appendingPathComponent("done"))
            return
        }
        let f = try ManagedErasureFixture(), directory = f.root.deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "DeviceSyncTests.DeviceSyncStorageFenceTests/testSeparateProcessUsesRetainedOwnerGateAndSeesFence", Bundle(for: Self.self).bundleURL.path]
        var childEnvironment = environment; childEnvironment["FOOTBALL_037_CHILD_ROOT"] = f.root.path; childEnvironment["FOOTBALL_037_CHILD_MARKERS"] = directory.path
        process.environment = childEnvironment; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() } }
        try waitForFile(directory.appendingPathComponent("ready"))
        try f.context.withActive {
            try Data().write(to: directory.appendingPathComponent("go"))
            try waitForFile(directory.appendingPathComponent("attempt"))
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path), "second process cannot bypass held owner inode")
            try f.context.ledger.begin(f.request, transfers: [], fault: nil)
        }
        try waitForFile(directory.appendingPathComponent("done"))
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.isRunning); XCTAssertEqual(process.terminationStatus, 0)
        guard case .completed = try await f.service().erase(f.request) else { return XCTFail("original fenced request recovery") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("inbox/frame-" + digest(Data("child-late".utf8)) + ".frame").path))
    }
    private func waitForFile(_ url: URL) throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw DeviceSyncErasureError.fileIO }
    }
    #endif
}
