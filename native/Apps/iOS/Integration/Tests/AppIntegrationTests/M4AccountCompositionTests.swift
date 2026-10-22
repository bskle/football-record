import Foundation
import Darwin
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import MatchPresentation
import AccountKit
import CryptoKit
import CloudSync
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
    let f = try await serviceFixture(), c = f.composition, observer = f.observer
    await c.context.account.perform(.recover)
    try await c.admitCurrentIdentity(); XCTAssertTrue(c.context.account.canEnterRecording)
    await observer.setCloud("foreign-cloud")
    do { try await c.admitCurrentIdentity(); XCTFail("mismatched current cloud identity cannot admit") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testAdmissionRejectsGenerationChangedDuringCurrentIdentityAwait() async throws {
    let f = try await serviceFixture(), c = f.composition, observer = f.observer
    await c.context.account.perform(.recover); await observer.holdNext()
    let admission = Task { try await c.admitCurrentIdentity() }
    await observer.waitForEntry(); try await c.repository.suspendAccountV4(); await observer.release()
    do { try await admission.value; XCTFail("old observation cannot cross durable identity generation") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await c.close()
  }
  func testQuiescencePermanentlyStopsBusinessButKeepsOriginalSagaFacadeWritable() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover)
    let value = try await c.repository.accountBindingV4(), original = try XCTUnwrap(value)
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
    let f = try await serviceFixture(), c = f.composition, observer = f.observer
    await c.context.account.perform(.recover); await observer.holdNext()
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
    let f = try await serviceFixture(), c = f.composition, observer = f.observer, relay = f.relay
    await c.context.account.perform(.recover); let priorCalls = await relay.calls
    await observer.holdNext()
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
    let calls = await relay.calls; XCTAssertEqual(calls, priorCalls, "no first Authority permit HTTP may escape while identity is being joined")
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
  private var account = "account-fixture", zone = "zone-fixture"
  private var environment: AuthorityEnvironment = .development
  private var suspend: Bool
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  private(set) var reads = 0
  init(suspend: Bool = false) { self.suspend = suspend }
  func currentIdentity() async throws -> M4CurrentAccountIdentity {
    reads += 1
    if suspend { suspend = false; await withCheckedContinuation { continuation in held = continuation; entered = true; entry?.resume(); entry = nil } }
    return M4CurrentAccountIdentity(accountID: account, cloudSpaceID: cloud, zoneID: zone, environment: environment)
  }
  func advanceIdentityFence(to generation: Int64) async throws {}
  func setCloud(_ value: String) { cloud = value }
  func setZone(_ value: String) { zone = value }
  func setAccount(_ value: String) { account = value }
  func setEnvironment(_ value: AuthorityEnvironment) { environment = value }
  func holdNext() { suspend = true; entered = false }
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
  private func serviceFixture(holdVault: Bool = false, managed: Bool = true, resourceReplyGate: (@MainActor () async -> Void)? = nil, expiresIn: Int64 = 3600, waiting: Bool = false, crashHook: ((M4ResourceCrashPoint) throws -> Void)? = nil) async throws -> ServiceFixture {
    let root = location(), key = Curve25519.Signing.PrivateKey(), vault = CompositionServiceVault(hold: holdVault), observer = CompositionIdentityFixture()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: "m4-service-owner", controlDirectory: root.appendingPathComponent("retained")) { _ in
      M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: "m4-service-owner", rawRepresentation: Data(repeating: 31, count: 32)), vault: vault)
    }
    let attempt = try AuthAttemptV4(requestID: "original-auth", deviceID: prepared.seed.installationID, publicKey: prepared.material.signer.publicKey, cloudSpaceID: "cloud-fixture", challengeID: "original-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
    let relay = CompositionAuthenticationRelay(key: key, attempt: attempt, expiresIn: expiresIn, waiting: waiting)
    if managed { try prepared.prepareManagedResources(crashHook: crashHook, resourceReplyGate: resourceReplyGate) }
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
  private(set) var replacements = 0, fenceMovements = 0
  private var fence: Int64 = 0
  init(hold: Bool) { self.hold = hold }
  func credential() async throws -> DeviceCredential { try await original.credential() }
  func advanceIdentityFence(to generation: Int64) async throws { try await original.advanceIdentityFence(to: generation); if generation > fence { fenceMovements += 1; fence = generation } }
  func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) async throws {
    entered = true; replacements += 1
    if hold && replacements == 1 { await withCheckedContinuation { held = $0 } }
    try await original.replace(credential, expectedIdentityGeneration: expectedIdentityGeneration)
  }
  func release() { held?.resume(); held = nil }
}
private actor CompositionAuthenticationRelay: AuthorityHTTPRelay {
  private let key: Curve25519.Signing.PrivateKey
  private let attempt: AuthAttemptV4
  private let expiresIn: Int64
  private let waiting: Bool
  private var recoveryFailure: Int?
  private(set) var paths: [String] = [], recoveredIDs: [String] = []
  func failRecovery(_ status: Int) { recoveryFailure = status }
  private(set) var calls = 0
  private(set) var phoneEntered = false
  private var heldPhone: CheckedContinuation<Void, Never>?
  func releasePhone() { heldPhone?.resume(); heldPhone = nil }
  init(key: Curve25519.Signing.PrivateKey, attempt: AuthAttemptV4, expiresIn: Int64 = 3600, waiting: Bool = false) { self.key = key; self.attempt = attempt; self.expiresIn = expiresIn; self.waiting = waiting }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1; paths.append(request.path)
    if request.path == "/v1/devices/watches" {
      guard request.authorization != nil, request.deviceProof != nil else { throw AuthorityError.invalidWire }
      phoneEntered = true
      await withCheckedContinuation { heldPhone = $0 }
      throw AuthorityError.unavailable
    }
    guard request.path == "/v1/auth/recover", let value = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          value["authRequestID"] as? String == attempt.requestID else { throw AuthorityError.invalidWire }
    recoveredIDs.append(attempt.requestID)
    if let recoveryFailure {
      if recoveryFailure == 0 { throw URLError(.timedOut) }
      return AuthorityHTTPResponse(status: recoveryFailure, body: try JSONSerialization.data(withJSONObject: ["code": recoveryFailure == 401 ? "unauthorized" : "notFound", "requestID": attempt.requestID, "retryable": false], options: [.sortedKeys]))
    }
    let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "service-key", "receiptID": "original-auth-receipt", "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "authApple", "accountID": "account-fixture", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": waiting ? "waitingMigration" : "registered", "issuedAt": Int64(Date().timeIntervalSince1970)]
    let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    let receipt: [String: Any] = ["body": body, "signature": AuthorityWire.base64URL(try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: raw)))]
    let expires = Int64(Date().timeIntervalSince1970) + expiresIn
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
    let reads = await f.observer.reads, calls = await f.relay.calls; XCTAssertGreaterThanOrEqual(reads, 3); XCTAssertEqual(calls, 2)
    try await f.composition.close()
  }
  func testOriginalUnboundWatchProtocolRetainsFactsWithoutBusinessAdmission() async throws {
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
      await action.value
      XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
      do { try await c.admitCurrentIdentity(); XCTFail("Watch protocol completion is not supported Phone resource admission") }
      catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
      XCTAssertEqual(c.context.account.phase, .suspended)
      let before = await f.relay.calls
      for action in [AccountUserAction.signIn, .registerWatch, .recover] {
        do { try await c.performAccount(action); XCTFail("bound Watch stays unsupported without new generic protocol calls") }
        catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
      }
      let after = await f.relay.calls; XCTAssertEqual(after, before)
      let reads = await f.observer.reads; XCTAssertGreaterThanOrEqual(reads, 1)
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
  private func freshServiceFixture(watch: Bool = false, holdVault: Bool = false, resourceReplyGate: (@MainActor () async -> Void)? = nil) async throws -> FreshServiceFixture {
    let root = location(), protocolRoot = root.appendingPathComponent("protocol"), key = Curve25519.Signing.PrivateKey(), observer = CompositionIdentityFixture(), vault = CompositionServiceVault(hold: holdVault)
    let namespace = watch ? "m4-ui-fresh-watch" : "m4-ui-fresh-phone", publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": publicKey])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("retained")) { _ in
      M4IdentityMaterial(signer: try DevelopmentDeviceSigner(namespace: namespace, rawRepresentation: Data(repeating: watch ? 42 : 41, count: 32)), vault: vault)
    }
    try prepared.prepareManagedResources(resourceReplyGate: resourceReplyGate)
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
        let bytes: Data
        do { bytes = try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
          // The original client can consume a previous request after enumeration.
          // Only its now-missing snapshot entry is retried; other errors remain.
          continue
        }
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], value["operation"] as? String == operation,
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
  let replyArchive: URL?
  init(key: Curve25519.Signing.PrivateKey, deviceID: String, publicKey: String, replyArchive: URL? = nil) { self.key = key; self.deviceID = deviceID; self.publicKey = publicKey; self.replyArchive = replyArchive }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1
    guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any], let id = object["requestID"] as? String,
          object["deviceID"] as? String == deviceID, object["devicePublicKey"] as? String == publicKey else { throw AuthorityError.invalidWire }
    if request.path == "/v1/auth/recover", let replyArchive {
      let archived = try Data(contentsOf: replyArchive)
      let response = try XCTUnwrap(JSONSerialization.jsonObject(with: archived) as? [String: Any])
      let receipt = try XCTUnwrap(response["receipt"] as? [String: Any]), receiptBody = try XCTUnwrap(receipt["body"] as? [String: Any])
      guard object["authRequestID"] as? String == receiptBody["requestID"] as? String,
            let proof = object["deviceProof"] as? String else { throw AuthorityError.invalidWire }
      var unsigned = object; unsigned["deviceProof"] = nil
      let bytes = try JSONSerialization.data(withJSONObject: unsigned, options: [.sortedKeys, .withoutEscapingSlashes])
      let deviceKey = try Curve25519.Signing.PublicKey(rawRepresentation: AuthorityWire.decodeBase64URL(publicKey, count: 32))
      guard deviceKey.isValidSignature(try AuthorityWire.decodeBase64URL(proof, count: 64), for: AuthorityWire.signedInput("football-record.device.auth-recover.v1", body: bytes)) else { throw AuthorityError.invalidSignature }
      return AuthorityHTTPResponse(status: 200, body: archived)
    }
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
    let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
    if let replyArchive { try bytes.write(to: replyArchive, options: .withoutOverwriting) }
    return AuthorityHTTPResponse(status: 200, body: bytes)
  }
}
#endif


