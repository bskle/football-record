import Foundation
import XCTest
@testable import CloudSync

final class CloudLocalTransportCurrentZeroTests: XCTestCase, @unchecked Sendable {
 private func rows(_ url: URL, table: String, scope: CloudScope) throws -> [[CloudSQLValue]] {
  let sql = try CloudSQL(url: url); defer { try? sql.close() }
  return try sql.rows("SELECT * FROM " + table + " WHERE scope=? ORDER BY rowid", [.text(try scope.key)])
 }
 private func restore(_ originals: [[CloudSQLValue]], table: String, to url: URL) throws {
  let sql = try CloudSQL(url: url); defer { try? sql.close() }
  try sql.transaction {
   for row in originals {
    try sql.execute("INSERT INTO " + table + " VALUES(" + Array(repeating: "?", count: row.count).joined(separator: ",") + ")", row)
   }
  }
 }
 private func control(_ url: URL) throws -> [String: [[String]]] {
  let sql = try CloudSQL(url: url); defer { try? sql.close() }
  return try Dictionary(uniqueKeysWithValues: ["cloud_local_erase_fences", "cloud_local_erase_receipts"].map { table in
   (table, try sql.rows("SELECT * FROM " + table + " ORDER BY rowid").map { $0.map { $0.string! } })
  })
 }
 private func identity(_ url: URL) throws -> [UInt64] {
  let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
  return try [FileAttributeKey.systemNumber, .systemFileNumber].map { key in
   try XCTUnwrap(attrs[key] as? NSNumber).uint64Value
  }
 }

 func testReplayRejectsEveryRestoredCanonicalTableInCurrentAndOldEpochs() async throws {
  for epoch in [Int64(1), Int64(7)] {
   for table in eraseTables {
    let url = try tempCloudURL(), scope = try cloudScope(), restoredScope = try cloudScope(epoch: epoch)
    let ledger = try SQLiteCloudLedger(url: url)
    try await seedErasurePhases(ledger, scope: restoredScope)
    let originals = try rows(url, table: table, scope: restoredScope)
    XCTAssertFalse(originals.isEmpty)
    let request = try CloudLocalTransportEraseRequest(requestID: "restored-table", scope: scope)
    _ = try await ledger.eraseLocalTransport(request)
    let firstControl = try control(url), originalInode = try identity(url)
    try restore(originals, table: table, to: url)
    let before = try canonicalSnapshot(url)
    await expectCloudError(.invalidPayload) { _ = try await ledger.eraseLocalTransport(request) }
    XCTAssertEqual(try canonicalSnapshot(url), before, "Replay must preserve restored canonical bytes, not re-erase")
    XCTAssertEqual(try control(url), firstControl)
    XCTAssertEqual(try identity(url), originalInode)
    try await ledger.close()
   }
  }
 }

 func testReopenOnOriginalInodeBlocksRestoredTargetWithoutChangingReceipt() async throws {
  let url = try tempCloudURL(), scope = try cloudScope(epoch: 31), ledger = try SQLiteCloudLedger(url: url)
  try await seedErasurePhases(ledger, scope: scope)
  let originals = try rows(url, table: "cloud_uploads", scope: scope)
  let request = try CloudLocalTransportEraseRequest(requestID: "reopen-current-zero", scope: cloudScope())
  _ = try await ledger.eraseLocalTransport(request); try await ledger.close()
  let firstControl = try control(url), originalInode = try identity(url)
  try restore(originals, table: "cloud_uploads", to: url)
  let before = try canonicalSnapshot(url), file = try Data(contentsOf: url)
  let reopened = try SQLiteCloudLedger(url: url)
  await expectCloudError(.invalidPayload) { _ = try await reopened.eraseLocalTransport(request) }
  try await reopened.close()
  XCTAssertEqual(try canonicalSnapshot(url), before); XCTAssertEqual(try control(url), firstControl)
  XCTAssertEqual(try identity(url), originalInode); XCTAssertEqual(try Data(contentsOf: url), file)
 }

 func testReplayStrictlyValidatesMalformedForeignInventoryAndPreservesIt() async throws {
  let edits = eraseTables.map { "UPDATE " + $0 + " SET original=x'0102'" } + [
   "UPDATE cloud_uploads SET scope='unknown-scope'", "UPDATE cloud_uploads SET digest='bad-digest'",
   "UPDATE cloud_uploads SET issue='future-issue'", "UPDATE cloud_batches SET state='future-state'"
  ]
  for edit in edits {
   let url = try tempCloudURL(), scope = try cloudScope()
   let other = try CloudScope(accountID: "other", cloudSpaceID: "space", zoneID: "zone", activationEpoch: 4)
   let ledger = try SQLiteCloudLedger(url: url)
   try await seedErasurePhases(ledger, scope: other)
   let request = try CloudLocalTransportEraseRequest(requestID: "unclassifiable-replay", scope: scope)
   _ = try await ledger.eraseLocalTransport(request); try await ledger.close()
   let firstControl = try control(url), raw = try CloudSQL(url: url)
   try raw.execute(edit); try raw.close()
   let before = try canonicalSnapshot(url), file = try Data(contentsOf: url)
   let reopened = try SQLiteCloudLedger(url: url)
   await expectCloudError(.invalidPayload) { _ = try await reopened.eraseLocalTransport(request) }
   try await reopened.close()
   XCTAssertEqual(try canonicalSnapshot(url), before); XCTAssertEqual(try control(url), firstControl)
   XCTAssertEqual(try Data(contentsOf: url), file)
  }
 }

