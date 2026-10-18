import Foundation
import XCTest
@testable import CloudSync

final class CloudScopeRawIdentityTests: XCTestCase, @unchecked Sendable {
 private func pair(_ field:Int = 1) throws -> [CloudScope] {
  try ["space-\u{e9}","space-e\u{301}"].map { id in
   try CloudScope(accountID:field == 0 ? id : "account",cloudSpaceID:field == 1 ? id : "space",zoneID:field == 2 ? id : "zone",activationEpoch:1)
  }
 }
 func testUnicodeScopeErasureRemovesAllFourTablesAndPreservesOtherRawScope() async throws {
  for selected in [1,0] {
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),scopes = try pair(),target = scopes[selected],other = scopes[1-selected]
   // NFC is deliberately inserted first. Both are legal and have distinct existing SQL/stable keys.
   for scope in scopes { try await seedErasurePhases(ledger,scope:scope) }
   XCTAssertNotEqual(target.stableZoneKey,other.stableZoneKey); XCTAssertNotEqual(try target.key,try other.key)
   let before = try canonicalSnapshot(url,scope:other)
   XCTAssertTrue(try canonicalSnapshot(url,scope:target).values.allSatisfy { !$0.isEmpty })
   let request = try CloudLocalTransportEraseRequest(requestID:"unicode-erase",scope:target),receipt = try await ledger.eraseLocalTransport(request)
   XCTAssertEqual(receipt.stableZoneKey,target.stableZoneKey)
   // Raw SQL selection verifies zero independently of Set<CloudScope> or Swift String equality.
   XCTAssertTrue(try canonicalSnapshot(url,scope:target).values.allSatisfy(\.isEmpty))
   XCTAssertEqual(try canonicalSnapshot(url,scope:other),before)
   try await ledger.close(); let reopened = try SQLiteCloudLedger(url:url)
   let replay = try await reopened.eraseLocalTransport(request); XCTAssertEqual(replay,receipt)
   XCTAssertTrue(try canonicalSnapshot(url,scope:target).values.allSatisfy(\.isEmpty)); XCTAssertEqual(try canonicalSnapshot(url,scope:other),before)
   let blocked = try await reopened.scopeState(scope:target),preserved = try await reopened.scopeState(scope:other)
   XCTAssertEqual(blocked.issue,.accountChanged); XCTAssertEqual(preserved.issue,.quotaExceeded); try await reopened.close()
  }
 }
 func testAllIdentifierBytesAndEpochDefineScopeEqualityAndSetMembership() throws {
  for field in 0...2 {
   let scopes = try pair(field),first = scopes[0],second = scopes[1]
   XCTAssertNotEqual(first,second); XCTAssertEqual(Set(scopes).count,2)
   let same = try CloudScope(accountID:first.accountID,cloudSpaceID:first.cloudSpaceID,zoneID:first.zoneID,activationEpoch:first.activationEpoch)
   XCTAssertEqual(first,same); XCTAssertEqual(Set([first,same]).count,1)
  }
  let first = try cloudScope(),next = try cloudScope(epoch:2)
  XCTAssertNotEqual(first,next); XCTAssertNotEqual(try first.key,try next.key); XCTAssertEqual(first.stableZoneKey,next.stableZoneKey)
 }
 func testCanonicalEquivalentScopeCannotCrossUploadOrSaveReadbackBoundary() async throws {
  for field in 0...2 {
   let scopes = try pair(field),upload = try eraseUpload(scopes[0]),original = try completeCloudSave(upload)
   XCTAssertThrowsError(try CloudUpload(scope:scopes[1],record:upload.record))
   let foreign = CloudSaveReadback(scope:scopes[1],recordID:original.recordID,manifestRecordID:original.manifestRecordID,manifestBytes:original.manifestBytes,manifestChangeTag:original.manifestChangeTag,manifestCondition:original.manifestCondition,parts:original.parts,confirmationID:original.confirmationID,recordChangeTag:original.recordChangeTag,recordCondition:original.recordCondition)
   let url = try tempCloudURL(),ledger = try SQLiteCloudLedger(url:url),driver = ControlledCloudDriver()
   try await ledger.enqueue(upload); await driver.configureSave(response:.complete(foreign))
   let result = try await CloudSyncService(scope:scopes[0],ledger:ledger,driver:driver).synchronize(),evidence = try await ledger.saveEvidence(scope:scopes[0]),rows = try await ledger.uploads(scope:scopes[0])
   XCTAssertEqual(result.issue,.invalidPayload); XCTAssertTrue(evidence.isEmpty); XCTAssertEqual(rows.first?.state,.blocked)
   try await ledger.close()
  }
 }
 func testEraseRequestAndReceiptReplayStayBoundToRawScopeBytes() async throws {
  let scopes = try pair(),first = try CloudLocalTransportEraseRequest(requestID:"same-id",scope:scopes[0]),other = try CloudLocalTransportEraseRequest(requestID:"same-id",scope:scopes[1])
  XCTAssertNotEqual(first,other); XCTAssertNotEqual(try first.digest,try other.digest)
  let ledger = try SQLiteCloudLedger(url:tempCloudURL()),receipt = try await ledger.eraseLocalTransport(first)
  XCTAssertEqual(receipt.requestDigest,try first.digest); XCTAssertNotEqual(receipt.stableZoneKey,scopes[1].stableZoneKey)
  await expectCloudError(.identityConflict) { _ = try await ledger.eraseLocalTransport(other) }; try await ledger.close()
 }
 func testLegacyScopeCanonicalAndKeyFixturesRemainByteIdentical() throws {
  let scope = try cloudScope(),expected = Data(#"{"accountID":"account","activationEpoch":1,"cloudSpaceID":"space","zoneID":"zone"}"#.utf8)
  XCTAssertEqual(try CloudCodec.encode(scope),expected)
  XCTAssertEqual(scope.stableZoneKey,"0c92250a1086fa278a1818d27d82e56cd941bc470b195292d59cd5f11ecf5abc")
  XCTAssertEqual(try scope.key,"d5d2e6c1b45b4cd91cb3a9a1f9c599bf0f5c8297ead4c82683c0a17220485646")
  for original in try pair() {
   let raw = try CloudCodec.encode(original),restored = try CloudCodec.decode(CloudScope.self,raw)
   XCTAssertEqual(Data(restored.cloudSpaceID.utf8),Data(original.cloudSpaceID.utf8)); XCTAssertEqual(try CloudCodec.encode(restored),raw)
  }
 }
}
