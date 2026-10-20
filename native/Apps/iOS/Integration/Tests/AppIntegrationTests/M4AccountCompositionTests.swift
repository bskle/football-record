import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import MatchPresentation
import AccountKit
import CryptoKit
@testable import AppIntegration

@MainActor final class M4AccountCompositionTests: XCTestCase {
  func testPermanentRecordingRetirementDropsBusinessReferences() async throws {
    let c = try AppBootstrap.composition(databaseNamespace: "m4-retire-model", development: true, rootDirectory: location())
    await c.model.start(starter: true); await c.model.load()
    XCTAssertNotNil(c.model.snapshot); XCTAssertFalse(c.model.history.isEmpty)
    try await M4AccountComposition.retireBusiness(session: c.session, recording: c.model)
    XCTAssertNil(c.model.snapshot, "retired UI must release business snapshots")
    XCTAssertTrue(c.model.history.isEmpty, "retired UI must release business history")
    try await c.repository.close()
  }
  func testPermanentRetirementJoinsOriginalSessionCaptureBeforeReturn() async throws {
    let gateway = CompositionSuspendedGateway()
    let c = try AppBootstrap.composition(databaseNamespace: "m4-retire-capture", development: true, workout: gateway, rootDirectory: location())
    await c.model.start(starter: true)
    let operation = await gateway.waitForEntry()
    var began = false, done = false
    let retirement = Task { began = true; try await M4AccountComposition.retireBusiness(session: c.session, recording: c.model); done = true }
    for _ in 0..<1000 { if began { break }; await Task.yield() }
    XCTAssertTrue(began)
    XCTAssertFalse(done, "retirement cannot acknowledge completion while the original Session capture driver is still awaiting a gateway")
    var generationAtReturn: Int64?
    if done { generationAtReturn = try await c.repository.snapshotV2(matchID: operation.binding.matchID).business.generation }
    await gateway.release(); try await retirement.value
    if generationAtReturn == nil { generationAtReturn = try await c.repository.snapshotV2(matchID: operation.binding.matchID).business.generation }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var settled = false
    while ContinuousClock.now < deadline {
      let value = try await c.repository.snapshotV2(matchID: operation.binding.matchID)
      if value.captureOperations.allSatisfy({ [.settled, .failed, .cancelled].contains($0.state) }) { settled = true; break }
      await Task.yield()
    }
    XCTAssertTrue(settled)
    let final = try await c.repository.snapshotV2(matchID: operation.binding.matchID)
    XCTAssertEqual(final.business.generation, generationAtReturn, "late observation wrote business facts after retirement returned")
    print("retirement-probe returned-generation=\(generationAtReturn ?? -1) final-generation=\(final.business.generation)")
    try await c.repository.close()
  }
  private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("m4-composition-" + UUID().uuidString) }
}

private actor CompositionSuspendedGateway: WorkoutGateway {
  private var operation: CaptureOperation?
  private var entry: CheckedContinuation<CaptureOperation, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  func waitForEntry() async -> CaptureOperation {
    if let operation { return operation }
    return await withCheckedContinuation { entry = $0 }
  }
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    self.operation = operation
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation; entry?.resume(returning: operation); entry = nil
    }
    return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: Date(), outcome: .running, window: CaptureWindow(start: operation.requestedAt, end: nil))
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
  func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

