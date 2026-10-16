import Foundation
import MatchCore
import XCTest

@testable import MatchStore

final class AbsentCaptureCleanupTests: XCTestCase, @unchecked Sendable {
  let h = CaptureTransactionTests()
  func update(
    _ store: MatchStore, _ command: String, _ operation: String, _ expected: CaptureOperationState,
    _ state: CaptureOperationState, _ outcome: WorkoutOutcome? = nil, window: CaptureWindow? = nil
  ) async throws -> StoreCommitV2 {
    let snapshot = try await store.snapshotV2(matchID: "match")
    let original = try XCTUnwrap(snapshot.captureOperations.first { $0.operation.id == operation })
    let observation = try outcome.map {
      try WorkoutObservation(
        operationID: operation, binding: original.operation.binding,
        externalToken: original.operation.externalToken,
        observedAt: h.h.t.addingTimeInterval(Double(snapshot.business.generation)), outcome: $0,
        window: window ?? CaptureWindow(start: nil, end: nil))
    }
    let u = try CaptureOperationUpdate(
      operationID: operation, expectedState: expected, state: state, observation: observation)
    let request = try h.request(
      command, generation: snapshot.business.generation, descriptor: snapshot.business.descriptor,
      updates: [u])
    _ = try await store.commitV2(request)
    return request
  }
  func fixture(
    negativeFirst: Bool = false, includeNegative: Bool = true, finishAction: CaptureAction = .finish
  ) async throws -> (URL, MatchStore, StoreCommitV2) {
    let url = h.h.path()
    try await h.h.prepare(url)
    let store = try MatchStore(url: url)
    _ = try await store.commitV2(
      h.request(
        "create-start", generation: 1, descriptor: h.h.descriptor(),
        operations: [h.operation(command: "create-start")]))
    _ = try await update(store, "mark-start", "op1", .pending, .needsReconciliation)
    _ = try await update(
      store, "unknown-start", "op1", .needsReconciliation, .needsReconciliation, .unknown)
    if negativeFirst && includeNegative {
      _ = try await update(
        store, "absent-start", "op1", .needsReconciliation, .failed, .notCreated(.unavailable))
    }
    let snapshot = try await store.snapshotV2(matchID: "match")
    let finish = try CaptureOperation(
      id: "finish", binding: h.binding(), associatedCommandID: "create-finish",
      action: finishAction,
      requestedAt: h.h.t, externalToken: "op1")
    _ = try await store.commitV2(
      h.request(
        "create-finish", generation: snapshot.business.generation,
        descriptor: snapshot.business.descriptor, operations: [finish]))
    _ = try await update(store, "mark-finish", "finish", .pending, .needsReconciliation)
    _ = try await update(
      store, "unknown-finish", "finish", .needsReconciliation, .needsReconciliation, .unknown)
    if !negativeFirst && includeNegative {
      _ = try await update(
        store, "absent-start", "op1", .needsReconciliation, .failed, .notCreated(.unavailable))
    }
    let latest = try await store.snapshotV2(matchID: "match")
    let cancel = try h.request(
      "cancel-absent", generation: latest.business.generation,
      descriptor: latest.business.descriptor,
      updates: [
        CaptureOperationUpdate(
          operationID: "finish", expectedState: .needsReconciliation, state: .cancelled,
          observation: nil)
      ])
    return (url, store, cancel)
  }
  func testProvenAbsentFinishCancellationSurvivesBothArrivalOrdersAndReceiptRetry() async throws {
    for negativeFirst in [false, true] {
      let (url, store, cancel) = try await fixture(negativeFirst: negativeFirst)
      let receipt = try await store.commitV2(cancel)
      _ = try await store.commitV2(
        h.request("later-generation", generation: receipt.generation, descriptor: cancel.descriptor)
      )
      let stored = try await store.committedCommandV2(commandID: "absent-start")
      let original = try XCTUnwrap(stored)
      let originalRetry = try await store.commitV2(original.request)
      XCTAssertEqual(originalRetry, original.receipt)
      try await store.close()
      let reopened = try MatchStore(url: url)
      let pending = try await reopened.pendingCaptureOperations(matchID: "match")
      XCTAssertTrue(pending.isEmpty)
      let retry = try await reopened.commitV2(cancel)
      XCTAssertEqual(retry, receipt)
      let lookup = try await reopened.committedCommandV2(commandID: cancel.commandID)
      XCTAssertEqual(lookup?.request, cancel)
      XCTAssertEqual(lookup?.receipt, receipt)
      let snapshot = try await reopened.snapshotV2(matchID: "match")
      XCTAssertEqual(snapshot.captureOperations.last?.state, .cancelled)
      try await reopened.close()
    }
  }
  func testProvenAbsentCancellationFaultsAndLostResponseReopen() async throws {
    for fault in [StoreFault.beforeCommit, .afterCommit] {
      let (url, initial, cancel) = try await fixture()
      try await initial.close()
      let store = try MatchStore(url: url, fault: fault)
      do {
        _ = try await store.commitV2(cancel)
        XCTFail("injected")
      } catch let e as StoreError {
        XCTAssertEqual(e, fault == .beforeCommit ? .injectedFailure : .responseLost)
      }
      try await store.close()
      let reopened = try MatchStore(url: url)
      let before = try await reopened.pendingCaptureOperations(matchID: "match")
      XCTAssertEqual(before.count, fault == .beforeCommit ? 1 : 0)
      let first = try await reopened.commitV2(cancel)
      let again = try await reopened.commitV2(cancel)
      XCTAssertEqual(first, again)
      try await reopened.close()
    }
  }
  func testNoNegativeProofOrOtherActionNeverGetsExceptionAfterReopen() async throws {
    for action in [CaptureAction.finish, .pause, .resume, .recover] {
      let (url, store, cancel) = try await fixture(
        includeNegative: action != .finish, finishAction: action)
      do {
        _ = try await store.commitV2(cancel)
        XCTFail("no general uncertain-operation cancellation")
      } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
      try await store.close()
      let reopened = try MatchStore(url: url)
      let pending = try await reopened.pendingCaptureOperations(matchID: "match")
      XCTAssertTrue(
        pending.contains { $0.operation.id == "finish" && $0.state == .needsReconciliation })
      try await reopened.close()
    }
  }
  func injectHistoricalWindow(_ url: URL) throws {
    // Represents an older valid v2 history: unknown(actual window) then unknown(nil).
    // Rehash both canonical command and historical record, leaving current labels negative/nil.
    let raw = try SQLite(url: url, fault: nil)
    let row = try XCTUnwrap(
      raw.rows(
        "SELECT record FROM capture_operation_history WHERE operation_id='finish' AND command_id='unknown-finish'"
      ).first)
    let saved = try JSONDecoder().decode(CaptureOperationRecord.self, from: XCTUnwrap(row[0].data))
    let observation = try WorkoutObservation(
      operationID: "finish", binding: h.binding(), externalToken: "op1", observedAt: h.h.t,
      outcome: .unknown, window: CaptureWindow(start: h.h.t, end: nil))
    let record = try CaptureOperationRecord(
      operation: saved.operation, state: .needsReconciliation, observation: observation)
    let bytes = try Canonical.data(record)
    try raw.execute(
      "UPDATE capture_operation_history SET record=?,checksum=? WHERE operation_id='finish' AND command_id='unknown-finish'",
      [.blob(bytes), .text(Canonical.hash(bytes))])
    let command = try XCTUnwrap(
      raw.rows("SELECT request FROM commands_v2 WHERE command_id='unknown-finish'").first)
    let request = try JSONDecoder().decode(StoreCommitV2.self, from: XCTUnwrap(command[0].data))
    let updated = try StoreCommitV2(
      commandID: request.commandID, expectedGeneration: request.expectedGeneration,
      descriptor: request.descriptor, events: request.events,
      captureRevisions: request.captureRevisions,
      newCaptureOperations: request.newCaptureOperations,
      captureOperationUpdates: [
        CaptureOperationUpdate(
          operationID: "finish", expectedState: .needsReconciliation, state: .needsReconciliation,
          observation: observation)
      ], businessOutbox: request.businessOutbox)
    let data = try Canonical.data(updated)
    try raw.execute(
      "UPDATE commands_v2 SET request=?,request_hash=? WHERE command_id='unknown-finish'",
      [.blob(data), .text(Canonical.hash(data))])
    try raw.close()
  }
  func testPositiveEvidenceOnlyInHistoryBlocksCancellation() async throws {
    let (url, store, _) = try await fixture()
    _ = try await update(
      store, "later-unknown-finish", "finish", .needsReconciliation, .needsReconciliation, .unknown)
    let snapshot = try await store.snapshotV2(matchID: "match")
    let cancel = try h.request(
      "history-cancel", generation: snapshot.business.generation,
      descriptor: snapshot.business.descriptor,
      updates: [
        CaptureOperationUpdate(
          operationID: "finish", expectedState: .needsReconciliation, state: .cancelled,
          observation: nil)
      ])
    try await store.close()
    try injectHistoricalWindow(url)
    let reopened = try MatchStore(url: url)
    let current = try await reopened.snapshotV2(matchID: "match")
    XCTAssertNil(current.captureOperations.last?.observation?.window.start)
    do {
      _ = try await reopened.commitV2(cancel)
      XCTFail("current label cannot erase history")
    } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
    let diagnostics = try await reopened.diagnostics(matchID: "match")
    XCTAssertTrue(diagnostics.contains { $0.severity == .blocking && !$0.rawBytes.isEmpty })
    try await reopened.close()
  }
  func testAllReadAndRetryBoundariesRecheckHistoricalProof() async throws {
    for path in [
      "snapshot", "snapshotV2", "pending", "outbox", "packets", "lookup", "retry", "legacyRetry",
      "write",
    ] {
      let (url, store, cancel) = try await fixture()
      _ = try await store.commitV2(cancel)
      try await store.close()
      try injectHistoricalWindow(url)
      let reopened = try MatchStore(url: url)
      do {
        switch path {
        case "snapshot": _ = try await reopened.snapshot(matchID: "match")
        case "snapshotV2": _ = try await reopened.snapshotV2(matchID: "match")
        case "pending": _ = try await reopened.pendingCaptureOperations(matchID: "match")
        case "outbox": _ = try await reopened.pendingBusinessOutbox(matchID: "match")
        case "packets": _ = try await reopened.pendingPackets(matchID: "match")
        case "lookup": _ = try await reopened.committedCommandV2(commandID: "create-start")
        case "retry": _ = try await reopened.commitV2(cancel)
        case "legacyRetry":
          _ = try await reopened.commit(
            StoreCommit(
              commandID: "intent", expectedGeneration: 0, descriptor: h.h.descriptor(), events: [],
              packets: []))
        default:
          _ = try await reopened.commitV2(
            h.request(
              "later-write", generation: cancel.expectedGeneration + 1,
              descriptor: cancel.descriptor))
        }
        XCTFail("invalid proof escaped through \(path)")
      } catch {}
      let diagnostics = try await reopened.diagnostics(matchID: "match")
      XCTAssertTrue(diagnostics.contains { $0.severity == .blocking && !$0.rawBytes.isEmpty }, path)
      try await reopened.close()
    }
  }
  func testOriginalStartCanonicalCommandMustStillMatchPersistedFacts() async throws {
    let (url, store, cancel) = try await fixture()
    _ = try await store.commitV2(cancel)
    try await store.close()
    let raw = try SQLite(url: url, fault: nil)
    let row = try XCTUnwrap(
      raw.rows("SELECT request FROM commands_v2 WHERE command_id='create-start'").first)
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(row[0].data)) as? [String: Any])
    var descriptor = try XCTUnwrap(json["descriptor"] as? [String: Any])
    descriptor["starter"] = false
    json["descriptor"] = descriptor
    let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try raw.execute(
      "UPDATE commands_v2 SET request=?,request_hash=? WHERE command_id='create-start'",
      [.blob(bytes), .text(Canonical.hash(bytes))])
    try raw.close()
    let reopened = try MatchStore(url: url)
    do {
      _ = try await reopened.pendingCaptureOperations(matchID: "match")
      XCTFail("row label/hash alone is insufficient")
    } catch {}
    let diagnostics = try await reopened.diagnostics(matchID: "match")
    XCTAssertTrue(diagnostics.contains { $0.severity == .blocking })
    try await reopened.close()
  }

  func testLatePositiveEvidenceIsRetainedAndBlocksAbsenceProofBeforeAndAfterCancellation()
    async throws
  {
    let cases: [(WorkoutOutcome, CaptureOperationState, CaptureFailure?, Bool)] = [
      (.running, .failed, .captureFailed, false), (.paused, .failed, .captureFailed, false),
      (.stopped, .needsReconciliation, .captureFailed, false),
      (.savedAwaitingLink, .needsReconciliation, nil, false),
      (.linked(workoutID: "real-late-workout"), .settled, nil, false),
      (.unknown, .needsReconciliation, nil, true),
    ]
    for cancelled in [false, true] {
      for (outcome, state, failure, actualWindow) in cases {
        let (_, store, cancel) = try await fixture()
        if cancelled { _ = try await store.commitV2(cancel) }
        let snapshot = try await store.snapshotV2(matchID: "match")
        let observation = try WorkoutObservation(
          operationID: "finish", binding: h.binding(), externalToken: "op1",
          observedAt: h.h.t.addingTimeInterval(100), outcome: outcome,
          window: CaptureWindow(start: actualWindow ? h.h.t : nil, end: nil), failure: failure)
        let update = try CaptureOperationUpdate(
          operationID: "finish", expectedState: cancelled ? .cancelled : .needsReconciliation,
          state: state, observation: observation)
        do {
          _ = try await store.commitV2(
            h.request(
              "late-positive", generation: snapshot.business.generation,
              descriptor: snapshot.business.descriptor, updates: [update]))
          XCTFail("positive fact cannot be overwritten by absence")
        } catch let e as StoreError { XCTAssertEqual(e, .captureConflict) }
        let bytes = try Canonical.data(observation)
        let diagnostics = try await store.diagnostics(matchID: "match")
        XCTAssertTrue(diagnostics.contains { $0.rawBytes == bytes && $0.severity == .blocking })
        if cancelled {
          do {
            _ = try await store.pendingCaptureOperations(matchID: "match")
            XCTFail("late contradictory evidence must block empty pending feedback")
          } catch {}
          do {
            _ = try await store.commitV2(cancel)
            XCTFail("negative receipt proof is now contradictory")
          } catch {}
        } else {
          do {
            _ = try await store.commitV2(cancel)
            XCTFail("known contradiction blocks a later negative cancellation")
          } catch {}
        }
        try await store.close()
      }
    }
  }
  func testSegmentOrRecoveryRequestPreventsFreshAbsenceException() async throws {
    for evidence in ["segment", "recover"] {
      let (_, store, cancel) = try await fixture()
      let s = try await store.snapshotV2(matchID: "match")
      if evidence == "segment" {
        let segment = try CaptureSegment(
          id: "arbitrary-untrusted-token-name", binding: h.binding(), workoutID: "real-existing",
          window: CaptureWindow(start: nil, end: nil))
        _ = try await store.commitV2(
          h.request(
            "physical-segment", generation: s.business.generation,
            descriptor: s.business.descriptor, revisions: [h.revision(segments: [segment])],
            outboxID: "segment-delta"))
      } else {
        let recover = try CaptureOperation(
          id: "recover", binding: h.binding(), associatedCommandID: "recovery-request",
          action: .recover, requestedAt: h.h.t, externalToken: "op1")
        _ = try await store.commitV2(
          h.request(
            "recovery-request", generation: s.business.generation,
            descriptor: s.business.descriptor, operations: [recover]))
      }
      let latest = try await store.snapshotV2(matchID: "match")
      let request = try h.request(
        "cannot-cancel", generation: latest.business.generation, descriptor: cancel.descriptor,
        updates: cancel.captureOperationUpdates)
      do {
        _ = try await store.commitV2(request)
        XCTFail("fresh proof excludes \(evidence)")
      } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
      let pending = try await store.pendingCaptureOperations(matchID: "match")
      XCTAssertTrue(
        pending.contains { $0.operation.id == "finish" && $0.state == .needsReconciliation })
      try await store.close()
    }
  }
  func testWrongTokenAndBindingNeverSupplyNegativeProof() async throws {
    let (_, store, cancel) = try await fixture(includeNegative: false)
    let s = try await store.snapshotV2(matchID: "match")
    let otherStart = try CaptureOperation(
      id: "op2", binding: h.binding(), associatedCommandID: "other-start", action: .start,
      requestedAt: h.h.t, externalToken: "op2")
    _ = try await store.commitV2(
      h.request(
        "other-start", generation: s.business.generation, descriptor: s.business.descriptor,
        operations: [otherStart]))
    _ = try await update(store, "mark-op2", "op2", .pending, .needsReconciliation)
    _ = try await update(
      store, "absent-op2", "op2", .needsReconciliation, .failed, .notCreated(.unavailable))
    let latest = try await store.snapshotV2(matchID: "match")
    do {
      _ = try await store.commitV2(
        h.request(
          "wrong-token-cancel", generation: latest.business.generation,
          descriptor: cancel.descriptor, updates: cancel.captureOperationUpdates))
      XCTFail("another absent start is insufficient")
    } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
    for wrongBinding in [false, true] {
      let observation = try WorkoutObservation(
        operationID: "op1",
        binding: wrongBinding
          ? CaptureBinding(matchID: "wrong", recordingDeviceID: "phone") : h.binding(),
        externalToken: wrongBinding ? "op1" : "op2", observedAt: h.h.t,
        outcome: .notCreated(.unavailable), window: CaptureWindow(start: nil, end: nil))
      let u = try CaptureOperationUpdate(
        operationID: "op1", expectedState: .needsReconciliation, state: .failed,
        observation: observation)
      do {
        _ = try await store.commitV2(
          h.request(
            "wrong-proof-\(wrongBinding)", generation: latest.business.generation,
            descriptor: cancel.descriptor, updates: [u]))
        XCTFail("wrong binding/token")
      } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
    }
    try await store.close()
  }

}
