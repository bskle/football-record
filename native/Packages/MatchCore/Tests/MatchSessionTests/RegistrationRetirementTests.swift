import Foundation
import CryptoKit
import SQLite3
import XCTest
import MatchCore
@testable import MatchStore
@testable import MatchSession

final class RegistrationRetirementTests: XCTestCase, @unchecked Sendable {
  private func eventually(_ message: String, _ condition: @escaping @Sendable () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline { if await condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
    XCTFail(message)
  }
  private func assertState(_ h: RegistrationFixture, _ expected: Data, _ message: String = "", repository: SQLiteSessionRepository? = nil) async throws {
    let actual = try await h.state(repository); XCTAssertEqual(actual, expected, message)
  }
  private func retired(_ result: Result<Void, any Error>, file: StaticString = #filePath, line: UInt = #line) {
    switch result { case .success: XCTFail("retired identity mutation succeeded", file: file, line: line)
    case .failure(let error): XCTAssertEqual(error as? SessionError, .retired, file: file, line: line) }
  }
  func testRetiredOriginalSessionRejectsEveryIdentityMutationBeforeSQL() async throws {
    for kind in RegistrationMutation.allCases {
      let h = try await RegistrationFixture(kind), before = try await h.state()
      try await h.session.retireBusiness()
      retired(await Task { try await h.run() }.result)
      let calls = await h.proxy.writes; XCTAssertEqual(calls, 0, kind.rawValue)
      try await assertState(h, before, kind.rawValue)
      let generation = try await h.base.identityGenerationV4(); XCTAssertEqual(generation, 0)
      try await h.base.close()
    }
  }
  func testHeldOriginalEnvironmentReadCannotResumeIntoAnyWriteAfterGate() async throws {
    for kind in RegistrationMutation.allCases {
      let h = try await RegistrationFixture(kind), before = try await h.state()
      await h.proxy.configure(.environment)
      let writer = Task { try await h.run() }
      await eventually("original environment read not held") { await h.proxy.entered }
      let done = RegistrationCompletion(), retirement = Task { try await h.session.retireBusiness(); await done.finish() }
      await eventually("original Session gate absent") { await h.session.businessRetired }
      let premature = await done.finished; XCTAssertFalse(premature, "retirement must join already-entered method")
      await h.proxy.release(); retired(await writer.result); try await retirement.value
      let calls = await h.proxy.writes; XCTAssertEqual(calls, 0, kind.rawValue)
      try await assertState(h, before, kind.rawValue); try await h.base.close()
    }
  }
  func testOriginalAuthorityMutexWaitRechecksGateBeforeEveryWrite() async throws {
    for kind in RegistrationMutation.allCases {
      let h = try await RegistrationFixture(kind), before = try await h.state()
      await h.session.acquire("_authority-account")
      let writer = Task { try await h.run() }
      await eventually("original authority mutex queue not entered") { await h.session.registrationWaiterCount() == 1 }
      let done = RegistrationCompletion(), retirement = Task { try await h.session.retireBusiness(); await done.finish() }
      await eventually("original retirement gate absent") { await h.session.businessRetired }
      let premature = await done.finished; XCTAssertFalse(premature)
      await h.session.release("_authority-account")
      retired(await writer.result); try await retirement.value
      let calls = await h.proxy.writes; XCTAssertEqual(calls, 0, kind.rawValue)
      try await assertState(h, before, kind.rawValue); try await h.base.close()
    }
  }
  func testRetirementJoinsEveryOriginallyAdmittedPositiveSQLReplyWithoutMasking() async throws {
    for kind in RegistrationMutation.allCases {
      let h = try await RegistrationFixture(kind), before = try await h.state()
      await h.proxy.configure(kind.point)
      let writer = Task { try await h.run() }
      await eventually("actual SQL commit reply not held") { await h.proxy.entered }
      let committed = try await h.state(); XCTAssertNotEqual(committed, before, kind.rawValue)
      let done = RegistrationCompletion(), retirement = Task { try await h.session.retireBusiness(); await done.finish() }
      await eventually("original retirement gate absent") { await h.session.businessRetired }
      let premature = await done.finished; XCTAssertFalse(premature, kind.rawValue)
      await h.proxy.release(); try await writer.value; try await retirement.value
      let calls = await h.proxy.writes; XCTAssertEqual(calls, 1)
      try await assertState(h, committed, "no retired throw or replacement write may hide original commit")
      let identity = await h.base.syncRepositoryIdentity(), original = await h.session.syncRepositoryIdentity(); XCTAssertEqual(identity, original)
      try await h.base.close()
      let reopened = try h.reopen(); try await assertState(h, committed, repository: reopened); try await reopened.close()
    }
  }
  func testAdmittedCommitResponseLostIsJoinedAndPreservesOriginalReceipt() async throws {
    for kind in [RegistrationMutation.authAccept, .watchAcceptPhone, .watchAcceptWatch] {
      let h = try await RegistrationFixture(kind)
      await h.proxy.configure(kind.point, loseResponse: true)
      let writer = Task { try await h.run() }; await eventually("actual committed reply not held") { await h.proxy.entered }
      let committed = try await h.state(), done = RegistrationCompletion()
      let retirement = Task { try await h.session.retireBusiness(); await done.finish() }
      await eventually("original retirement gate absent") { await h.session.businessRetired }
      let premature = await done.finished; XCTAssertFalse(premature)
      await h.proxy.release()
      do { try await writer.value; XCTFail("original response loss must remain visible") }
      catch { XCTAssertEqual(error as? StoreError, .responseLost) }
      try await retirement.value; try await assertState(h, committed)
      try await h.base.close(); let reopened = try h.reopen(); try await assertState(h, committed, repository: reopened); try await reopened.close()
    }
  }
  func testOriginalSQLFailureIsJoinedAndReturnedWithoutRetiredSubstitution() async throws {
    let h = try await RegistrationFixture(.authAccept), before = try await h.state()
    try await h.execute("CREATE TRIGGER test_owned_auth_failure BEFORE INSERT ON account_binding_v4 BEGIN SELECT RAISE(ABORT,'test-owned SQL failure'); END")
    await h.proxy.configure(.authAccept)
    let writer = Task { try await h.run() }; await eventually("real SQLite failure reply not held") { await h.proxy.entered }
    let done = RegistrationCompletion(), retirement = Task { try await h.session.retireBusiness(); await done.finish() }
    await eventually("original retirement gate absent") { await h.session.businessRetired }
    let premature = await done.finished; XCTAssertFalse(premature)
    await h.proxy.release()
    do { try await writer.value; XCTFail("actual original SQL failure must be visible") }
    catch { let original = await h.proxy.originalFailure; XCTAssertEqual(String(describing: error), original); XCTAssertNil(error as? SessionError) }
    try await retirement.value; try await assertState(h, before); try await h.base.close()
  }
  func testActiveOriginalIdentityWritesAndGenerationCASRemainIntact() async throws {
    for kind in RegistrationMutation.allCases {
      let h = try await RegistrationFixture(kind), before = try await h.state(); try await h.run()
      let after = try await h.state(); XCTAssertNotEqual(after, before); let calls = await h.proxy.writes; XCTAssertEqual(calls, 1)
      try await h.session.retireBusiness(); try await h.base.close()
    }
    for kind in [RegistrationMutation.authAccept, .watchAcceptPhone, .watchAcceptWatch] {
      let h = try await RegistrationFixture(kind)
      try await h.base.suspendAccountV4(); let before = try await h.state()
      do { try await h.run(); XCTFail("real identity generation CAS must remain") }
      catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      try await assertState(h, before); try await h.base.close()
    }
  }
  func testTerminalClosuresAndOriginalReauthenticatedSagaControlRemainAvailable() async throws {
    let h = try await RegistrationFixture(.watchAcceptPhone, direct: true)
    let auth = try h.authAttempt(); try await h.base.saveAuthAttemptV4(auth, expectedIdentityGeneration: 0)
    let session = h.session
    try await session.retireBusiness()
    try await session.resolveAuthAttempt(requestID: auth.requestID, resolution: .knownAbandoned)
    let originalClosed = try h.receipt(operation: .registerWatch, result: .knownAbandoned)
    try await session.closeWatchRegistration(h.watch, receipt: originalClosed, expectedIdentityGeneration: 0)
    let resolved = try await h.base.authResolutionV4(requestID: auth.requestID), receipt = try await h.base.watchRegistrationReceiptV4(requestID: h.watch.requestID)
    XCTAssertEqual(resolved, .knownAbandoned); XCTAssertEqual(receipt, originalClosed.raw)
    let capability = AuthorityWire.base64URL(Data(repeating: 9, count: 32)); var fields = AuthorityFields()
    fields.reauthenticationID = "original-reauth-control"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
    let intent = try ControlIntentV1(requestID: "original-delete", operation: .deleteAccount, fields: fields)
    _ = try await session.prepareLifecycleControl(intent)
    let saga = try DeletionSagaV4(intent: intent, accountID: "account", activationEpoch: 1, recoveryCapability: capability, cloudChoice: .keep, localChoice: .keep, healthChoice: .keep, healthConfirmed: false, originalScope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 1))
    try await session.createDeletionSaga(saga)
    let saved = try await h.base.deletionSagaV4(requestID: intent.requestID); XCTAssertEqual(saved, saga)
    let closed = try await session.resolveTerminalAuthentication(requestID: auth.requestID, resolution: .knownExpired, expectedIdentityGeneration: 0)
    XCTAssertEqual(closed, 1); try await h.base.close()
  }
}