extension M4AccountCompositionTests {
  func testIdentityChangedUsesOriginalControlOwnerAndPreservesOriginalFacade() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover)
    let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: c.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
    let scope = resources.scope, ledger = resources.ledger
    let originalID = await c.repository.syncRepositoryIdentity(), before = try await c.repository.identityGenerationV4()
    do { try await c.performAccount(.identityChanged) }
    catch { XCTFail("original identity control must complete: \(error)") }
    let retained = try await c.repository.accountBindingV4(), generation = try await c.repository.identityGenerationV4()
    XCTAssertTrue(try XCTUnwrap(retained).suspended, "original Session must persist identity suspension")
    XCTAssertGreaterThan(generation, before, "persist the original identity generation")
    do { _ = try await f.prepared.material.vault.credential(); XCTFail("old credential cannot survive the original durable generation fence") } catch {}
    do { _ = try await c.session.prepareStart(starter: true); XCTFail("identity action permanently retires the original Session") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertTrue(c.context.account.requiresReload)
    let after = await c.repository.syncRepositoryIdentity(), sessionID = await c.session.syncRepositoryIdentity()
    XCTAssertEqual(after, originalID); XCTAssertEqual(sessionID, originalID)
    let analytics = try await c.repository.analyticsEnabledV4(); XCTAssertFalse(analytics)
    let fenced = try await ledger.scopeState(scope: scope); XCTAssertEqual(fenced.issue, .accountChanged)
    try await c.close(); try await ledger.close()
  }
  func testIdentityChangedControlDoesNotJoinItselfOrReadmitHeldIdentity() async throws {
    let f = try await serviceFixture(), c = f.composition, observer = f.observer
    await c.context.account.perform(.recover)
    let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: c.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
    let ledger = resources.ledger
    await observer.holdNext()
    let admission = Task { try await c.admitCurrentIdentity() }; await observer.waitForEntry()
    var done = false
    let changed = Task { do { try await c.performAccount(.identityChanged) } catch { XCTFail("original identity control must complete: \(error)") }; done = true }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(500)); var retired = false
    while ContinuousClock.now < deadline {
      do { _ = try await c.session.prepareStart(starter: true) }
      catch { if error as? SessionError == .retired { retired = true; break } }
      await Task.yield()
    }
    XCTAssertTrue(retired, "held observation must not delay the original Session permanent gate")
    XCTAssertFalse(done, "control must join the original held observation without joining itself")
    await observer.release(); _ = await admission.result; await changed.value
    XCTAssertTrue(done); XCTAssertFalse(c.context.account.canEnterRecording)
    let retained = try await c.repository.accountBindingV4(); XCTAssertTrue(try XCTUnwrap(retained).suspended)
    try await c.close(); try await ledger.close()
  }
}


extension M4AccountCompositionTests {
  func testIdentityChangedMissingLedgerStaysRetiredAndRetriesWithOriginalScope() async throws {
    let (prepared, trust) = try await identityFixture("m4-identity-action-retry"), observer = CompositionIdentityFixture()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer)
    // A deliberately unadmitted protocol control fixture, never full-seal UI proof.
    try await c.repository.bindAccountV4(binding(prepared)); XCTAssertFalse(c.context.account.canEnterRecording)
    let original = try await c.repository.accountBindingV4(), before = try await c.repository.identityGenerationV4()
    do { try await c.performAccount(.identityChanged); XCTFail("missing original ledger cannot claim full fencing") }
    catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    let retained = try await c.repository.accountBindingV4(), still = try await c.repository.identityGenerationV4()
    XCTAssertEqual(retained, original); XCTAssertEqual(still, before)
    XCTAssertTrue(c.context.account.requiresReload); XCTAssertFalse(c.context.account.canEnterRecording)
    do { _ = try await c.session.prepareStart(starter: true); XCTFail("failure must not reopen business") }
    catch { XCTAssertEqual(error as? SessionError, .retired) }
    let scope = try CloudScope(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", zoneID: "zone-fixture", activationEpoch: 1)
    let ledger = try SQLiteCloudLedger(url: prepared.seed.controlDirectory.appendingPathComponent("identity-cloud.sqlite"))
    try await c.installIdentityLifecycle(ledger: ledger, scope: scope); try await c.performAccount(.identityChanged)
    let suspended = try await c.repository.accountBindingV4(); XCTAssertTrue(try XCTUnwrap(suspended).suspended)
    let once = try await c.repository.identityGenerationV4(); try await c.performAccount(.identityChanged)
    let twice = try await c.repository.identityGenerationV4(); XCTAssertEqual(once, twice, "completed original owner is idempotent")
    try await c.close(); try await ledger.close()
  }
}

#if DEBUG
extension M4AccountCompositionTests {
  func testOriginalPhoneInboxChecksFreshIdentityForEveryRequestAndStopsAtQuiesce() async throws {
    let f = try await freshServiceFixture(), c = f.composition
    let signingIn = Task { await c.context.account.perform(.signIn) }
    let apple = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    try serviceMailboxReply(apple, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    await signingIn.value; XCTAssertTrue(c.context.account.canEnterRecording)
    try await c.startPhoneInbox()
    let first = try originalInboxRequest(f.protocolRoot), raw = try await originalInboxReply(first.response)
    let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(raw["payload"] as? String)))
    let context = try AuthorityWire.decode(WatchRegistrationContextV4.self, payload)
    XCTAssertEqual(context.phoneID, f.prepared.seed.installationID); XCTAssertEqual(context.accountID, "account-fixture")
    let firstReads = await f.observer.reads; XCTAssertGreaterThanOrEqual(firstReads, 5)
    try consumeOwnedInboxFixture(first)
    await f.observer.setCloud("foreign-cloud")
    let second = try originalInboxRequest(f.protocolRoot), refusal = try await originalInboxReply(second.response)
    XCTAssertEqual(refusal["issue"] as? String, "unavailable"); XCTAssertNil(refusal["payload"])
    let secondReads = await f.observer.reads; XCTAssertEqual(secondReads, firstReads + 1); XCTAssertFalse(c.context.account.canEnterRecording)
    try consumeOwnedInboxFixture(second)
    try await c.quiesceBusiness()
    let stopped = try originalInboxRequest(f.protocolRoot)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.response.path), "retired original inbox cannot publish even a new error response")
    XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.request.path), "quiesce preserves borrowed pending input")
    try consumeOwnedInboxFixture(stopped); try await c.close()
  }
  func testOriginalPhoneInboxQuiesceJoinsHeldOriginalIdentityAndCannotPublishLateReply() async throws {
    let f = try await freshServiceFixture(), c = f.composition
    let signingIn = Task { await c.context.account.perform(.signIn) }
    let apple = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    try serviceMailboxReply(apple, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    await signingIn.value; try await c.startPhoneInbox(); await f.observer.holdNext()
    let held = try originalInboxRequest(f.protocolRoot); await f.observer.waitForEntry()
    var done = false; let stopping = Task { try await c.quiesceBusiness(); done = true }
    let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
    try await Task.sleep(for: .milliseconds(30)); XCTAssertFalse(done)
    await f.observer.release(); try await stopping.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: held.response.path), "no late original success/error may be published after stop")
    XCTAssertTrue(FileManager.default.fileExists(atPath: held.request.path)); XCTAssertFalse(c.context.account.canEnterRecording)
    try consumeOwnedInboxFixture(held); try await c.close()
  }
  private struct OriginalInboxFixture { let request, response: URL }
  private func originalInboxRequest(_ root: URL) throws -> OriginalInboxFixture {
    let id = UUID().uuidString, mailbox = root.appendingPathComponent("development/mailbox")
    let file = mailbox.appendingPathComponent("incoming/" + id + ".json")
    try JSONSerialization.data(withJSONObject: ["id": id, "operation": "phone-context", "dataset": "fresh", "payload": Data().base64EncodedString()], options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .withoutOverwriting)
    return OriginalInboxFixture(request: file, response: mailbox.appendingPathComponent("incoming-responses/" + id + ".json"))
  }
  private func originalInboxReply(_ file: URL) async throws -> [String: Any] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      if FileManager.default.fileExists(atPath: file.path) { return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AuthorityError.unavailable
  }
  private func consumeOwnedInboxFixture(_ item: OriginalInboxFixture) throws {
    // Exact fixtures only, standing in for the external broker consuming its own
    // request/reply. Neither production code nor the inbox removes these files.
    try FileManager.default.removeItem(at: item.request)
    if FileManager.default.fileExists(atPath: item.response.path) { try FileManager.default.removeItem(at: item.response) }
  }
}
#endif


