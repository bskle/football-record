import Foundation
import XCTest
import MatchCore
import CloudSync
import MatchStore
import MatchSession
@testable import MatchPresentation

@MainActor final class LifecycleStatusTests: XCTestCase {
  func testLateActionCannotReobserveAnOldRealMatchOrPublishItsFailure() async throws {
    for fails in [false, true] {
      let (repo, a, b) = try await twoStoredMatches()
      let entered = expectation(description: "Old action entered")
      let gate = LifecycleActionGate(entered)
      let model = LifecycleStatusModel(repository: repo, development: true, action: { _ in
        await gate.hold()
        if fails { throw AuthorityError.unavailable }
      })
      await model.refresh(matchID: a)
      let old = Task { await model.perform(.retryControls, matchID: a) }
      await fulfillment(of: [entered], timeout: 2)
      await model.refresh(matchID: b)
      XCTAssertEqual(model.matchID, b); XCTAssertNil(model.issue)
      await gate.release(); await old.value
      XCTAssertEqual(model.matchID, b, "Old action must not borrow a new refresh generation")
      XCTAssertNil(model.issue, "Old failure must not pollute the new match")
      XCTAssertFalse(model.busy)
      try await repo.close()
    }
  }
  func testMatchSwitchDuringActionRefreshRejectsLatePostRefreshFailure() async throws {
    for fails in [false, true] {
      let (repo, a, b) = try await twoStoredMatches()
      let realLedger = try SQLiteCloudLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
      let entered = expectation(description: "Old refresh read entered")
      let ledger = LifecycleReadGate(realLedger, entered)
      let scope = try CloudScope(accountID: "a", cloudSpaceID: "c", zoneID: "z", activationEpoch: 1)
      let model = LifecycleStatusModel(repository: repo, development: true, ledger: ledger, scope: scope, action: { _ in if fails { throw AuthorityError.unavailable } })
      await model.refresh(matchID: a); await ledger.holdNext()
      let old = Task { await model.perform(.retryControls, matchID: a) }
      await fulfillment(of: [entered], timeout: 2)
      await model.refresh(matchID: b)
      XCTAssertEqual(model.matchID, b); XCTAssertNil(model.issue)
      await ledger.release(); await old.value
      XCTAssertEqual(model.matchID, b)
      XCTAssertNil(model.issue, "Post-refresh failure must still own the same observation")
      try await repo.close(); try await realLedger.close()
    }
  }
  private func twoStoredMatches() async throws -> (SQLiteSessionRepository, String, String) {
    let repo = try accountRepository("late-lifecycle")
    for id in ["match-a", "match-b"] {
      let intent = StartIntent(id: "intent-" + id, matchID: id, recordingDeviceID: "local", requestedAt: Date())
      _ = try await repo.commitV2(StoreCommitV2(commandID: "store-" + id, expectedGeneration: 0, descriptor: MatchDescriptor(startIntent: intent, starter: false), events: [], captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: []))
    }
    return (repo, "match-a", "match-b")
  }
  func testFreshRealStoreDefaultsAnalyticsOffAndReadErrorIsUnknown() async throws {
    let repo = try accountRepository("lifecycle-read")
    let model = LifecycleStatusModel(repository: repo)
    await model.refresh()
    XCTAssertEqual(model.analyticsEnabled, false)
    XCTAssertTrue(model.deletions.isEmpty)
    try await repo.close(); await model.refresh()
    XCTAssertNil(model.analyticsEnabled)
    XCTAssertNotNil(model.issue)
    XCTAssertNil(model.cloudSaved)
  }
  func testFourDeletionGroupsAggregateBothLocalComponents() throws {
    var fields = AuthorityFields(); fields.reauthenticationID = "fresh-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(AuthorityWire.base64URL(Data(repeating: 3, count: 32)).utf8))
    let intent = try ControlIntentV1(requestID: "delete-original", operation: .deleteAccount, fields: fields)
    var saga = try DeletionSagaV4(intent: intent, accountID: "account", activationEpoch: 1, recoveryCapability: AuthorityWire.base64URL(Data(repeating: 3, count: 32)), cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "matches", activationEpoch: 1))
    saga.lastIssue = .unavailable
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[0].progress, .failed)
    saga.backendDeleted = true; saga.localProgress = .completed; saga.localTransportProgress = .failed
    let rows = LifecycleStatusModel.deletionRows(saga)
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows[2].progress, .failed)
    XCTAssertFalse(saga.finished)
    saga.localTransportProgress = .completed
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[2].progress, .completed)
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[1].progress, .retained)
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[3].progress, .retained)
    XCTAssertTrue(saga.finished)
  }
}

private actor LifecycleActionGate {
  let entered: XCTestExpectation
  var continuation: CheckedContinuation<Void,Never>?
  init(_ entered: XCTestExpectation) { self.entered = entered }
  func hold() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
  func release() { continuation?.resume(); continuation = nil }
}
private actor LifecycleReadGate: CloudLedger {
  let base: SQLiteCloudLedger
  let entered: XCTestExpectation
  var next = false
  var continuation: CheckedContinuation<Void,Never>?
  init(_ base: SQLiteCloudLedger, _ entered: XCTestExpectation) { self.base = base; self.entered = entered }
  func holdNext() { next = true }
  func release() { continuation?.resume(); continuation = nil }
  func scopeState(scope: CloudScope) async throws -> CloudScopeState {
    let value = try await base.scopeState(scope: scope)
    if next { next = false; await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    return value
  }
  func enqueue(_ upload: CloudUpload) async throws { try await base.enqueue(upload) }
  func uploads(scope: CloudScope) async throws -> [CloudUploadEntry] { try await base.uploads(scope: scope) }
  func failUpload(id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws { try await base.failUpload(id: id, issue: issue, at: at, nextAttemptAt: nextAttemptAt) }
  func stage(_ batch: CloudFetchBatch) async throws { try await base.stage(batch) }
  func batches(scope: CloudScope) async throws -> [CloudBatchEntry] { try await base.batches(scope: scope) }
  func acknowledge(_ acknowledgement: CloudImportAcknowledgement) async throws { try await base.acknowledge(acknowledgement) }
  func failBatch(scope: CloudScope, id: String, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws { try await base.failBatch(scope: scope, id: id, issue: issue, at: at, nextAttemptAt: nextAttemptAt) }
  func recordScopeIssue(scope: CloudScope, issue: CloudIssue, at: Date, nextAttemptAt: Date?) async throws { try await base.recordScopeIssue(scope: scope, issue: issue, at: at, nextAttemptAt: nextAttemptAt) }
  func clearScopeIssue(scope: CloudScope) async throws { try await base.clearScopeIssue(scope: scope) }
  func retainConflict(_ conflict: CloudConflict) async throws { try await base.retainConflict(conflict) }
  func conflicts(scope: CloudScope) async throws -> [CloudConflict] { try await base.conflicts(scope: scope) }
  func confirmUpload(_ evidence: DevelopmentCloudSaveEvidence) async throws { try await base.confirmUpload(evidence) }
  func saveEvidence(scope: CloudScope) async throws -> [DevelopmentCloudSaveEvidence] { try await base.saveEvidence(scope: scope) }
}
