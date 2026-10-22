#if DEBUG && os(macOS)
import Foundation
import XCTest
import AccountKit
import MatchCore
import MatchStore
import MatchPresentation
import CloudSync
@testable import AppIntegration

@MainActor final class M4ManagedDeletionOwnerTests: XCTestCase {
  private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw M4HTTPFixtureError.timeout
  }
  private func cleanup(_ f: M4HTTPFixtureHarness) async {
    let r = await f.close()
    XCTAssertTrue(r.ownerClosed && r.workerJoined && r.requestsJoined)
    XCTAssertTrue(r.process.exited && r.process.readersJoined && r.process.closeAcknowledged)
    XCTAssertEqual(r.process.status, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
    print("F1 cleanup nodePID=\(r.process.pid) status=\(r.process.status) owner=\(r.ownerClosed) requests=\(r.requestsJoined) worker=\(r.workerJoined) readers=\(r.process.readersJoined) closeAck=\(r.process.closeAcknowledged)")
  }
  private func withFixture(_ body: @MainActor (M4HTTPFixtureHarness) async throws -> Void) async throws {
    let f = try await M4HTTPFixtureHarness.start()
    do { try await body(f) } catch { await cleanup(f); throw error }
    await cleanup(f)
  }
  private func normalCompleted(_ context: AccountAppContext, fixture f: M4HTTPFixtureHarness) async throws -> String {
    await context.recording.start(starter: true)
    let id = try XCTUnwrap(context.recording.snapshot?.replay.matchID)
    try await wait {
      let s = try await context.repository.snapshotV2(matchID: id)
      return s.captureOperations.contains { $0.operation.action == .start && $0.state == .settled }
    }
    await context.recording.perform(.end)
    try await wait {
      let s = try await context.repository.snapshotV2(matchID: id)
      return s.captureOperations.contains { $0.operation.action == .finish && $0.state == .settled }
    }
    _ = try await f.refreshIdentity()
    await context.lifecycle.perform(.synchronize(id), matchID: id)
    try await wait { context.recording.snapshot?.replay.state == .completed }
    let saved = try await context.repository.matchingCloudSaveV4(matchID: id)
    XCTAssertNotNil(saved)
    return id
  }
  func testFirstPhoneWithoutActualReauthenticationRefusesManagedCreationBeforeRetirement() async throws {
    try await withFixture { f in
      _ = try await f.cli.command("revoker")
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      _ = try await f.signIn()
      print("Task3 signed-in ready=\(c.context.account.canEnterRecording) reauthPresent=\(c.reauthenticationID != nil)")
      _ = try await self.normalCompleted(c.context, fixture: f)
      _ = try await f.refreshIdentity()
      let controller = try c.managedDeletionController()
      var stages = 0
      controller.observation = { _ in stages += 1 }
      XCTAssertTrue(try c.managedDeletionController() === controller)
      let parent = "managed-original-parent", confirmedAt = Int64(Date().timeIntervalSince1970)
      XCTAssertTrue(c.reauthenticationID == nil)
      let binding = try await c.repository.accountBindingV4()
      let auth = try await c.repository.currentAuthRequestIDV4()
      let replies = f.replies
      do { _ = try await controller.create(requestID: parent, confirmedAt: confirmedAt); XCTFail("missing actual auth value cannot become deletion authority") }
      catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
      let sagas = try await c.repository.deletionSagasV4()
      let afterBinding = try await c.repository.accountBindingV4()
      let afterAuth = try await c.repository.currentAuthRequestIDV4()
      XCTAssertTrue(sagas.isEmpty); XCTAssertEqual(stages, 0)
      XCTAssertTrue(afterBinding == binding); XCTAssertTrue(afterAuth == auth)
      XCTAssertEqual(f.replies, replies)
      XCTAssertTrue(c.context.account.canEnterRecording)
      do { _ = try controller.snapshot(); XCTFail("refusal must not reserve or bind a catalog") }
      catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    }
  }
  func testManagedFactoryStronglyRetainsSameControllerUntilSuccessfulOriginalClose() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      var borrowed: M4DeletionResumeController? = try c.managedDeletionController()
      weak let probe = borrowed
      borrowed = nil
      XCTAssertNotNil(probe)
      XCTAssertTrue(try c.managedDeletionController() === probe)
      try await c.close()
      XCTAssertNil(probe)
    }
  }
  func testFailedFinalCloseRetainsSameStoppedManagedControllerForOriginalCloseRetry() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      var borrowed: M4DeletionResumeController? = try c.managedDeletionController()
      weak let probe = borrowed
      borrowed = nil
      try await c.quiesceBusiness()
      let file = f.nativeRoot.appendingPathComponent("development/mailbox/incoming/task3-owned-close-veto")
      let bytes = Data([14, 2, 9]); try bytes.write(to: file)
      do { try await c.close(); XCTFail("undrained original adapter must preserve the same owner") }
      catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
      XCTAssertNotNil(probe)
      XCTAssertTrue(try c.managedDeletionController() === probe)
      let retained = try await c.repository.deletionSagasV4(); XCTAssertTrue(retained.isEmpty)
      do { _ = try await probe?.create(requestID: "after-failed-final-close", confirmedAt: 1); XCTFail("failed final close does not reopen stopped control") }
      catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      guard try Data(contentsOf: file) == bytes else { throw M4HTTPFixtureError.mailboxChanged }
      try FileManager.default.removeItem(at: file)
      try await c.close(); XCTAssertNil(probe)
    }
  }
  func testManagedResumeWithoutOriginalSagaNeverBindsOrCreatesParent() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      let controller = try c.managedDeletionController()
      do { _ = try await controller.resume(requestID: "unknown-original-parent"); XCTFail("unknown is not permission to create") }
      catch { XCTAssertEqual(error as? LifecycleClientError, .unknownOriginal) }
      let sagas = try await c.repository.deletionSagasV4(); XCTAssertTrue(sagas.isEmpty)
      do { _ = try controller.snapshot(); XCTFail("unknown resume has no original borrow") }
      catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    }
  }
  func testFoundationPublicDeleteRemainsUnsupportedAndPreservesOriginalFacts() async throws {
  try await withFixture { f in
    _ = try await f.cli.command("revoker")
    let wrapper = try await f.bootstrap(workout: M4HTTPWorkoutGateway())
    _ = try await f.signIn()
    let c = wrapper.context
    let id = try await self.normalCompleted(c, fixture: f)
    let before = try await c.repository.snapshotV2(matchID: id)
    let binding = try await c.repository.accountBindingV4()
    let currentAuth = try await c.repository.currentAuthRequestIDV4()
    _ = try await f.refreshIdentity()
    await c.lifecycle.perform(.delete(cloud: .keep, local: .delete, health: .keep, healthConfirmed: false))
    let sagas = try await c.repository.deletionSagasV4()
    let after = try await c.repository.snapshotV2(matchID: id)
    let retainedBinding = try await c.repository.accountBindingV4()
    let retainedAuth = try await c.repository.currentAuthRequestIDV4()
    XCTAssertTrue(sagas.isEmpty)
    XCTAssertNotNil(c.lifecycle.issue)
    XCTAssertEqual(after.business.events, before.business.events)
    XCTAssertEqual(after.business.generation, before.business.generation)
    XCTAssertEqual(after.captureRevisions, before.captureRevisions)
    XCTAssertEqual(after.captureOperations, before.captureOperations)
    XCTAssertEqual(retainedBinding, binding)
    XCTAssertEqual(retainedAuth, currentAuth)
    XCTAssertEqual(c.recording.snapshot?.replay.state, .completed)
  }
}
}
#endif