extension M4AccountCompositionTests {
  func testRenewRequiresControlPurposeAuthenticationAndNeverFallsBackToGenericSignIn() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover); XCTAssertTrue(c.context.account.canEnterRecording)
    let original = try await c.repository.accountBindingV4(), credential = try await f.vault.credential(), generation = try await c.repository.identityGenerationV4()
    let callsBefore = await f.relay.calls
    do { try await c.performAccount(.renew); XCTFail("control renewal is unavailable until the accepted purpose-specific control API is integrated") }
    catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    let callsAfter = await f.relay.calls, binding = try await c.repository.accountBindingV4(), current = try await f.vault.credential(), afterGeneration = try await c.repository.identityGenerationV4()
    XCTAssertEqual(callsAfter, callsBefore, "matching current identity cannot authorize a generic auth/challenge fallback")
    XCTAssertEqual(binding, original); XCTAssertEqual(current, credential); XCTAssertEqual(afterGeneration, generation)
    XCTAssertFalse(c.context.account.canEnterRecording, "explicit unavailable renewal must pause the old admission")
    try await c.close()
  }
}

// Actual original service/SQLite/verified receipt; no fixture capsule or binding.
extension M4AccountCompositionTests {
  func testManagedSignedPhoneOwnsRealLedgerAndStoreBeforeReady() async throws {
    let f = try await serviceFixture(managed: true)
    await f.composition.context.account.perform(.recover)
    let generation = try await f.composition.repository.identityGenerationV4()
    let current = try await f.composition.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
    let proof = try XCTUnwrap(current)
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let entries = try catalog.index().entries
    XCTAssertEqual(entries.filter { $0.capsule.kind == .cloudLedger }.count, 1, "real ledger must be owned before UI readiness")
    XCTAssertEqual(entries.filter { $0.capsule.kind == .businessStore }.count, 1, "original Store must be sealed before UI readiness")
    for entry in entries {
      XCTAssertEqual(entry.capsule.scope.accountID, proof.binding.accountID)
      XCTAssertEqual(entry.capsule.scope.cloudSpaceID, proof.binding.cloudSpaceID)
      XCTAssertEqual(entry.capsule.scope.activationEpoch, proof.binding.activationEpoch)
      try entry.capsule.verifyCurrent()
    }
    XCTAssertTrue(f.composition.context.account.canEnterRecording)
    try catalog.close(); try await f.composition.close()
  }
}

extension M4AccountCompositionTests {
  func testZoneChangeDuringOriginalAuthVaultTailCannotChooseAReplacementScope() async throws {
    let f = try await serviceFixture(holdVault: true)
    let task = Task { await f.composition.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else { XCTFail("actual original vault tail required"); await task.value; return }
    let before = try await f.composition.repository.identityGenerationV4()
    await f.observer.setZone("changed-during-vault")
    await f.vault.release(); await task.value
    XCTAssertFalse(f.composition.context.account.canEnterRecording, "a post-auth zone cannot replace the pre-service independent identity")
    XCTAssertNil(f.composition.admittedScope)
    let after = try await f.composition.repository.identityGenerationV4(); XCTAssertEqual(after, before)
    try await f.composition.close()
  }
}

@MainActor private final class PhoneScopeBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  private var entry: CheckedContinuation<Void, Never>?
  private var entered = false
  func hold() async { entered = true; entry?.resume(); entry = nil; await withCheckedContinuation { continuation = $0 } }
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { entry = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}
extension M4AccountCompositionTests {
  func testHeldResourceWorkRequiresLastIndependentZoneAndPreservesOriginalSeal() async throws {
    let barrier = PhoneScopeBarrier(), f = try await serviceFixture(resourceReplyGate: { await barrier.hold() })
    let action = Task { await f.composition.context.account.perform(.recover) }
    await barrier.waitForEntry()
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let before = try M4CatalogIO.encode(catalog.phoneResources()), originalGeneration = try await f.composition.repository.identityGenerationV4()
    XCTAssertFalse(f.composition.context.account.canEnterRecording)
    await f.observer.setZone("after-owner-zone"); barrier.release(); await action.value
    XCTAssertFalse(f.composition.context.account.canEnterRecording); XCTAssertNil(f.composition.admittedScope)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.phoneResources()), before)
    let afterGeneration = try await f.composition.repository.identityGenerationV4(); XCTAssertEqual(afterGeneration, originalGeneration)
    try catalog.close(); try await f.composition.close()
  }
  func testRealCredentialExpiryWhileLastObserverHeldNeverPublishesReady() async throws {
    let barrier = PhoneScopeBarrier(), f = try await serviceFixture(resourceReplyGate: { await barrier.hold() }, expiresIn: 2)
    let action = Task { await f.composition.context.account.perform(.recover) }
    await barrier.waitForEntry()
    let credential = try await f.vault.credential(); XCTAssertGreaterThan(Double(credential.expiresAt), Date().timeIntervalSince1970)
    await f.observer.holdNext(); barrier.release(); await f.observer.waitForEntry()
    XCTAssertFalse(f.composition.context.account.canEnterRecording)
    while Date().timeIntervalSince1970 < Double(credential.expiresAt) { try await Task.sleep(for: .milliseconds(20)) }
    await f.observer.release(); await action.value
    XCTAssertFalse(f.composition.context.account.canEnterRecording); XCTAssertNil(f.composition.admittedScope)
    let replacements = await f.vault.replacements; XCTAssertEqual(replacements, 1)
    try await f.composition.close()
  }
  func testNoAttachmentUnknownRepeatedSignInAndReopenRecoverOnlyOriginalAttempt() async throws {
    let f = try await serviceFixture(), c = f.composition
    let original = try await c.repository.authAttemptV4(requestID: f.attempt.requestID)
    for status in [404, 401, 0] { await f.relay.failRecovery(status); await c.context.account.perform(.signIn) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    let material = f.prepared.material, seed = f.prepared.seed
    try await c.close()
    let next = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    try next.prepareManagedResources()
    let reopened = try await M4AccountComposition.make(prepared: next, trust: f.trust, cloudSpaceID: "cloud-fixture", identity: f.observer, authorityRelay: f.relay)
    await reopened.context.account.perform(.signIn)
    let pending = try await reopened.repository.pendingAuthAttemptsV4(), current = try await reopened.repository.currentAuthRequestIDV4()
    XCTAssertEqual(pending, [try XCTUnwrap(original)]); XCTAssertNil(current)
    let paths = await f.relay.paths, ids = await f.relay.recoveredIDs
    XCTAssertEqual(paths, Array(repeating: "/v1/auth/recover", count: 4)); XCTAssertEqual(ids, Array(repeating: f.attempt.requestID, count: 4))
    let replacements = await f.vault.replacements, movements = await f.vault.fenceMovements
    XCTAssertEqual(replacements, 0); XCTAssertEqual(movements, 0)
    XCTAssertFalse(reopened.context.account.canEnterRecording); XCTAssertNil(try next.activePhoneAttachment())
    try await reopened.close()
  }
  func testActivePhoneReservationRefusesNewGenericAuthBeforeAnyExtraHTTP() async throws {
    let f = try await serviceFixture(); await f.composition.context.account.perform(.recover)
    let original = try f.prepared.activePhoneAttachment(), before = await f.relay.calls
    await f.composition.context.account.perform(.signIn)
    await f.observer.setAccount("foreign-account"); await f.composition.context.account.perform(.signIn)
    let after = await f.relay.calls; XCTAssertEqual(after, before)
    XCTAssertEqual(try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), try M4CatalogIO.encode(original))
    let attempts = try await f.composition.repository.authAttemptsV4(); XCTAssertEqual(attempts.count, 1)
    XCTAssertFalse(f.composition.context.account.canEnterRecording)
    try await f.composition.close()
  }
  func testUnmanagedPublicAdmissionCannotUseBindingAndCredentialAsFullSeal() async throws {
    let (prepared, trust) = try await identityFixture("unmanaged-no-fullseal")
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: CompositionIdentityFixture())
    try await c.repository.bindAccountV4(binding(prepared))
    do { try await c.admitCurrentIdentity(); XCTFail("unmanaged binding/credential is no signed pair seal") } catch {}
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    try await c.close()
  }
}

