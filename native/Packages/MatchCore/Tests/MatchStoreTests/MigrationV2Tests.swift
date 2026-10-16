import Foundation
import XCTest
import SQLite3
@testable import MatchStore
final class MigrationV2Tests: XCTestCase, @unchecked Sendable {
 func testNewDatabaseReachesVersionTwo() async throws {
  let url = TransactionTests().path(); let store = try MatchStore(url: url); try await store.close()
  let inspect = try SQLite(url: url, fault: nil)
  XCTAssertEqual(try inspect.scalar("PRAGMA user_version").number, 2)
  try inspect.close()
 }
 func rawInt(_ url:URL,_ sql:String) throws -> Int64 {
  var db:OpaquePointer?; var statement:OpaquePointer?
  guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK else { throw StoreError.invalidRequest }
  defer { sqlite3_close(db) }
  guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else { throw StoreError.invalidRequest }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement)==SQLITE_ROW else { throw StoreError.invalidRequest }
  return sqlite3_column_int64(statement,0)
 }
 func testFrozenV1MigrationFaultsLeaveOldSchemaAndBlobsUntouched() async throws {
  let f=LegacyCompatibilityTests()
  for fault in [StoreFault.migrationAfterSchema,.migrationBeforeV2Version,.migrationAfterV2Version] {
   let url=try f.database(); let before=try Data(contentsOf:url)
   XCTAssertThrowsError(try MatchStore(url:url,fault:fault))
   XCTAssertEqual(try rawInt(url,"PRAGMA user_version"),1)
   XCTAssertEqual(try rawInt(url,"SELECT count(*) FROM sqlite_master WHERE name LIKE 'capture_%' OR name='commands_v2' OR name='business_outbox' OR name='completion_v2'"),0)
   XCTAssertEqual(try Data(contentsOf:url),before)
   let reopened=try MatchStore(url:url); let snap=try await reopened.snapshot(matchID:"match"); XCTAssertEqual(snap.events.count,3); try await reopened.close()
  }
 }
 func testPartialOldSchemaFailsBeforeAddingV2Tables() throws {
  let f=LegacyCompatibilityTests(); let url=try f.database(); var db:OpaquePointer?
  XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
  XCTAssertEqual(sqlite3_exec(db,"ALTER TABLE matches RENAME COLUMN descriptor TO missing",nil,nil,nil),SQLITE_OK)
  XCTAssertEqual(sqlite3_close(db),SQLITE_OK)
  let before=try Data(contentsOf:url); XCTAssertThrowsError(try MatchStore(url:url))
  XCTAssertEqual(try rawInt(url,"PRAGMA user_version"),1)
  XCTAssertEqual(try rawInt(url,"SELECT count(*) FROM sqlite_master WHERE name='capture_revisions'"),0)
  XCTAssertEqual(try Data(contentsOf:url),before)
 }

}
