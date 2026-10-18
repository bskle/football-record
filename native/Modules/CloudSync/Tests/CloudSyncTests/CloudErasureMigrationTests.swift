import Foundation
import XCTest
@testable import CloudSync

final class CloudErasureMigrationTests: XCTestCase, @unchecked Sendable {
 private func legacy(_ url:URL,version:Int) throws {
  let sql = try CloudSQL(url:url)
  try sql.transaction {
   try sql.execute("DROP TABLE cloud_local_erase_receipts"); try sql.execute("DROP TABLE cloud_local_erase_fences")
   if version < 3 { for table in ["cloud_scope_state","cloud_conflicts","cloud_save_evidence"] { try sql.execute("DROP TABLE " + table) } }
   if version < 2 { try sql.execute("DROP TABLE cloud_batches") }
   try sql.execute("PRAGMA user_version="+String(version))
  }; try sql.close()
 }
 func testEveryMigrationFailureRollsBackSchemaAndPreservesCanonical() async throws {
  for fault in [CloudLedgerMigrationFault.afterLegacyValidation,.afterFenceTable,.afterReceiptTable,.afterVersion,.afterValidation] {
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url)
   try await seedErasurePhases(ledger,scope:cloudScope()); try await ledger.close(); try legacy(url,version:3)
   let before = try canonicalSnapshot(url),file = try Data(contentsOf:url)
   XCTAssertThrowsError(try SQLiteCloudLedger(url:url,migrationFault:fault))
   XCTAssertEqual(try canonicalSnapshot(url),before); XCTAssertEqual(try Data(contentsOf:url),file)
   let raw = try CloudSQL(url:url); XCTAssertEqual(try raw.rows("PRAGMA user_version").first?.first?.number,3)
   XCTAssertTrue(try raw.rows("SELECT name FROM sqlite_master WHERE name LIKE 'cloud_local_erase_%'").isEmpty); try raw.close()
  }
 }
 func testMigrationCommitLostResponseReopensWithOriginalCanonical() async throws {
  let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url)
  try await seedErasurePhases(ledger,scope:cloudScope()); try await ledger.close(); try legacy(url,version:3)
  let before = try canonicalSnapshot(url)
  XCTAssertThrowsError(try SQLiteCloudLedger(url:url,migrationFault:.afterCommitResponseLost))
  let reopened = try SQLiteCloudLedger(url:url); XCTAssertEqual(try canonicalSnapshot(url),before)
  _ = try await reopened.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:"migrated",scope:cloudScope()))
  XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await reopened.close()
 }
 func testVersionOneAndTwoUpgradePreserveOriginalUploadBytes() async throws {
  for version in [1,2] {
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),upload = try cloudUpload()
   try await ledger.enqueue(upload); try await ledger.close(); try legacy(url,version:version)
   let reopened = try SQLiteCloudLedger(url:url),uploads = try await reopened.uploads(scope:upload.scope)
   XCTAssertEqual(uploads.first?.originalBytes,try upload.canonicalBytes()); try await reopened.close()
  }
 }
 func testUnknownFutureSchemaAndMissingCurrentControlTablePreserveFile() async throws {
  for edit in ["PRAGMA user_version=99","DROP TABLE cloud_local_erase_receipts"] {
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url); try await ledger.enqueue(cloudUpload()); try await ledger.close()
   let raw = try CloudSQL(url:url); try raw.execute(edit); try raw.close(); let file = try Data(contentsOf:url)
   XCTAssertThrowsError(try SQLiteCloudLedger(url:url)); XCTAssertEqual(try Data(contentsOf:url),file)
  }
 }
 func testMalformedLegacyCanonicalFailsBeforeMigrationChangesFile() async throws {
  for edit in ["UPDATE cloud_uploads SET original=x'0102'","UPDATE cloud_uploads SET scope=scope||char(0)||'junk'"] {
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url); try await ledger.enqueue(cloudUpload()); try await ledger.close(); try legacy(url,version:3)
   let raw = try CloudSQL(url:url); try raw.execute(edit); try raw.close(); let file = try Data(contentsOf:url)
   XCTAssertThrowsError(try SQLiteCloudLedger(url:url)); XCTAssertEqual(try Data(contentsOf:url),file)
   let inspect = try CloudSQL(url:url); XCTAssertEqual(try inspect.rows("PRAGMA user_version").first?.first?.number,3); try inspect.close()
  }
 }
}