#if DEBUG
extension M4AccountCompositionTests {
  private func attemptWatchWhilePhoneUnknown(_ composition: M4AccountComposition, protocolRoot: URL) async throws -> Int {
    var done = false, watchCalls = 0; var seen: Set<String> = []
    let action = Task { await composition.context.account.perform(.registerWatch); done = true }
    let directory = protocolRoot.appendingPathComponent("development/mailbox/outgoing"), deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !done, ContinuousClock.now < deadline {
      for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { continue }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = value["id"] as? String, let operation = value["operation"] as? String else { continue }
        guard seen.insert(id).inserted else { continue }
        watchCalls += 1
        let response = protocolRoot.appendingPathComponent("development/mailbox/responses/" + id + ".json")
        if operation == "phone-context" {
          let context = try WatchRegistrationContextV4(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", phoneID: "independent-original-phone", activationEpoch: 1, environment: .development)
          try serviceMailboxReply(ServiceMailboxRequest(response: response, payload: Data()), payload: AuthorityWire.encode(context))
        } else { try JSONSerialization.data(withJSONObject: ["issue": "unavailable"], options: [.sortedKeys]).write(to: response, options: .atomic) }
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    await action.value
    return watchCalls
  }
  func testPendingPhoneCannotSwitchToWatchProtocolWithoutAttachment() async throws {
    let f = try await freshServiceFixture(), original = f.composition
    let attempt = try AuthAttemptV4(requestID: "original-unknown-phone", deviceID: f.prepared.seed.installationID, publicKey: f.prepared.material.signer.publicKey, cloudSpaceID: "cloud-fixture", challengeID: "original-phone-challenge", requestDigest: String(repeating: "b", count: 64), environment: .development)
    try await original.session.saveAuthAttempt(attempt, expectedIdentityGeneration: 0)
    for _ in 0..<2 {
      let calls = try await attemptWatchWhilePhoneUnknown(original, protocolRoot: f.protocolRoot)
      XCTAssertEqual(calls, 0, "unknown Phone cannot select Watch initially or on repetition")
    }
    let material = f.prepared.material, seed = f.prepared.seed; try await original.close()
    let prepared = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    try prepared.prepareManagedResources()
    let publicKey = AuthorityWire.base64URL(f.key.publicKey.rawRepresentation), trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": publicKey])
    let configuration = DevelopmentAuthorityConfiguration(dataset: "fresh", namespace: seed.namespace, baseURL: "http://127.0.0.1:1", keyID: "service-key", publicKey: publicKey, cloudSpaceID: "cloud-fixture", subject: "configuration-does-not-admit-current-identity", role: "phone")
    let adapters = try M4ControlledAdapters.make(configuration: configuration, rootDirectory: f.protocolRoot)
    let reopened = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: f.observer, authorityRelay: f.relay, controlledAdapters: adapters)
    let watchCalls = try await attemptWatchWhilePhoneUnknown(reopened, protocolRoot: f.protocolRoot)
    XCTAssertEqual(watchCalls, 0, "reopen cannot switch an unknown original Phone to Watch")
    let phone = try await reopened.repository.authAttemptV4(requestID: attempt.requestID), watches = try await reopened.repository.pendingWatchRegistrationAttemptsV4()
    XCTAssertEqual(phone, attempt); XCTAssertTrue(watches.isEmpty)
    let attempts = try await reopened.repository.authAttemptsV4(); XCTAssertEqual(attempts, [attempt])
    let calls = await f.relay.calls, replacements = await f.vault.replacements; XCTAssertEqual(calls, 0); XCTAssertEqual(replacements, 0)
    XCTAssertFalse(reopened.context.account.canEnterRecording); XCTAssertNil(reopened.admittedScope); XCTAssertNil(try prepared.activePhoneAttachment())
    try await reopened.close()
  }
}
#endif


extension M4AccountCompositionTests {
  func testPermanentLedgerFenceCannotBeReadmittedByOriginalSignedProof() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover); XCTAssertTrue(c.context.account.canEnterRecording)
    let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: c.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
    let original = try M4CatalogIO.encode(resources.attachment)
    try await resources.ledger.recordScopeIssue(scope: resources.scope, issue: .accountChanged, at: Date(), nextAttemptAt: nil)
    do { try await c.admitCurrentIdentity(); XCTFail("a permanent ledger fence cannot be revived by an unchanged signed grant") } catch {}
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    let state = try await resources.ledger.scopeState(scope: resources.scope); XCTAssertEqual(state.issue, .accountChanged)
    XCTAssertEqual(try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), try M4CatalogIO.encode(Optional(resources.attachment)))
    XCTAssertEqual(try M4CatalogIO.encode(resources.attachment), original)
    try await c.close()
  }
  func testPhoneLedgerPublicationCrashWindowsReadBackOriginalReservationAndInode() async throws {
    for point in [M4ResourceCrashPoint.afterLedgerReservation, .afterLedgerRename, .afterLedgerInitialization, .afterPairSeal] {
      var fired = false
      let f = try await serviceFixture(crashHook: { actual in
        if actual == point && !fired { fired = true; throw M4CatalogError.injectedFailure }
      }), c = f.composition
      await c.context.account.perform(.recover)
      XCTAssertTrue(fired); XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
      let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
      let before = try XCTUnwrap(catalog.phoneResources()), physical = try XCTUnwrap(catalog.physicalBootstrap())
      XCTAssertEqual(before.attachment.physicalReservationID, physical.reservation.reservationID)
      let source = URL(fileURLWithPath: before.ledger.source.path), published = URL(fileURLWithPath: before.ledger.published.path)
      let actual = FileManager.default.fileExists(atPath: source.path) ? source : published
      var state = stat(); XCTAssertEqual(lstat(actual.path, &state), 0); XCTAssertEqual(state.st_ino, physical.reservation.ledgerSlot.inode)
      if point == .afterLedgerReservation || point == .afterLedgerRename {
        XCTAssertEqual(state.st_size, 0, "descriptor durable readback and NO_REPLACE publication must precede SQLite initialization")
        XCTAssertTrue(try catalog.index().entries.isEmpty)
      } else { XCTAssertGreaterThan(state.st_size, 0) }
      if point == .afterPairSeal { _ = try catalog.requirePhoneSeal() }
      let calls = await f.relay.calls
      try await c.admitCurrentIdentity()
      XCTAssertTrue(c.context.account.canEnterRecording)
      let after = try XCTUnwrap(catalog.phoneResources())
      XCTAssertEqual(try M4CatalogIO.encode(after.attachment), try M4CatalogIO.encode(before.attachment))
      XCTAssertEqual(try M4CatalogIO.encode(after.ledger), try M4CatalogIO.encode(before.ledger))
      XCTAssertEqual(try catalog.index().entries.count, 2); _ = try catalog.requirePhoneSeal()
      let nextCalls = await f.relay.calls; XCTAssertEqual(nextCalls, calls, "resource retry never creates another authority request")
      var final = stat(); XCTAssertEqual(lstat(published.path, &final), 0); XCTAssertEqual(final.st_ino, state.st_ino)
      try catalog.close(); try await c.close()
    }
  }
}


