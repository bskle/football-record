import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class LegacyCompatibilityTests: XCTestCase, @unchecked Sendable {
 let h=TransactionTests()
 func fixture(_ name:String,_ ext:String="json") throws -> Data {
  try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Fixtures")))
 }
 func database() throws -> URL {
  let url=h.path(); try fixture("legacy-v1","sqlite").write(to:url); return url
 }
 func testFrozenV1RowsAndCanonicalRequestsSurviveMigrationAndLaterV2Facts() async throws {
  let url=try database(); let s=try MatchStore(url:url)
  let expected=try JSONDecoder().decode([String:[[String]]].self,from:fixture("legacy-rows"))
  let raw=try SQLite(url:url,fault:nil)
  for (table,rows) in expected {
   let actual=try raw.rows("SELECT * FROM "+table+" ORDER BY rowid").map { row in row.map { value in
    switch value { case .null:return "null"; case .text(let s):return "text:"+s; case .integer(let n):return "integer:"+String(n); case .blob(let b):return "blob:"+b.map { String(format:"%02X",$0) }.joined() }
   } }
   XCTAssertEqual(actual,rows,table)
  }
  try raw.close()
  let command=try JSONDecoder().decode(StoreCommit.self,from:fixture("command"))
  let packet=try JSONDecoder().decode(MatchPacket.self,from:fixture("packet"))
  XCTAssertEqual(try Canonical.data(command),try fixture("command")); XCTAssertEqual(try Canonical.data(packet),try fixture("packet"))
  let receipt=try JSONDecoder().decode(CommitReceipt.self,from:fixture("receipt"))
  let first=try await s.commit(command); XCTAssertEqual(first,receipt)
  let d=try await s.snapshot(matchID:"match").descriptor
  let b=try CaptureBinding(matchID:"match",recordingDeviceID:"watch")
  let r=try CaptureRevision(id:"new-revision",binding:b,parentID:nil,revision:1,observedAt:h.t,metadata:CaptureMetadata(binding:b,segments:[],gaps:[]))
  let out=try BusinessOutboxItem(id:"new-delta",matchID:"match",sourceDeviceID:"watch",payload:BusinessDeltaV2(descriptor:d,events:[],captureRevisions:[r]))
  _=try await s.commitV2(StoreCommitV2(commandID:"v2",expectedGeneration:4,descriptor:d,events:[],captureRevisions:[r],newCaptureOperations:[],captureOperationUpdates:[],businessOutbox:[out]))
  let repeated=try await s.commit(command); XCTAssertEqual(repeated,receipt)
  let inbound=try JSONDecoder().decode(MatchPacket.self,from:fixture("inbound"))
  let ack=try await s.receive(inbound,expectedPeerDeviceID:"watch",localDeviceID:"phone",expectedMatchID:"match")
  XCTAssertEqual(try Canonical.data(ack),try fixture("inbound-ack"))
  try await s.acknowledge(JSONDecoder().decode(DurableACK.self,from:fixture("ack")))
  let pending=try await s.pendingPackets(matchID:"match"); XCTAssertEqual(pending.count,1); XCTAssertEqual(pending[0].body.packetID,"packet-legacy-end")
  try await s.close()
  let lost=try MatchStore(url:url,fault:.afterCommit)
  do { _=try await lost.commit(command); XCTFail("lost receipt") } catch let error as StoreError { XCTAssertEqual(error,.responseLost) }
  try await lost.close(); let reopened=try MatchStore(url:url)
  let result=try await reopened.commit(command); XCTAssertEqual(result,receipt); try await reopened.close()
 }
}
