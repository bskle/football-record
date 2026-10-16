import Foundation
import MatchCore
import XCTest

@testable import MatchStore

final class CaptureCancellationTests: XCTestCase, @unchecked Sendable {
  let h = CaptureTransactionTests()
  func testCancelledIsTerminalAndExcludedAfterReopenWithOriginalReceiptValid() async throws {
    let url = h.h.path()
    try await h.h.prepare(url)
    let store = try MatchStore(url: url)
    let create = try h.request(
      "create", generation: 1, descriptor: h.h.descriptor(),
      operations: [h.operation(command: "create")])
    let receipt = try await store.commitV2(create)
    let update = try CaptureOperationUpdate(
      operationID: "op1", expectedState: .pending, state: .cancelled, observation: nil)
    let cancel = try h.request(
      "cancel", generation: 2, descriptor: h.h.descriptor(), updates: [update])
    let cancelled = try await store.commitV2(cancel)
    try await store.close()
    let reopened = try MatchStore(url: url)
    let pending = try await reopened.pendingCaptureOperations(matchID: "match")
    XCTAssertTrue(pending.isEmpty)
    let first = try await reopened.commitV2(create)
    XCTAssertEqual(first, receipt)
    let second = try await reopened.commitV2(cancel)
    XCTAssertEqual(second, cancelled)
    let marker = try CaptureOperationUpdate(
      operationID: "op1", expectedState: .cancelled, state: .needsReconciliation, observation: nil)
    do {
      _ = try await reopened.commitV2(
        h.request("bad", generation: 3, descriptor: h.h.descriptor(), updates: [marker]))
      XCTFail("terminal cancellation")
    } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
    try await reopened.close()
  }
  func testMarkerWinningCASCannotBeCancelled() async throws {
    let url = h.h.path()
    try await h.h.prepare(url)
    let store = try MatchStore(url: url)
    _ = try await store.commitV2(
      h.request(
        "create", generation: 1, descriptor: h.h.descriptor(),
        operations: [h.operation(command: "create")]))
    let marker = try CaptureOperationUpdate(
      operationID: "op1", expectedState: .pending, state: .needsReconciliation, observation: nil)
    _ = try await store.commitV2(
      h.request("mark", generation: 2, descriptor: h.h.descriptor(), updates: [marker]))
    let cancel = try CaptureOperationUpdate(
      operationID: "op1", expectedState: .needsReconciliation, state: .cancelled, observation: nil)
    do {
      _ = try await store.commitV2(
        h.request("cancel", generation: 3, descriptor: h.h.descriptor(), updates: [cancel]))
      XCTFail("cannot erase uncertain effect")
    } catch let e as StoreError { XCTAssertEqual(e, .invalidOperationTransition) }
    let pending = try await store.pendingCaptureOperations(matchID: "match")
    XCTAssertEqual(pending.first?.state, .needsReconciliation)
    try await store.close()
  }
  func testCancellationCommitFailureAndLostResponsePreserveTruth() async throws {
    for fault in [StoreFault.beforeCommit, .afterCommit] {
      let url = h.h.path()
      try await h.h.prepare(url)
      let initial = try MatchStore(url: url)
      _ = try await initial.commitV2(
        h.request(
          "create", generation: 1, descriptor: h.h.descriptor(),
          operations: [h.operation(command: "create")]))
      try await initial.close()
      let store = try MatchStore(url: url, fault: fault)
      let update = try CaptureOperationUpdate(
        operationID: "op1", expectedState: .pending, state: .cancelled, observation: nil)
      let cancel = try h.request(
        "cancel", generation: 2, descriptor: h.h.descriptor(), updates: [update])
      do {
        _ = try await store.commitV2(cancel)
        XCTFail("injected")
      } catch {}
      try await store.close()
      let reopened = try MatchStore(url: url)
      let pending = try await reopened.pendingCaptureOperations(matchID: "match")
      XCTAssertEqual(pending.count, fault == .beforeCommit ? 1 : 0)
      _ = try await reopened.commitV2(cancel)
      try await reopened.close()
    }
  }
}
