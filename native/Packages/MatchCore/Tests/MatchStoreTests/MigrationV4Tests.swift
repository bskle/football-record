import Foundation
import XCTest
import SQLite3
@testable import MatchStore

final class MigrationV4Tests: XCTestCase, @unchecked Sendable {
    func testNewAndFrozenV1ReachFourWithoutChangingLegacyBlobs() async throws {
        for frozen in [false, true] {
            let url = frozen ? try LegacyCompatibilityTests().database() : TransactionTests().path()
            let before = frozen ? try blobs(url) : [:]
            let store = try MatchStore(url: url); try await store.close()
            XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), 4)
            if frozen { XCTAssertEqual(try blobs(url), before) }
        }
    }
    func testEveryV4FaultRollsBackZeroThroughThreeAndReopens() async throws {
        for version in 0...3 {
            for fault in [StoreFault.migrationAfterV4Schema, .migrationBeforeV4Version, .migrationAfterV4Version] {
                let url = version == 1 ? try LegacyCompatibilityTests().database() : TransactionTests().path()
                if version != 1 {
                    let store = try MatchStore(url: url); try await store.close()
                    let raw = try SQLite(url: url, fault: nil)
                    let names = try raw.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0[0].string }
                    for name in names where version == 0 || name.hasSuffix("_v4") || (version == 2 && name.hasPrefix("sync_")) { try raw.execute("DROP TABLE " + name) }
                    try raw.execute("PRAGMA user_version=" + String(version)); try raw.close()
                }
                let before = try Data(contentsOf: url)
                XCTAssertThrowsError(try MatchStore(url: url, fault: fault))
                XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), Int64(version))
                XCTAssertEqual(try Data(contentsOf: url), before)
                let store = try MatchStore(url: url); try await store.close()
                XCTAssertEqual(try MigrationV2Tests().rawInt(url, "PRAGMA user_version"), 4)
            }
        }
    }
    func testFutureAndPartialFourPreserveFile() async throws {
        for future in [false, true] {
            let url = TransactionTests().path(), store = try MatchStore(url: url); try await store.close()
            let raw = try SQLite(url: url, fault: nil)
            try raw.execute(future ? "PRAGMA user_version=5" : "ALTER TABLE authority_results_v4 RENAME COLUMN payload TO missing")
            try raw.close(); let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try MatchStore(url: url)); XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
    func blobs(_ url: URL) throws -> [String: Data] {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }; var result: [String: Data] = [:]
        for (table, column) in [("matches","descriptor"),("events","payload"),("commands","receipt"),("outbox","packet"),("inbound","ack"),("completion","evidence")] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rowid," + column + " FROM " + table + " ORDER BY rowid", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let n = Int(sqlite3_column_bytes(statement, 1))
                result[table + "/" + String(sqlite3_column_int64(statement, 0))] = Data(bytes: sqlite3_column_blob(statement, 1)!, count: n)
            }
        }; return result
    }
}