#if DEBUG && os(macOS)
private actor PhoneDurableVault: DeviceCredentialVault {
  let original: any DeviceCredentialVault
  let exitBeforeCredentialWrite: Bool
  init(_ original: any DeviceCredentialVault, exitBeforeCredentialWrite: Bool) { self.original = original; self.exitBeforeCredentialWrite = exitBeforeCredentialWrite }
  func credential() async throws -> DeviceCredential { try await original.credential() }
  func advanceIdentityFence(to generation: Int64) async throws { try await original.advanceIdentityFence(to: generation) }
  func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) async throws {
    if credential != nil && exitBeforeCredentialWrite { _exit(86) }
    try await original.replace(credential, expectedIdentityGeneration: expectedIdentityGeneration)
  }
}
extension M4AccountCompositionTests {
  private struct DurablePhoneFixture {
    let prepared: M4PreparedIdentity
    let composition: M4AccountComposition
    let relay: CompositionFreshAuthenticationRelay
    let observer: M4ControlledCurrentIdentity
    let protocolRoot: URL
  }
  private func durablePhoneFixture(root: URL, createObservation: Bool, exitBeforeCredentialWrite: Bool = false,
                                   crashHook: ((M4ResourceCrashPoint) throws -> Void)? = nil) async throws -> DurablePhoneFixture {
    let namespace = "m4-ui-durable-phone", key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 77, count: 32))
    let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
    let configuration = DevelopmentAuthorityConfiguration(dataset: "durable", namespace: namespace, baseURL: "http://127.0.0.1:1", keyID: "service-key", publicKey: publicKey, cloudSpaceID: "cloud-fixture", subject: "separate-configured-subject", role: "phone")
    let protocolRoot = root.appendingPathComponent("protocol"), observations = root.appendingPathComponent("observations")
    if createObservation {
      try FileManager.default.createDirectory(at: observations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let id = UUID().uuidString
      let pairs: [(String, [String: Any])] = [
        ("apple-account.json", ["version": 1, "environment": "development", "namespace": namespace, "observationID": id, "accountID": "account-fixture"]),
        ("cloud-space.json", ["version": 1, "environment": "development", "namespace": namespace, "observationID": id, "cloudSpaceID": "cloud-fixture", "zoneID": "original-zone"])]
      for (name, object) in pairs {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let file = observations.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
      }
    }
    let observer = try M4ControlledCurrentIdentity(directory: observations, namespace: namespace)
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("retained/identity")) { seed in
      // Actual051 creates random device material once and validates all retained
      // files on reopen. Only the authority fixture key is a reproducible seed.
      let material = try DevelopmentAuthorityScenario.deviceMaterial(configuration: configuration, namespaceDirectory: seed.namespaceDirectory, installationID: seed.installationID)
      return M4IdentityMaterial(signer: material.signer, vault: PhoneDurableVault(material.vault, exitBeforeCredentialWrite: exitBeforeCredentialWrite))
    }
    try prepared.prepareManagedResources(crashHook: crashHook)
    let adapters = try M4ControlledAdapters.make(configuration: configuration, rootDirectory: protocolRoot)
    let relay = CompositionFreshAuthenticationRelay(key: key, deviceID: prepared.seed.installationID, publicKey: prepared.material.signer.publicKey, replyArchive: root.appendingPathComponent("authority-auth-response.json"))
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": publicKey])
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: observer, authorityRelay: relay, controlledAdapters: adapters)
    return DurablePhoneFixture(prepared: prepared, composition: c, relay: relay, observer: observer, protocolRoot: protocolRoot)
  }
  private func durableFreshSignIn(_ f: DurablePhoneFixture) async throws {
    let task = Task { await f.composition.context.account.perform(.signIn) }
    let request = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    try serviceMailboxReply(request, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    await task.value
  }
  func testDurablePhoneProcessRecoveryUsesOriginalGrantMaterialAndLedgerWAL() async throws {
    let environment = ProcessInfo.processInfo.environment, variable = "NATIVE026_PHONE_PROCESS_ROOT"
    if let path = environment[variable], let mode = environment["NATIVE026_PHONE_PROCESS_MODE"] {
      let points: [String: M4ResourceCrashPoint] = ["reserved": .afterLedgerReservation, "renamed": .afterLedgerRename, "initialized": .afterLedgerInitialization, "sealed": .afterPairSeal]
      let f = try await durablePhoneFixture(root: URL(fileURLWithPath: path), createObservation: true, exitBeforeCredentialWrite: mode == "auth-commit", crashHook: { if $0 == points[mode] { _exit(86) } })
      try await durableFreshSignIn(f)
      guard mode == "own-wal", f.composition.context.account.canEnterRecording else { return XCTFail("child did not reach its exact original crash boundary") }
      let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: f.composition.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
      try await resources.ledger.recordScopeIssue(scope: resources.scope, issue: .networkUnavailable, at: Date(timeIntervalSince1970: 1234), nextAttemptAt: nil)
      _exit(86) // Actual SQLite WAL is intentionally not checkpointed/closed.
    }
    for mode in ["auth-commit", "reserved", "renamed", "initialized", "sealed", "own-wal"] {
      let root = location(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      child.arguments = ["xctest", "-XCTest", "AppIntegrationTests.M4AccountCompositionTests/testDurablePhoneProcessRecoveryUsesOriginalGrantMaterialAndLedgerWAL", Bundle(for: Self.self).bundleURL.path]
      var childEnvironment = environment; childEnvironment[variable] = root.path; childEnvironment["NATIVE026_PHONE_PROCESS_MODE"] = mode; child.environment = childEnvironment
      let log = root.appendingPathComponent("child.log"); XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
      let output = try FileHandle(forWritingTo: log); child.standardOutput = output; child.standardError = output
      try child.run(); child.waitUntilExit(); try output.close()
      guard child.terminationReason == .exit, child.terminationStatus == 86 else { return XCTFail("actual child boundary \(mode) failed: \(try String(contentsOf: log, encoding: .utf8))") }
      let namespace = root.appendingPathComponent("business/m4-ui-durable-phone")
      let originals = try ["device.identity", "development.key", "authority.fixture"].map { name -> (URL, M4CatalogPath, Data) in
        let file = namespace.appendingPathComponent(name); return (file, try M4CatalogIO.anchor(file), try Data(contentsOf: file))
      }
      let catalogURL = root.appendingPathComponent("retained/catalog"), beforeCatalog = try M4OwnedDataCatalog(directory: catalogURL)
      let originalPhysical = try XCTUnwrap(beforeCatalog.physicalBootstrap()), originalPhone = try beforeCatalog.phoneResources()
      let oldPhoneBytes = try M4CatalogIO.encode(originalPhone)
      if mode == "auth-commit" { XCTAssertNil(originalPhone) }
      if mode == "own-wal" {
        let phone = try XCTUnwrap(originalPhone), wal = URL(fileURLWithPath: phone.ledger.published.path + "-wal")
        XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0)
      }
      try beforeCatalog.close()
      let f = try await durablePhoneFixture(root: root, createObservation: false), c = f.composition
      XCTAssertFalse(c.context.account.canEnterRecording)
      let generation = try await c.repository.identityGenerationV4()
      let currentProof = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
      let proof = try XCTUnwrap(currentProof)
      let attempts = try await c.repository.authAttemptsV4(); XCTAssertEqual(attempts.count, 1); XCTAssertEqual(proof.currentAuthRequestID, attempts[0].requestID)
      let current = try M4OwnedDataCatalog(directory: catalogURL)
      XCTAssertEqual(try M4CatalogIO.encode(current.physicalBootstrap()?.reservation), try M4CatalogIO.encode(Optional(originalPhysical.reservation)))
      XCTAssertEqual(try M4CatalogIO.encode(current.phoneResources()), oldPhoneBytes, "reopen itself never retargets or seals")
      if mode == "auth-commit" {
        do { try await c.admitCurrentIdentity(); XCTFail("original SQL COMMIT does not fabricate the missing real vault credential") } catch {}
        XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
        let callsBefore = await f.relay.calls; XCTAssertEqual(callsBefore, 0)
        await c.context.account.perform(.recover)
        let calls = await f.relay.calls; XCTAssertEqual(calls, 1, "recover only the original server-retained signed response")
      } else { try await c.admitCurrentIdentity(); let calls = await f.relay.calls; XCTAssertEqual(calls, 0) }
      XCTAssertTrue(c.context.account.canEnterRecording); _ = try current.requirePhoneSeal()
      let phone = try XCTUnwrap(current.phoneResources())
      XCTAssertEqual(phone.attachment.currentAuthRequestID, proof.currentAuthRequestID)
      XCTAssertEqual(phone.ledger.source.inode, originalPhysical.reservation.ledgerSlot.inode)
      if let originalPhone {
        XCTAssertEqual(try M4CatalogIO.encode(phone.attachment), try M4CatalogIO.encode(originalPhone.attachment))
        XCTAssertEqual(try M4CatalogIO.encode(phone.ledger), try M4CatalogIO.encode(originalPhone.ledger))
      }
      if mode == "own-wal" {
        let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: generation, observed: f.observer.currentIdentity())
        let state = try await resources.ledger.scopeState(scope: resources.scope); XCTAssertEqual(state.issue, .networkUnavailable)
      }
      for (file, anchor, bytes) in originals { XCTAssertEqual(try M4CatalogIO.encode(M4CatalogIO.anchor(file)), try M4CatalogIO.encode(anchor)); XCTAssertEqual(try Data(contentsOf: file), bytes) }
      print("durable-phone-child mode=\(mode) exit=86 root=\(root.path) originalAuthID=\(proof.currentAuthRequestID)")
      try current.close(); try await c.close()
    }
  }
}
#endif


