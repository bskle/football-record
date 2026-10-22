#if DEBUG && os(macOS)
import Foundation
import XCTest
import AccountKit
import MatchStore
import MatchPresentation
@testable import AppIntegration

@MainActor final class M4FirstPhoneHTTPTests: XCTestCase {
  private func assertCleanup(_ report: M4HTTPFixtureHarness.Report) {
    XCTAssertTrue(report.ownerClosed); XCTAssertTrue(report.workerJoined); XCTAssertTrue(report.requestsJoined); XCTAssertTrue(report.process.exited)
    XCTAssertEqual(report.process.status, 0); XCTAssertTrue(report.process.readersJoined); XCTAssertTrue(report.process.closeAcknowledged)
    print("S1 cleanup nodePID=\(report.process.pid) status=\(report.process.status) ownerClosed=\(report.ownerClosed) requestsJoined=\(report.requestsJoined) workerJoined=\(report.workerJoined) readersJoined=\(report.process.readersJoined) closeAck=\(report.process.closeAcknowledged)")
  }
  private func withFixture(_ body: @MainActor (M4HTTPFixtureHarness) async throws -> Void) async throws {
    let f = try await M4HTTPFixtureHarness.start()
    do {
      try await body(f)
      let report = await f.close()
      assertCleanup(report); XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "owned private runtime material must be removed after successful joins")
    } catch { assertCleanup(await f.close()); XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path)); throw error }
  }
  func testOriginalPublicBootstrapFirstPhoneUsesGenuineIndependentObservationAndHTTP() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(), context = wrapper.context
      XCTAssertTrue(wrapper.developmentSimulation)
      let bindingBefore = try await context.repository.accountBindingV4(), attemptsBefore = try await context.repository.authAttemptsV4(), currentBefore = try await context.repository.currentAuthRequestIDV4()
      XCTAssertNil(bindingBefore); XCTAssertTrue(attemptsBefore.isEmpty); XCTAssertNil(currentBefore); XCTAssertFalse(context.account.canEnterRecording)
      let directory = f.nativeRoot.appendingPathComponent(f.configuration.namespace)
      let identity = try String(contentsOf: directory.appendingPathComponent("device.identity"), encoding: .utf8)
      let deviceID = String(identity.dropFirst("football-record.identity.v1:".count)); XCTAssertEqual(UUID(uuidString: deviceID)?.uuidString, deviceID)
      let material = try DevelopmentAuthorityScenario.deviceMaterial(configuration: f.configuration, namespaceDirectory: directory, installationID: deviceID)
      let publicKey = material.signer.publicKey
      let observed = try await f.signIn()
      let generation = try await context.repository.identityGenerationV4(), current = try await context.repository.currentAuthRequestIDV4(), evidence = try await context.repository.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation)
      let actualBinding = try await context.repository.accountBindingV4()
      let proof = try XCTUnwrap(evidence), binding = try XCTUnwrap(actualBinding)
      XCTAssertEqual(current, proof.currentAuthRequestID); XCTAssertEqual(proof.binding, binding); XCTAssertEqual(binding.accountID, observed.accountID)
      XCTAssertEqual(binding.deviceID, deviceID); XCTAssertEqual(binding.role, .phone); XCTAssertEqual(proof.attempt.publicKey, publicKey)
      let repositoryIdentity = await context.repository.syncRepositoryIdentity(), sessionIdentity = await context.session.syncRepositoryIdentity(); XCTAssertEqual(repositoryIdentity, sessionIdentity)
      XCTAssertTrue(context.account.canEnterRecording); XCTAssertEqual(f.replies, 1); XCTAssertEqual(f.rejected, 0)
      XCTAssertEqual(f.observations, 2); XCTAssertTrue(f.authenticationSubjectDiffersFromHint); XCTAssertNotEqual(observed.accountID, f.configuration.subject)
      let catalog = try M4OwnedDataCatalog(directory: f.nativeRoot.appendingPathComponent("development/m4-controls/" + f.configuration.namespace + "/catalog"))
      let attachment = try XCTUnwrap(catalog.phoneResources()?.attachment); _ = try catalog.requirePhoneSeal()
      XCTAssertEqual(attachment.currentAuthRequestID, proof.currentAuthRequestID); XCTAssertEqual(attachment.receiptRaw, proof.receipt.raw)
      XCTAssertEqual(attachment.scope.accountID, observed.accountID); XCTAssertEqual(attachment.scope.cloudSpaceID, f.cloudSpaceID); XCTAssertEqual(attachment.scope.zoneID, f.zoneID)
      XCTAssertEqual(try catalog.index().entries.count, 2); try catalog.close()
      let original = try DevelopmentAuthorityScenario.deviceMaterial(configuration: f.configuration, namespaceDirectory: directory, installationID: deviceID); XCTAssertEqual(original.signer.publicKey, publicKey)
      print("S1 original public Phone HTTP: genuine observations=2 authenticated=1 original signed current proof+managed pair seal+ready; controlled Cloud only")
    }
  }
  func testAlternateObservationCannotAdmitPrimaryAuthentication() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(observationIdentity: "alternate")
      let alternate = try await f.signIn(observationIdentity: "alternate")
      let primary = try await f.observe(identity: "primary"); XCTAssertNotEqual(alternate.accountID, primary.accountID)
      XCTAssertFalse(wrapper.context.account.canEnterRecording)
      let catalog = try M4OwnedDataCatalog(directory: f.nativeRoot.appendingPathComponent("development/m4-controls/" + f.configuration.namespace + "/catalog"))
      XCTAssertNil(try catalog.phoneResources()); XCTAssertTrue(try catalog.index().entries.isEmpty); try catalog.close()
      XCTAssertEqual(f.replies, 1); XCTAssertTrue(f.authenticationSubjectDiffersFromHint)
    }
  }
  func testCancelledOriginalOwnerDiscardsLateTokenReplyAndCannotBeRevivedByRefresh() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(); f.holdReplies = true
      let login = f.beginSignIn()
      try await f.waitUntil { f.held }
      try await wrapper.shutdown(); _ = try await login.value
      f.holdReplies = false; try await f.waitUntil { f.suppressed == 1 }
      XCTAssertEqual(f.replies, 0); XCTAssertFalse(wrapper.context.account.canEnterRecording)
      let responses = f.nativeRoot.appendingPathComponent("development/mailbox/responses")
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
      _ = try await f.refreshIdentity("alternate")
      do { try await wrapper.activateControlled(); XCTFail("fresh server observation cannot revive an already closed original owner") } catch {}
      XCTAssertFalse(wrapper.context.account.canEnterRecording)
    }
  }
  func testChangedOriginalRequestBytesAndAnchorSuppressHeldAuthenticationReply() async throws {
    try await withFixture { f in
      let wrapper = try await f.bootstrap(); f.holdReplies = true
      let login = f.beginSignIn(); try await f.waitUntil { f.held }
      let directory = f.nativeRoot.appendingPathComponent("development/mailbox/outgoing")
      let request = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
      let original = try M4HTTPFixtureHarness.read(request), raw = original.0
      var value = try M4HTTPFixtureCLI.object(raw, keys: ["id", "operation", "dataset", "payload"]); value["dataset"] = "foreign-dataset"
      try JSONSerialization.data(withJSONObject: value).write(to: request, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
      XCTAssertNotEqual(try M4HTTPFixtureHarness.anchor(request), original.1)
      f.holdReplies = false; try await f.waitUntil { f.suppressed == 1 }
      XCTAssertEqual(f.replies, 0); XCTAssertFalse(wrapper.context.account.canEnterRecording)
      login.cancel(); _ = await login.result; try await wrapper.shutdown()
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.nativeRoot.appendingPathComponent("development/mailbox/responses").path).isEmpty)
    }
  }
  func testHarnessRejectsMalformedMailboxShapeAndDuplicateCLIRequest() async throws {
    try await withFixture { f in
      _ = try await f.bootstrap()
      let id = UUID().uuidString, outgoing = f.nativeRoot.appendingPathComponent("development/mailbox/outgoing/" + id + ".json")
      let malformed: [String: Any] = ["id": id, "operation": "apple", "dataset": f.configuration.dataset, "payload": Data("{}".utf8).base64EncodedString(), "extra": "refuse"]
      try JSONSerialization.data(withJSONObject: malformed).write(to: outgoing, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outgoing.path)
      try await f.waitUntil { f.rejected == 1 }; XCTAssertEqual(f.replies, 0)
      try FileManager.default.removeItem(at: outgoing)
      let requestID = UUID().uuidString; _ = try await f.cli.command("identity.begin", requestID: requestID)
      do { _ = try await f.cli.command("identity.begin", requestID: requestID); XCTFail("duplicate local request must fail before IPC") } catch { XCTAssertEqual(error as? M4HTTPFixtureError, .duplicate) }
      let invalid = try JSONSerialization.data(withJSONObject: ["kind": "wrong", "environment": "development", "namespace": f.metadata.namespace, "observationID": UUID().uuidString, "accountID": "not-a-server-observation", "observedAt": Int64(Date().timeIntervalSince1970), "expiresAt": Int64(Date().timeIntervalSince1970) + 60])
      do { _ = try M4HTTPFixtureHarness.observation(invalid, metadata: f.metadata); XCTFail("wrong observation kind must not be published") } catch { XCTAssertEqual(error as? M4HTTPFixtureError, .shape) }
    }
  }
}
#endif
