import Foundation
import Darwin
import SQLite3
import CryptoKit
import XCTest
import MatchCore
import MatchStore
@testable import MatchSession

final class ExistingControlRepositoryTests: XCTestCase, @unchecked Sendable {
    func path() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent("core-repo-" + UUID().uuidString) }
    func directory() throws -> URL {
        let root = path(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testNormalRepositoryStillCreatesMissingRoot() async throws {
        let root = path(); defer { try? FileManager.default.removeItem(at: root) }
        let opened = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "retained-core"); try await opened.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("retained-core/matches.sqlite").path))
    }
    func testStrictMissingRootNamespaceAndMainNeverCreate() throws {
        let missing = path()
        XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: missing, databaseNamespace: "retained-core"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let root = try directory()
        XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: "retained-core"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let namespace = root.appendingPathComponent("retained-core")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: "retained-core"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: namespace.path), [])
    }
    func testNonCanonicalNamespacesAreRejectedBeforeAnyCreation() throws {
        for namespace in ["", "Production", "../escape", "name/child", "球历", "e\u{301}", "a.b"] {
            let root = path()
            XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: namespace)) { XCTAssertEqual($0 as? SessionError, .invalidRequest) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }
    func testPrivateOriginalRootAndNamespaceAreRequired() async throws {
        for kind in 0..<4 {
            let root = try directory(), namespace = root.appendingPathComponent("retained-core")
            let seed = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "retained-core"), database = await seed.databaseURL
            try await seed.close(); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespace.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
            let target = kind % 2 == 0 ? root : namespace
            if kind < 2 { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            else {
                let original = URL(fileURLWithPath: target.path + "-original")
                try FileManager.default.moveItem(at: target, to: original); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
                addTeardownBlock { try? FileManager.default.removeItem(at: original) }
            }
            XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: "retained-core"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        }
    }
    func typedSnapshot(_ url: URL) throws -> [String] {
        // Existing-only raw handle for logical snapshots; no CREATE, migrations or DDL.
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let handle = try XCTUnwrap(db); defer { sqlite3_close(handle) }
        func query(_ sql: String) throws -> [String] {
            var stmt: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), SQLITE_OK)
            let statement = try XCTUnwrap(stmt); defer { sqlite3_finalize(statement) }; var result: [String] = []
            while true {
                let code = sqlite3_step(statement); if code == SQLITE_DONE { return result }; XCTAssertEqual(code, SQLITE_ROW)
                guard code == SQLITE_ROW else { throw SessionError.invalidRequest }
                result.append((0..<sqlite3_column_count(statement)).map { i in
                    let type = sqlite3_column_type(statement, i)
                    if type == SQLITE_NULL { return "null" }
                    if type == SQLITE_INTEGER { return "integer:" + String(sqlite3_column_int64(statement, i)) }
                    let count = Int(sqlite3_column_bytes(statement, i)), pointer = sqlite3_column_blob(statement, i)
                    return String(type) + ":" + (pointer.map { Data(bytes: $0, count: count) } ?? Data()).base64EncodedString()
                }.joined(separator: "|"))
            }
        }
        var result = try query("PRAGMA user_version") + query("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name")
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }; var tables: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(statement, 0))) }
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            result.append(table); result += try query("PRAGMA table_info(" + quoted + ")") + query("SELECT * FROM " + quoted + " ORDER BY rowid")
        }
        return result
    }
    func testStrictRepositoryReadsOriginalSuspendedBindingWithoutAdmission() async throws {
        let root = try directory(), namespace = "retained-core", key = Curve25519.Signing.PrivateKey()
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["original-key": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        let seed = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: namespace, authorityTrust: trust)
        let binding = try AccountBindingV4(accountID: "original-account", cloudSpaceID: "original-cloud", deviceID: "original-phone", activationEpoch: 1, role: .phone, environment: .development)
        try await seed.bindAccountV4(binding); try await seed.suspendAccountV4()
        let original = try await seed.accountBindingV4(), generation = try await seed.identityGenerationV4(), database = await seed.databaseURL
        try await seed.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(namespace).path)
        for suffix in ["", "-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: database.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path + suffix)
        }
        var beforeInode = stat(); XCTAssertEqual(lstat(database.path, &beforeInode), 0)
        let before = try typedSnapshot(database)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(database.path + suffix, &info) == 0 {
                XCTAssertEqual(info.st_mode & 0o7777, 0o600, "private fixture mode for \(suffix)")
                XCTAssertEqual(info.st_uid, geteuid()); XCTAssertEqual(info.st_nlink, 1)
            }
        }
        let reopened = try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: namespace, authorityTrust: trust)
        do {
            let current = try await reopened.accountBindingV4(), currentGeneration = try await reopened.identityGenerationV4(), sagas = try await reopened.deletionSagasV4()
            let one = await reopened.syncRepositoryIdentity(), two = await reopened.syncRepositoryIdentity(), actual = await reopened.databaseURL
            XCTAssertEqual(current, original); XCTAssertTrue(current?.suspended == true); XCTAssertEqual(currentGeneration, generation); XCTAssertTrue(sagas.isEmpty)
            XCTAssertEqual(one, two); XCTAssertEqual(one.databaseNamespace, namespace); XCTAssertEqual(actual, database)
            try await reopened.close(); try await reopened.close()
        } catch { try? await reopened.close(); throw error }
        XCTAssertEqual(try typedSnapshot(database), before)
        let unavailable = try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: namespace)
        do { _ = try await unavailable.accountBindingV4(); XCTFail("opening cannot supply authority trust") }
        catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
        try await unavailable.close(); XCTAssertEqual(try typedSnapshot(database), before)
        var afterInode = stat(); XCTAssertEqual(lstat(database.path, &afterInode), 0); XCTAssertEqual(afterInode.st_ino, beforeInode.st_ino); XCTAssertEqual(afterInode.st_dev, beforeInode.st_dev)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [namespace])
    }
    func testStrictWrapperRefusesLegacyMainWithoutFallbackMigration() throws {
        let root = try directory(), namespace = root.appendingPathComponent("retained-core")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let database = namespace.appendingPathComponent("matches.sqlite")
        try Data(repeating: 0, count: 99).write(to: database); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        let before = try Data(contentsOf: database)
        XCTAssertThrowsError(try SQLiteSessionRepository(existingCurrentV4RootDirectory: root, databaseNamespace: "retained-core"))
        XCTAssertEqual(try Data(contentsOf: database), before); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: namespace.path), ["matches.sqlite"])
    }
}