extension M4AccountCompositionTests {
  func testAcceptedAuthWithoutAttachmentRepeatedSignInRecoversOriginalID() async throws {
    let f = try await serviceFixture(holdVault: true), c = f.composition
    let action = Task { await c.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else { return XCTFail("original accepted auth vault tail required") }
    await f.observer.setZone("temporary-foreign-zone"); await f.vault.release(); await action.value
    XCTAssertNil(try f.prepared.activePhoneAttachment())
    let current = try await c.repository.currentAuthRequestIDV4(); XCTAssertEqual(current, f.attempt.requestID)
    await f.observer.setZone("zone-fixture")
    await c.context.account.perform(.signIn)
    let paths = await f.relay.paths, ids = await f.relay.recoveredIDs
    XCTAssertEqual(paths, ["/v1/auth/recover", "/v1/auth/recover"], "accepted current pointer without a resource attachment is still an original recovery")
    XCTAssertEqual(ids, [f.attempt.requestID, f.attempt.requestID])
    let attempts = try await c.repository.authAttemptsV4(); XCTAssertEqual(attempts, [f.attempt])
    try await c.close()
  }
  func testUninitializedLedgerRefusesForeignSQLiteSidecarsWithoutConsumingBytes() async throws {
    let foreignRoot = location(), foreign = try SQLiteSessionRepository(rootDirectory: foreignRoot, databaseNamespace: "foreign-ledger-wal")
    try await foreign.setAnalyticsEnabledV4(false)
    let foreignURL = await foreign.databaseURL
    let wal = try Data(contentsOf: URL(fileURLWithPath: foreignURL.path + "-wal")), shm = try Data(contentsOf: URL(fileURLWithPath: foreignURL.path + "-shm"))
    try await foreign.close(); XCTAssertFalse(wal.isEmpty); XCTAssertFalse(shm.isEmpty)
    for suffixes in [["-wal"], ["-shm"], ["-wal", "-shm"], ["-journal"]] {
      var fired = false
      let f = try await serviceFixture(crashHook: { if $0 == .afterLedgerRename && !fired { fired = true; throw M4CatalogError.injectedFailure } }), c = f.composition
      await c.context.account.perform(.recover); XCTAssertTrue(fired)
      let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
      let original = try XCTUnwrap(catalog.phoneResources()), main = URL(fileURLWithPath: original.ledger.published.path)
      let originalMain = try M4CatalogIO.anchor(main); XCTAssertEqual(try Data(contentsOf: main), Data())
      var sidecars: [(URL, M4CatalogPath, Data)] = []
      for suffix in suffixes {
        let file = URL(fileURLWithPath: main.path + suffix), bytes = suffix == "-shm" ? shm : wal
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
        sidecars.append((file, try M4CatalogIO.anchor(file), bytes))
      }
      do { try await c.admitCurrentIdentity(); XCTFail("original ledger0 cannot consume foreign sidecars") } catch {}
      XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
      XCTAssertEqual(try Data(contentsOf: main), Data()); XCTAssertEqual(try M4CatalogIO.encode(M4CatalogIO.anchor(main)), try M4CatalogIO.encode(originalMain))
      XCTAssertEqual(try M4CatalogIO.encode(catalog.phoneResources()), try M4CatalogIO.encode(Optional(original)))
      for (file, anchor, bytes) in sidecars {
        XCTAssertEqual(try M4CatalogIO.encode(M4CatalogIO.anchor(file)), try M4CatalogIO.encode(anchor)); XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: file) // Remove only this exact test-injected file after preservation assertions.
      }
      try catalog.close(); try await c.close()
    }
  }
  func testFailedResourceCloseRetainsOriginalLiveLedgerAndFacadeForRetry() async throws {
    let f = try await serviceFixture(), c = f.composition
    await c.context.account.perform(.recover)
    let resources = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: c.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
    let unknown = URL(fileURLWithPath: resources.ledgerCapsule.root.path).deletingLastPathComponent().appendingPathComponent("unknown-original-evidence")
    let bytes = Data([0, 255, 19]); try bytes.write(to: unknown, options: .withoutOverwriting)
    do { try await c.close(); XCTFail("unknown resource control must block close while retaining retry ownership") } catch {}
    XCTAssertEqual(try Data(contentsOf: unknown), bytes)
    let scope = try await resources.ledger.scopeState(scope: resources.scope); XCTAssertNil(scope.issue)
    let binding = try await c.repository.accountBindingV4(); XCTAssertEqual(binding?.accountID, resources.scope.accountID)
    do { try await c.admitCurrentIdentity(); XCTFail("close failure never revives the permanently retired business owner") } catch {}
    XCTAssertFalse(c.context.account.canEnterRecording)
    try FileManager.default.removeItem(at: unknown) // Only the exact fixture introduced above.
    try await c.close()
  }
}


