import Foundation
import XCTest
import CryptoKit
import MatchStore
import MatchSession
@testable import MatchPresentation

@MainActor final class AccountStatusTests: XCTestCase {
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