// Test-only access to the real actor's existing queue, never a fake coordinator.
private extension MatchSession { func registrationWaiterCount() -> Int { waiters["_authority-account"]?.count ?? 0 } }
private actor RegistrationCompletion { private(set) var finished = false; func finish() { finished = true } }
private enum RegistrationPoint: Sendable { case environment, authSave, authAccept, watchAdmit, watchSave, watchAccept }
private enum RegistrationMutation: String, CaseIterable, Sendable {
  case authSave, authAccept, watchAdmit, watchSave, watchAcceptPhone, watchAcceptWatch
  var point: RegistrationPoint { switch self { case .authSave: .authSave; case .authAccept: .authAccept; case .watchAdmit: .watchAdmit; case .watchSave: .watchSave; case .watchAcceptPhone, .watchAcceptWatch: .watchAccept } }
}
private struct RegistrationFixture: Sendable {
  static let namespace = "registration-retirement"
  let kind: RegistrationMutation, root: URL, databaseURL: URL, key: Curve25519.Signing.PrivateKey, trust: AuthorityTrustConfiguration
  let base: SQLiteSessionRepository, proxy: RegistrationRepository, session: MatchSession
  let watch: WatchRegistrationAttemptV4
  init(_ kind: RegistrationMutation, direct: Bool = false) async throws {
    self.kind = kind; root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    key = Curve25519.Signing.PrivateKey(); trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["test": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    base = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: Self.namespace, authorityTrust: trust)
    databaseURL = await base.databaseURL
    let watchKey = Curve25519.Signing.PrivateKey(), publicKey = AuthorityWire.base64URL(watchKey.publicKey.rawRepresentation), hash = String(repeating: "a", count: 64)
    let context = try WatchRegistrationContextV4(accountID: "account", cloudSpaceID: "cloud", phoneID: "phone", activationEpoch: 1, environment: .development)
    let signing: [String: Any] = ["version": 1, "requestID": "watch-attempt", "watchID": "watch", "watchPublicKey": publicKey, "challengeID": "challenge", "challengeSHA256": hash]
    let raw = try JSONSerialization.data(withJSONObject: signing, options: [.sortedKeys, .withoutEscapingSlashes])
    watch = try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: "watch-attempt", watchID: "watch", watchPublicKey: publicKey, challengeID: "challenge", deviceProof: AuthorityWire.base64URL(watchKey.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: raw)))), challengeRequestID: "challenge-request", challengeSHA256: hash)
    proxy = RegistrationRepository(base)
    let store: any SessionRepository = direct ? base : proxy
    session = MatchSession(store: store, deviceIdentity: Identity(value: "phone"), clock: TestClock(), ids: TestIDs(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: Self.namespace))
    switch kind {
    case .authSave, .watchAdmit: break
    case .authAccept: try await base.saveAuthAttemptV4(authAttempt(), expectedIdentityGeneration: 0)
    case .watchSave: _ = try await base.admitWatchRegistrationContextV4(context, deviceID: "watch", publicKey: publicKey)
    case .watchAcceptWatch:
      _ = try await base.admitWatchRegistrationContextV4(context, deviceID: "watch", publicKey: publicKey)
      try await base.saveWatchRegistrationAttemptV4(watch, expectedIdentityGeneration: 0)
    case .watchAcceptPhone:
      try await base.bindAccountV4(binding(.phone)); try await base.saveWatchRegistrationAttemptV4(watch, expectedIdentityGeneration: 0)
    }
  }
  func binding(_ role: AccountBindingV4.Role) throws -> AccountBindingV4 { try AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: role == .watch ? "watch" : "phone", activationEpoch: 1, role: role, environment: .development) }
  func authAttempt() throws -> AuthAttemptV4 { try AuthAttemptV4(requestID: "auth-attempt", deviceID: "phone", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation), cloudSpaceID: "cloud", challengeID: "auth-challenge", requestDigest: String(repeating: "b", count: 64), environment: .development) }
  func receipt(operation: AuthorityOperation, result: AuthorityResult = .registered) throws -> VerifiedAuthorityReceiptV1 {
    let requestID = operation == .authApple ? "auth-attempt" : watch.requestID, digest = try operation == .authApple ? authAttempt().requestDigest : watch.requestDigest
    var body: [String: Any] = ["version": 1, "environment": "development", "keyID": "test", "receiptID": requestID + "-receipt", "requestID": requestID, "requestDigest": digest, "operation": operation.rawValue, "accountID": "account", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": result.rawValue, "issuedAt": 1000]
    if operation == .registerWatch { body["registration"] = ["watchID": "watch", "watchPublicKey": watch.payload.watchPublicKey] }
    let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    let envelope = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: raw)))], options: [.sortedKeys, .withoutEscapingSlashes])
    return try VerifiedAuthorityReceiptV1.verify(envelope, expected: AuthorityExpectedIntent(requestID: requestID, digest: digest, operation: operation, accountID: "account", epoch: 1), trust: trust)
  }
  func run() async throws {
    switch kind {
    case .authSave: try await session.saveAuthAttempt(authAttempt(), expectedIdentityGeneration: 0)
    case .authAccept: try await session.acceptAuthentication(attempt: authAttempt(), binding: binding(.phone), receipt: receipt(operation: .authApple), expectedIdentityGeneration: 0)
    case .watchAdmit: _ = try await session.admitWatchRegistrationContext(watch.context, deviceID: "watch", publicKey: watch.payload.watchPublicKey)
    case .watchSave: try await session.saveWatchRegistrationAttempt(watch, expectedIdentityGeneration: 0)
    case .watchAcceptPhone: try await session.acceptWatchRegistration(watch, receipt: receipt(operation: .registerWatch), watchBinding: nil, expectedIdentityGeneration: 0)
    case .watchAcceptWatch: try await session.acceptWatchRegistration(watch, receipt: receipt(operation: .registerWatch), watchBinding: binding(.watch), expectedIdentityGeneration: 0)
    }
  }
  func reopen() throws -> SQLiteSessionRepository { try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: Self.namespace, authorityTrust: trust) }
  // These test-only queries use the same original MatchStore actor/connection.
  func state(_ repository: SQLiteSessionRepository? = nil) async throws -> Data {
    let original = await (repository ?? base).store
    return try await original.registrationCanonicalState()
  }
  func execute(_ sql: String) async throws { let original = await base.store; try await original.registrationExecute(sql) }

}