extension M4AccountCompositionTests {
  func testFactoryKeepsOriginalFacadeSessionAndNeverAdmitsFromCredentialAlone() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-one")
    let observer = CompositionIdentityFixture()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    XCTAssertTrue(c.context.repository === c.repository); XCTAssertTrue(c.context.session === c.session)
    let repoID = await c.repository.syncRepositoryIdentity(), sessionID = await c.session.syncRepositoryIdentity()
    XCTAssertEqual(repoID, sessionID)
    try await c.repository.bindAccountV4(binding(prepared))
    await c.context.refresh(); XCTAssertFalse(c.context.account.canEnterRecording)
    let observations = await observer.reads; XCTAssertEqual(observations, 0, "opening storage is not current identity admission")
    try await c.close()
  }
  func testProductionRejectsExplicitHTTPFixtureBeforeOpeningBusinessDB() async throws {
    let (prepared, _) = try await identityFixture(SQLiteSessionRepository.productionNamespace, signerNamespace: "m4-production-http-fixture")
    let key = Curve25519.Signing.PrivateKey(), trust = try AuthorityTrustConfiguration(environment: .production, publicKeys: ["production-fixture": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
    do { _ = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", authorityRelay: CompositionUnavailableRelay()); XCTFail("production cannot enable an explicit development protocol client") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
    try await prepared.close()
  }
  #if DEBUG
  func testControlledNamespaceAndProductionRejectionHappenBeforeOpeningDB() async throws {
    for production in [false, true] {
      let (prepared, developmentTrust) = try await identityFixture(production ? SQLiteSessionRepository.productionNamespace : "m4-controlled-wrong-namespace", signerNamespace: "m4-client-isolation")
      let directory = location(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let config = DevelopmentAuthorityConfiguration(dataset: "adapters", namespace: "m4-ui-adapters-phone", baseURL: "http://127.0.0.1:1", keyID: "authority-fixture", publicKey: try XCTUnwrap(developmentTrust.publicKeys["authority-fixture"]), cloudSpaceID: "cloud-fixture", subject: "controlled-subject", role: "phone")
      let adapters = try M4ControlledAdapters.make(configuration: config, rootDirectory: directory)
      let trust = production ? try AuthorityTrustConfiguration(environment: .production, publicKeys: developmentTrust.publicKeys) : developmentTrust
      XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
      do { _ = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", controlledAdapters: adapters); XCTFail("controlled clients must reject this original namespace/environment before opening storage") }
      catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.seed.businessDatabaseURL.path))
      try await adapters.finalClose(); try await prepared.close()
    }
  }
  func testControlledClientsCannotBeReattachedToASecondFacade() async throws {
    let (prepared, trust) = try await identityFixture("m4-ui-adapters-phone")
    let directory = location(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = DevelopmentAuthorityConfiguration(dataset: "adapters", namespace: prepared.seed.namespace, baseURL: "http://127.0.0.1:1", keyID: "authority-fixture", publicKey: try XCTUnwrap(trust.publicKeys["authority-fixture"]), cloudSpaceID: "cloud-fixture", subject: "controlled-subject", role: "phone")
    let adapters = try M4ControlledAdapters.make(configuration: config, rootDirectory: directory)
    let original = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", controlledAdapters: adapters)
    let (other, _) = try await identityFixture(prepared.seed.namespace)
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.seed.businessDatabaseURL.path))
    do { _ = try await M4AccountComposition.make(prepared: other, trust: trust, cloudSpaceID: "cloud-fixture", controlledAdapters: adapters); XCTFail("the original clients cannot be adopted by another facade") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.seed.businessDatabaseURL.path))
    let repositoryID = await original.repository.syncRepositoryIdentity(), sessionID = await original.session.syncRepositoryIdentity(); XCTAssertEqual(repositoryID, sessionID)
    XCTAssertTrue(original.context.repository === original.repository); XCTAssertTrue(original.context.session === original.session)
    try await other.close(); try await original.close()
  }
  #endif
  func testDefaultCurrentIdentityRemainsUnavailableDespiteStoredBindingAndCredential() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-two")
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture")
    try await c.repository.bindAccountV4(binding(prepared))
    do { try await c.admitCurrentIdentity(); XCTFail("default identity boundary cannot admit") }
    catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testExplicitAdmissionRequiresMatchingFreshAppleAndCloudObservation() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-three")
    let observer = CompositionIdentityFixture()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    try await c.repository.bindAccountV4(binding(prepared))
    try await c.admitCurrentIdentity(); XCTAssertTrue(c.context.account.canEnterRecording)
    await observer.setCloud("foreign-cloud")
    do { try await c.admitCurrentIdentity(); XCTFail("mismatched current cloud identity cannot admit") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testAdmissionRejectsGenerationChangedDuringCurrentIdentityAwait() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-four")
    let observer = CompositionIdentityFixture(suspend: true)
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    try await c.repository.bindAccountV4(binding(prepared))
    let admission = Task { try await c.admitCurrentIdentity() }
    await observer.waitForEntry(); try await c.repository.suspendAccountV4(); await observer.release()
    do { try await admission.value; XCTFail("old observation cannot cross durable identity generation") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testQuiescencePermanentlyStopsBusinessButKeepsOriginalSagaFacadeWritable() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-quiesce"), observer = CompositionIdentityFixture()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    let original = try binding(prepared); try await c.repository.bindAccountV4(original)
    try await c.admitCurrentIdentity()
    let generation = try await c.repository.identityGenerationV4(), identity = await c.repository.syncRepositoryIdentity()
    try await c.quiesceBusiness(); try await c.quiesceBusiness()
    XCTAssertFalse(c.context.account.canEnterRecording)
    do { _ = try await c.session.prepareStart(starter: true); XCTFail("old Session business retirement is permanent") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    do { try await c.admitCurrentIdentity(); XCTFail("old composition cannot readmit after quiescence") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    let capability = AuthorityWire.base64URL(Data(repeating: 7, count: 32)); var fields = AuthorityFields()
    fields.reauthenticationID = "original-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
    let saga = try DeletionSagaV4(intent: ControlIntentV1(requestID: "retained-parent", operation: .deleteAccount, fields: fields), accountID: original.accountID, activationEpoch: original.activationEpoch, recoveryCapability: capability, cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: CloudScopeV1(accountID: original.accountID, cloudSpaceID: original.cloudSpaceID, zoneID: "zone-fixture", activationEpoch: original.activationEpoch))
    try await c.session.createDeletionSaga(saga)
    let persisted = try await c.repository.deletionSagaV4(requestID: saga.intent.requestID)
    XCTAssertEqual(persisted, saga)
    let currentGeneration = try await c.repository.identityGenerationV4(), repoIdentity = await c.repository.syncRepositoryIdentity(), sessionIdentity = await c.session.syncRepositoryIdentity()
    XCTAssertEqual(currentGeneration, generation); XCTAssertEqual(repoIdentity, identity); XCTAssertEqual(sessionIdentity, identity)
    XCTAssertNil(c.context.recording.snapshot); XCTAssertTrue(c.context.recording.history.isEmpty)
    try await c.close()
  }
  func testQuiescenceJoinsUncooperativeIdentityObservationAndRejectsLateAdmission() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-held-identity"), observer = CompositionIdentityFixture(suspend: true)
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    try await c.repository.bindAccountV4(binding(prepared))
    let admission = Task { try await c.admitCurrentIdentity() }; await observer.waitForEntry()
    var began = false, done = false
    let retiring = Task { began = true; try await c.quiesceBusiness(); done = true }
    while !began { await Task.yield() }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(done, "quiescence must join its original cancellation-insensitive identity observation")
    await observer.release()
    do { try await admission.value; XCTFail("late old observation cannot admit") } catch {}
    try await retiring.value
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    try await c.close()
  }
  func testHeldIdentityCannotDelayOriginalSessionGateOrDispatchPreparedPermit() async throws {
    let (prepared, trust) = try await identityFixture("m4-held-identity-business-gate")
    let observer = CompositionIdentityFixture(suspend: true), relay = CompositionCountingRelay()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer, authorityRelay: relay)
    try await c.repository.bindAccountV4(binding(prepared))
    let originalID = await c.repository.syncRepositoryIdentity(), request = try await c.session.prepareStart(starter: true)
    let admission = Task { try await c.admitCurrentIdentity() }; await observer.waitForEntry()
    var done = false
    let retiring = Task { try await c.quiesceBusiness(); done = true }
    // Observe the real original Session's typed gate while the observer remains
    // held. A bounded state observation is not a scheduling/yield-count signal.
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    var retired = false
    while ContinuousClock.now < deadline {
      do { _ = try await c.session.prepareStart(starter: false) }
      catch { if error as? SessionError == .retired { retired = true; break } }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(retired, "an uncooperative identity observer cannot delay the original Session gate")
    XCTAssertFalse(done, "gate establishment does not substitute for joining the held identity task")
    do { _ = try await c.session.execute(request); XCTFail("a pre-quiescence request cannot dispatch its first permit after retirement") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    let calls = await relay.calls; XCTAssertEqual(calls, 0, "no first Authority permit HTTP may escape while identity is being joined")
    await observer.release(); _ = await admission.result; try await retiring.value
    let repositoryID = await c.repository.syncRepositoryIdentity(), sessionID = await c.session.syncRepositoryIdentity()
    XCTAssertEqual(repositoryID, originalID); XCTAssertEqual(sessionID, originalID)
    XCTAssertNil(c.admittedScope); XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testPublicM4ShutdownRetiresOriginalSessionBeforeHeldPermitReturns() async throws {
    let (prepared, trust) = try await identityFixture("m4-public-early-owner"), relay = CompositionHeldPermitRelay()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", authorityRelay: relay)
    try await c.repository.bindAccountV4(binding(prepared))
    let originalIdentity = await c.repository.syncRepositoryIdentity(), starting = Task { await c.context.recording.start(starter: true) }
    await relay.waitForEntry()
    var closed = false
    let closing = Task { await c.context.shutdown(); closed = true }
    let repeated = Task { await c.context.shutdown() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1)); var retired = false
    while ContinuousClock.now < deadline {
      do { _ = try await c.session.prepareStart(starter: false) }
      catch { if error as? SessionError == .retired { retired = true; break } }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(retired, "public M4 shutdown must reach the original Session gate before waiting for the held model operation")
    XCTAssertFalse(closed, "the same original model/Session request must finish before its DB closes")
    let calls = await relay.calls; XCTAssertEqual(calls, 1, "this integration fixture holds an already dispatched original request; it is not048's held-before-first-permit case")
    let sessionIdentity = await c.session.syncRepositoryIdentity(); XCTAssertEqual(sessionIdentity, originalIdentity)
    await relay.release(); await starting.value; await closing.value; await repeated.value
    XCTAssertNil(c.lastCloseFailure); XCTAssertNil(c.context.recording.snapshot); XCTAssertTrue(c.context.recording.history.isEmpty)
    do { _ = try await c.session.prepareStart(starter: false); XCTFail("the old Session gate is permanent") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    let original = try await M4IdentityBootstrap.prepare(root: prepared.seed.root, namespace: prepared.seed.namespace, controlDirectory: prepared.seed.controlDirectory) { _ in prepared.material }
    let repository = try original.openRepository(authorityTrust: trust)
    let ids = try await repository.matchIDs(); XCTAssertEqual(ids.count, 1)
    let saved = try await repository.snapshotV2(matchID: XCTUnwrap(ids.first))
    XCTAssertNil(saved.business.descriptor.startPermit); XCTAssertTrue(saved.business.events.isEmpty)
    try await original.close()
  }
  func testPublicContextShutdownJoinsOriginalHeldCaptureBeforeClosingFacade() async throws {
    let (prepared, trust) = try await identityFixture("m4-public-close-capture"), gateway = CompositionSuspendedGateway()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", workout: gateway)
    let operation = try await seedOriginalPendingCapture(c, prepared: prepared)
    await c.context.recording.load(); _ = await gateway.waitForEntry()
    var began = false, done = false
    let closing = Task { began = true; await c.context.shutdown(); done = true }
    while !began { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(done, "public Void context shutdown must still join the original Session writer")
    var ownerDone = false
    let sameClose = Task { try await c.close(); ownerDone = true }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(ownerDone)
    await gateway.release(); await closing.value; try await sameClose.value
    // Drain the old implementation's late error path before reopening the same DB.
    _ = try? await c.session.retireBusiness()
    let next = try await M4IdentityBootstrap.prepare(root: prepared.seed.root, namespace: prepared.seed.namespace, controlDirectory: prepared.seed.controlDirectory) { _ in prepared.material }
    let repo = try next.openRepository(authorityTrust: trust)
    let snapshot = try await repo.snapshotV2(matchID: operation.binding.matchID)
    XCTAssertEqual(snapshot.captureOperations.first(where: { $0.operation.id == operation.id })?.observation?.outcome, .running)
    try await next.close()
  }
  func testAccountReplacementLeaseFailureKeepsOriginalAndBlocksQueuedFactories() async throws {
    let (prepared, trust) = try await identityFixture("m4-account-replace-close"), gateway = CompositionSuspendedGateway()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", workout: gateway)
    _ = try await seedOriginalPendingCapture(c, prepared: prepared)
    await c.context.recording.load(); _ = await gateway.waitForEntry()
    let lifecycle = IntegrationLifecycle(), original = try await lifecycle.replace { IntegrationContext.account(c) }
    let owner = prepared.seed.controlDirectory.appendingPathComponent("identity.owner"), retained = prepared.seed.root.deletingLastPathComponent().appendingPathComponent("retained-original-owner")
    try FileManager.default.moveItem(at: owner, to: retained); try Data("foreign close owner".utf8).write(to: owner)
    var firstBegan = false, factories = 0
    let first = Task { firstBegan = true; return try await lifecycle.replace { factories += 1; throw CompositionCloseProbe.factoryReached } }
    while !firstBegan { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    let second = Task { try await lifecycle.replace { factories += 1; throw CompositionCloseProbe.factoryReached } }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(factories, 0)
    await gateway.release()
    do { _ = try await first.value; XCTFail("original lease close must fail") } catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    do { _ = try await second.value; XCTFail("queued replacement must retain the same failed owner") } catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    XCTAssertEqual(factories, 0); XCTAssertTrue(lifecycle.current === original); XCTAssertNotNil(c.lastCloseFailure)
    let foreign = prepared.seed.root.deletingLastPathComponent().appendingPathComponent("foreign-owner-preserved")
    try FileManager.default.moveItem(at: owner, to: foreign); try FileManager.default.moveItem(at: retained, to: owner)
    do { _ = try await lifecycle.replace { factories += 1; throw CompositionCloseProbe.factoryReached }; XCTFail("probe factory throws") }
    catch { XCTAssertEqual(error as? CompositionCloseProbe, .factoryReached) }
    XCTAssertEqual(factories, 1); XCTAssertNil(c.lastCloseFailure)
  }
  private func seedOriginalPendingCapture(_ c: M4AccountComposition, prepared: M4PreparedIdentity) async throws -> CaptureOperation {
    // Explicit local unbound-development facts only, on the one original facade.
    // This is not an authenticated account recording or an authority permit test.
    let date = Date(), intent = StartIntent(id: "close-intent", matchID: "close-match", recordingDeviceID: prepared.seed.installationID, requestedAt: date)
    let original = MatchDescriptor(startIntent: intent, starter: true)
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: intent.id, expectedGeneration: 0, descriptor: original, events: [], captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: []))
    let descriptor = MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
    var recorder = LiveMatchRecorder(descriptor: descriptor); try recorder.start(eventID: "close-start", sourceDeviceID: prepared.seed.installationID, now: date)
    let operation = try CaptureOperation(id: "close-capture", binding: CaptureBinding(matchID: intent.matchID, recordingDeviceID: prepared.seed.installationID), associatedCommandID: "close-start-command", action: .start, requestedAt: date, externalToken: "close-capture")
    let delta = try BusinessOutboxItem(id: "close-delta", matchID: intent.matchID, sourceDeviceID: prepared.seed.installationID, payload: BusinessDeltaV2(descriptor: descriptor, events: recorder.events, captureRevisions: []))
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: "close-start-command", expectedGeneration: 1, descriptor: descriptor, events: recorder.events, captureRevisions: [], newCaptureOperations: [operation], captureOperationUpdates: [], businessOutbox: [delta]))
    return operation
  }
  private func binding(_ prepared: M4PreparedIdentity) throws -> AccountBindingV4 {
    try AccountBindingV4(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", deviceID: prepared.seed.installationID, activationEpoch: 1, role: .phone, environment: .development)
  }
  private func identityFixture(_ namespace: String, signerNamespace: String? = nil) async throws -> (M4PreparedIdentity, AuthorityTrustConfiguration) {
    let root = location(), trustKey = Curve25519.Signing.PrivateKey()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["authority-fixture": AuthorityWire.base64URL(trustKey.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("retained")) { seed in
      let signer = try DevelopmentDeviceSigner(namespace: signerNamespace ?? namespace, rawRepresentation: Data(repeating: 21, count: 32))
      let credential = DeviceCredential(token: AuthorityWire.base64URL(Data(repeating: 5, count: 32)), sessionID: "session-fixture", accountID: "account-fixture", deviceID: seed.installationID, keyID: try AuthorityWire.deviceKeyID(publicKey: signer.publicKey), activationEpoch: 1, expiresAt: 9_007_199_254_740_990)
      return M4IdentityMaterial(signer: signer, vault: MemoryDeviceCredentialVault(credential))
    }
    return (prepared, trust)
  }
}
private actor CompositionIdentityFixture: M4CurrentIdentityObserving {
  private var cloud = "cloud-fixture"
  private let suspend: Bool
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  private(set) var reads = 0
  init(suspend: Bool = false) { self.suspend = suspend }
  func currentIdentity() async throws -> M4CurrentAccountIdentity {
    reads += 1
    if suspend { await withCheckedContinuation { continuation in held = continuation; entered = true; entry?.resume(); entry = nil } }
    return M4CurrentAccountIdentity(accountID: "account-fixture", cloudSpaceID: cloud, zoneID: "zone-fixture", environment: .development)
  }
  func advanceIdentityFence(to generation: Int64) async throws {}
  func setCloud(_ value: String) { cloud = value }
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { entry = $0 } }
  func release() { held?.resume(); held = nil }
}

private struct CompositionUnavailableRelay: AuthorityHTTPRelay {
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse { throw AuthorityError.unavailable }
}

private enum CompositionCloseProbe: Error { case factoryReached }

private actor CompositionCountingRelay: AuthorityHTTPRelay {
  private(set) var calls = 0
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1; throw AuthorityError.unavailable
  }
}

private actor CompositionHeldPermitRelay: AuthorityHTTPRelay {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  private(set) var calls = 0
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1; entered = true
    await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
    throw AuthorityError.unavailable
  }
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
  func release() { held?.resume(); held = nil }
}

extension M4AccountCompositionTests {
  func testInitialAccountRecoveryUsesFreshIdentityAndOriginalSignedService() async throws {
    let f = try await serviceFixture()
    let original = await f.composition.repository.syncRepositoryIdentity()
    await f.composition.context.account.perform(.recover)
    let binding = try await f.composition.repository.accountBindingV4(), credential = try? await f.vault.credential()
    let reads = await f.observer.reads, calls = await f.relay.calls
    XCTAssertEqual(binding?.accountID, "account-fixture"); XCTAssertEqual(credential?.accountID, "account-fixture")
    XCTAssertGreaterThanOrEqual(reads, 2, "initial service admission and final presentation each need a new independent observation")
    XCTAssertEqual(calls, 1); XCTAssertTrue(f.composition.context.account.canEnterRecording)
    let after = await f.composition.repository.syncRepositoryIdentity(), session = await f.composition.session.syncRepositoryIdentity()
    XCTAssertEqual(after, original); XCTAssertEqual(session, original)
    try await f.composition.close()
  }
  func testMismatchingFreshIdentityRejectsInitialRecoveryBeforeHTTP() async throws {
    let f = try await serviceFixture(); await f.observer.setCloud("foreign-cloud")
    let before = try await f.composition.repository.authAttemptV4(requestID: f.attempt.requestID)
    await f.composition.context.account.perform(.recover)
    let calls = await f.relay.calls, reads = await f.observer.reads
    let binding = try await f.composition.repository.accountBindingV4(), after = try await f.composition.repository.authAttemptV4(requestID: f.attempt.requestID)
    XCTAssertEqual(calls, 0); XCTAssertEqual(reads, 1); XCTAssertNil(binding); XCTAssertEqual(before, after)
    XCTAssertFalse(f.composition.context.account.canEnterRecording)
    try await f.composition.close()
  }
  func testQuiesceJoinsOriginalAuthenticationVaultTailBeforeReturning() async throws {
    let f = try await serviceFixture(holdVault: true), c = f.composition
    let action = Task { await c.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else {
      XCTFail("original AccountService must reach its real vault.replace after verified receipt and original SQL")
      await action.value; try await c.close(); return
    }
    let committed = try await c.repository.accountBindingV4(); XCTAssertEqual(committed?.accountID, "account-fixture")
    var quiesced = false
    let drain = Task { try await c.quiesceBusiness(); quiesced = true }
    let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while !quiesced, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertFalse(quiesced, "Session SQL drain alone must not release the still-held original vault write")
    await f.vault.release(); await action.value; try await drain.value
    let retained = try await c.repository.accountBindingV4(), credential = try await f.vault.credential()
    XCTAssertEqual(retained, committed); XCTAssertEqual(credential.accountID, "account-fixture")
    XCTAssertFalse(c.context.account.canEnterRecording)
    let before = await f.relay.calls; await c.context.account.perform(.renew); let after = await f.relay.calls; XCTAssertEqual(after, before)
    try await c.close()
    let reopened = try SQLiteSessionRepository(rootDirectory: f.prepared.seed.root, databaseNamespace: f.prepared.seed.namespace, authorityTrust: f.trust)
    let original = try await reopened.accountBindingV4(); XCTAssertEqual(original, committed); try await reopened.close()
  }
  func testFinalCloseJoinsOriginalAuthenticationVaultTailAndPublicVoidCallback() async throws {
    let f = try await serviceFixture(holdVault: true), c = f.composition
    let action = Task { await c.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else {
      XCTFail("original service did not reach its verified credential tail")
      await action.value; try await c.close(); return
    }
    let committed = try await c.repository.accountBindingV4()
    var publicDone = false, closeDone = false
    let publicClose = Task { await c.context.shutdown(); publicDone = true }
    let close = Task { try await c.close(); closeDone = true }
    let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while !closeDone, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertFalse(closeDone); XCTAssertFalse(publicDone)
    let heldOriginal = try? await c.repository.accountBindingV4()
    XCTAssertEqual(heldOriginal, committed, "original DB must remain open until the complete original service returns")
    await f.vault.release(); await action.value; try await close.value; await publicClose.value
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.lastCloseFailure)
    let reopened = try SQLiteSessionRepository(rootDirectory: f.prepared.seed.root, databaseNamespace: f.prepared.seed.namespace, authorityTrust: f.trust)
    let retained = try await reopened.accountBindingV4(); XCTAssertEqual(retained, committed); try await reopened.close()
  }
  func testChangedPostServiceIdentityCannotAdmitInitialRecovery() async throws {
    let f = try await serviceFixture(holdVault: true)
    let action = Task { await f.composition.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else {
      XCTFail("original service did not reach the real credential tail")
      await action.value; try await f.composition.close(); return
    }
    await f.observer.setCloud("foreign-cloud"); await f.vault.release(); await action.value
    let binding = try await f.composition.repository.accountBindingV4(), reads = await f.observer.reads
    XCTAssertEqual(binding?.accountID, "account-fixture", "verified original positive SQL remains retained")
    XCTAssertGreaterThanOrEqual(reads, 2); XCTAssertFalse(f.composition.context.account.canEnterRecording)
    try await f.composition.close()
  }
  func testReadyAccountRenewalMismatchImmediatelyDropsPriorAdmission() async throws {
    let f = try await serviceFixture(); await f.composition.context.account.perform(.recover)
    XCTAssertTrue(f.composition.context.account.canEnterRecording)
    let original = try await f.composition.repository.accountBindingV4()
    await f.observer.setCloud("foreign-cloud"); await f.composition.context.account.perform(.renew)
    let calls = await f.relay.calls, retained = try await f.composition.repository.accountBindingV4()
    XCTAssertEqual(calls, 1); XCTAssertEqual(retained, original)
    XCTAssertFalse(f.composition.context.account.canEnterRecording, "a failed new current observation must remove the prior UI admission")
    try await f.composition.close()
  }
  func testOwnedPhoneAuthorizerUsesFreshIdentityAndRejectsAfterRetirement() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover)
    let endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: c.phoneAuthorizer), id = UUID()
    guard case .context(let replyID, let original) = try await endpoint.handle(.context(id)) else { return XCTFail("original context reply required") }
    XCTAssertEqual(replyID, id); XCTAssertEqual(original.phoneID, f.prepared.seed.installationID)
    XCTAssertEqual(original.accountID, "account-fixture"); XCTAssertEqual(original.cloudSpaceID, "cloud-fixture")
    await f.observer.setCloud("foreign-cloud")
    do { _ = try await endpoint.handle(.context(UUID())); XCTFail("Phone may not authorize from a retained credential/config") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    await f.observer.setCloud("cloud-fixture"); try await c.quiesceBusiness()
    do { _ = try await endpoint.handle(.context(UUID())); XCTFail("original Phone entry remains permanently stopped") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    await endpoint.close(); try await c.close()
  }
  func testQuiesceJoinsCompleteOriginalPhoneAuthorizationCall() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover)
    let context = try await c.phoneAuthorizer.registrationContext(), key = Curve25519.Signing.PrivateKey()
    let hash = AuthorityWire.hash(Data("original-phone-challenge".utf8)), publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
    let body: [String: Any] = ["version": 1, "requestID": "phone-held-watch", "watchID": "watch-service", "watchPublicKey": publicKey, "challengeID": "phone-held-challenge", "challengeSHA256": hash]
    let proof = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])))
    let attempt = try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: "phone-held-watch", watchID: "watch-service", watchPublicKey: publicKey, challengeID: "phone-held-challenge", deviceProof: AuthorityWire.base64URL(proof)), challengeRequestID: "phone-held-challenge-request", challengeSHA256: hash)
    let endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: c.phoneAuthorizer)
    let call = Task { try await endpoint.handle(.authorize(UUID(), attempt, .submit)) }
    let until = ContinuousClock.now.advanced(by: .seconds(2)); var entered = false
    while ContinuousClock.now < until { if await f.relay.phoneEntered { entered = true; break }; try await Task.sleep(for: .milliseconds(2)) }
    guard entered else { XCTFail("original Phone service must reach its real signed HTTP request"); _ = await call.result; await endpoint.close(); try await c.close(); return }
    let persisted = try await c.repository.watchRegistrationAttemptV4(requestID: attempt.requestID); XCTAssertEqual(persisted, attempt)
    var done = false; let drain = Task { try await c.quiesceBusiness(); done = true }
    let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while !done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertFalse(done, "Phone service may still publish/accept after its SQL attempt has already returned")
    let retained = try? await c.repository.watchRegistrationAttemptV4(requestID: attempt.requestID); XCTAssertEqual(retained, attempt)
    await f.relay.releasePhone()
    do { _ = try await call.value; XCTFail("controlled original HTTP refusal must remain an error") } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    try await drain.value; await endpoint.close()
    let receipt = try await c.repository.watchRegistrationReceiptV4(requestID: attempt.requestID); XCTAssertNil(receipt)
    try await c.close()
  }
  private func waitForVault(_ vault: CompositionServiceVault) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline { if await vault.entered { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
  }
  private func waitForOriginalRetirement(_ session: MatchSession) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      do { _ = try await session.prepareStart(starter: true) }
      catch SessionError.retired { return true } catch {}
      try? await Task.sleep(for: .milliseconds(2))
    }
    return false
  }
  private struct ServiceFixture {
    let composition: M4AccountComposition
    let prepared: M4PreparedIdentity
    let trust: AuthorityTrustConfiguration
    let observer: CompositionIdentityFixture
    let vault: CompositionServiceVault
    let relay: CompositionAuthenticationRelay
    let attempt: AuthAttemptV4
  }
  private func serviceFixture(holdVault: Bool = false) async throws -> ServiceFixture {
    let root = location(), key = Curve25519.Signing.PrivateKey(), vault = CompositionServiceVault(hold: holdVault), observer = CompositionIdentityFixture()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "m4-service-owner", controlDirectory: root.appendingPathComponent("retained")) { _ in
      M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: "m4-service-owner", rawRepresentation: Data(repeating: 31, count: 32)), vault: vault)
    }
    let attempt = try AuthAttemptV4(requestID: "original-auth", deviceID: prepared.seed.installationID, publicKey: prepared.material.signer.publicKey, cloudSpaceID: "cloud-fixture", challengeID: "original-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
    let relay = CompositionAuthenticationRelay(key: key, attempt: attempt)
    let composition = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer, authorityRelay: relay)
    try await composition.session.saveAuthAttempt(attempt, expectedIdentityGeneration: 0)
    return ServiceFixture(composition: composition, prepared: prepared, trust: trust, observer: observer, vault: vault, relay: relay, attempt: attempt)
  }
}

