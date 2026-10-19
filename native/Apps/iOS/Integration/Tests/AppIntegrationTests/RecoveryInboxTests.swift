import XCTest
@testable import AppIntegration

@MainActor final class RecoveryInboxTests: XCTestCase {
  func testDetachCancelsAndJoinsOldWorkerAndDropsPending() async {
    let inbox = RecoveryInbox(), gate = RecoverySuspension()
    var oldCalls = 0, newCalls = 0, cancelled = false, began = false, joined = false
    inbox.attach(isReady: { true }, recover: { oldCalls += 1; await gate.hold(); cancelled = Task.isCancelled })
    inbox.request(); await gate.waitForEntry(); inbox.request()
    let detach = Task { began = true; await inbox.detach(); joined = true }
    await spin { began }
    XCTAssertFalse(joined, "detach must join work even if recovery ignores cancellation until released")
    inbox.request()
    XCTAssertFalse(inbox.attach(isReady: { true }, recover: { newCalls += 1 }), "replacement cannot attach during old-worker join")
    await gate.release(); await detach.value
    XCTAssertTrue(cancelled); XCTAssertEqual(oldCalls, 1)
    XCTAssertTrue(inbox.attach(isReady: { true }, recover: { newCalls += 1 }))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(newCalls, 0, "signals owned by the detached context cannot reach its replacement")
    inbox.request(); await spin { newCalls == 1 }; XCTAssertEqual(newCalls, 1)
    await inbox.detach()
  }
  func testAttachCannotReplaceInFlightRecoveryWithoutDetach() async {
    let inbox = RecoveryInbox(), gate = RecoverySuspension()
    var original = 0, replacement = 0
    inbox.attach(isReady: { true }, recover: { original += 1; if original == 1 { await gate.hold() } })
    inbox.request(); await gate.waitForEntry()
    XCTAssertFalse(inbox.attach(isReady: { true }, recover: { replacement += 1 }))
    inbox.request(); await gate.release(); await spin { original == 2 || replacement != 0 }
    XCTAssertEqual(original, 2); XCTAssertEqual(replacement, 0)
    await inbox.detach()
  }
  func testConcurrentDetachWaitersJoinSameOldWorker() async {
    let inbox = RecoveryInbox(), gate = RecoverySuspension()
    var starts = 0, finishes = 0
    inbox.attach(isReady: { true }, recover: { await gate.hold() })
    inbox.request(); await gate.waitForEntry()
    let first = Task { starts += 1; await inbox.detach(); finishes += 1 }
    let second = Task { starts += 1; await inbox.detach(); finishes += 1 }
    await spin { starts == 2 }; XCTAssertEqual(finishes, 0)
    await gate.release(); await first.value; await second.value
    XCTAssertEqual(finishes, 2)
    XCTAssertTrue(inbox.attach(isReady: { true }, recover: {}))
    await inbox.detach()
  }
  func testDetachWhileWaitingForReadinessDropsOldSignal() async {
    let inbox = RecoveryInbox(); var ready = false, calls = 0
    inbox.attach(isReady: { ready }, recover: { calls += 1 })
    inbox.request(); await Task.yield(); await inbox.detach()
    ready = true
    XCTAssertTrue(inbox.attach(isReady: { true }, recover: { calls += 1 }))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(calls, 0)
    inbox.request(); await spin { calls == 1 }; XCTAssertEqual(calls, 1)
    await inbox.detach()
  }
  private func spin(_ predicate: () -> Bool) async {
    for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
    XCTFail("expected bounded actor progress")
  }
}

private actor RecoverySuspension {
  private var entered = false
  private var holdContinuation: CheckedContinuation<Void, Never>?
  private var entryContinuation: CheckedContinuation<Void, Never>?
  func hold() async {
    await withCheckedContinuation { continuation in
      holdContinuation = continuation; entered = true
      entryContinuation?.resume(); entryContinuation = nil
    }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entryContinuation = $0 }
  }
  func release() { holdContinuation?.resume(); holdContinuation = nil }
}