extension M4AccountCompositionTests {
  func testSignedWaitingGrantPreservesFactsAndEmptyLedgerWithoutPhoneAdmission() async throws {
    let f = try await serviceFixture(waiting: true), c = f.composition
    await c.context.account.perform(.recover)
    let generation = try await c.repository.identityGenerationV4(), binding = try await c.repository.accountBindingV4()
    let evidence = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
    XCTAssertEqual(binding?.role, .waiting); XCTAssertEqual(evidence?.receipt.body.result, .waitingMigration)
    XCTAssertEqual(evidence?.currentAuthRequestID, f.attempt.requestID)
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope); XCTAssertNil(try f.prepared.activePhoneAttachment())
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let physical = try XCTUnwrap(catalog.physicalBootstrap()); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: physical.reservation.ledgerSlot.path)), Data())
    XCTAssertTrue(try catalog.index().entries.isEmpty)
    let calls = await f.relay.calls
    for action in [AccountUserAction.signIn, .registerWatch, .recover] {
      do { try await c.performAccount(action); XCTFail("waiting is unsupported by this active Phone slice") } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    }
    let nextCalls = await f.relay.calls; XCTAssertEqual(calls, nextCalls)
    let nextBinding = try await c.repository.accountBindingV4(); XCTAssertEqual(nextBinding, binding)
    try catalog.close(); try await c.close()
  }
  private func unattachedSignedPhoneFixture() async throws -> ServiceFixture {
    let f = try await serviceFixture(holdVault: true)
    let action = Task { await f.composition.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else { throw AuthorityError.unavailable }
    await f.observer.setZone("temporary-unmatched-observation"); await f.vault.release(); await action.value
    await f.observer.setZone("zone-fixture")
    guard try f.prepared.activePhoneAttachment() == nil else { throw AuthorityError.identityChanged }
    return f
  }
  private func actualPhoneReservation(_ f: ServiceFixture, catalog: M4OwnedDataCatalog) async throws -> (M4PhoneResourceState, M4OwnershipCapsule, M4OwnershipCapsule) {
    let physical = try XCTUnwrap(catalog.physicalBootstrap()).reservation
    let generation = try await f.composition.repository.identityGenerationV4()
    let witness = try await f.composition.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation), proof = try XCTUnwrap(witness)
    let observed = try await f.observer.currentIdentity(), id = UUID().uuidString
    let scope = try CloudScope(accountID: proof.binding.accountID, cloudSpaceID: proof.binding.cloudSpaceID, zoneID: observed.zoneID, activationEpoch: proof.binding.activationEpoch)
    let attachment = M4PhoneScopeAttachment(attachmentID: UUID().uuidString, physicalReservationID: physical.reservationID, identityGeneration: generation, currentAuthRequestID: proof.currentAuthRequestID, attempt: proof.attempt, binding: proof.binding, receiptRaw: proof.receipt.raw, scope: scope)
    let root = M4CatalogPath(path: physical.directory.path + "/ledger-" + id + ".sqlite", device: physical.ledgerSlot.device, inode: physical.ledgerSlot.inode, directory: false)
    let controls = [physical.owner] + physical.identityControls + physical.catalogControls
    let descriptor = M4PhoneLedgerDescriptor(ledgerID: id, source: physical.ledgerSlot, published: root, ancestors: try M4CatalogIO.ancestors([root] + controls))
    func capsule(_ root: M4CatalogPath, kind: M4OwnedLeafKind, id: String) throws -> M4OwnershipCapsule {
      M4OwnershipCapsule(version: 1, namespaceID: physical.reservationID, componentID: id, revision: 1, kind: kind, scope: scope, root: root, retainedControls: controls, ancestors: try M4CatalogIO.ancestors([root] + controls))
    }
    return try (M4PhoneResourceState(attachment: attachment, ledger: descriptor, published: false, seal: nil), capsule(physical.businessDatabase, kind: .businessStore, id: "m4-business-store"), capsule(root, kind: .cloudLedger, id: descriptor.componentID))
  }
  func testOriginalSignedCatalogReservationPublicationAndCapsuleResponseLossReadBackExactly() async throws {
    for lostStage in 0...2 {
    let f = try await unattachedSignedPhoneFixture(), c = f.composition
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let (phone, store, ledgerCapsule) = try await actualPhoneReservation(f, catalog: catalog)
    catalog.injectNextFailure(.beforeCommit)
    XCTAssertThrowsError(try catalog.reservePhoneResources(phone, store: store, ledger: ledgerCapsule))
    XCTAssertNil(try catalog.phoneResources()); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: phone.ledger.source.path)), Data())
    XCTAssertFalse(FileManager.default.fileExists(atPath: phone.ledger.published.path))
    catalog.injectNextFailure(.afterCommitResponseLost)
    try catalog.reservePhoneResources(phone, store: store, ledger: ledgerCapsule)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.phoneResources()), try M4CatalogIO.encode(Optional(phone)))
    XCTAssertEqual(renameatx_np(AT_FDCWD, phone.ledger.source.path, AT_FDCWD, phone.ledger.published.path, UInt32(RENAME_EXCL)), 0)
    try M4CatalogIO.syncDirectory(URL(fileURLWithPath: phone.ledger.published.path).deletingLastPathComponent())
    catalog.injectNextFailure(.afterCommitResponseLost); try catalog.publishPhoneLedger(phone.ledger)
    let actualLedger = try SQLiteCloudLedger(url: URL(fileURLWithPath: phone.ledger.published.path))
    try await actualLedger.close()
    catalog.injectNextFailure(.beforeCommit)
    XCTAssertThrowsError(try catalog.sealPhoneResources(store: store, ledger: ledgerCapsule))
    XCTAssertTrue(try catalog.index().entries.isEmpty); XCTAssertFalse(c.context.account.canEnterRecording)
    if lostStage > 0 { try catalog.record(ledgerCapsule) }
    if lostStage > 1 { try catalog.record(store) }
    catalog.injectNextFailure(.afterCommitResponseLost)
    let seal = try catalog.sealPhoneResources(store: store, ledger: ledgerCapsule), revision = try catalog.index().revision
    XCTAssertEqual(try M4CatalogIO.encode(catalog.sealPhoneResources(store: store, ledger: ledgerCapsule)), try M4CatalogIO.encode(seal))
    XCTAssertEqual(try catalog.index().revision, revision); XCTAssertEqual(try catalog.index().entries.count, 2)
    try await c.admitCurrentIdentity(); XCTAssertTrue(c.context.account.canEnterRecording)
    let calls = await f.relay.calls; XCTAssertEqual(calls, 1)
    try catalog.close(); try await c.close()
    }
  }
  func testProspectiveActualCapsuleCapacityFailsBeforeLedgerReservationOrSQL() async throws {
    let f = try await unattachedSignedPhoneFixture(), c = f.composition
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let (phone, store, ledger) = try await actualPhoneReservation(f, catalog: catalog)
    let root = location(); var deep = root
    while deep.path.utf8.count < 650 { deep.appendPathComponent(String(repeating: "d", count: 38)) }
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    var controls = store.retainedControls
    for index in 0..<(256 - controls.count) {
      let branch = deep.appendingPathComponent(String(format: "%03d", index) + String(repeating: "b", count: 65))
      try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: false)
      let leaf = branch.appendingPathComponent(String(repeating: "l", count: 100))
      try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
      let file = leaf.appendingPathComponent(String(repeating: "f", count: 70))
      XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]))
      controls.append(try M4CatalogIO.anchor(file))
    }
    func expanded(_ original: M4OwnershipCapsule) throws -> M4OwnershipCapsule {
      M4OwnershipCapsule(version: original.version, namespaceID: original.namespaceID, componentID: original.componentID, revision: original.revision, kind: original.kind, scope: original.scope, root: original.root, retainedControls: controls, ancestors: try M4CatalogIO.ancestors([original.root] + controls))
    }
    let largeStore = try expanded(store), largeLedger = try expanded(ledger)
    XCTAssertThrowsError(try catalog.reservePhoneResources(phone, store: largeStore, ledger: largeLedger)) { XCTAssertEqual($0 as? M4CatalogError, .budgetExceeded) }
    XCTAssertNil(try catalog.phoneResources()); XCTAssertTrue(try catalog.index().entries.isEmpty)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: phone.ledger.source.path)), Data()); XCTAssertFalse(FileManager.default.fileExists(atPath: phone.ledger.published.path))
    try catalog.close(); try await c.close()
  }
}


extension M4AccountCompositionTests {
  func testHeldResourceWorkRejectsIndependentAccountChangeWithoutRetargetingSeal() async throws {
    let barrier = PhoneScopeBarrier(), f = try await serviceFixture(resourceReplyGate: { await barrier.hold() })
    let action = Task { await f.composition.context.account.perform(.recover) }
    await barrier.waitForEntry()
    let original = try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), generation = try await f.composition.repository.identityGenerationV4()
    await f.observer.setAccount("different-current-account"); barrier.release(); await action.value
    XCTAssertFalse(f.composition.context.account.canEnterRecording); XCTAssertNil(f.composition.admittedScope)
    let nextGeneration = try await f.composition.repository.identityGenerationV4(); XCTAssertEqual(nextGeneration, generation)
    XCTAssertEqual(try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), original)
    try await f.composition.close()
  }
  func testRealCredentialExpiryDuringOriginalVaultWriteTailPreservesGrantAndPausesUI() async throws {
    let f = try await serviceFixture(holdVault: true, expiresIn: 2), c = f.composition
    let start = Date(), action = Task { await c.context.account.perform(.recover) }
    guard await waitForVault(f.vault) else { return XCTFail("original vault write required") }
    while Date().timeIntervalSince(start) < 2.1 { try await Task.sleep(for: .milliseconds(20)) }
    await f.vault.release(); await action.value
    let generation = try await c.repository.identityGenerationV4(), proof = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
    XCTAssertEqual(proof?.currentAuthRequestID, f.attempt.requestID)
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    let credential = try await f.vault.credential(); XCTAssertLessThanOrEqual(Double(credential.expiresAt), Date().timeIntervalSince1970)
    let writes = await f.vault.replacements; XCTAssertEqual(writes, 1)
    try await c.close()
  }
  func testCloseJoinsHeldResourceTailBeforeClosingOriginalLedgerAndStore() async throws {
    let barrier = PhoneScopeBarrier(), f = try await serviceFixture(resourceReplyGate: { await barrier.hold() }), c = f.composition
    let action = Task { await c.context.account.perform(.recover) }; await barrier.waitForEntry()
    var done = false; let closing = Task { try await c.close(); done = true }
    let retired = await waitForOriginalRetirement(c.session); XCTAssertTrue(retired)
    try await Task.sleep(for: .milliseconds(30)); XCTAssertFalse(done)
    let binding = try await c.repository.accountBindingV4(); XCTAssertEqual(binding?.accountID, "account-fixture")
    barrier.release(); await action.value; try await closing.value
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
  }
}
#if DEBUG
extension M4AccountCompositionTests {
  func testHeldResourceTailRejectsRealNewSignedCurrentRequestAtUnchangedGeneration() async throws {
    let barrier = PhoneScopeBarrier(), f = try await freshServiceFixture(resourceReplyGate: { await barrier.hold() }), c = f.composition
    let action = Task { await c.context.account.perform(.signIn) }
    let firstApple = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    try serviceMailboxReply(firstApple, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    await barrier.waitForEntry()
    let original = try XCTUnwrap(f.prepared.activePhoneAttachment()), generation = try await c.repository.identityGenerationV4()
    // A second real accepted service result on the same original facade models
    // a current-pointer change while the owner reply is held; no forged Store proof.
    let changing = Task { try await c.accountService.signIn(requestID: "independent-new-current", challengeRequestID: "independent-new-challenge") }
    let secondApple = try await serviceMailboxRequest(f.protocolRoot, operation: "apple")
    try serviceMailboxReply(secondApple, payload: JSONSerialization.data(withJSONObject: ["identityToken": "explicit-current-token", "authorizationCode": "explicit-current-code"]))
    _ = try await changing.value
    let nextGeneration = try await c.repository.identityGenerationV4(), current = try await c.repository.currentAuthRequestIDV4()
    XCTAssertEqual(nextGeneration, generation); XCTAssertEqual(current, "independent-new-current")
    barrier.release(); await action.value
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    XCTAssertEqual(try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), try M4CatalogIO.encode(Optional(original)))
    try await c.close()
  }
}
#endif


