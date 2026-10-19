import Foundation
import Observation
import XCTest
import CryptoKit
import MatchStore
import MatchSession
@testable import MatchPresentation

@MainActor final class AccountStatusTests: XCTestCase {
  func testGateObservationTracksPauseConfirmationAndStop() async throws {
    let repo = try accountRepository("gate-observation"); try await repo.bindAccountV4(try binding(.phone))
    let model = AccountStatusModel(repository: repo, development: true, identityVerified: true, action: { _ in })
    await model.refresh(); XCTAssertTrue(model.canEnterRecording)
    let paused = expectation(description: "Root sees identity pause")
    withObservationTracking { _ = model.canEnterRecording } onChange: { paused.fulfill() }
    model.pauseIdentity(); await model.refresh()
    await fulfillment(of: [paused], timeout: 1); XCTAssertFalse(model.canEnterRecording)
    let confirmed = expectation(description: "Root sees explicit identity confirmation")
    withObservationTracking { _ = model.canEnterRecording } onChange: { confirmed.fulfill() }
    model.confirmIdentity(); await model.refresh()
    await fulfillment(of: [confirmed], timeout: 1); XCTAssertTrue(model.canEnterRecording)
    let stopped = expectation(description: "Root sees context stop")
    withObservationTracking { _ = model.canEnterRecording } onChange: { stopped.fulfill() }
    model.stop(); await fulfillment(of: [stopped], timeout: 1); XCTAssertFalse(model.canEnterRecording)
    try await repo.close()
  }
  func testOldFailureCannotPublishAfterCurrentIdentityWasPaused() async throws {
    let repo = try accountRepository("account-action-gate")
    let b = try binding(.phone); try await repo.bindAccountV4(b)
    let entered = expectation(description: "Account action entered")
    let gate = AccountActionGate(entered)
    let model = AccountStatusModel(repository: repo, development: true, identityVerified: true, action: { _ in await gate.hold(); throw AuthorityError.unavailable })
    await model.refresh()
    let old = Task { await model.perform(.recover) }
    await fulfillment(of: [entered], timeout: 2)
    model.pauseIdentity(); await model.refresh()
    XCTAssertEqual(model.phase, .suspended); XCTAssertNil(model.issue)
    await gate.release(); await old.value
    XCTAssertEqual(model.phase, .suspended); XCTAssertNil(model.issue)
    try await repo.close()
  }
  func testProductionIsUnavailableEvenWithPersistedBinding() async throws {
    let repo = try accountRepository("production-gate")
    try await repo.bindAccountV4(try binding(.phone))
    let model = AccountStatusModel(repository: repo)
    await model.refresh()
    XCTAssertEqual(model.phase, .unavailable)
    XCTAssertFalse(model.canEnterRecording)
    try await repo.close()
  }
  func testRealPersistedWaitingRoleReopensWithoutRecordingAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = try accountRepository("waiting", root: root)
    try await repo.bindAccountV4(try binding(.waiting))
    let model = AccountStatusModel(repository: repo, development: true, identityVerified: true, action: { _ in })
    await model.refresh()
    XCTAssertEqual(model.phase, .waitingMigration)
    XCTAssertFalse(model.canEnterRecording)
    try await repo.close()
    let reopened = try accountRepository("waiting", root: root)
    let second = AccountStatusModel(repository: reopened, development: true, identityVerified: true, action: { _ in })
    await second.refresh()
    XCTAssertEqual(second.binding?.deviceID, "phone-local")
    XCTAssertEqual(second.phase, .waitingMigration)
    try await reopened.close()
  }
  func testReadFailureAndIdentityPauseClearReadyConclusion() async throws {
    let repo = try accountRepository("read-status")
    try await repo.bindAccountV4(try binding(.phone))
    let model = AccountStatusModel(repository: repo, development: true, identityVerified: true, action: { _ in })
    await model.refresh(); XCTAssertTrue(model.canEnterRecording)
    try await repo.suspendAccountV4()
    await model.refresh(); XCTAssertEqual(model.phase, .suspended); XCTAssertFalse(model.canEnterRecording)
    try await repo.close()
    await model.refresh(); XCTAssertEqual(model.phase, .unknown); XCTAssertNil(model.binding); XCTAssertFalse(model.canEnterRecording)
  }
  func testUnverifiedIdentityCannotAdmitStoredPhone() async throws {
    let repo = try accountRepository("mismatch")
    try await repo.bindAccountV4(try binding(.phone))
    let model = AccountStatusModel(repository: repo, development: true, identityVerified: false, action: { _ in })
    await model.refresh(); XCTAssertFalse(model.canEnterRecording)
    XCTAssertEqual(model.phase, .suspended)
    try await repo.close()
  }
  private func binding(_ role: AccountBindingV4.Role) throws -> AccountBindingV4 {
    try AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: "phone-local", activationEpoch: 1, role: role, environment: .development)
  }
}
func accountRepository(_ namespace: String, root: URL? = nil) throws -> SQLiteSessionRepository {
  let key = Curve25519.Signing.PrivateKey()
  let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["fixture": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
  return try SQLiteSessionRepository(rootDirectory: root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), databaseNamespace: namespace, authorityTrust: trust, cloudSavePolicy: .development(databaseNamespace: namespace))
}