private actor CompositionServiceVault: DeviceCredentialVault {
  private let original = MemoryDeviceCredentialVault()
  private let hold: Bool
  private var held: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  init(hold: Bool) { self.hold = hold }
  func credential() async throws -> DeviceCredential { try await original.credential() }
  func advanceIdentityFence(to generation: Int64) async throws { try await original.advanceIdentityFence(to: generation) }
  func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) async throws {
    entered = true
    if hold { await withCheckedContinuation { held = $0 } }
    try await original.replace(credential, expectedIdentityGeneration: expectedIdentityGeneration)
  }
  func release() { held?.resume(); held = nil }
}
private actor CompositionAuthenticationRelay: AuthorityHTTPRelay {
  private let key: Curve25519.Signing.PrivateKey
  private let attempt: AuthAttemptV4
  private(set) var calls = 0
  private(set) var phoneEntered = false
  private var heldPhone: CheckedContinuation<Void, Never>?
  func releasePhone() { heldPhone?.resume(); heldPhone = nil }
  init(key: Curve25519.Signing.PrivateKey, attempt: AuthAttemptV4) { self.key = key; self.attempt = attempt }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1
    if request.path == "/v1/devices/watches" {
      guard request.authorization != nil, request.deviceProof != nil else { throw AuthorityError.invalidWire }
      phoneEntered = true
      await withCheckedContinuation { heldPhone = $0 }
      throw AuthorityError.unavailable
    }
    guard request.path == "/v1/auth/recover", let value = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          value["authRequestID"] as? String == attempt.requestID else { throw AuthorityError.invalidWire }
    let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "service-key", "receiptID": "original-auth-receipt", "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "authApple", "accountID": "account-fixture", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "registered", "issuedAt": Int64(Date().timeIntervalSince1970)]
    let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    let receipt: [String: Any] = ["body": body, "signature": AuthorityWire.base64URL(try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: raw)))]
    let expires = Int64(Date().timeIntervalSince1970) + 3600
    let response: [String: Any] = ["receipt": receipt, "sessionClaims": ["sessionID": "original-service-session", "expiresAt": expires], "credential": ["token": AuthorityWire.base64URL(Data(repeating: 11, count: 32)), "sessionID": "original-service-session", "accountID": "account-fixture", "deviceID": attempt.deviceID, "keyID": attempt.keyID, "activationEpoch": 1, "expiresAt": expires], "context": ["accountID": "account-fixture", "deviceID": attempt.deviceID, "keyID": attempt.keyID, "activationEpoch": 1], "reauthenticationID": "original-service-reauth"]
    return AuthorityHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]))
  }
}

