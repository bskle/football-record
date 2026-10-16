import Foundation
import XCTest
import MatchCore
@testable import MatchStore
final class CaptureTransactionTests: XCTestCase, @unchecked Sendable {
 let h = TransactionTests()
 func binding(_ match: String = "match") throws -> CaptureBinding { try CaptureBinding(matchID: match, recordingDeviceID: "watch") }
 func revision(_ id: String = "r1", parent: String? = nil, number: Int64 = 1, segments: [CaptureSegment] = []) throws -> CaptureRevision {
  let b = try binding(); return try CaptureRevision(id: id, binding: b, parentID: parent, revision: number, observedAt: h.t,
   metadata: CaptureMetadata(binding: b, segments: segments, gaps: []))
 }
 func operation(_ id: String = "op1", command: String = "c0") throws -> CaptureOperation {
  try CaptureOperation(id: id, binding: binding(), associatedCommandID: command, action: .start, requestedAt: h.t, externalToken: id)
 }
 func request(_ id: String, generation: Int64, descriptor: MatchDescriptor, events: [MatchEvent] = [], revisions: [CaptureRevision] = [], operations: [CaptureOperation] = [], updates: [CaptureOperationUpdate] = [], outboxID: String? = nil) throws -> StoreCommitV2 {
  let items = try outboxID.map { [try BusinessOutboxItem(id: $0, matchID: descriptor.matchID, sourceDeviceID: "watch", payload: BusinessDeltaV2(descriptor: descriptor, events: events, captureRevisions: revisions))] } ?? []
  return try StoreCommitV2(commandID: id, expectedGeneration: generation, descriptor: descriptor, events: events, captureRevisions: revisions,
   newCaptureOperations: operations, captureOperationUpdates: updates, businessOutbox: items)
 }
 func testLocalFactsCaptureAndOutboxPersistWithoutInventingPeer() async throws {
  let url = h.path(); try await h.prepare(url); let s = try MatchStore(url: url); let (d,e) = try h.facts()
  let c = try request("c0", generation: 1, descriptor: d, events: e, revisions: [revision()], operations: [operation()], outboxID: "delta")
  let receipt = try await s.commitV2(c); XCTAssertEqual(receipt.generation, 2); try await s.close()
  let reopened = try MatchStore(url: url); let snapshot = try await reopened.snapshotV2(matchID: "match")
  XCTAssertEqual(snapshot.business.events,e); XCTAssertEqual(snapshot.captureRevisions.count,1)
  let actual1 = try await reopened.pendingCaptureOperations(matchID: "match").count; XCTAssertEqual(actual1,1)
  let actual2 = try await reopened.pendingBusinessOutbox(matchID: "match").map(\.id); XCTAssertEqual(actual2,["delta"])
  let actual9 = try await reopened.pendingPackets(matchID: "match").isEmpty; XCTAssertTrue(actual9)
  let actual3 = try await reopened.commitV2(c); XCTAssertEqual(actual3,receipt); try await reopened.close()
 }
 func testFactsRequireCompleteMatchingDelta() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let(d,e)=try h.facts()
  do { _=try await s.commitV2(request("bad",generation:1,descriptor:d,events:e)); XCTFail("uncovered facts") } catch let error as StoreError { XCTAssertEqual(error,.invalidRequest) }
  let actual10 = try await s.snapshot(matchID:"match").events.isEmpty; XCTAssertTrue(actual10); try await s.close()
 }
 func testAllTransactionFaultsRollBackAndLostResponseRetries() async throws {
  for point in [StoreFault.afterEvents,.afterCaptureRevisions,.afterCaptureOperations,.afterOutbox,.afterReceipt,.beforeCommit] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url,fault:point); let(d,e)=try h.facts()
   let c=try request("c0",generation:1,descriptor:d,events:e,revisions:[revision()],operations:[operation()],outboxID:"delta")
   do { _=try await s.commitV2(c); XCTFail("injected failure") } catch {}
   try await s.close(); let reopened=try MatchStore(url:url); let snap=try await reopened.snapshotV2(matchID:"match")
   XCTAssertEqual(snap.business.generation,1); XCTAssertTrue(snap.captureRevisions.isEmpty); XCTAssertTrue(snap.captureOperations.isEmpty)
   let actual11 = try await reopened.pendingBusinessOutbox(matchID:"match").isEmpty; XCTAssertTrue(actual11)
   _=try await reopened.commitV2(c); try await reopened.close()
  }
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url,fault:.afterCommit); let(d,e)=try h.facts()
  let c=try request("c0",generation:1,descriptor:d,events:e,operations:[operation()],outboxID:"delta")
  do { _=try await s.commitV2(c); XCTFail("lost") } catch let error as StoreError { XCTAssertEqual(error,.responseLost) }
  try await s.close(); let reopened=try MatchStore(url:url); let a=try await reopened.commitV2(c); let b=try await reopened.commitV2(c); XCTAssertEqual(a,b)
  let changed=try request("c0",generation:2,descriptor:d)
  do { _=try await reopened.commitV2(changed); XCTFail("same ID different request") } catch let error as StoreError { XCTAssertEqual(error,.commandConflict) }
  try await reopened.close()
 }
 func testRevisionParentForkCollisionAndStableSegmentReuse() async throws {
  for mode in ["parent","branch","collision"] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   _=try await s.commitV2(request("root",generation:1,descriptor:d,revisions:[revision()],outboxID:"delta1"))
   var bad=try revision("r2",parent:"r1",number:2)
   if mode=="parent" { bad=try revision("r2",parent:"missing",number:2) }
   if mode=="branch" { bad=try revision("r2") }
   if mode=="collision" { bad=try revision("delta1",parent:"r1",number:2) }
   do { _=try await s.commitV2(request("bad",generation:2,descriptor:d,revisions:[bad],outboxID:"delta2")); XCTFail(mode) } catch {}
   let snap=try await s.snapshotV2(matchID:"match"); XCTAssertEqual(snap.captureRevisions.count,1); XCTAssertEqual(snap.business.generation,2)
   XCTAssertTrue(snap.business.diagnostics.contains { $0.severity == .blocking }); try await s.close()
  }
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
  let segment=try CaptureSegment(id:"segment",binding:binding(),workoutID:"real-workout",window:CaptureWindow(start:nil,end:nil))
  _=try await s.commitV2(request("one",generation:1,descriptor:d,revisions:[revision(segments:[segment])],outboxID:"delta1"))
  _=try await s.commitV2(request("two",generation:2,descriptor:d,revisions:[revision("r2",parent:"r1",number:2,segments:[segment])],outboxID:"delta2"))
  let actual4 = try await s.snapshotV2(matchID:"match").captureRevisions.count; XCTAssertEqual(actual4,2); try await s.close()
 }
 func observation(_ outcome: WorkoutOutcome) throws -> WorkoutObservation { try WorkoutObservation(operationID:"op1",binding:binding(),externalToken:"op1",observedAt:h.t,outcome:outcome,window:CaptureWindow(start:nil,end:nil)) }
 func testOperationReceiptsRemainValidAfterLegalEvolutionAndReopen() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
  let c0=try request("c0",generation:1,descriptor:d,operations:[operation()]); let r0=try await s.commitV2(c0)
  let u1=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
  let c1=try request("c1",generation:2,descriptor:d,updates:[u1]); let r1=try await s.commitV2(c1)
  let u2=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.settled,observation:observation(.linked(workoutID:"real-workout")))
  let segment=try CaptureSegment(id:"linked-segment",binding:binding(),workoutID:"real-workout",window:CaptureWindow(start:nil,end:nil))
  let c2=try request("c2",generation:3,descriptor:d,revisions:[revision(segments:[segment])],updates:[u2],outboxID:"delta")
  _=try await s.commitV2(c2); try await s.close(); let reopened=try MatchStore(url:url)
  let actual5 = try await reopened.commitV2(c0); XCTAssertEqual(actual5,r0); let actual6 = try await reopened.commitV2(c1); XCTAssertEqual(actual6,r1)
  let actual12 = try await reopened.pendingCaptureOperations(matchID:"match").isEmpty; XCTAssertTrue(actual12)
  let actual7 = try await reopened.snapshotV2(matchID:"match").captureOperations[0].state; XCTAssertEqual(actual7,.settled)
  do { _=try await reopened.commitV2(request("stale",generation:4,descriptor:d,updates:[u1])); XCTFail("terminal CAS") } catch let error as StoreError { XCTAssertEqual(error,.invalidOperationTransition) }
  try await reopened.close()
 }
 func testUnknownAndSavedAwaitingLinkRemainReconciliation() async throws {
  for outcome in [WorkoutOutcome.unknown,.savedAwaitingLink] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   _=try await s.commitV2(request("c0",generation:1,descriptor:d,operations:[operation()]))
   let u=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
   _=try await s.commitV2(request("c1",generation:2,descriptor:d,updates:[u]))
   let update=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.needsReconciliation,observation:observation(outcome))
   _=try await s.commitV2(request("c2",generation:3,descriptor:d,updates:[update]))
   let actual8 = try await s.pendingCaptureOperations(matchID:"match").first?.state; XCTAssertEqual(actual8,.needsReconciliation)
   try await s.close()
  }
 }
 func testReceiptDetectsMissingOrTamperedRevisionOperationAndOutbox() async throws {
  for sql in ["DELETE FROM capture_revisions", "UPDATE capture_operations SET operation=x'626164'", "DELETE FROM business_outbox", "DELETE FROM capture_operation_history"] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   let c=try request("c0",generation:1,descriptor:d,revisions:[revision()],operations:[operation()],outboxID:"delta")
   _=try await s.commitV2(c); try await s.close(); let raw=try SQLite(url:url,fault:nil); try raw.execute(sql); try raw.close()
   let reopened=try MatchStore(url:url)
   do { _=try await reopened.commitV2(c); XCTFail("receipt cannot replace raw records") } catch {}
   let actual13 = try await reopened.diagnostics(matchID:"match").contains { $0.severity == .blocking }; XCTAssertTrue(actual13); try await reopened.close()
  }
 }
 func testCaptureDigestInvalidatesBothSnapshotAPIsAndRejectsLegacyBypass() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let(d,e)=try h.facts(); var recorder=LiveMatchRecorder(descriptor:d,events:e)
  try recorder.transition(.matchEnded,eventID:"end",sourceDeviceID:"watch",now:h.t.addingTimeInterval(10))
  _=try await s.commitV2(request("ended",generation:1,descriptor:d,events:recorder.events,outboxID:"delta-end"))
  let proof=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:d,events:recorder.events,confirmationID:"trusted",now:h.t.addingTimeInterval(20))
  try await s.saveCompletionEvidence(proof,expectedGeneration:2,now:h.t.addingTimeInterval(20))
  _=try await s.commitV2(request("r1-command",generation:2,descriptor:d,revisions:[revision()],outboxID:"delta-r1"))
  let actual14 = try await s.snapshot(matchID:"match").completionEvidence; XCTAssertNil(actual14); let actual15 = try await s.snapshotV2(matchID:"match").business.completionEvidence; XCTAssertNil(actual15)
  do { try await s.saveCompletionEvidence(proof,expectedGeneration:3,now:h.t.addingTimeInterval(20)); XCTFail("legacy bypass") } catch let error as StoreError { XCTAssertEqual(error,.staleCaptureEvidence) }
  do { try await s.saveCompletionProofV2(evidence:proof,captureDigest:CaptureRevision.digest([]),expectedGeneration:3,now:h.t.addingTimeInterval(20)); XCTFail("old digest") } catch let error as StoreError { XCTAssertEqual(error,.staleCaptureEvidence) }
  do { try await s.saveCompletionProofV2(evidence:proof,captureDigest:CaptureRevision.digest([revision()]),expectedGeneration:3,now:h.t.addingTimeInterval(20)); XCTFail("old confirmation cannot assert new capture save") } catch let error as StoreError { XCTAssertEqual(error,.staleCaptureEvidence) }
  let captureProof=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:d,events:recorder.events,confirmationID:"trusted-capture-r1",now:h.t.addingTimeInterval(20))
  try await s.saveCompletionProofV2(evidence:captureProof,captureDigest:CaptureRevision.digest([revision()]),expectedGeneration:3,now:h.t.addingTimeInterval(20))
  let actual17 = try await s.snapshot(matchID:"match").completionEvidence; XCTAssertNotNil(actual17)
  _=try await s.commitV2(request("r2-command",generation:3,descriptor:d,revisions:[revision("r2",parent:"r1",number:2)],outboxID:"delta-r2"))
  let actual16 = try await s.snapshot(matchID:"match").completionEvidence; XCTAssertNil(actual16); try await s.close()
 }
 func testReadOnlyLookupReturnsOriginalRequestAndRejectsCorruptIndexHashAndReceipt() async throws {
  for damage in ["none","request","hash","receipt","index"] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   let c=try request("c0",generation:1,descriptor:d,operations:[operation()]); let receipt=try await s.commitV2(c)
   _=try await s.commitV2(request("later",generation:2,descriptor:d)); try await s.close()
   let raw=try SQLite(url:url,fault:nil)
   if damage=="request" { try raw.execute("UPDATE commands_v2 SET request=x'626164' WHERE command_id='c0'") }
   if damage=="hash" { try raw.execute("UPDATE commands_v2 SET request_hash='bad' WHERE command_id='c0'") }
   if damage=="receipt" { try raw.execute("UPDATE commands_v2 SET receipt=x'626164' WHERE command_id='c0'") }
   if damage=="index" { try raw.execute("UPDATE commands_v2 SET command_id='renamed' WHERE command_id='c0'") }
   try raw.close(); let reopened=try MatchStore(url:url)
   let missing=try await reopened.committedCommandV2(commandID:"absent"); XCTAssertNil(missing)
   if damage=="none" {
    let saved=try await reopened.committedCommandV2(commandID:"c0"); XCTAssertEqual(saved?.request,c); XCTAssertEqual(saved?.receipt,receipt)
    let snapshot=try await reopened.snapshotV2(matchID:"match"); XCTAssertEqual(snapshot.business.generation,3)
   } else {
    do { _=try await reopened.committedCommandV2(commandID:damage=="index" ? "renamed":"c0"); XCTFail("damaged lookup") } catch {}
    let diagnostics=try await reopened.diagnostics(matchID:"match"); XCTAssertTrue(diagnostics.contains { $0.severity == .blocking })
   }
   try await reopened.close()
  }
 }
 func testGlobalIdentityCollisionAndChangedOperationTokenRetainRawDiagnostic() async throws {
  for kind in ["revision","operation","outbox","cross-match"] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   let segment=try CaptureSegment(id:"shared",binding:binding(),workoutID:"real",window:CaptureWindow(start:nil,end:nil))
   _=try await s.commitV2(request("one",generation:1,descriptor:d,revisions:[revision(segments:[segment])],outboxID:"delta1"))
   var bad:StoreCommitV2
   if kind=="revision" { bad=try request("bad",generation:2,descriptor:d,revisions:[revision("shared",parent:"r1",number:2)],outboxID:"delta2") }
   else if kind=="operation" { bad=try request("bad",generation:2,descriptor:d,operations:[operation("shared",command:"bad")]) }
   else if kind=="outbox" { bad=try request("bad",generation:2,descriptor:d,outboxID:"shared") }
   else {
    let other=MatchDescriptor(startIntent:StartIntent(id:"other-intent",matchID:"other",recordingDeviceID:"watch",requestedAt:h.t),starter:true)
    _=try await s.commitV2(request("other-intent-command",generation:0,descriptor:other))
    let b=try CaptureBinding(matchID:"other",recordingDeviceID:"watch")
    let r=try CaptureRevision(id:"r1",binding:b,parentID:nil,revision:1,observedAt:h.t,metadata:CaptureMetadata(binding:b,segments:[],gaps:[]))
    bad=try request("bad",generation:1,descriptor:other,revisions:[r],outboxID:"delta2")
   }
   do { _=try await s.commitV2(bad); XCTFail("global ID collision") } catch let error as StoreError { XCTAssertEqual(error,.captureConflict) }
   let snap=try await s.snapshotV2(matchID:"match"); XCTAssertEqual(snap.captureRevisions.count,1); XCTAssertEqual(snap.business.generation,2)
   let diagnostics=try await s.diagnostics(matchID:bad.descriptor.matchID); XCTAssertTrue(diagnostics.contains { !$0.rawBytes.isEmpty && $0.severity == .blocking }); try await s.close()
  }
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor(); let c=try request("c0",generation:1,descriptor:d,operations:[operation()])
  _=try await s.commitV2(c); try await s.close(); let raw=try SQLite(url:url,fault:nil)
  let op=try operation(); var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Canonical.data(op)) as? [String:Any]); json["associatedCommandID"]="tampered"
  let bytes=try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys])
  try raw.execute("UPDATE capture_operations SET operation=?,checksum=?",[.blob(bytes),.text(Canonical.hash(bytes))]); try raw.close()
  let reopened=try MatchStore(url:url)
  do { _=try await reopened.commitV2(c); XCTFail("immutable request tampered") } catch {}
  let diagnostics=try await reopened.diagnostics(matchID:"match"); XCTAssertTrue(diagnostics.contains { $0.rawBytes==bytes }); try await reopened.close()
 }

 func testSavedWorkoutCannotBecomeNotCreatedOrLoseSavedObservation() async throws {
  for outcome in [WorkoutOutcome.notCreated(.captureFailed),.unknown] {
   let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
   _=try await s.commitV2(request("c0",generation:1,descriptor:d,operations:[operation()]))
   let before=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
   _=try await s.commitV2(request("c1",generation:2,descriptor:d,updates:[before]))
   let saved=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.needsReconciliation,observation:observation(.savedAwaitingLink))
   _=try await s.commitV2(request("c2",generation:3,descriptor:d,updates:[saved]))
   let next=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:outcome == .unknown ? .needsReconciliation:.failed,observation:observation(outcome))
   do { _=try await s.commitV2(request("bad",generation:4,descriptor:d,updates:[next])); XCTFail("cannot erase known save") } catch let error as StoreError { XCTAssertEqual(error,.invalidOperationTransition) }
   let pending=try await s.pendingCaptureOperations(matchID:"match"); XCTAssertEqual(pending.first?.observation?.outcome,.savedAwaitingLink)
   try await s.close()
  }
 }
 func testCreationReceiptChecksHistoryAgainstSavedCanonicalUpdateRequest() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
  let c0=try request("c0",generation:1,descriptor:d,operations:[operation()]); _=try await s.commitV2(c0)
  let before=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
  _=try await s.commitV2(request("c1",generation:2,descriptor:d,updates:[before]))
  let saved=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.needsReconciliation,observation:observation(.savedAwaitingLink))
  _=try await s.commitV2(request("c2",generation:3,descriptor:d,updates:[saved])); try await s.close()
  let raw=try SQLite(url:url,fault:nil)
  let altered=try WorkoutObservation(operationID:"op1",binding:binding(),externalToken:"op1",observedAt:h.t.addingTimeInterval(1),outcome:.savedAwaitingLink,window:CaptureWindow(start:nil,end:nil))
  let bytes=try Canonical.data(CaptureOperationRecord(operation:operation(),state:.needsReconciliation,observation:altered))
  try raw.execute("UPDATE capture_operation_history SET record=?,checksum=? WHERE ordinal=2",[.blob(bytes),.text(Canonical.hash(bytes))])
  try raw.execute("UPDATE capture_operations SET record=?,record_checksum=?",[.blob(bytes),.text(Canonical.hash(bytes))]); try raw.close()
  let reopened=try MatchStore(url:url)
  do { _=try await reopened.commitV2(c0); XCTFail("history hash cannot replace original command") } catch {}
  let diagnostics=try await reopened.diagnostics(matchID:"match"); XCTAssertTrue(diagnostics.contains { $0.rawBytes == bytes && $0.severity == .blocking }); try await reopened.close()
 }

 func testLinkedOutcomeRequiresRealSegmentAndCanReuseExistingAssociation() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
  _=try await s.commitV2(request("c0",generation:1,descriptor:d,operations:[operation()]))
  let pending=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
  _=try await s.commitV2(request("c1",generation:2,descriptor:d,updates:[pending]))
  let linked=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.settled,observation:observation(.linked(workoutID:"actual-workout")))
  do { _=try await s.commitV2(request("missing-link",generation:3,descriptor:d,updates:[linked])); XCTFail("no manufactured segment") } catch let error as StoreError { XCTAssertEqual(error,.invalidCaptureRevision) }
  let segment=try CaptureSegment(id:"real-segment",binding:binding(),workoutID:"actual-workout",window:CaptureWindow(start:nil,end:nil))
  _=try await s.commitV2(request("association",generation:3,descriptor:d,revisions:[revision(segments:[segment])],outboxID:"delta"))
  _=try await s.commitV2(request("linked",generation:4,descriptor:d,updates:[linked]))
  let snapshot=try await s.snapshotV2(matchID:"match"); XCTAssertEqual(snapshot.captureOperations.first?.state,.settled); XCTAssertEqual(snapshot.captureRevisions.count,1)
  try await s.close()
 }
 func testV2ProofGenerationTimelineAndConfirmationHistoryStayBound() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let(d,e)=try h.facts(); var recorder=LiveMatchRecorder(descriptor:d,events:e)
  try recorder.transition(.matchEnded,eventID:"end",sourceDeviceID:"watch",now:h.t.addingTimeInterval(10))
  _=try await s.commitV2(request("end",generation:1,descriptor:d,events:recorder.events,outboxID:"end-delta"))
  let proof=try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor:d,events:recorder.events,confirmationID:"capture-confirmation",now:h.t.addingTimeInterval(20))
  let empty=try CaptureRevision.digest([])
  do { try await s.saveCompletionProofV2(evidence:proof,captureDigest:empty,expectedGeneration:1,now:h.t.addingTimeInterval(20)); XCTFail("CAS") } catch let error as StoreError { XCTAssertEqual(error,.staleGeneration) }
  try await s.saveCompletionProofV2(evidence:proof,captureDigest:empty,expectedGeneration:2,now:h.t.addingTimeInterval(20))
  _=try await s.commitV2(request("revision",generation:2,descriptor:d,revisions:[revision()],outboxID:"r-delta"))
  do { try await s.saveCompletionProofV2(evidence:proof,captureDigest:CaptureRevision.digest([revision()]),expectedGeneration:3,now:h.t.addingTimeInterval(20)); XCTFail("same confirmation different digest") } catch let error as StoreError { XCTAssertEqual(error,.staleCaptureEvidence) }
  let correction=try PostMatchEditor.revise(eventID:"goal",newEventID:"delete-goal",descriptor:d,events:recorder.events,delete:true,sourceDeviceID:"watch",now:h.t.addingTimeInterval(20))
  _=try await s.commitV2(request("correct",generation:3,descriptor:d,events:[correction],outboxID:"correct-delta"))
  do { try await s.saveCompletionProofV2(evidence:proof,captureDigest:CaptureRevision.digest([revision()]),expectedGeneration:4,now:h.t.addingTimeInterval(20)); XCTFail("old event evidence") } catch let error as StoreError { XCTAssertEqual(error,.staleCompletionEvidence) }
  let snapshot=try await s.snapshot(matchID:"match"); XCTAssertNil(snapshot.completionEvidence); try await s.close()
 }
 func testRouteWarningAndStoppedUncertainSaveStayPendingWithoutLosingToken() async throws {
  let url=h.path(); try await h.prepare(url); let s=try MatchStore(url:url); let d=h.descriptor()
  _=try await s.commitV2(request("c0",generation:1,descriptor:d,operations:[operation()]))
  let pending=try CaptureOperationUpdate(operationID:"op1",expectedState:.pending,state:.needsReconciliation,observation:nil)
  _=try await s.commitV2(request("c1",generation:2,descriptor:d,updates:[pending]))
  let window=try CaptureWindow(start:nil,end:nil)
  let stopped=try WorkoutObservation(operationID:"op1",binding:binding(),externalToken:"op1",observedAt:h.t,outcome:.stopped,window:window,failure:.captureFailed)
  let update=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.needsReconciliation,observation:stopped)
  _=try await s.commitV2(request("c2",generation:3,descriptor:d,updates:[update]))
  try await s.close(); let reopened=try MatchStore(url:url); let operations=try await reopened.pendingCaptureOperations(matchID:"match")
  XCTAssertEqual(operations.first?.operation.externalToken,"op1"); XCTAssertEqual(operations.first?.observation?.outcome,.stopped); XCTAssertEqual(operations.first?.observation?.failure,.captureFailed)
  let madeUp=try CaptureOperationUpdate(operationID:"op1",expectedState:.needsReconciliation,state:.failed,observation:observation(.notCreated(.captureFailed)))
  do { _=try await reopened.commitV2(request("bad",generation:4,descriptor:d,updates:[madeUp])); XCTFail("stopped Workout exists") } catch let error as StoreError { XCTAssertEqual(error,.invalidOperationTransition) }
  try await reopened.close()
 }

}
