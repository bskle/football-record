#if DEBUG && os(macOS)
import Foundation
import XCTest
import SQLite3
@testable import AccountKit
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
  private enum InitialVeto: Error { case stage }
  private func required<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
  private func database(_ f: M4HTTPFixtureHarness, _ c: M4AccountComposition) -> URL {
    f.nativeRoot.appendingPathComponent(c.namespace + "/matches.sqlite")
  }
  private func catalogState(_ f: M4HTTPFixtureHarness, _ c: M4AccountComposition) throws -> M4CatalogState {
    // Diagnostic read of this fixture's original publication, never another owner.
    let url = f.nativeRoot.appendingPathComponent("development/m4-controls/" + c.namespace + "/catalog/catalog.json")
    return try JSONDecoder().decode(M4CatalogState.self, from: Data(contentsOf: url))
  }
  private func purposeRows(_ f: M4HTTPFixtureHarness, _ c: M4AccountComposition) throws -> [String] {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(database(f, c).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }
    defer { sqlite3_close(db) }
    let query = "SELECT id, hex(payload), checksum FROM lifecycle_steps_v4 WHERE id LIKE 'initial-delete-auth-v1:%' ORDER BY id"
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append((0..<3).map { String(cString: sqlite3_column_text(statement, Int32($0))) }.joined(separator: "|"))
    }
    return rows
  }
  private func sourceBytes(_ source: VerifiedLocalAuthenticationEvidenceV4) throws -> Data {
    try AuthorityWire.encode([AuthorityWire.encode(source.binding).base64EncodedString(), String(source.identityGeneration),
      source.currentAuthRequestID, AuthorityWire.encode(source.attempt).base64EncodedString(),
      String(source.admissionGeneration), source.receipt.raw.base64EncodedString()])
  }
  private func descriptorBytes(_ value: InitialDeletionReservationV1) throws -> Data {
    try AuthorityWire.encode([AuthorityWire.encode(value.request).base64EncodedString(), String(value.identityGeneration),
      value.originalAuthRequestID, value.originalAuthReceiptDigest, value.initialAuthRequestID,
      value.initialAuthRequestDigest, value.initialAuthReceiptDigest, value.opaqueReauthenticationID])
  }
  private func vaultBytes(_ f: M4HTTPFixtureHarness, _ c: M4AccountComposition) throws -> Data {
    try Data(contentsOf: database(f, c).deletingLastPathComponent().appendingPathComponent("development.vault"))
  }
  private func firstPhone(_ f: M4HTTPFixtureHarness) async throws -> M4AccountComposition {
    let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
    _ = try await f.signIn(); XCTAssertNil(c.reauthenticationID); XCTAssertTrue(c.context.account.canEnterRecording)
    return c
  }
  private func creationFails(_ controller: M4DeletionResumeController, parent: String, time: Int64) async -> (any Error)? {
    do { _ = try await controller.create(requestID: parent, confirmedAt: time); XCTFail("veto must preserve the original creation boundary"); return nil }
    catch { return error }
  }
  func testFirstPhoneDedicatedFreshCreatesAndResumesOriginalParent() async throws {
    try await withFixture { f in
      _ = try await f.cli.command("revoker")
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      _ = try await f.signIn()
      guard c.reauthenticationID == nil else {
        XCTFail("the real first ordinary authentication must return nil reauthentication")
        return
      }
      _ = try await self.normalCompleted(c.context, fixture: f)
      _ = try await f.refreshIdentity()
      let controller = try c.managedDeletionController()
      XCTAssertTrue(try c.managedDeletionController() === controller)
      let parent = "managed-original-parent", confirmedAt = Int64(Date().timeIntervalSince1970)
      let generation = try await c.repository.identityGenerationV4()
      let observed = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
      guard let source = observed, source.binding.role == .phone, c.context.account.canEnterRecording,
            c.context.recording.snapshot?.replay.state == .completed else {
        XCTFail("the strict original Phone and normal completed publication must precede deletion creation")
        return
      }
      let originalSource = try self.sourceBytes(source), originalVault = try self.vaultBytes(f, c)
      let originalPhysical = try M4CatalogIO.encode(self.catalogState(f, c).physicalBootstrap)
      let initialState = try self.catalogState(f, c)
      XCTAssertEqual(initialState.entries.count, 2)
      XCTAssertTrue(initialState.physicalBootstrap?.resourcesPublished == true && initialState.physicalBootstrap?.businessPublished == true)
      XCTAssertTrue(initialState.physicalBootstrap?.phone?.published == true)
      let serviceID = try XCTUnwrap(c.initialDeletionServiceID)
      var phases: [M4DeletionResumeController.Phase] = [], publishedOwner: M4DeletionResumeController.Snapshot?
      controller.observation = { phase in
        phases.append(phase)
        if [.initialAssociated, .initialReserved, .quiescedBeforeCatalog].contains(phase) {
          let current = try self.required(try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation))
          XCTAssertTrue(try self.sourceBytes(current) == originalSource)
          XCTAssertTrue(try self.vaultBytes(f, c) == originalVault)
          XCTAssertTrue(try M4CatalogIO.encode(self.catalogState(f, c).physicalBootstrap) == originalPhysical)
          XCTAssertEqual(c.initialDeletionServiceID, serviceID); XCTAssertNil(c.reauthenticationID)
          let context = try self.required(try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation))
          if phase == .initialAssociated {
            XCTAssertEqual(context.phase, .associated); XCTAssertNil(context.reservation)
            XCTAssertTrue(c.context.account.canEnterRecording)
          } else {
            let d = try XCTUnwrap(context.reservation)
            XCTAssertEqual(d.originalAuthRequestID, source.currentAuthRequestID)
            XCTAssertEqual(d.originalAuthReceiptDigest, AuthorityWire.hash(source.receipt.raw))
            XCTAssertNotEqual(d.initialAuthRequestID, source.currentAuthRequestID)
            XCTAssertEqual(context.attempts.count, 1)
            XCTAssertTrue((context.association?.receipt.raw.count ?? 0) > 0)
            XCTAssertEqual(c.context.account.canEnterRecording, phase == .initialReserved)
          }
        }
        if phase == .reserved { publishedOwner = try controller.snapshot() }
        if phase == .parentStored {
          let committed = try await c.repository.deletionSagaV4(requestID: parent)
          XCTAssertNotNil(committed)
          do { _ = try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation); XCTFail("original SQL transaction must consume the purpose") }
          catch { XCTAssertEqual(error as? InitialDeletionIssueV1, .parentExists) }
        }
      }
      print("M4 initialAuth probe firstOrdinaryReauthNil=true normalCompleted=true strictOriginalPhone=true")
      let created: DeletionSagaV4
      do { created = try await controller.create(requestID: parent, confirmedAt: confirmedAt) }
      catch {
        guard error as? AuthorityError == .unavailable else {
          print("M4 initialAuth probe stage=unexpectedCreateError type=\(String(describing: type(of: error)))")
          throw error
        }
        print("M4 initialAuth probe expectedLegacyCreationUnavailable=true stage=create errorType=AuthorityError errorCode=unavailable")
        XCTFail("dedicated initial authentication must create the original parent after the real first nil authentication")
        return
      }
      XCTAssertEqual(created.intent.requestID, parent)
      XCTAssertFalse(created.backendDeleted, "create must only persist and seal; resume dispatches deletion separately")
      let after = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
      XCTAssertEqual(after?.currentAuthRequestID, source.currentAuthRequestID)
      XCTAssertEqual(after?.attempt, source.attempt)
      XCTAssertEqual(after?.receipt.raw, source.receipt.raw)
      XCTAssertEqual(after?.binding, source.binding)
      let stored = try await c.repository.deletionSagaV4(requestID: parent)
      XCTAssertTrue(stored?.intent.canonicalRequest == created.intent.canonicalRequest)
      XCTAssertTrue(stored?.recoveryCapability.utf8.elementsEqual(created.recoveryCapability.utf8) == true)
      let snapshot = try controller.snapshot()
      XCTAssertEqual(snapshot.dispatch, .started)
      XCTAssertEqual(snapshot.parentDigest, created.intent.digest)
      XCTAssertEqual(snapshot.fullSealDigest, created.intent.digest)
      XCTAssertEqual(snapshot.entryCount, 2)
      XCTAssertEqual(snapshot.catalogID, publishedOwner?.catalogID); XCTAssertEqual(snapshot.ledgerID, publishedOwner?.ledgerID)
      XCTAssertEqual(phases, [.initialAssociated, .initialReserved, .quiescedBeforeCatalog, .reserved, .started, .parentStored, .requestReturned, .beforeFullSeal, .sealed])
      controller.observation = nil
      let completed = try await controller.resume(requestID: parent)
      XCTAssertTrue(completed.backendDeleted)
      XCTAssertNotNil(completed.backendReceipt)
      XCTAssertEqual(completed.localProgress, .completed)
      XCTAssertTrue(completed.intent.canonicalRequest == created.intent.canonicalRequest)
      XCTAssertTrue(completed.recoveryCapability.utf8.elementsEqual(created.recoveryCapability.utf8))
      let completedSnapshot = try controller.snapshot()
      XCTAssertEqual(completedSnapshot.catalogID, snapshot.catalogID)
      XCTAssertEqual(completedSnapshot.ledgerID, snapshot.ledgerID)
      XCTAssertEqual(completedSnapshot.receiptCount, 2)
      let replay = try await controller.resume(requestID: parent)
      XCTAssertTrue(replay.recoveryCapability.utf8.elementsEqual(created.recoveryCapability.utf8))
      XCTAssertTrue(replay.backendReceipt == completed.backendReceipt)
      let afterReplay = try controller.snapshot(); XCTAssertEqual(afterReplay.receiptCount, 2)
      let originalAgain = try await controller.create(requestID: parent, confirmedAt: confirmedAt)
      XCTAssertTrue(originalAgain.intent.canonicalRequest == created.intent.canonicalRequest)
      XCTAssertTrue(originalAgain.recoveryCapability.utf8.elementsEqual(created.recoveryCapability.utf8))
    }
  }
  func testInitialAuthPreparedRetryAndSentExplicitRecoveryReusePersistedIDs() async throws {
    for sent in [false, true] {
      try await withFixture { f in
        let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
        let parent = "persisted-initial-pair", time = Int64(Date().timeIntervalSince1970)
        let generation = try await c.repository.identityGenerationV4()
        if sent { _ = try await f.cli.command("fault", fields: ["name": "dropResponseAfterOperation", "value": "authenticate"]) }
        else { f.holdReplies = true }
        let first = Task { try await controller.create(requestID: parent, confirmedAt: time) }
        do {
          if sent {
            do { _ = try await first.value; XCTFail("response loss must leave the actual sent attempt unresolved") }
            catch { XCTAssertEqual(error as? InitialDeletionIssueV1, .unresolved) }
          } else {
            try await f.waitUntil { f.held }
            first.cancel(); f.holdReplies = false
            _ = await first.result
            try await f.waitUntil { !f.held }
          }
          let before = try self.required(try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation))
          XCTAssertEqual(before.phase, .preparing); XCTAssertEqual(before.attempts.count, 1)
          let attempt = try XCTUnwrap(before.attempts.first)
          XCTAssertEqual(attempt.authentication != nil, sent); XCTAssertNil(attempt.resolution)
          let beforeReplies = f.replies
          _ = try await f.cli.command("fault", fields: ["name": "dropResponseAfterOperation", "value": NSNull()])
          var associated: InitialDeletionContextV1?
          controller.observation = { phase in
            if phase == .initialAssociated {
              associated = try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation)
              throw InitialVeto.stage
            }
          }
          let error = await self.creationFails(controller, parent: parent, time: time)
          XCTAssertTrue(error is InitialVeto)
          let actual = try XCTUnwrap(associated), reused = try XCTUnwrap(actual.attempts.first)
          XCTAssertEqual(actual.attempts.count, 1); XCTAssertEqual(actual.phase, .associated)
          XCTAssertEqual(reused.authRequestID, attempt.authRequestID); XCTAssertEqual(reused.challengeRequestID, attempt.challengeRequestID)
          XCTAssertNil(reused.resolution); XCTAssertNotNil(actual.association)
          if sent { XCTAssertEqual(f.replies, beforeReplies, "explicit recover must not ask Apple for another reply") }
          else { XCTAssertEqual(f.replies, beforeReplies + 1) }
          let parents = try await c.repository.deletionSagasV4(); XCTAssertTrue(parents.isEmpty)
        } catch { f.holdReplies = false; first.cancel(); _ = await first.result; throw error }
        controller.observation = nil
      }
    }
  }
  func testInitialReservationRetryAfterQuiesceBeforeCatalogIsReadOnly() async throws {
    try await withFixture { f in
      let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
      let parent = "reserved-read-retry", time = Int64(Date().timeIntervalSince1970)
      let generation = try await c.repository.identityGenerationV4()
      var baseline: Data?, rows: [String]?, firstOwner: M4DeletionResumeController.Snapshot?
      let stages: [M4DeletionResumeController.Phase] = [.initialReserved, .quiescedBeforeCatalog, .reserved]
      for target in stages {
        controller.observation = { phase in
          if phase == .initialReserved {
            let context = try self.required(try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation))
            let descriptor = try self.descriptorBytes(try XCTUnwrap(context.reservation))
            let currentRows = try self.purposeRows(f, c)
            if let baseline, let rows { XCTAssertTrue(descriptor == baseline); XCTAssertTrue(currentRows == rows) }
            else { baseline = descriptor; rows = currentRows }
          }
          if phase == .reserved { firstOwner = try controller.snapshot() }
          if phase == target { throw InitialVeto.stage }
        }
        let error = await self.creationFails(controller, parent: parent, time: time); XCTAssertTrue(error is InitialVeto)
      }
      let replies = f.replies
      controller.observation = { phase in
        if phase == .initialReserved {
          XCTAssertFalse(c.context.account.canEnterRecording)
          let context = try self.required(try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation))
          XCTAssertTrue(try self.descriptorBytes(try XCTUnwrap(context.reservation)) == baseline)
          XCTAssertTrue(try self.purposeRows(f, c) == rows)
        }
      }
      let created = try await controller.create(requestID: parent, confirmedAt: time)
      XCTAssertFalse(created.backendDeleted); XCTAssertEqual(f.replies, replies)
      let snapshot = try controller.snapshot()
      XCTAssertEqual(snapshot.catalogID, firstOwner?.catalogID); XCTAssertEqual(snapshot.ledgerID, firstOwner?.ledgerID)
      XCTAssertEqual(snapshot.fullSealDigest, created.intent.digest)
      controller.observation = nil
    }
    // An associated fact has not reserved authority and cannot cross retirement.
    try await withFixture { f in
      let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
      let parent = "associated-retired", time = Int64(Date().timeIntervalSince1970)
      let generation = try await c.repository.identityGenerationV4()
      controller.observation = { if $0 == .initialAssociated { throw InitialVeto.stage } }
      let first = await self.creationFails(controller, parent: parent, time: time); XCTAssertTrue(first is InitialVeto)
      let context = try self.required(try await c.repository.initialDeletionContextV4(creationID: parent, expectedIdentityGeneration: generation))
      XCTAssertEqual(context.phase, .associated); XCTAssertNil(context.reservation)
      let originalRows = try self.purposeRows(f, c)
      try await c.quiesceBusiness() // Outside the ended active suboperation.
      controller.observation = nil
      let error = await self.creationFails(controller, parent: parent, time: time)
      XCTAssertEqual(error as? AuthorityError, .identityChanged)
      XCTAssertTrue(try self.purposeRows(f, c) == originalRows)
      XCTAssertNil(try self.catalogState(f, c).deletionCreation)
    }
  }
  func testInitialParentCommittedReplyLossAndStartedUnknownNeverMintSecondCapability() async throws {
    for commit in [true, false] {
      try await withFixture { f in
        let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
        let parent = "original-commit-or-unknown", time = Int64(Date().timeIntervalSince1970)
        var committed: DeletionSagaV4?, storedCalls = 0
        controller.observation = { phase in
          if phase == .parentStored {
            storedCalls += 1
            committed = try await c.repository.deletionSagaV4(requestID: parent)
            XCTAssertNotNil(committed)
            throw InitialVeto.stage // Native SQL already committed; consumer lost return.
          }
          if !commit, phase == .started { throw InitialVeto.stage }
        }
        if commit {
          let first = try await controller.create(requestID: parent, confirmedAt: time)
          let actual = try XCTUnwrap(committed)
          XCTAssertTrue(first.intent.canonicalRequest == actual.intent.canonicalRequest)
          XCTAssertTrue(first.recoveryCapability.utf8.elementsEqual(actual.recoveryCapability.utf8))
          let originalRows = try self.purposeRows(f, c), replies = f.replies
          let second = try await controller.create(requestID: parent, confirmedAt: time)
          XCTAssertTrue(second.intent.canonicalRequest == first.intent.canonicalRequest)
          XCTAssertTrue(second.recoveryCapability.utf8.elementsEqual(first.recoveryCapability.utf8))
          XCTAssertEqual(storedCalls, 1); XCTAssertEqual(f.replies, replies)
          XCTAssertTrue(try self.purposeRows(f, c) == originalRows)
          let control = try await c.repository.lifecycleControlIntentV4(requestID: parent)
          XCTAssertTrue(control?.canonicalRequest == first.intent.canonicalRequest)
        } else {
          let first = await self.creationFails(controller, parent: parent, time: time); XCTAssertTrue(first is InitialVeto)
          let originalRows = try self.purposeRows(f, c), replies = f.replies
          controller.observation = nil
          for _ in 0..<2 {
            let error = await self.creationFails(controller, parent: parent, time: time)
            XCTAssertEqual(error as? LifecycleClientError, .unknownOriginal)
          }
          let actual = try await c.repository.deletionSagaV4(requestID: parent)
          XCTAssertNil(actual); XCTAssertNil(committed); XCTAssertEqual(storedCalls, 0)
          XCTAssertEqual(f.replies, replies); XCTAssertTrue(try self.purposeRows(f, c) == originalRows)
          XCTAssertNil(try controller.snapshot().fullSealDigest)
        }
        let conflict = await self.creationFails(controller, parent: parent, time: time + 1)
        XCTAssertEqual(conflict as? AuthorityError, .conflict)
        controller.observation = nil
      }
    }
  }
  func testInitialCreationProvenanceAndOriginalGuardsFailClosed() async throws {
    for field in ["account", "cloud", "zone", "source", "vault", "credential", "time", "held", "terminationPending"] {
      try await withFixture { f in
        let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
        let parent = "original-guard", time = Int64(Date().timeIntervalSince1970)
        let generation = try await c.repository.identityGenerationV4()
        var beforeRows: [String] = [], vetoed = false
        var inCallCredentialError: (any Error)?
        if ["held", "terminationPending"].contains(field) {
          await c.context.recording.start(starter: true)
          let id = try XCTUnwrap(c.context.recording.snapshot?.replay.matchID)
          try await self.wait { try await c.repository.snapshotV2(matchID: id).captureOperations.contains { $0.operation.action == .start && $0.state == .settled } }
          if field == "terminationPending" {
            let held = try await c.repository.authorityStateV4(matchID: id, now: Date())
            let acquire = try XCTUnwrap(held.acquire)
            var fields = AuthorityFields(); fields.matchID = id; fields.lockID = acquire.body.lockID
            fields.recordingDeviceID = acquire.body.recordingDeviceID; fields.activationEpoch = acquire.body.activationEpoch; fields.mode = "abnormal"
            let intent = try ControlIntentV1(requestID: "actual-pending-termination", operation: .terminate, fields: fields)
            _ = try await c.session.prepareAbnormalTermination(intent)
          }
          let authority = try await c.repository.authorityStateV4(matchID: id, now: Date())
          XCTAssertEqual(authority.status, field == "held" ? .held : .terminationPending)
        } else {
          controller.observation = { phase in
            guard phase == .initialReserved else { return }
            beforeRows = try self.purposeRows(f, c); vetoed = true
            if field == "credential" {
              let original = try await c.client.vault.credential()
              let earlier = original.expiresAt - 1
              XCTAssertGreaterThan(Double(earlier), Date().timeIntervalSince1970)
              // Keep the actual token/session/binding and a still-valid expiry;
              // even this complete-credential change during one create is vetoed.
              let changed = DeviceCredential(token: original.token, sessionID: original.sessionID, accountID: original.accountID,
                deviceID: original.deviceID, keyID: original.keyID, activationEpoch: original.activationEpoch, expiresAt: earlier)
              try await c.client.vault.replace(changed, expectedIdentityGeneration: generation)
              return
            }
            throw InitialVeto.stage
          }
          let first = await self.creationFails(controller, parent: parent, time: time)
          if field == "credential" { inCallCredentialError = first; XCTAssertEqual(first as? AuthorityError, .identityChanged) }
          else { XCTAssertTrue(first is InitialVeto) }
          XCTAssertTrue(vetoed)
          controller.observation = nil
          if ["account", "cloud", "zone"].contains(field) { try await f.changeIndependentField(field) }
          if field == "source" { try await c.session.suspendAccount() }
          if field == "vault" {
            let original = try await c.client.vault.credential()
            let expired = DeviceCredential(token: original.token, sessionID: original.sessionID, accountID: original.accountID,
              deviceID: original.deviceID, keyID: original.keyID, activationEpoch: original.activationEpoch, expiresAt: 1)
            try await c.client.vault.replace(expired, expectedIdentityGeneration: generation)
          }
        }
        let error = field == "credential" ? inCallCredentialError : await self.creationFails(controller, parent: parent, time: field == "time" ? time + 1 : time)
        XCTAssertNotNil(error)
        let parents = try await c.repository.deletionSagasV4(); XCTAssertTrue(parents.isEmpty)
        XCTAssertNil(try self.catalogState(f, c).deletionCreation)
        if vetoed { XCTAssertTrue(try self.purposeRows(f, c) == beforeRows) }
        if ["account", "cloud", "zone"].contains(field) {
          // Restore only our fixture's original independent files for close; no
          // subsequent positive operation is performed with the restored bytes.
          _ = try await f.refreshIdentity()
        }
      }
    }
  }
  func testInitialCreateFIFOStopAndCloseDrainActualFreshAndReturnTails() async throws {
    try await withFixture { f in
      let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
      let parent = "fresh-fifo-tail", time = Int64(Date().timeIntervalSince1970)
      let probe = M4ReturnTailProbe(holding: [.create])
      controller.queueObservation = { probe.recordQueue($0) }
      controller.returnTailObservation = { await probe.hold($0) }
      probe.selfJoinLaunch = {
        [Task {
          do { try await c.close(); probe.recordSelfClose(false) }
          catch { probe.recordSelfClose(error as? AuthorityError == .conflict) }
        }, Task {
          do { try await controller.stopAndJoin(); probe.recordSelfStop(false) }
          catch { probe.recordSelfStop(error as? AuthorityError == .conflict) }
        }]
      }
      f.holdReplies = true
      let first = Task { try await controller.create(requestID: parent, confirmedAt: time) }
      var joins: [@MainActor () async -> Void] = [{ _ = await first.result }]
      do {
        try await f.waitUntil { f.held }
        let duplicate = Task { try await controller.create(requestID: parent, confirmedAt: time) }
        joins.append { _ = await duplicate.result }
        _ = try await probe.queue { $0.phase == .registered && $0.kind == .create && $0.borrowerCount == 2 }
        let successor = Task { try await controller.recover() }; joins.append { _ = await successor.result }
        _ = try await probe.queue { $0.phase == .predecessorParked && $0.kind == .recover }
        first.cancel(); f.holdReplies = false
        let held1 = try await probe.held(.create), held2 = try await probe.held(.create, excluding: held1.borrowerID)
        XCTAssertEqual(held1.operationID, held2.operationID); XCTAssertEqual(held2.borrowerCount, 2)
        XCTAssertEqual(held1.result, .failure); XCTAssertEqual(held2.result, .failure)
        // Inherited close/stop are rejected before mutating original admission.
        let selfClose = try await probe.selfCloseResult(), selfStop = try await probe.selfStopResult()
        XCTAssertTrue(selfClose); XCTAssertTrue(selfStop)
        var closeDone = false, stopDone = false
        let externalStop = Task { try await controller.stopAndJoin(); stopDone = true }
        let externalClose = Task { try await c.close(); closeDone = true }
        joins.append { _ = await externalStop.result }; joins.append { _ = await externalClose.result }
        _ = try await probe.queue { $0.phase == .admissionClosed }
        XCTAssertFalse(closeDone); XCTAssertFalse(stopDone)
        let beforeClose = try await c.repository.deletionSagasV4(); XCTAssertTrue(beforeClose.isEmpty)
        XCTAssertNotNil(c.initialDeletionServiceID)
        probe.release(held1.borrowerID)
        _ = try await probe.queue { $0.phase == .released && $0.borrowerID == held1.borrowerID }
        XCTAssertFalse(closeDone); XCTAssertFalse(stopDone); XCTAssertFalse(probe.bodyEntered(.recover))
        probe.release(held2.borrowerID)
        probe.releaseAll()
        for join in joins { await join() }
        XCTAssertTrue(closeDone); XCTAssertTrue(stopDone); XCTAssertNil(c.initialDeletionServiceID)
      } catch {
        f.holdReplies = false; probe.releaseAll(); first.cancel()
        for join in joins { await join() }
        await probe.joinChildren(); throw error
      }
      await probe.joinChildren()
      controller.queueObservation = nil; controller.returnTailObservation = nil
    }
    // Final close also owns a real fresh Apple wait, before any return-tail hold.
    try await withFixture { f in
      let c = try await self.firstPhone(f), controller = try c.managedDeletionController()
      let serviceID = try XCTUnwrap(c.initialDeletionServiceID)
      let tail = M4ReturnTailProbe(holding: [.create])
      controller.queueObservation = { tail.recordQueue($0) }
      controller.returnTailObservation = { await tail.hold($0) }
      f.holdReplies = true
      let create = Task { try await controller.create(requestID: "close-real-fresh", confirmedAt: Int64(Date().timeIntervalSince1970)) }
      var closing: Task<Void, any Error>?
      do {
        try await f.waitUntil { f.held }
        var done = false
        let close = Task { try await c.close(); done = true }; closing = close
        // finalClosing closes this synchronous factory before joining the real
        // business Apple call. Do not wait for the later controller drain yet.
        try await self.wait {
          do { _ = try c.managedDeletionController(); return false }
          catch { guard error as? AuthorityError == .identityChanged else { throw error }; return true }
        }
        XCTAssertTrue(f.held); XCTAssertFalse(done)
        XCTAssertEqual(c.initialDeletionServiceID, serviceID)
        let parents = try await c.repository.deletionSagasV4(); XCTAssertTrue(parents.isEmpty)
        f.holdReplies = false
        _ = try await tail.held(.create)
        _ = try await tail.queue { $0.phase == .admissionClosed }
        XCTAssertFalse(done)
        tail.releaseAll()
        _ = await create.result; try await close.value
        XCTAssertTrue(done); XCTAssertNil(c.initialDeletionServiceID)
      } catch {
        f.holdReplies = false; tail.releaseAll(); create.cancel(); _ = await create.result
        _ = await closing?.result; await tail.joinChildren(); throw error
      }
      await tail.joinChildren()
      controller.queueObservation = nil; controller.returnTailObservation = nil
    }
  }
  func testManagedFactoryStronglyRetainsSameControllerUntilSuccessfulOriginalClose() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      var borrowed: M4DeletionResumeController? = try c.managedDeletionController()
      weak let probe = borrowed
      let originalService = try XCTUnwrap(c.initialDeletionServiceID)
      borrowed = nil
      XCTAssertEqual(c.initialDeletionServiceID, originalService)
      XCTAssertNotNil(probe)
      XCTAssertTrue(try c.managedDeletionController() === probe)
      try await c.close()
      XCTAssertNil(probe); XCTAssertNil(c.initialDeletionServiceID)
    }
  }
  func testFailedFinalCloseRetainsSameStoppedManagedControllerForOriginalCloseRetry() async throws {
    try await withFixture { f in
      let c = try await f.bootstrapStrict(workout: M4HTTPWorkoutGateway())
      var borrowed: M4DeletionResumeController? = try c.managedDeletionController()
      weak let probe = borrowed
      let originalService = try XCTUnwrap(c.initialDeletionServiceID)
      borrowed = nil
      try await c.quiesceBusiness()
      let file = f.nativeRoot.appendingPathComponent("development/mailbox/incoming/task3-owned-close-veto")
      let bytes = Data([14, 2, 9]); try bytes.write(to: file)
      do { try await c.close(); XCTFail("undrained original adapter must preserve the same owner") }
      catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
      XCTAssertNotNil(probe)
      XCTAssertEqual(c.initialDeletionServiceID, originalService)
      XCTAssertTrue(try c.managedDeletionController() === probe)
      let retained = try await c.repository.deletionSagasV4(); XCTAssertTrue(retained.isEmpty)
      do { _ = try await probe?.create(requestID: "after-failed-final-close", confirmedAt: 1); XCTFail("failed final close does not reopen stopped control") }
      catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      guard try Data(contentsOf: file) == bytes else { throw M4HTTPFixtureError.mailboxChanged }
      try FileManager.default.removeItem(at: file)
      try await c.close(); XCTAssertNil(probe); XCTAssertNil(c.initialDeletionServiceID)
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