#if DEBUG
extension M4AccountCompositionTests {
  func testFreshSignInUsesOriginalChallengeAppleProofAndCurrentIdentity() async throws {
    let f = try await freshServiceFixture()
    let action = Task { await f.composition.context.account.perform(.signIn) }
    let apple = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: apple.payload) as? [String: String])
    XCTAssertEqual(payload["nonce"], AuthorityWire.hash(Data("original-service-challenge".utf8)))
    try serviceMailboxReply(apple, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    await action.value
    let binding = try await f.composition.repository.accountBindingV4(), current = try await f.composition.repository.currentAuthRequestIDV4()
    let attempt = try await f.composition.repository.authAttemptV4(requestID: XCTUnwrap(current)), body = await f.relay.originalAuthBody
    XCTAssertEqual(binding?.role, .phone); XCTAssertEqual(binding?.deviceID, f.prepared.seed.installationID)
    XCTAssertEqual(attempt?.requestDigest, body.map(AuthorityWire.hash)); XCTAssertTrue(f.composition.context.account.canEnterRecording)
    let reads = await f.observer.reads, calls = await f.relay.calls; XCTAssertEqual(reads, 2); XCTAssertEqual(calls, 2)
    try await f.composition.close()
  }
  func testFreshWatchRegistrationUsesOriginalServiceAndTwoContexts() async throws {
    try await freshWatchService(holdVault: false)
  }
  func testOriginalWatchVaultTailCannotOutliveBusinessDrain() async throws {
    try await freshWatchService(holdVault: true)
  }
  private func freshWatchService(holdVault: Bool) async throws {
    let f = try await freshServiceFixture(watch: true, holdVault: holdVault), c = f.composition
    let context = try WatchRegistrationContextV4(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", phoneID: "independent-original-phone", activationEpoch: 1, environment: .development)
    let action = Task { await c.context.account.perform(.registerWatch) }
    let first = try await serviceMailboxRequest(f.protocolRoot, operation: "phone-context")
    try serviceMailboxReply(first, payload: AuthorityWire.encode(context))
    let registration = try await serviceMailboxRequest(f.protocolRoot, operation: "phone-register")
    let forward = try JSONDecoder().decode(CompositionWatchForward.self, from: registration.payload)
    XCTAssertEqual(forward.action, .submit); XCTAssertEqual(forward.attempt.context, context)
    XCTAssertEqual(forward.attempt.payload.watchID, f.prepared.seed.installationID)
    let receipt = try serviceFixtureReceipt(key: f.key, requestID: forward.attempt.requestID, digest: forward.attempt.requestDigest, operation: "registerWatch", registration: ["watchID": forward.attempt.payload.watchID, "watchPublicKey": forward.attempt.payload.watchPublicKey])
    let expires = Int64(Date().timeIntervalSince1970) + 3600
    let response: [String: Any] = ["receipt": receipt, "sessionClaims": ["sessionID": "original-watch-session", "expiresAt": expires], "credential": ["token": AuthorityWire.base64URL(Data(repeating: 15, count: 32)), "sessionID": "original-watch-session", "accountID": "account-fixture", "deviceID": f.prepared.seed.installationID, "keyID": try AuthorityWire.deviceKeyID(publicKey: f.prepared.material.signer.publicKey), "activationEpoch": 1, "expiresAt": expires]]
    try serviceMailboxReply(registration, payload: JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]))
    if holdVault {
      guard await waitForVault(f.vault) else { XCTFail("original Watch service must reach its credential tail"); await action.value; try await c.close(); return }
      let committed = try await c.repository.accountBindingV4(); XCTAssertEqual(committed?.role, .watch)
      var done = false; let drain = Task { try await c.quiesceBusiness(); done = true }
      let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
      while !done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertFalse(done); let stillOpen = try? await c.repository.accountBindingV4(); XCTAssertEqual(stillOpen, committed)
      await f.vault.release(); await action.value; try await drain.value
      XCTAssertFalse(c.context.account.canEnterRecording)
    } else {
      let second = try await serviceMailboxRequest(f.protocolRoot, operation: "phone-context")
      try serviceMailboxReply(second, payload: AuthorityWire.encode(context))
      await action.value; XCTAssertTrue(c.context.account.canEnterRecording)
      let reads = await f.observer.reads; XCTAssertEqual(reads, 2)
    }
    let actual = try await c.repository.watchRegistrationAttemptV4(requestID: forward.attempt.requestID), raw = try await c.repository.watchRegistrationReceiptV4(requestID: forward.attempt.requestID)
    XCTAssertEqual(actual, forward.attempt); XCTAssertEqual(raw, try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes]))
    let credential = try await f.vault.credential(); XCTAssertEqual(credential.deviceID, f.prepared.seed.installationID)
    let repoID = await c.repository.syncRepositoryIdentity(), sessionID = await c.session.syncRepositoryIdentity(); XCTAssertEqual(repoID, sessionID)
    try await c.close()
  }
  private struct FreshServiceFixture {
    let composition: M4AccountComposition
    let prepared: M4PreparedIdentity
    let observer: CompositionIdentityFixture
    let vault: CompositionServiceVault
    let relay: CompositionFreshAuthenticationRelay
    let protocolRoot: URL
    let key: Curve25519.Signing.PrivateKey
  }
  private func freshServiceFixture(watch: Bool = false, holdVault: Bool = false) async throws -> FreshServiceFixture {
    let root = location(), protocolRoot = root.appendingPathComponent("protocol"), key = Curve25519.Signing.PrivateKey(), observer = CompositionIdentityFixture(), vault = CompositionServiceVault(hold: holdVault)
    let namespace = watch ? "m4-ui-fresh-watch" : "m4-ui-fresh-phone", publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": publicKey])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("retained")) { _ in
      M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: namespace, rawRepresentation: Data(repeating: watch ? 42 : 41, count: 32)), vault: vault)
    }
    let config = DevelopmentAuthorityConfiguration(dataset: "fresh", namespace: namespace, baseURL: "http://127.0.0.1:1", keyID: "service-key", publicKey: publicKey, cloudSpaceID: "cloud-fixture", subject: "configuration-does-not-admit-current-identity", role: watch ? "watch" : "phone")
    let adapters = try M4ControlledAdapters.make(configuration: config, rootDirectory: protocolRoot)
    let relay = CompositionFreshAuthenticationRelay(key: key, deviceID: prepared.seed.installationID, publicKey: prepared.material.signer.publicKey)
    let composition = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer, authorityRelay: relay, controlledAdapters: adapters)
    return FreshServiceFixture(composition: composition, prepared: prepared, observer: observer, vault: vault, relay: relay, protocolRoot: protocolRoot, key: key)
  }
  private struct ServiceMailboxRequest { let response: URL; let payload: Data }
  private func serviceMailboxRequest(_ root: URL, operation: String) async throws -> ServiceMailboxRequest {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3)), directory = root.appendingPathComponent("development/mailbox/outgoing")
    while ContinuousClock.now < deadline {
      for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], value["operation"] as? String == operation,
              let id = value["id"] as? String, let encoded = value["payload"] as? String, let payload = Data(base64Encoded: encoded) else { continue }
        return ServiceMailboxRequest(response: root.appendingPathComponent("development/mailbox/responses/" + id + ".json"), payload: payload)
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AuthorityError.unavailable
  }
  private func serviceMailboxReply(_ request: ServiceMailboxRequest, payload: Data) throws {
    try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString()], options: [.sortedKeys]).write(to: request.response, options: .atomic)
  }
}
private struct CompositionWatchForward: Decodable { let attempt: WatchRegistrationAttemptV4; let action: WatchRegistrationAction }
private func serviceFixtureReceipt(key: Curve25519.Signing.PrivateKey, requestID: String, digest: String, operation: String, registration: [String: String]? = nil) throws -> [String: Any] {
  var body: [String: Any] = ["version": 1, "environment": "development", "keyID": "service-key", "receiptID": requestID + "-receipt", "requestID": requestID, "requestDigest": digest, "operation": operation, "accountID": "account-fixture", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "registered", "issuedAt": Int64(Date().timeIntervalSince1970)]
  if let registration { body["registration"] = registration }
  let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
  return ["body": body, "signature": AuthorityWire.base64URL(try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: raw)))]
}
private actor CompositionFreshAuthenticationRelay: AuthorityHTTPRelay {
  let key: Curve25519.Signing.PrivateKey
  let deviceID, publicKey: String
  private(set) var calls = 0
  private(set) var originalAuthBody: Data?
  init(key: Curve25519.Signing.PrivateKey, deviceID: String, publicKey: String) { self.key = key; self.deviceID = deviceID; self.publicKey = publicKey }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1
    guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any], let id = object["requestID"] as? String,
          object["deviceID"] as? String == deviceID, object["devicePublicKey"] as? String == publicKey else { throw AuthorityError.invalidWire }
    if request.path == "/v1/auth/challenges" {
      let value: [String: Any] = ["version": 1, "requestID": id, "challengeID": "fresh-original-challenge", "challenge": "original-service-challenge", "expiresAt": Int64(Date().timeIntervalSince1970) + 120]
      return AuthorityHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    guard request.path == "/v1/auth/apple", object["identityToken"] as? String == "explicit-current-token", object["authorizationCode"] as? String == "explicit-current-code",
          object["challengeID"] as? String == "fresh-original-challenge", object["cloudSpaceID"] as? String == "cloud-fixture", let proof = object["deviceProof"] as? String else { throw AuthorityError.invalidWire }
    var signing = object; signing["deviceProof"] = nil; signing["challengeSHA256"] = AuthorityWire.hash(Data("original-service-challenge".utf8))
    let signingBytes = try JSONSerialization.data(withJSONObject: signing, options: [.sortedKeys, .withoutEscapingSlashes]), deviceKey = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(publicKey, count: 32))
    guard deviceKey.isValidSignature(try AuthorityWire.decodeBase64URL(proof, count: 64), for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: signingBytes)) else { throw AuthorityError.invalidSignature }
    originalAuthBody = request.body
    let receipt = try serviceFixtureReceipt(key: key, requestID: id, digest: AuthorityWire.hash(request.body), operation: "authApple"), expires = Int64(Date().timeIntervalSince1970) + 3600
    let keyID = try AuthorityWire.deviceKeyID(publicKey: publicKey)
    let response: [String: Any] = ["receipt": receipt, "sessionClaims": ["sessionID": "fresh-original-session", "expiresAt": expires], "credential": ["token": AuthorityWire.base64URL(Data(repeating: 16, count: 32)), "sessionID": "fresh-original-session", "accountID": "account-fixture", "deviceID": deviceID, "keyID": keyID, "activationEpoch": 1, "expiresAt": expires], "context": ["accountID": "account-fixture", "deviceID": deviceID, "keyID": keyID, "activationEpoch": 1], "reauthenticationID": "fresh-original-reauth"]
    return AuthorityHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]))
  }
}
#endif