private actor AccountActionGate {
  let entered: XCTestExpectation
  var continuation: CheckedContinuation<Void,Never>?
  init(_ entered: XCTestExpectation) { self.entered = entered }
  func hold() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
  func release() { continuation?.resume(); continuation = nil }
}


extension AccountStatusTests {
  func testCheckedAdmissionUsesPersistedBindingAndKeepsWaitingPendingUnavailableGates() async throws {
    for role in [AccountBindingV4.Role.phone, .watch, .waiting] {
      let repo = try accountRepository("admit-role"), b = try binding(role); try await repo.bindAccountV4(b)
      let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
      try await model.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4())
      XCTAssertEqual(model.phase, role == .waiting ? .waitingMigration : .ready)
      XCTAssertEqual(model.canEnterRecording, role != .waiting)
      let unavailable = AccountStatusModel(repository:repo)
      try await unavailable.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4())
      XCTAssertEqual(unavailable.phase,.unavailable); XCTAssertFalse(unavailable.canEnterRecording)
      if role == .phone {
        let key = Curve25519.Signing.PrivateKey()
        let attempt = try AuthAttemptV4(requestID:"pending-original",deviceID:b.deviceID,publicKey:AuthorityWire.base64URL(key.publicKey.rawRepresentation),cloudSpaceID:b.cloudSpaceID,challengeID:"challenge",requestDigest:String(repeating:"a",count:64),environment:.development)
        try await repo.saveAuthAttemptV4(attempt)
        try await model.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4())
        XCTAssertEqual(model.phase,.pending); XCTAssertFalse(model.canEnterRecording)
      }
      try await repo.close()
    }
  }
  func testCheckedAdmissionRejectsEveryChangedBindingFieldAndGeneration() async throws {
    let repo = try accountRepository("admit-mismatch"), b = try binding(.phone); try await repo.bindAccountV4(b)
    let wrong = [
      try AccountBindingV4(accountID:"other",cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:1,role:.phone,environment:.development),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:"other",deviceID:b.deviceID,activationEpoch:1,role:.phone,environment:.development),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:"other",activationEpoch:1,role:.phone,environment:.development),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:2,role:.phone,environment:.development),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:1,role:.watch,environment:.development),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:1,role:.phone,environment:.production),
      try AccountBindingV4(accountID:b.accountID,cloudSpaceID:b.cloudSpaceID,deviceID:b.deviceID,activationEpoch:1,role:.phone,environment:.development,suspended:true)
    ]
    let model = AccountStatusModel(repository:repo,development:true,action:{ _ in })
    for value in wrong {
      do { try await model.admitIdentity(value,expectedIdentityGeneration:0); XCTFail("wrong binding") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }
      XCTAssertFalse(model.canEnterRecording)
    }
    for generation in [-1,1] as [Int64] {
      do { try await model.admitIdentity(b,expectedIdentityGeneration:generation); XCTFail("wrong generation") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }
    }
    try await repo.suspendAccountV4()
    let suspendedValue = try await repo.accountBindingV4()
    let suspended = try XCTUnwrap(suspendedValue)
    do { try await model.admitIdentity(suspended,expectedIdentityGeneration:1); XCTFail("suspended binding") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }
    XCTAssertFalse(model.canEnterRecording); try await repo.close()
    let empty = try accountRepository("admit-empty"), missing = AccountStatusModel(repository:empty,development:true,action:{ _ in })
    do { try await missing.admitIdentity(b,expectedIdentityGeneration:0); XCTFail("missing binding") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }; try await empty.close()
  }
  func testCheckedAdmissionRejectsUnicodeEquivalentButByteDifferentBinding() async throws {
    let repo = try accountRepository("admit-raw-bytes"), b = try binding(.phone)
    // Synthesized Codable can carry a legacy/malformed DTO beyond initializer grammar.
    // It must never turn Swift Unicode equivalence into evidence for a different raw row.
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(b)) as? [String:Any])
    object["cloudSpaceID"] = "space-é"
    let stored = try JSONDecoder().decode(AccountBindingV4.self,from:JSONSerialization.data(withJSONObject:object))
    object["cloudSpaceID"] = "space-e\u{301}"
    let alias = try JSONDecoder().decode(AccountBindingV4.self,from:JSONSerialization.data(withJSONObject:object))
    XCTAssertEqual(stored,alias); XCTAssertNotEqual(Data(stored.cloudSpaceID.utf8),Data(alias.cloudSpaceID.utf8))
    try await repo.bindAccountV4(stored)
    let model = AccountStatusModel(repository:repo,development:true,action:{ _ in })
    do { try await model.admitIdentity(alias,expectedIdentityGeneration:0); XCTFail("raw identity must match") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }
    XCTAssertFalse(model.canEnterRecording); try await repo.close()
  }
  func testCheckedAdmissionCannotPublishAfterPauseStopRefreshReloadOrNewerAdmission() async throws {
    for change in ["pause","stop","refresh","reload","newer","durable"] {
      let repo = try accountRepository("admit-late"), b = try binding(.phone); try await repo.bindAccountV4(b)
      let model = AccountStatusModel(repository:repo,development:true,action:{ _ in })
      let entered = expectation(description:"admission read held"), gate = AccountActionGate(entered)
      let old = Task { () -> Bool in
        do { try await model.admitIdentity(b,expectedIdentityGeneration:0,read:{ let value = try await PresentationAccountAdmissionRead.read(repo); await gate.hold(); return value }); return true }
        catch { return false }
      }
      await fulfillment(of:[entered],timeout:2)
      switch change {
      case "pause":model.pauseIdentity()
      case "stop":model.stop()
      case "refresh":await model.refresh()
      case "reload":model.requireReload()
      case "newer":try await model.admitIdentity(b,expectedIdentityGeneration:0)
      default:try await repo.suspendAccountV4()
      }
      await gate.release(); let accepted = await old.value
      XCTAssertFalse(accepted,change); XCTAssertEqual(model.canEnterRecording,change == "newer",change)
      try await repo.close()
    }
  }
  func testCheckedReadmissionKeepsReloadAndStoppedContextClosed() async throws {
    let repo = try accountRepository("admit-reload"), b = try binding(.phone); try await repo.bindAccountV4(b)
    let session = MatchSession(store:repo,deviceIdentity:AccountCheckedIdentity(),clock:SystemSessionClock(),ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"admit-reload"))
    let recording = RecordingModel(session:session,repository:repo,development:true)
    let account = AccountStatusModel(repository:repo,development:true,action:{ _ in }), lifecycle = LifecycleStatusModel(repository:repo)
    let context = try await AppBootstrap.accountContext(repository:repo,session:session,recording:recording,account:account,lifecycle:lifecycle,close:{ try? await repo.close() })
    account.requireReload(); await recording.shutdown()
    try await account.admitIdentity(b,expectedIdentityGeneration:0)
    XCTAssertTrue(account.requiresReload); XCTAssertFalse(account.canEnterRecording)
    await recording.start(starter:true); XCTAssertNil(recording.pendingRequest); XCTAssertEqual(recording.feedbackCount,0)
    await context.shutdown()
    do { try await account.admitIdentity(b,expectedIdentityGeneration:0); XCTFail("stopped context") } catch { XCTAssertEqual(error as? AuthorityError,.identityChanged) }
    XCTAssertFalse(account.canEnterRecording)
  }
}
private struct AccountCheckedIdentity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "checked-local" } }
