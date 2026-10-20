import Foundation
import Darwin
import SQLite3
import XCTest
@testable import CloudSync

final class CloudLocalTransportEmptyWALTests: XCTestCase, @unchecked Sendable {
 private func assertNoSidecars(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
  for suffix in ["-wal", "-shm", "-journal"] {
   XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "test must reach strict reopen with no coordination sidecar", file: file, line: line)
  }
 }
 // Test-only public SQLite checkpoint/close control, never used for the fresh-empty case.
 // It removes coordination files through SQLite itself after real public API writes.
 private func checkpointAndClose(_ url: URL) throws {
  var db: OpaquePointer?
  guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw CloudError(.storageUnavailable) }
  var closed = false; defer { if !closed { sqlite3_close(db) } }
  var persist: Int32 = 0
  guard sqlite3_exec(db, "PRAGMA user_version", nil, nil, nil) == SQLITE_OK,
        sqlite3_file_control(db, nil, SQLITE_FCNTL_PERSIST_WAL, &persist) == SQLITE_OK,
        sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK,
        sqlite3_close(db) == SQLITE_OK else { throw CloudError(.storageUnavailable) }
  closed = true
 }
 func testFreshEmptyLedgerStrictReopensBeforeAnyBusinessOrInspectionWrite() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url)
  try await seed.close(); assertNoSidecars(url)
  let original = try Data(contentsOf: url)
  do {
   let opened = try SQLiteCloudLedger(existingLocalErasureURL: url)
   let request = try CloudLocalTransportEraseRequest(requestID: "empty-first", scope: cloudScope())
   let first = try await opened.eraseLocalTransport(request)
   let replay = try await opened.replayLocalTransportErasure(request, expectedReceipt: first)
   XCTAssertEqual(try CloudCodec.encode(first), try CloudCodec.encode(replay)); try await opened.close()
  } catch { XCTFail("valid fresh empty WAL main must reopen without manufacturing business rows: \(error)") }
  XCTAssertEqual(Array(original.prefix(16)), Array("SQLite format 3\0".utf8))
 }
 func testCleanNonemptyLedgerStrictReopensWithoutChangingCanonicalBytes() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url), upload = try cloudUpload(id: "nonempty")
  try await seed.enqueue(upload); try await seed.close(); try checkpointAndClose(url); assertNoSidecars(url)
  let original = try Data(contentsOf: url)
  do {
   let opened = try SQLiteCloudLedger(existingLocalErasureURL: url)
   let stored = try await opened.uploads(scope: cloudScope())
   XCTAssertEqual(stored.count, 1); XCTAssertEqual(try stored.first?.upload.canonicalBytes(), try upload.canonicalBytes())
   try await opened.close(); XCTAssertEqual(try Data(contentsOf: url), original)
  } catch { XCTFail("nonempty checkpointed WAL must retain its original canonical facts: \(error)") }
 }
 func testCleanFirstReceiptLedgerReplaysOriginalProofWithoutNewReceipt() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url)
  let request = try CloudLocalTransportEraseRequest(requestID: "original-first", scope: cloudScope())
  let first = try await seed.eraseLocalTransport(request); try await seed.close(); try checkpointAndClose(url); assertNoSidecars(url)
  let original = try Data(contentsOf: url)
  do {
   let opened = try SQLiteCloudLedger(existingLocalErasureURL: url)
   let replay = try await opened.replayLocalTransportErasure(request, expectedReceipt: first)
   XCTAssertEqual(try CloudCodec.encode(first), try CloudCodec.encode(replay)); try await opened.close()
   XCTAssertEqual(try Data(contentsOf: url), original)
  } catch { XCTFail("checkpointed original firstreceipt/fence must reopen and replay original bytes: \(error)") }
 }
 func testSidecarAppearingAtEitherStaticHandoffCheckpointIsPreservedAndBlocks() async throws {
  for stage in [CloudErasureReadOnlyStage.afterStaticValidation, .beforeReadWriteOpen] {
   for suffix in ["-wal", "-shm", "-journal"] {
    let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url)
    try await seed.close(); assertNoSidecars(url)
    let before = try Data(contentsOf: url), marker = Data([1, 2, 3]), sidecar = URL(fileURLWithPath: url.path + suffix)
    do {
     let opened = try SQLiteCloudLedger(existingLocalErasureURL: url, readOnlyCheckpoint: { point in
      if point == stage { try marker.write(to: sidecar) }
     }); try await opened.close(); XCTFail("appeared coordination cannot be ignored by static validation")
    } catch { XCTAssertEqual(error as? CloudError, CloudError(.identityConflict)) }
    XCTAssertEqual(try Data(contentsOf: url), before); XCTAssertEqual(try Data(contentsOf: sidecar), marker)
   }
  }
 }
 func testOriginalMainReplacementAtHandoffIsNotAdopted() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url); try await seed.close()
  let before = try Data(contentsOf: url), retired = url.appendingPathExtension("original")
  do {
   let opened = try SQLiteCloudLedger(existingLocalErasureURL: url, readOnlyCheckpoint: { stage in
    if stage == .beforeReadWriteOpen { try FileManager.default.moveItem(at: url, to: retired); try before.write(to: url) }
   }); try await opened.close(); XCTFail("an equal-byte replacement is not the original inode")
  } catch { XCTAssertEqual(error as? CloudError, CloudError(.identityConflict)) }
  XCTAssertEqual(try Data(contentsOf: retired), before); XCTAssertEqual(try Data(contentsOf: url), before)
 }
 func testMainMutationAfterStaticParseRemainsUnrepairedAndBlocks() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url); try await seed.close()
  let before = try Data(contentsOf: url)
  var edited = before; edited[edited.count - 1] ^= 1
  let changed = edited
  do {
   let opened = try SQLiteCloudLedger(existingLocalErasureURL: url, readOnlyCheckpoint: { stage in
    if stage == .afterStaticValidation { try changed.write(to: url) }
   }); try await opened.close(); XCTFail("changed original is not a static read proof")
  } catch { // Write through the existing inode, not Foundation's exclusive creation option.
   if error as? CloudError != CloudError(.identityConflict) { throw error }
  }
  XCTAssertEqual(try Data(contentsOf: url), changed)
 }
 func testLiteralURICharactersAndDecomposedUnicodeKeepOriginalFile() async throws {
  let url = try tempCloudURL("literal %?# e\u{301}"), seed = try SQLiteCloudLedger(url: url)
  try await seed.close(); assertNoSidecars(url); let before = try Data(contentsOf: url)
  let opened = try SQLiteCloudLedger(existingLocalErasureURL: url); try await opened.close()
  XCTAssertEqual(try Data(contentsOf: url), before)
 }
 func testUnsupportedAndMalformedSidecarFreeFilesRemainByteExact() async throws {
  for (edit, expected) in [("PRAGMA user_version=3", CloudIssue.unsupportedSchema),
   ("PRAGMA user_version=99", .unsupportedSchema), ("CREATE TABLE future_business(raw BLOB) STRICT", .invalidPayload),
   ("ALTER TABLE cloud_uploads ADD COLUMN future_field BLOB", .invalidPayload),
   ("UPDATE cloud_uploads SET original=x'010203'", .invalidPayload)] {
   let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url)
   try await seed.enqueue(cloudUpload()); try await seed.close()
   let setup = try CloudSQL(url: url); try setup.execute(edit); try setup.close(); try checkpointAndClose(url); assertNoSidecars(url)
   let before = try Data(contentsOf: url)
   await expectCloudError(expected) { let opened = try SQLiteCloudLedger(existingLocalErasureURL: url); try await opened.close() }
   XCTAssertEqual(try Data(contentsOf: url), before); assertNoSidecars(url)
  }
 }
 func testExistingZeroLengthSidecarNeverUsesImmutableCheckpoint() async throws {
  for suffix in ["-wal", "-shm", "-journal"] {
   let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url); try await seed.close()
   let sidecar = URL(fileURLWithPath: url.path + suffix), marker = url.appendingPathExtension("immutable-used")
   try Data().write(to: sidecar); let original = try Data(contentsOf: url)
   do {
    let opened = try SQLiteCloudLedger(existingLocalErasureURL: url, readOnlyCheckpoint: { _ in try Data([1]).write(to: marker) })
    try await opened.close()
   } catch { XCTAssertNotNil(error as? CloudError) }
   XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertEqual(try Data(contentsOf: url), original)
  }
 }
 func testNonregularSidecarsAreNotFollowedOrRemoved() async throws {
  for suffix in ["-wal", "-shm", "-journal"] {
   let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url); try await seed.close()
   let victim = url.appendingPathExtension("foreign"), sidecar = URL(fileURLWithPath: url.path + suffix), data = Data([4, 5, 6])
   try data.write(to: victim); try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: victim)
   let original = try Data(contentsOf: url)
   await expectCloudError(.invalidPayload) { let opened = try SQLiteCloudLedger(existingLocalErasureURL: url); try await opened.close() }
   XCTAssertEqual(try Data(contentsOf: victim), data); XCTAssertEqual(try Data(contentsOf: url), original)
   XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path), victim.path)
  }
 }
 func testStaticReadCannotReconstructMissingOriginalErasureProof() async throws {
  let url = try tempCloudURL(), seed = try SQLiteCloudLedger(url: url)
  let request = try CloudLocalTransportEraseRequest(requestID: "lost-controls", scope: cloudScope())
  let first = try await seed.eraseLocalTransport(request); try await seed.close()
  let setup = try CloudSQL(url: url)
  try setup.execute("DELETE FROM cloud_local_erase_receipts"); try setup.execute("DELETE FROM cloud_local_erase_fences"); try setup.close()
  try checkpointAndClose(url); assertNoSidecars(url); let before = try Data(contentsOf: url)
  let opened = try SQLiteCloudLedger(existingLocalErasureURL: url)
  await expectCloudError(.invalidPayload) { _ = try await opened.replayLocalTransportErasure(request, expectedReceipt: first) }
  try await opened.close(); XCTAssertEqual(try Data(contentsOf: url), before)
 }
}
