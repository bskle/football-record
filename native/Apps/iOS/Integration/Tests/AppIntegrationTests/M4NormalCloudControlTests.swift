#if DEBUG && os(macOS)
import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import AccountKit
import CloudSync
import MatchPresentation
@testable import AppIntegration

@MainActor final class M4NormalCloudControlTests: XCTestCase {
  // Evaluate actor/SQL reads before entering XCTest's synchronous autoclosures.
  private func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, message, file: file, line: line) }
  private func notEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotEqual(a, b, message, file: file, line: line) }
  private func isTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, message, file: file, line: line) }
  private func isFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, message, file: file, line: line) }
  private func isNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, message, file: file, line: line) }
  private func notNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(value, message, file: file, line: line) }
  private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

  private func noTerminationWithOriginalAcquire(_ queue: [ControlQueueEntryV4], file: StaticString = #filePath, line: UInt = #line) {
    isTrue(queue.contains { $0.intent.operation == .acquire && $0.state == .confirmed }, "retain the actual original confirmed acquire history", file: file, line: line)
    isFalse(queue.contains { $0.intent.operation == .terminate }, "no normal or abnormal replacement may be prepared", file: file, line: line)
  }
  private func withFixture(_ body: @MainActor (M4HTTPFixtureHarness) async throws -> Void) async throws {
    let f = try await M4HTTPFixtureHarness.start()
    do { try await body(f) } catch { await cleanup(f); throw error }
    await cleanup(f)
  }
  private func cleanup(_ f: M4HTTPFixtureHarness) async {
    let r = await f.close()
    isTrue(r.ownerClosed && r.requestsJoined && r.workerJoined && r.process.exited && r.process.readersJoined && r.process.closeAcknowledged)
    equal(r.process.status, 0); isFalse(FileManager.default.fileExists(atPath: f.root.path))
    print("S2 cleanup nodePID=\(r.process.pid) status=\(r.process.status) owner=\(r.ownerClosed) requests=\(r.requestsJoined) worker=\(r.workerJoined) readers=\(r.process.readersJoined) closeAck=\(r.process.closeAcknowledged)")
  }
  private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while ContinuousClock.now < deadline { if try await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw M4HTTPFixtureError.timeout
  }
  private func ended(_ context: AccountAppContext) async throws -> String {
    await context.recording.start(starter: true)
    let id = try unwrap(context.recording.snapshot?.replay.matchID)
    try await wait { let s = try await context.repository.snapshotV2(matchID: id); return s.captureOperations.contains { $0.operation.action == .start && $0.state == .settled } }
    await context.recording.perform(.end)
    try await wait { let s = try await context.repository.snapshotV2(matchID: id); return s.captureOperations.contains { $0.operation.action == .finish && $0.state == .settled } }
    equal(context.recording.snapshot?.replay.state, .endedPendingSync)
    return id
  }
  func testOriginalStrictModelNormalControlReleasesOnlyAfterCloudSave() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      _ = try await f.signIn(); isTrue(c.context.account.canEnterRecording)
      let id = try await self.ended(c.context)
      _ = try await f.refreshIdentity()
      await c.context.lifecycle.perform(.synchronize(id), matchID: id)
      let saved = try await c.repository.matchingCloudSaveV4(matchID: id)
      notNil(saved, "normal path must actually save/read back the complete original facts")
      try await self.wait { c.context.recording.snapshot?.replay.state == .completed }
      isTrue(c.context.recording.canStartNext)
    }
  }
  func testPublicWrapperSaveOnlyThenNormalNextHeldUsesOriginalFullFacts() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(workout: M4HTTPWorkoutGateway()), c = wrapper.context
      _ = try await f.signIn(); let id = try await self.ended(c)
      let originalIdentity = await c.repository.syncRepositoryIdentity()
      _ = try await f.refreshIdentity(); await c.lifecycle.perform(.saveCloudOnly(id), matchID: id)
      let saved = try await c.repository.matchingCloudSaveV4(matchID: id), held = try await c.repository.authorityStateV4(matchID: id, now: Date())
      notNil(saved); equal(held.status, .held); isNil(held.verifiedNormalRelease)
      equal(c.recording.snapshot?.replay.state, .endedPendingSync); isFalse(c.recording.canStartNext)
      equal(f.cloudSaveCalls, 1)
      let upload = try unwrap(f.cloudUploads.values.first)
      guard case .matchFacts(let facts) = try upload.record.payload else { return XCTFail("original complete facts required") }
      isFalse(facts.captureRevisions.isEmpty)
      _ = try await f.refreshIdentity(); await c.lifecycle.perform(.synchronize(id), matchID: id)
      try await self.wait { c.recording.snapshot?.replay.state == .completed }
      isNil(c.lifecycle.issue); isTrue(c.recording.canStartNext); equal(f.cloudSaveCalls, 1)
      let queue = try await c.repository.controlQueueV4().filter { $0.intent.operation == .terminate }
      equal(queue.count, 1); equal(queue.first?.intent.fields.mode, "normal")
      let release = try unwrap(try await c.repository.authorityStateV4(matchID: id, now: Date()).verifiedNormalRelease)
      equal(release.body.requestID, queue.first?.intent.requestID)
      await c.recording.start(starter: false)
      let next = try unwrap(c.recording.snapshot?.replay.matchID); notEqual(next, id)
      equal(try await c.repository.authorityStateV4(matchID: next, now: Date()).status, .held)
      equal(await c.session.syncRepositoryIdentity(), originalIdentity)
    }
  }
  func testCommittedNormalResponseLossReopensOriginalFilesAndRetriesOriginalIntent() async throws {
    try await withFixture { f in
      let gateway = M4HTTPWorkoutGateway(), wrapper = try await f.bootstrap(workout: gateway), c = wrapper.context
      _ = try await f.signIn(); let id = try await self.ended(c)
      let binding = try await c.repository.accountBindingV4(), auth = try await c.repository.currentAuthRequestIDV4()
      let native = f.nativeRoot.appendingPathComponent(f.configuration.namespace)
      let names = ["device.identity", "development.key", "authority.fixture", "development.vault"]
      let original = try names.map { name in try M4HTTPFixtureHarness.read(native.appendingPathComponent(name)) }
      let database = try M4HTTPFixtureHarness.anchor(native.appendingPathComponent("matches.sqlite"))
      _ = try await f.cli.command("fault", fields: ["name": "dropResponseAfterOperation", "value": "terminate"])
      _ = try await f.refreshIdentity(); await c.lifecycle.perform(.synchronize(id), matchID: id)
      let pending = try unwrap(try await c.repository.controlQueueV4().first { $0.intent.operation == .terminate })
      notEqual(pending.state, .confirmed); equal(pending.intent.fields.mode, "normal")
      isNil(try await c.repository.authorityStateV4(matchID: id, now: Date()).verifiedNormalRelease)
      _ = try await f.cli.command("fault", fields: ["name": "dropResponseAfterOperation", "value": NSNull()])
      let reopened = try await f.reopen(workout: gateway), next = reopened.context
      for (index, name) in names.enumerated() {
        let current = try M4HTTPFixtureHarness.read(native.appendingPathComponent(name))
        equal(current.0, original[index].0); equal(current.1, original[index].1)
      }
      equal(try M4HTTPFixtureHarness.anchor(native.appendingPathComponent("matches.sqlite")), database)
      equal(try await next.repository.accountBindingV4(), binding); equal(try await next.repository.currentAuthRequestIDV4(), auth)
      try await self.wait { pending.nextAttemptAt.map { $0 <= Date() } ?? true }
      _ = try await f.refreshIdentity(); await next.lifecycle.perform(.retryControls, matchID: id)
      try await self.wait { next.recording.snapshot?.replay.state == .completed }
      let queue = try await next.repository.controlQueueV4().filter { $0.intent.operation == .terminate }
      equal(queue.count, 1); equal(queue[0].intent, pending.intent); equal(queue[0].state, .confirmed)
      equal(f.replies, 2, "one Apple reply plus one cloud save; reopen/retry never signs in again")
      isTrue(next.recording.canStartNext)
    }
  }
  func testOldNormalReplayCannotReleaseNextRealHeldLock() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      _ = try await f.signIn(); let id = try await self.ended(c.context)
      _ = try await f.refreshIdentity(); await c.context.lifecycle.perform(.synchronize(id), matchID: id)
      try await self.wait { c.context.recording.snapshot?.replay.state == .completed }
      let original = try unwrap(try await c.repository.controlQueueV4().first { $0.intent.operation == .terminate }).intent
      let first = try unwrap(try await c.repository.authorityStateV4(matchID: id, now: Date()).verifiedNormalRelease)
      await c.context.recording.start(starter: false)
      let next = try unwrap(c.context.recording.snapshot?.replay.matchID), state = try await c.repository.authorityStateV4(matchID: next, now: Date())
      let acquire = try unwrap(state.acquire)
      let replay = try await c.client.send(original); equal(replay, first.raw)
      let verified = try VerifiedAuthorityReceiptV1.verify(replay, expected: AuthorityExpectedIntent(original, accountID: first.body.accountID, epoch: first.body.activationEpoch), trust: c.client.trust)
      _ = try await c.session.acceptAuthorityResult(verified)
      let query = try LiveLockQueryV1(requestID: UUID().uuidString, acquireRequestID: acquire.body.requestID, matchID: next, lockID: acquire.body.lockID, recordingDeviceID: acquire.body.recordingDeviceID, activationEpoch: acquire.body.activationEpoch, nonce: UUID().uuidString)
      let live = try await c.client.liveStatus(query, accountID: acquire.body.accountID)
      equal(live.body.status, .held); try await c.session.acceptLiveLock(live)
      let retained = try await c.repository.authorityStateV4(matchID: next, now: Date())
      equal(retained.status, .held); equal(retained.acquire?.raw, acquire.raw); isNil(retained.verifiedNormalRelease)
      equal(c.context.recording.snapshot?.replay.matchID, next); isFalse(c.context.recording.canStartNext)
    }
  }
  func testIncompleteAndChangedReadbackRetainOriginalPendingUploadWithoutLoopOrNormal() async throws {
    for mode in ["truncated", "changed"] {
      try await withFixture { f in
        let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
        _ = try await f.signIn(); let id = try await self.ended(c.context), handle = try await f.originalResources(c)
        f.corruptReadback = mode; _ = try await f.refreshIdentity()
        await c.context.lifecycle.perform(.synchronize(id), matchID: id)
        let before = try await handle.ledger.uploads(scope: handle.scope)
        equal(before.count, 1); notEqual(before[0].state, .confirmed)
        isTrue(try await handle.ledger.saveEvidence(scope: handle.scope).isEmpty)
        isNil(try await c.repository.matchingCloudSaveV4(matchID: id)); noTerminationWithOriginalAcquire(try await c.repository.controlQueueV4())
        equal(f.cloudSaveCalls, 1); f.corruptReadback = nil
        _ = try await f.refreshIdentity(); await c.context.lifecycle.perform(.synchronize(id), matchID: id)
        let after = try await handle.ledger.uploads(scope: handle.scope)
        equal(after[0].upload, before[0].upload); equal(after[0].originalBytes, before[0].originalBytes)
        equal(f.cloudSaveCalls, 1, "future retry must return after one unit, never loop to a save")
        equal(c.context.recording.snapshot?.replay.state, .endedPendingSync); isFalse(c.context.recording.canStartNext)
      }
    }
  }
  func testPendingBatchUnitWithoutTargetEvidenceDoesNotNormalUntilNextAction() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      _ = try await f.signIn(); let id = try await self.ended(c.context), h = try await f.originalResources(c)
      let cursor = try await c.cloudBridge.appliedCursor(scope: h.scope)
      try await h.ledger.stage(CloudFetchBatch(scope: h.scope, batchID: UUID().uuidString, records: [], expectedAppliedToken: cursor.appliedToken, nextToken: Data("first-empty-batch".utf8), fetchGeneration: cursor.fetchGeneration, moreComing: false))
      _ = try await f.refreshIdentity(); await c.context.lifecycle.perform(.synchronize(id), matchID: id)
      equal(f.cloudSaveCalls, 0); isNil(try await c.repository.matchingCloudSaveV4(matchID: id))
      noTerminationWithOriginalAcquire(try await c.repository.controlQueueV4())
      equal(try await h.ledger.batches(scope: h.scope).first?.state, .confirmed)
      let original = try unwrap(try await h.ledger.uploads(scope: h.scope).first)
      _ = try await f.refreshIdentity(); await c.context.lifecycle.perform(.synchronize(id), matchID: id)
      try await self.wait { c.context.recording.snapshot?.replay.state == .completed }
      equal(f.cloudSaveCalls, 1); equal(try await h.ledger.uploads(scope: h.scope).first?.originalBytes, original.originalBytes)
    }
  }
  func testHeldFinishCannotPublishIncompleteUploadOrNormal() async throws {
    try await withFixture { f in
      let gateway = M4HTTPWorkoutGateway(), wrapper = try await f.bootstrap(workout: gateway), c = wrapper.context
      _ = try await f.signIn(); await c.recording.start(starter: true)
      let id = try unwrap(c.recording.snapshot?.replay.matchID)
      try await self.wait { try await c.repository.snapshotV2(matchID: id).captureOperations.contains { $0.operation.action == .start && $0.state == .settled } }
      await gateway.setHoldFinish(true); await c.recording.perform(.end)
      try await self.wait { await gateway.finishEntered }
      _ = try await f.refreshIdentity(); await c.lifecycle.perform(.synchronize(id), matchID: id)
      equal(f.cloudSaveCalls, 0); noTerminationWithOriginalAcquire(try await c.repository.controlQueueV4())
      await gateway.setHoldFinish(false)
      try await self.wait { try await c.repository.snapshotV2(matchID: id).captureOperations.allSatisfy { [.settled, .failed, .cancelled].contains($0.state) } }
      _ = try await f.refreshIdentity(); await c.lifecycle.perform(.synchronize(id), matchID: id)
      try await self.wait { c.recording.snapshot?.replay.state == .completed }
    }
  }
  func testFourIndependentChangesAfterCloudWaitBlockBusinessAcceptance() async throws {
    for field in ["account", "cloud", "zone", "environment"] {
      try await withFixture { f in
        let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
        _ = try await f.signIn(); let id = try await self.ended(c.context), h = try await f.originalResources(c)
        let generation = try await c.repository.identityGenerationV4()
        f.holdCloudReplies = true; _ = try await f.refreshIdentity()
        let action = try f.beginLifecycle(.synchronize(id), matchID: id); try await f.waitUntil { f.cloudHeld }
        try await f.changeIndependentField(field); f.holdCloudReplies = false; await action.value
        equal(try await c.repository.identityGenerationV4(), generation)
        isNil(try await c.repository.matchingCloudSaveV4(matchID: id)); noTerminationWithOriginalAcquire(try await c.repository.controlQueueV4())
        isFalse(c.context.account.canEnterRecording); isFalse(c.context.recording.canStartNext)
        // A transport confirmation may legally persist before the business gate;
        // it is not a Store checkpoint, normal receipt or completed publication.
        equal(try await h.ledger.uploads(scope: h.scope).count, 1)
      }
    }
  }
  func testUnreadableAndMalformedIdentityAfterCloudWaitClearAdmission() async throws {
    for mode in ["unreadable", "malformed"] {
      try await withFixture { f in
        let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
        _ = try await f.signIn(); let id = try await self.ended(c.context), h = try await f.originalResources(c)
        let generation = try await c.repository.identityGenerationV4(), binding = try await c.repository.accountBindingV4()
        let authentication = try await c.repository.currentAuthRequestIDV4(), repositoryIdentity = await c.repository.syncRepositoryIdentity()
        let queue = try await c.repository.controlQueueV4()
        isTrue(c.context.account.canEnterRecording); notNil(c.admittedScope)
        f.holdCloudReplies = true; _ = try await f.refreshIdentity()
        let action = f.beginOriginalLifecycle(.synchronize(id), composition: c)
        try await f.waitUntil { f.cloudHeld }
        let original = try unwrap(try await h.ledger.uploads(scope: h.scope).first)
        try f.damageIndependentIdentitySource(mode); f.holdCloudReplies = false
        let failure = try unwrap(await action.value)
        if mode == "unreadable" { isTrue(failure as? AuthorityError == .unavailable, "preserve the original independent-source unavailable error") }
        else { isTrue(failure is DecodingError, "preserve the original independent-source decoding error") }
        isTrue(c.admittedScope == nil, "failed independent observation must clear the old admission: " + mode)
        isFalse(c.context.account.canEnterRecording, "failed independent observation must clear the old ready projection: " + mode)
        isFalse(c.context.recording.canStartNext)
        equal(c.context.recording.snapshot?.replay.state, .endedPendingSync)
        equal(try await c.repository.identityGenerationV4(), generation)
        let retainedBinding = try await c.repository.accountBindingV4()
        isTrue(try AuthorityWire.encode(retainedBinding) == AuthorityWire.encode(binding))
        equal(try await c.repository.currentAuthRequestIDV4(), authentication)
        equal(await c.repository.syncRepositoryIdentity(), repositoryIdentity)
        equal(await c.session.syncRepositoryIdentity(), repositoryIdentity)
        isNil(try await c.repository.matchingCloudSaveV4(matchID: id))
        let retained = try await c.repository.controlQueueV4()
        isTrue(retained == queue, "preserve the original control history without a replacement intent")
        noTerminationWithOriginalAcquire(retained)
        let uploads = try await h.ledger.uploads(scope: h.scope)
        equal(uploads.count, 1)
        isTrue(uploads.first?.upload == original.upload); isTrue(uploads.first?.originalBytes == original.originalBytes)
        equal(f.cloudSaveCalls, 1)
      }
    }
  }
  func testIdentityChangeAfterActualNormalHTTPKeepsOriginalUnknownBeforeAcceptance() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway(), holdTerminate: true)
      let gate = try unwrap(f.authorityGate)
      _ = try await f.signIn(); let id = try await self.ended(c.context), generation = try await c.repository.identityGenerationV4()
      _ = try await f.refreshIdentity(); let action = try f.beginLifecycle(.synchronize(id), matchID: id)
      try await self.wait { await gate.entered }
      let before = try unwrap(try await c.repository.controlQueueV4().first { $0.intent.operation == .terminate })
      _ = try await f.refreshIdentity("alternate"); await gate.release(); await action.value
      equal(try await c.repository.identityGenerationV4(), generation)
      isNil(try await c.repository.authorityStateV4(matchID: id, now: Date()).verifiedNormalRelease)
      let after = try unwrap(try await c.repository.controlQueueV4().first { $0.intent.operation == .terminate })
      equal(after.intent, before.intent); notEqual(after.state, .confirmed)
      isFalse(c.context.account.canEnterRecording); equal(c.context.recording.snapshot?.replay.state, .endedPendingSync)
      isFalse(c.context.recording.canStartNext)
    }
  }
  func testCloseJoinsHeldNormalHTTPAndSuppressesLateCompletedPublication() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway(), holdTerminate: true)
      let gate = try unwrap(f.authorityGate)
      _ = try await f.signIn(); let id = try await self.ended(c.context)
      _ = try await f.refreshIdentity(); let action = try f.beginLifecycle(.synchronize(id), matchID: id)
      try await self.wait { await gate.entered }
      var began = false, closed = false; let close = Task { began = true; try await c.close(); closed = true }
      try await self.wait { began && c.context.recording.snapshot == nil }
      isFalse(closed, "owner entered retirement but cannot return while original HTTP borrower is held")
      await gate.release(); try await close.value; await action.value
      isNil(c.context.recording.snapshot); isFalse(c.context.account.canEnterRecording)
      isFalse(c.context.recording.canStartNext)
    }
  }
  func testCloseCancelsOriginalCloudWaitAndSuppressesLateMailboxReply() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(workout: M4HTTPWorkoutGateway()), c = wrapper.context
      _ = try await f.signIn(); let id = try await self.ended(c)
      f.holdCloudReplies = true; _ = try await f.refreshIdentity(); let action = try f.beginLifecycle(.synchronize(id), matchID: id)
      try await f.waitUntil { f.cloudHeld }; try await wrapper.shutdown(); await action.value
      f.holdCloudReplies = false; try await f.waitUntil { f.suppressed == 1 }
      isNil(c.recording.snapshot); isFalse(c.account.canEnterRecording)
      isTrue(try FileManager.default.contentsOfDirectory(atPath: f.nativeRoot.appendingPathComponent("development/mailbox/responses").path).isEmpty)
    }
  }

}
#endif
