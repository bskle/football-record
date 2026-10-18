import Foundation
import XCTest
import SQLite3
@testable import MatchStore

final class MigrationV3Tests: XCTestCase, @unchecked Sendable {
    func testNewDatabaseUsesSchemaThree() async throws {
        let url = TransactionTests().path(); let store = try MatchStore(url: url); try await store.close()
        XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), 4)
    }
    func testMigrationV3RollsBackAtEachFault() async throws {
        for fault in [StoreFault.migrationAfterV3Schema, .migrationBeforeV3Version, .migrationAfterV3Version] {
            let url = try LegacyCompatibilityTests().database()
            let v2 = try MatchStore(url: url); try await v2.close()
            let raw = try SQLite(url: url, fault: nil)
            let tables = try raw.rows("SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE 'sync_%' OR name LIKE '%_v4')").compactMap { $0[0].string }
            for table in tables { try raw.execute("DROP TABLE " + table) }; try raw.close()
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK); XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try MatchStore(url: url, fault: fault))
            XCTAssertEqual(try RecoveryTests().inspectInt(url, "PRAGMA user_version"), 2)
            XCTAssertEqual(try Data(contentsOf: url), before)
            let reopened = try MatchStore(url: url); try await reopened.close()
        }
    }
    func testMigrationThreeFailureDoesNotAdvanceFrozenV1() async throws {
        for fault in [StoreFault.migrationAfterV3Schema, .migrationBeforeV3Version, .migrationAfterV3Version] {
            let url = try LegacyCompatibilityTests().database(), before = try Data(contentsOf: url)
            XCTAssertThrowsError(try MatchStore(url: url, fault: fault))
            XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), 1)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

}

extension MigrationV3Tests {
    func testVersionZeroV3FaultsLeaveNoTablesAndReopen() async throws {
        for fault in [StoreFault.migrationAfterV3Schema, .migrationBeforeV3Version, .migrationAfterV3Version] {
            let url = TransactionTests().path()
            var handle: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK); XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try MatchStore(url: url, fault: fault))
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), 0)
            XCTAssertEqual(try MigrationV2Tests().rawInt(url, "SELECT count(*) FROM sqlite_master WHERE type='table'"), 0)
            let s = try MatchStore(url: url); try await s.close()
        }
    }
    func testFutureFiveAndPartialThreeFailWithoutRepair() async throws {
        for future in [false, true] {
            let url = TransactionTests().path(), store = try MatchStore(url: url); try await store.close()
            let raw = try SQLite(url: url, fault: nil)
            if future { try raw.execute("PRAGMA user_version=5") } else { try raw.execute("ALTER TABLE sync_routes_v3 RENAME COLUMN record TO missing") }
            try raw.close(); let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try MatchStore(url: url))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
}