// Every operation forwards to the same original SQLite facade. Gates delay only
// its actual reply (or namespace read), never substitute identity or SQL facts.
private actor RegistrationRepository: SessionRepository, AccountLifecycleRepository, WatchRegistrationRepository {
  let base: SQLiteSessionRepository
  private var point: RegistrationPoint?, continuation: CheckedContinuation<Void, Never>?, loseResponse = false
  private(set) var entered = false, writes = 0, originalFailure: String?
  init(_ base: SQLiteSessionRepository) { self.base = base }
  func configure(_ point: RegistrationPoint, loseResponse: Bool = false) { self.point = point; self.loseResponse = loseResponse }
  func hold(_ point: RegistrationPoint) async { if self.point == point { entered = true; await withCheckedContinuation { continuation = $0 } } }
  func release() { point = nil; continuation?.resume(); continuation = nil }
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await base.syncRepositoryIdentity() }
  func databaseNamespace() async -> String { let value = await base.databaseNamespace(); await hold(.environment); return value }
  func matchIDs() async throws -> [String] { try await base.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await base.snapshotV2(matchID: matchID) }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await base.committedCommandV2(commandID: commandID) }
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 { try await base.commitV2(request) }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await base.pendingCaptureOperations(matchID: matchID) }
  func identityGenerationV4() async throws -> Int64 { try await base.identityGenerationV4() }
  func currentAuthRequestIDV4() async throws -> String? { try await base.currentAuthRequestIDV4() }
  func authAttemptsV4() async throws -> [AuthAttemptV4] { try await base.authAttemptsV4() }
  func authResolutionV4(requestID: String) async throws -> AuthResolutionV4? { try await base.authResolutionV4(requestID: requestID) }
  func pendingAuthAttemptsV4() async throws -> [AuthAttemptV4] { try await base.pendingAuthAttemptsV4() }
  func authAttemptV4(requestID: String) async throws -> AuthAttemptV4? { try await base.authAttemptV4(requestID: requestID) }
  func resolveTerminalAuthenticationV4(requestID: String, resolution: AuthResolutionV4, expectedIdentityGeneration: Int64) async throws -> Int64? { try await base.resolveTerminalAuthenticationV4(requestID: requestID, resolution: resolution, expectedIdentityGeneration: expectedIdentityGeneration) }
  func resolveAuthAttemptV4(requestID: String, resolution: AuthResolutionV4) async throws { try await base.resolveAuthAttemptV4(requestID: requestID, resolution: resolution) }
  func saveAuthAttemptV4(_ attempt: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws { writes += 1; try await base.saveAuthAttemptV4(attempt, expectedIdentityGeneration: expectedIdentityGeneration); await hold(.authSave) }
  func acceptAuthenticationV4(attempt: AuthAttemptV4, binding: AccountBindingV4, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws {
    writes += 1
    do { try await base.acceptAuthenticationV4(attempt: attempt, binding: binding, receipt: receipt, expectedIdentityGeneration: expectedIdentityGeneration) }
    catch { originalFailure = String(describing: error); await hold(.authAccept); throw error }
    await hold(.authAccept); if loseResponse { throw StoreError.responseLost }
  }
  func admitWatchRegistrationContextV4(_ context: WatchRegistrationContextV4, deviceID: String, publicKey: String) async throws -> Int64 { writes += 1; let value = try await base.admitWatchRegistrationContextV4(context, deviceID: deviceID, publicKey: publicKey); await hold(.watchAdmit); return value }
  func watchRegistrationAttemptV4(requestID: String) async throws -> WatchRegistrationAttemptV4? { try await base.watchRegistrationAttemptV4(requestID: requestID) }
  func pendingWatchRegistrationAttemptsV4() async throws -> [WatchRegistrationAttemptV4] { try await base.pendingWatchRegistrationAttemptsV4() }
  func watchRegistrationReceiptV4(requestID: String) async throws -> Data? { try await base.watchRegistrationReceiptV4(requestID: requestID) }
  func saveWatchRegistrationAttemptV4(_ attempt: WatchRegistrationAttemptV4, expectedIdentityGeneration: Int64) async throws { writes += 1; try await base.saveWatchRegistrationAttemptV4(attempt, expectedIdentityGeneration: expectedIdentityGeneration); await hold(.watchSave) }
  func closeWatchRegistrationV4(_ attempt: WatchRegistrationAttemptV4, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws { try await base.closeWatchRegistrationV4(attempt, receipt: receipt, expectedIdentityGeneration: expectedIdentityGeneration) }
  func acceptWatchRegistrationV4(_ attempt: WatchRegistrationAttemptV4, receipt: VerifiedAuthorityReceiptV1, watchBinding: AccountBindingV4?, expectedIdentityGeneration: Int64) async throws { writes += 1; try await base.acceptWatchRegistrationV4(attempt, receipt: receipt, watchBinding: watchBinding, expectedIdentityGeneration: expectedIdentityGeneration); await hold(.watchAccept); if loseResponse { throw StoreError.responseLost } }
  func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await base.unroutedBusinessOutboxV3(matchID: matchID) }
  func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await base.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
  func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await base.pendingPacketsV2(matchID: matchID) }
  func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await base.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
  func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await base.acknowledgeV2(bytes, peer: peer, now: now) }
  func syncStateV3(matchID: String) async throws -> SyncState { try await base.syncStateV3(matchID: matchID) }
  func ensureSyncDeliveriesV3(matchID: String) async throws { try await base.ensureSyncDeliveriesV3(matchID: matchID) }
  func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await base.dueSyncDeliveriesV3(now: now, limit: limit) }
  func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await base.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
  func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await base.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
  func reactivateSyncACKsV3() async throws { try await base.reactivateSyncACKsV3() }
  func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await base.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
  func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await base.pendingSyncAssembliesV3(peer: peer, now: now) }
  func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await base.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
  func expireSyncAssembliesV3(now: Date) async throws { try await base.expireSyncAssembliesV3(now: now) }
}

private extension MatchStore {
  func registrationCanonicalState() throws -> Data {
    let rows = try db.rows("SELECT 'binding',id,payload,checksum FROM account_binding_v4 UNION ALL SELECT 'lifecycle',id,payload,checksum FROM lifecycle_steps_v4 ORDER BY 1,2")
    let values = try rows.map { row -> [String] in
      guard let kind = row[0].string, let id = row[1].string, let payload = row[2].data, let checksum = row[3].string else { throw StoreError.invalidRequest }
      return [kind, id, payload.base64EncodedString(), checksum]
    }
    return try JSONEncoder().encode(values)
  }
  func registrationExecute(_ sql: String) throws { try db.execute(sql) }
}