extension M4AccountCompositionTests {
  func testActualModelSQLAwaitCrossingRealTTLUsesOriginalCompositionVeto() async throws {
    let f = try await serviceFixture(expiresIn: 3), c = f.composition
    await c.context.account.perform(.recover); XCTAssertTrue(c.context.account.canEnterRecording)
    let handle = try await f.prepared.prepareCurrentPhoneResources(expectedIdentityGeneration: c.repository.identityGenerationV4(), observed: f.observer.currentIdentity())
    let credential = try await f.vault.credential(), generation = try await c.repository.identityGenerationV4()
    do { try await c.performAccount(.renew) } catch {} // Clear old UI/scope without changing original proof or credential.
    let veto = c.finalPhoneAdmissionCheck(handle, credential: credential), barrier = PhoneScopeBarrier()
    let admission = Task {
      try await c.context.account.admitIdentity(handle.attachment.binding, expectedIdentityGeneration: generation, read: {
        let actual = try await PresentationAccountAdmissionRead.read(c.repository)
        await barrier.hold() // Existing056 test seam; actual original SQL read has completed.
        return actual
      }, finalCheck: veto)
    }
    await barrier.waitForEntry(); XCTAssertFalse(c.context.account.canEnterRecording)
    while Date().timeIntervalSince1970 < Double(credential.expiresAt) { try await Task.sleep(for: .milliseconds(20)) }
    barrier.release()
    do { try await admission.value; XCTFail("the actual model cannot publish ready after the retained credential expired during its own awaited read") }
    catch { XCTAssertEqual(error as? AuthorityError, .staleAttestation) }
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    let writes = await f.vault.replacements; XCTAssertEqual(writes, 1, "final publication never adds a vault await/write")
    try await c.close()
  }
  func testHeldOwnerRejectsIndependentEnvironmentChangeWithoutChangingOriginalProof() async throws {
    let barrier = PhoneScopeBarrier(), f = try await serviceFixture(resourceReplyGate: { await barrier.hold() }), c = f.composition
    let action = Task { await c.context.account.perform(.recover) }; await barrier.waitForEntry()
    let original = try M4CatalogIO.encode(f.prepared.activePhoneAttachment())
    await f.observer.setEnvironment(.production); barrier.release(); await action.value
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    XCTAssertEqual(try M4CatalogIO.encode(f.prepared.activePhoneAttachment()), original)
    try await c.close()
  }
  func testPublicAccountAndFormalActivationRoutesCannotBypassIncompletePairSeal() async throws {
    var fired = false
    let f = try await serviceFixture(crashHook: { if $0 == .afterLedgerInitialization && !fired { fired = true; throw M4CatalogError.injectedFailure } }), c = f.composition
    await c.context.account.perform(.recover); XCTAssertTrue(fired)
    let catalog = try M4OwnedDataCatalog(directory: f.prepared.seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    let original = try XCTUnwrap(catalog.phoneResources()); XCTAssertNil(original.seal)
    let unknown = URL(fileURLWithPath: original.ledger.published.path).deletingLastPathComponent().appendingPathComponent("unrecognized-pair-evidence")
    let bytes = Data([3, 0, 255]); try bytes.write(to: unknown, options: .withoutOverwriting)
    let before = await f.relay.calls
    for action in [AccountUserAction.signIn, .registerWatch] {
      do { try await c.performAccount(action); XCTFail("reserved old namespace refuses every new generic protocol before side effects") } catch {}
    }
    do { try await c.admitCurrentIdentity(); XCTFail("public observation cannot bypass a missing seal") } catch {}
    let app = M4ApplicationContext(original: c, developmentSimulation: true)
    do { try await app.activateControlled(); XCTFail("formal activation must use the same pair-seal gate") } catch {}
    let calls = await f.relay.calls; XCTAssertEqual(calls, before)
    XCTAssertFalse(c.context.account.canEnterRecording); XCTAssertNil(c.admittedScope)
    XCTAssertEqual(try Data(contentsOf: unknown), bytes); XCTAssertEqual(try M4CatalogIO.encode(catalog.phoneResources()), try M4CatalogIO.encode(Optional(original)))
    try FileManager.default.removeItem(at: unknown) // Exact fixture only, after preservation checks.
    try await c.admitCurrentIdentity(); XCTAssertTrue(c.context.account.canEnterRecording); _ = try catalog.requirePhoneSeal()
    try catalog.close(); try await app.shutdown()
  }
}
#if DEBUG
extension M4AccountCompositionTests {
  private func originalUnknownWatchAction(_ f: FreshServiceFixture, action: AccountUserAction, expected: WatchRegistrationAction) async throws -> WatchRegistrationAttemptV4 {
    let task = Task { await f.composition.context.account.perform(action) }
    let contextRequest = try await serviceMailboxRequest(f.protocolRoot, operation: "phone-context")
    let context = try WatchRegistrationContextV4(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", phoneID: "independent-original-phone", activationEpoch: 1, environment: .development)
    try serviceMailboxReply(contextRequest, payload: AuthorityWire.encode(context))
    let registration = try await serviceMailboxRequest(f.protocolRoot, operation: "phone-register")
    let forward = try JSONDecoder().decode(CompositionWatchForward.self, from: registration.payload)
    XCTAssertEqual(forward.action, expected)
    try JSONSerialization.data(withJSONObject: ["issue": "unavailable"], options: [.sortedKeys]).write(to: registration.response, options: .atomic)
    await task.value
    XCTAssertFalse(f.composition.context.account.canEnterRecording); XCTAssertNil(f.composition.admittedScope)
    return forward.attempt
  }
  func testUnboundWatchUnknownRepeatedAndReopenedRecoveryKeepsOriginalIDWithoutPhoneSwitch() async throws {
    let f = try await freshServiceFixture(watch: true), c = f.composition
    let original = try await originalUnknownWatchAction(f, action: .registerWatch, expected: .submit)
    let repeated = try await originalUnknownWatchAction(f, action: .registerWatch, expected: .recover); XCTAssertEqual(repeated, original)
    do { try await c.performAccount(.signIn); XCTFail("unknown Watch cannot switch to fresh Phone authentication") } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    let material = f.prepared.material, seed = f.prepared.seed
    try await c.close()
    let prepared = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    try prepared.prepareManagedResources()
    let publicKey = AuthorityWire.base64URL(f.key.publicKey.rawRepresentation), trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["service-key": publicKey])
    let configuration = DevelopmentAuthorityConfiguration(dataset: "fresh", namespace: seed.namespace, baseURL: "http://127.0.0.1:1", keyID: "service-key", publicKey: publicKey, cloudSpaceID: "cloud-fixture", subject: "configuration-does-not-admit-current-identity", role: "watch")
    let adapters = try M4ControlledAdapters.make(configuration: configuration, rootDirectory: f.protocolRoot)
    let reopened = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture", identity: f.observer, authorityRelay: f.relay, controlledAdapters: adapters)
    let next = FreshServiceFixture(composition: reopened, prepared: prepared, observer: f.observer, vault: f.vault, relay: f.relay, protocolRoot: f.protocolRoot, key: f.key)
    let recovered = try await originalUnknownWatchAction(next, action: .recover, expected: .recover); XCTAssertEqual(recovered, original)
    let attempts = try await reopened.repository.pendingWatchRegistrationAttemptsV4(), phones = try await reopened.repository.authAttemptsV4()
    XCTAssertEqual(attempts, [original]); XCTAssertTrue(phones.isEmpty)
    let calls = await f.relay.calls, writes = await f.vault.replacements; XCTAssertEqual(calls, 1, "only the original fresh Watch challenge"); XCTAssertEqual(writes, 0)
    XCTAssertNil(try prepared.activePhoneAttachment()); try await reopened.close()
  }
}
#endif

extension M4AccountCompositionTests {
  func testOriginalProofCannotAllocateLedgerBeforeConfiguredCloudMismatchIsRejected() async throws {
    let f = try await unattachedSignedPhoneFixture(), seed = f.prepared.seed, material = f.prepared.material
    try await f.composition.close()
    let prepared = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    try prepared.prepareManagedResources()
    let c = try await M4AccountComposition.make(prepared: prepared, trust: f.trust, cloudSpaceID: "different-configured-cloud", identity: f.observer, authorityRelay: f.relay)
    let generation = try await c.repository.identityGenerationV4(), witness = try await c.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
    XCTAssertNotNil(witness, "actual retained original signed current proof is the test precondition")
    do { try await c.admitCurrentIdentity(); XCTFail("fresh identity must match original configured cloud before owner work") } catch {}
    let catalog = try M4OwnedDataCatalog(directory: seed.controlDirectory.deletingLastPathComponent().appendingPathComponent("catalog"))
    XCTAssertNil(try catalog.phoneResources(), "mismatched independent/configured cloud cannot reserve or initialize a foreign ledger")
    let physical = try XCTUnwrap(catalog.physicalBootstrap())
    let slot = URL(fileURLWithPath: physical.reservation.ledgerSlot.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: slot.path))
    if FileManager.default.fileExists(atPath: slot.path) { XCTAssertEqual(try Data(contentsOf: slot), Data()) }
    XCTAssertTrue(try catalog.index().entries.isEmpty); XCTAssertFalse(c.context.account.canEnterRecording)
    try catalog.close(); try await c.close()
  }
}