 func testReplayReturnsOriginalReceiptWithEveryLegalForeignScopeUnchanged() async throws {
  let url = try tempCloudURL(), scope = try cloudScope(), ledger = try SQLiteCloudLedger(url: url)
  let others = try [CloudScope(accountID: "other", cloudSpaceID: "space", zoneID: "zone", activationEpoch: 1),
   CloudScope(accountID: "account", cloudSpaceID: "other", zoneID: "zone", activationEpoch: 2),
   CloudScope(accountID: "account", cloudSpaceID: "space", zoneID: "other", activationEpoch: 3)]
  try await seedErasurePhases(ledger, scope: scope)
  for other in others { try await seedErasurePhases(ledger, scope: other) }
  let request = try CloudLocalTransportEraseRequest(requestID: "foreign-kept", scope: scope)
  let receipt = try await ledger.eraseLocalTransport(request), firstControl = try control(url)
  let before = try canonicalSnapshot(url)
  for _ in 0..<2 { let replay = try await ledger.eraseLocalTransport(request); XCTAssertEqual(replay, receipt) }
  try await ledger.close()
  let reopened = try SQLiteCloudLedger(url: url), replay = try await reopened.eraseLocalTransport(request)
  XCTAssertEqual(try CloudCodec.encode(replay), try CloudCodec.encode(receipt))
  XCTAssertEqual(try canonicalSnapshot(url), before); XCTAssertEqual(try control(url), firstControl)
  XCTAssertTrue(try canonicalSnapshot(url, scope: scope).values.allSatisfy(\.isEmpty))
  for other in others { XCTAssertTrue(try canonicalSnapshot(url, scope: other).values.allSatisfy { !$0.isEmpty }) }
  try await reopened.close()
 }

 func testCommitResponseLostReopensOriginalReceiptAtCurrentZero() async throws {
  let url = try tempCloudURL(), scope = try cloudScope(), seed = try SQLiteCloudLedger(url: url)
  try await seedErasurePhases(seed, scope: scope); try await seed.close()
  let request = try CloudLocalTransportEraseRequest(requestID: "lost-replay", scope: scope)
  let lost = try SQLiteCloudLedger(url: url, fault: .afterCommitResponseLost)
  await expectCloudError(.storageUnavailable) { _ = try await lost.eraseLocalTransport(request) }; try await lost.close()
  let firstControl = try control(url), reopened = try SQLiteCloudLedger(url: url)
  let first = try await reopened.eraseLocalTransport(request), second = try await reopened.eraseLocalTransport(request)
  XCTAssertEqual(try CloudCodec.encode(first), try CloudCodec.encode(second))
  XCTAssertEqual(try control(url), firstControl)
  XCTAssertEqual(first.requestDigest, try request.digest); XCTAssertEqual(first.stableZoneKey, scope.stableZoneKey)
  XCTAssertTrue(try canonicalSnapshot(url).values.allSatisfy(\.isEmpty)); try await reopened.close()
 }

 func testDifferentIntentKeepsFirstReceiptConflictPrecedence() async throws {
  let url = try tempCloudURL(), ledger = try SQLiteCloudLedger(url: url), scope = try cloudScope()
  let request = try CloudLocalTransportEraseRequest(requestID: "same-first-id", scope: scope)
  _ = try await ledger.eraseLocalTransport(request)
  let firstControl = try control(url)
  await expectCloudError(.identityConflict) {
   _ = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID: request.requestID, scope: cloudScope(epoch: 2)))
  }
  XCTAssertEqual(try control(url), firstControl)
  let replay = try await ledger.eraseLocalTransport(request)
  XCTAssertEqual(replay.requestDigest, try request.digest); try await ledger.close()
 }

 func testLiveReceiptReplayRejectsFutureOrUnknownLayoutWithoutChangingIt() async throws {
  let edits: [(String, CloudIssue)] = [
   ("PRAGMA user_version=99", .unsupportedSchema),
   ("CREATE TABLE future_business(value BLOB) STRICT", .invalidPayload),
   ("ALTER TABLE cloud_uploads ADD COLUMN future_field TEXT", .invalidPayload),
   ("CREATE VIEW future_view AS SELECT id FROM cloud_uploads", .invalidPayload),
   ("CREATE TRIGGER future_trigger AFTER INSERT ON cloud_uploads BEGIN SELECT 1; END", .invalidPayload),
   ("CREATE INDEX future_index ON cloud_uploads(scope)", .invalidPayload)
  ]
  for (edit, expected) in edits {
   let url = try tempCloudURL(), ledger = try SQLiteCloudLedger(url: url), scope = try cloudScope()
   let other = try CloudScope(accountID: "other", cloudSpaceID: "space", zoneID: "zone", activationEpoch: 1)
   try await seedErasurePhases(ledger, scope: other)
   let request = try CloudLocalTransportEraseRequest(requestID: "live-layout", scope: scope)
   _ = try await ledger.eraseLocalTransport(request)
   let firstControl = try control(url), raw = try CloudSQL(url: url)
   try raw.execute(edit)
   let schema = try raw.rows("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name").map { $0.map(\.string) }
   let version = try raw.rows("PRAGMA user_version").first?.first?.number
   let before = try canonicalSnapshot(url), originalInode = try identity(url)
   do {
    _ = try await ledger.eraseLocalTransport(request)
    XCTFail("Expected \(expected) for \(edit)")
   } catch let error as CloudError {
    print("Layout probe blocked \(edit): \(error.issue)")
    XCTAssertEqual(error.issue, expected, edit)
   }
   XCTAssertEqual(try raw.rows("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name").map { $0.map(\.string) }, schema)
   XCTAssertEqual(try raw.rows("PRAGMA user_version").first?.first?.number, version)
   XCTAssertEqual(try canonicalSnapshot(url), before); XCTAssertEqual(try control(url), firstControl)
   XCTAssertEqual(try identity(url), originalInode)
   try raw.close(); try await ledger.close()
  }
 }
}
