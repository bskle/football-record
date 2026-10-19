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
    await c.model.shutdown()
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
    let retirement = Task { began = true; await c.model.shutdown(); done = true }
    for _ in 0..<1000 { if began { break }; await Task.yield() }
    XCTAssertTrue(began)
    XCTAssertFalse(done, "retirement cannot acknowledge completion while the original Session capture driver is still awaiting a gateway")
    var generationAtReturn: Int64?
    if done { generationAtReturn = try await c.repository.snapshotV2(matchID: operation.binding.matchID).business.generation }
    await gateway.release(); await retirement.value
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
    try await prepared.close()
  }
  func testDefaultCurrentIdentityRemainsUnavailableDespiteStoredBindingAndCredential() async throws {
    let (prepared, trust) = try await identityFixture("m4-compose-two")
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud-fixture")
    try await c.repository.bindAccountV4(binding(prepared))
    do { try await c.admitCurrentIdentity(); XCTFail("default identity boundary cannot admit") }
    catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    XCTAssertFalse(c.context.account.canEnterRecording)
    try await prepared.close()
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
    try await prepared.close()
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
    try await prepared.close()
  }
  private func binding(_ prepared: M4PreparedIdentity) throws -> AccountBindingV4 {
    try AccountBindingV4(accountID: "account-fixture", cloudSpaceID: "cloud-fixture", deviceID: prepared.seed.installationID, activationEpoch: 1, role: .phone, environment: .development)
  }
  private func identityFixture(_ namespace: String) async throws -> (M4PreparedIdentity, AuthorityTrustConfiguration) {
    let root = location(), trustKey = Curve25519.Signing.PrivateKey()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["authority-fixture": AuthorityWire.base64URL(trustKey.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("retained")) { seed in
      let signer = try DevelopmentDeviceSigner(namespace: namespace, rawRepresentation: Data(repeating: 21, count: 32))
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
