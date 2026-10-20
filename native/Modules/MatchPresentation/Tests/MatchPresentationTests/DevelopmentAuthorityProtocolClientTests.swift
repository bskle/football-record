#if DEBUG
import Foundation
import Darwin
import CryptoKit
import XCTest
import MatchCore
import MatchStore
import AccountKit
import CloudSync
@testable import MatchPresentation

@MainActor final class DevelopmentAuthorityProtocolClientTests: XCTestCase {
 private func configuration() throws -> DevelopmentAuthorityConfiguration {
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
  return DevelopmentAuthorityConfiguration(dataset: "protocol", namespace: "m4-ui-protocol-phone", baseURL: "http://127.0.0.1:1", keyID: "fixture-key", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation), cloudSpaceID: "space", subject: "fixture-subject", role: "phone")
 }
 private func root() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-clients-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
 }
 private func mailbox(_ root: URL) -> URL { root.appendingPathComponent("development/mailbox") }
 private func write(_ data: Data, _ url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url, options: .atomic)
 }
 func testFactoryHasNoDatabaseIdentitySignerOrVaultSideEffects() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let config = try configuration(), directory = root.appendingPathComponent(config.namespace)
  let originals = ["matches.sqlite", "device.identity", "development.key", "development.vault", "authority.fixture"]
  for name in originals { try write(Data(("original:" + name).utf8), directory.appendingPathComponent(name)) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: config, rootDirectory: root)
  XCTAssertEqual(clients.namespace, config.namespace)
  for name in originals { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data(("original:" + name).utf8)) }
  XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), originals.sorted())
  XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox(root).path).sorted(), ["incoming", "incoming-responses", "outgoing", "responses"])
  let actual = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { path in
   try root.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
  }
  XCTAssertEqual(actual.sorted(), originals.map { config.namespace + "/" + $0 }.sorted())
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testNonCanonicalNamespaceOrNonLoopbackConfigurationCannotCreateMailbox() throws {
  for variant in 0..<3 {
   let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
   var config = try configuration()
   if variant == 0 { config.namespace = "production" }
   if variant == 1 { config.dataset = "../other" }
   if variant == 2 { config.baseURL = "https://example.com" }
   XCTAssertThrowsError(try DevelopmentAuthorityScenario.protocolClients(configuration: config, rootDirectory: root))
   XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
 }
 func testExistingPendingOrUnknownMailboxContentsArePreservedAndRejected() async throws {
  for path in ["outgoing/old-request.json", "responses/old-response.json", "unknown-business.bin"] {
   let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
   let original = Data([0, 255, 17]), file = mailbox(root).appendingPathComponent(path)
   try write(original, file)
   do {
    let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
    _ = await clients.close(); XCTFail("Existing mailbox contents cannot be adopted")
   } catch { XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .undrainedMailbox) }
   XCTAssertEqual(try Data(contentsOf: file), original)
  }
 }
 func testDrainStateReadsCurrentMailboxWithoutClosingOrAdoptingContents() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let initial = await clients.drainState(); XCTAssertEqual(initial, .drained)
  let foreign = mailbox(root).appendingPathComponent("foreign-business.bin"), bytes = Data([0, 255, 88])
  try write(bytes, foreign)
  let occupied = await clients.drainState(); XCTAssertEqual(occupied, .undrained)
  let occupiedAgain = await clients.drainState(); XCTAssertEqual(occupiedAgain, .undrained)
  XCTAssertEqual(try Data(contentsOf: foreign), bytes)
  // The fixture alone removes its own file; inspection never cleans or adopts it.
  try FileManager.default.removeItem(at: foreign)
  let emptyAgain = await clients.drainState(); XCTAssertEqual(emptyAgain, .drained)
  let call = Task { try await clients.authorize(nonceSHA256: "original-saga-nonce") }
  let pending = try await request(root, operation: "apple")
  let outstanding = await clients.drainState(); XCTAssertEqual(outstanding, .undrained)
  let outstandingAgain = await clients.drainState(); XCTAssertEqual(outstandingAgain, .undrained)
  XCTAssertFalse(FileManager.default.fileExists(atPath: pending.response.path))
  try reply(pending, payload: JSONSerialization.data(withJSONObject: ["identityToken": "original-saga-token", "authorizationCode": "original-saga-code"]))
  let value = try await call.value; XCTAssertEqual(value.identityToken, "original-saga-token")
  let completed = await clients.drainState(); XCTAssertEqual(completed, .drained)
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testDrainStateDoesNotReportDrainedBeforeOwnedWorkWritesMailbox() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let gate = ProtocolClientGate()
  let work = Task { try await clients.owned { await gate.hold(); return Data([0, 255, 5]) } }
  await gate.waitForStarted()
  XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: mailbox(root).appendingPathComponent("outgoing").path).isEmpty)
  let active = await clients.drainState(); XCTAssertEqual(active, .undrained)
  await gate.release()
  let value = try await work.value; XCTAssertEqual(value, Data([0, 255, 5]), "Read-only drainState must not cancel the original call")
  let drained = await clients.drainState(); XCTAssertEqual(drained, .drained)
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testFinalCloseJoinsCancellationInsensitiveOwnedWorkAndRejectsLateResult() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let gate = ProtocolClientGate(), finished = ProtocolClientFlag()
  let work = Task { try await clients.owned { await gate.hold(); return Data([0, 255, 4]) } }
  await gate.waitForStarted()
  let closing = Task { let state = await clients.close(); await finished.set(); return state }
  var fenced = false
  let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
  while ContinuousClock.now < deadline {
   do { _ = try await clients.owned { 1 } }
   catch { fenced = (error as? DevelopmentAuthorityProtocolError) == .closed; break }
   await Task.yield()
  }
  XCTAssertTrue(fenced)
  let returnedEarly = await finished.value; XCTAssertFalse(returnedEarly, "close must join the original cancellation-insensitive task")
  await gate.release()
  do { _ = try await work.value; XCTFail("Late typed result cannot escape final close") }
  catch { XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .closed) }
  let state = await closing.value; XCTAssertEqual(state, .drained)
  do { _ = try await clients.owned { 2 }; XCTFail("Closed admission is permanent") }
  catch { XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .closed) }
 }
 private func request(_ root: URL, operation: String) async throws -> ProtocolMailboxObservation {
  let outgoing = mailbox(root).appendingPathComponent("outgoing")
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
   try Task.checkCancellation()
   let files = try FileManager.default.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)
   if let file = files.first {
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let id = try XCTUnwrap(value["id"] as? String)
    XCTAssertNotNil(UUID(uuidString: id)); XCTAssertEqual(value["operation"] as? String, operation)
    XCTAssertEqual(value["dataset"] as? String, "protocol")
    let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(value["payload"] as? String)))
    return ProtocolMailboxObservation(payload: payload, response: mailbox(root).appendingPathComponent("responses/" + id + ".json"))
   }
   try await Task.sleep(for: .milliseconds(2))
  }
  throw ProtocolFixtureError.timeout
 }
 private func reply(_ request: ProtocolMailboxObservation, payload: Data) throws {
  try write(JSONEncoder().encode(ProtocolMailboxReply(payload: payload)), request.response)
 }
 func testAppleUsesOriginalMailboxAndPreservesTransientAuthorization() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let nonce = AuthorityWire.hash(Data("nonce".utf8)), task = Task { try await clients.authorize(nonceSHA256: nonce) }
  let original = try await request(root, operation: "apple")
  let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: original.payload) as? [String: String])
  XCTAssertEqual(fields, ["nonce": nonce])
  try reply(original, payload: JSONSerialization.data(withJSONObject: ["identityToken": "transient-opaque-token", "authorizationCode": "transient-code"]))
  let value = try await task.value
  XCTAssertEqual(value.identityToken, "transient-opaque-token"); XCTAssertEqual(value.authorizationCode, "transient-code")
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testCloudUsesOriginalTypedMailboxWithoutChangingCanonicalOrCursor() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let scope = try CloudScope(accountID: "account", cloudSpaceID: "space", zoneID: "zone", activationEpoch: 3)
  let checkpoint = try CloudCheckpoint.account(scope: scope, checkpointID: UUID(), recordIDs: [])
  let record = try CloudRecord(scope: scope, payload: .checkpoint(checkpoint)), upload = try CloudUpload(scope: scope, record: record)
  let saving = Task { try await clients.save(upload) }, savedRequest = try await request(root, operation: "cloud-save")
  let submitted = try JSONDecoder().decode(CloudUpload.self, from: savedRequest.payload)
  XCTAssertEqual(submitted, upload); XCTAssertEqual(submitted.record.canonicalBytes, record.canonicalBytes)
  try reply(savedRequest, payload: JSONEncoder().encode(submitted))
  let outcome = try await saving.value
  guard case .complete(let saved) = outcome else { throw ProtocolFixtureError.invalid }
  XCTAssertEqual(saved.parts.first?.readBackBytes, record.canonicalBytes)
  XCTAssertEqual(saved.scope, scope); XCTAssertTrue(saved.confirmationID.hasPrefix("development-confirm-"))
  let cursor = try CloudCursor(appliedToken: Data([0, 255, 7]), fetchGeneration: 9)
  let fetching = Task { try await clients.fetch(scope: scope, cursor: cursor) }, fetchRequest = try await request(root, operation: "cloud-fetch")
  XCTAssertEqual(try JSONDecoder().decode(CloudScope.self, from: fetchRequest.payload), scope)
  try reply(fetchRequest, payload: JSONEncoder().encode([record]))
  let batch = try await fetching.value
  XCTAssertEqual(batch.records, [record]); XCTAssertEqual(batch.expectedAppliedToken, cursor.appliedToken); XCTAssertEqual(batch.fetchGeneration, cursor.fetchGeneration)
  let deleting = Task { try await clients.deletePrivateZone(scope: scope) }, deleteRequest = try await request(root, operation: "cloud-delete")
  XCTAssertEqual(try JSONDecoder().decode(CloudScope.self, from: deleteRequest.payload), scope)
  try reply(deleteRequest, payload: Data()); try await deleting.value
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testWatchSubmitAndRecoverKeepTheExactOriginalAttemptAndOpaqueReply() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let context = try WatchRegistrationContextV4(accountID: "account", cloudSpaceID: "space", phoneID: "phone", activationEpoch: 3, environment: .development)
  let fetching = Task { try await clients.registrationContext() }, contextRequest = try await request(root, operation: "phone-context")
  XCTAssertTrue(contextRequest.payload.isEmpty); try reply(contextRequest, payload: AuthorityWire.encode(context))
  let found = try await fetching.value; XCTAssertEqual(found, context)
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 8, count: 32))
  let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation), hash = String(repeating: "a", count: 64)
  let body: [String: Any] = ["version": 1, "requestID": "watch-request", "watchID": "watch", "watchPublicKey": publicKey, "challengeID": "challenge", "challengeSHA256": hash]
  let signature = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])))
  let payload = WatchRegistrationPayloadV4(requestID: "watch-request", watchID: "watch", watchPublicKey: publicKey, challengeID: "challenge", deviceProof: AuthorityWire.base64URL(signature))
  let attempt = try WatchRegistrationAttemptV4(context: context, payload: payload, challengeRequestID: "challenge-request", challengeSHA256: hash)
  for action in [WatchRegistrationAction.submit, .recover] {
   let forwarding = Task { try await clients.authorizeRegistration(attempt, action: action) }, original = try await request(root, operation: "phone-register")
   let forwarded = try JSONDecoder().decode(ProtocolWatchForward.self, from: original.payload)
   XCTAssertEqual(forwarded.attempt, attempt); XCTAssertEqual(forwarded.attempt.canonicalRequest, attempt.canonicalRequest); XCTAssertEqual(forwarded.action, action)
   let bytes = Data([0, 255, 4, 128]); try reply(original, payload: bytes)
   let raw = try await forwarding.value; XCTAssertEqual(raw, bytes)
  }
  let state = await clients.close(); XCTAssertEqual(state, .drained)
 }
 func testClosePreservesAnotherClientsCallAndRechecksCurrentInventory() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let first = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let other = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let call = Task { try await other.authorize(nonceSHA256: "other-nonce") }, original = try await request(root, operation: "apple")
  let pending = await first.close(); XCTAssertEqual(pending, .undrained)
  XCTAssertTrue(FileManager.default.fileExists(atPath: original.response.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outgoing").path))
  try reply(original, payload: JSONSerialization.data(withJSONObject: ["identityToken": "other-token", "authorizationCode": "other-code"]))
  let value = try await call.value; XCTAssertEqual(value.identityToken, "other-token")
  let drained = await first.close(); XCTAssertEqual(drained, .drained)
  let foreign = mailbox(root).appendingPathComponent("foreign-business.bin"), bytes = Data([0, 255, 99])
  try write(bytes, foreign)
  let restored = await first.close(); XCTAssertEqual(restored, .undrained)
  XCTAssertEqual(try Data(contentsOf: foreign), bytes)
  let otherState = await other.close(); XCTAssertEqual(otherState, .undrained)
 }
 func testLateProtocolReplyIsRejectedAndNeverDeletedAsForeignData() async throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let clients = try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)
  let call = Task { try await clients.authorize(nonceSHA256: "old-nonce") }, original = try await request(root, operation: "apple")
  let state = await clients.close(); XCTAssertEqual(state, .drained)
  do { _ = try await call.value; XCTFail("late authorization") }
  catch { XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .closed) }
  let bytes = Data("late-external-response".utf8); try write(bytes, original.response)
  do { _ = try await clients.authorize(nonceSHA256: "new-nonce"); XCTFail("new operation after final close") }
  catch { XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .closed) }
  let inventory = await clients.close(); XCTAssertEqual(inventory, .undrained)
  XCTAssertEqual(try Data(contentsOf: original.response), bytes)
 }
 func testMailboxSymlinkCannotAdoptAnotherDirectory() throws {
  let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appendingPathComponent("outside"), linked = mailbox(root).appendingPathComponent("outgoing")
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
  XCTAssertThrowsError(try DevelopmentAuthorityScenario.protocolClients(configuration: configuration(), rootDirectory: root)) { error in
   XCTAssertEqual(error as? DevelopmentAuthorityProtocolError, .undrainedMailbox)
  }
  XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
 }
 #if os(macOS)
 func testOriginalHTTPRelayPreservesRawBodyAndClosingOneDoesNotInvalidateAnother() async throws {
  let fixture = try ProtocolEchoFixture(); defer { fixture.close() }
  let firstRoot = try root(), otherRoot = try root()
  defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: otherRoot) }
  var config = try configuration(); config.baseURL = fixture.baseURL
  let first = try DevelopmentAuthorityScenario.protocolClients(configuration: config, rootDirectory: firstRoot)
  let other = try DevelopmentAuthorityScenario.protocolClients(configuration: config, rootDirectory: otherRoot)
  _ = await first.close()
  let body = Data([0, 255, 34, 92, 7]), auth = "Bearer " + AuthorityWire.base64URL(Data([1, 2])), proof = AuthorityWire.base64URL(Data([3, 4]))
  let request = try AuthorityHTTPRequest.opaqueRelay(method: "POST", path: "/v1/protocol-echo", body: body, authorization: auth, deviceProof: proof)
  let response = try await other.send(request)
  XCTAssertEqual(response.status, 207)
  let value = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])
  XCTAssertEqual(value["body"], body.base64EncodedString()); XCTAssertEqual(value["path"], request.path); XCTAssertEqual(value["method"], "POST")
  XCTAssertEqual(value["authorization"], auth); XCTAssertEqual(value["proof"], proof)
  let state = await other.close(); XCTAssertEqual(state, .drained)
 }
 #endif
}

private struct ProtocolMailboxObservation: Sendable { let payload: Data; let response: URL }
private struct ProtocolMailboxReply: Encodable { let payload: Data }
private struct ProtocolWatchForward: Decodable { let attempt: WatchRegistrationAttemptV4; let action: WatchRegistrationAction }
private enum ProtocolFixtureError: Error { case timeout, invalid }

private actor ProtocolClientGate {
 private var started = false
 private var starts: [CheckedContinuation<Void, Never>] = []
 private var pending: CheckedContinuation<Void, Never>?
 func hold() async {
  started = true; starts.forEach { $0.resume() }; starts.removeAll()
  await withCheckedContinuation { pending = $0 }
 }
 func waitForStarted() async { if started { return }; await withCheckedContinuation { starts.append($0) } }
 func release() { pending?.resume(); pending = nil }
}
private actor ProtocolClientFlag {
 private(set) var value = false
 func set() { value = true }
}
#if os(macOS)
private final class ProtocolEchoFixture {
 let process = Process()
 let baseURL: String
 init() throws {
  let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  process.arguments = ["-u", "-c", """
import base64,http.server,json
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  data=json.dumps(dict(body=base64.b64encode(body).decode(),path=self.path,method=self.command,authorization=self.headers.get('Authorization'),proof=self.headers.get('X-Device-PoP'))).encode()
  self.send_response(207);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""]
  process.standardOutput = pipe; process.standardError = Pipe(); try process.run()
  do {
   let fd = pipe.fileHandleForReading.fileDescriptor
   var bytes = Data()
   let deadline = ContinuousClock.now.advanced(by: .seconds(5))
   while bytes.count < 16, bytes.last != 10 {
    guard ContinuousClock.now < deadline, process.isRunning else { throw ProtocolFixtureError.timeout }
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let status = poll(&ready, 1, 100)
    if status == 0 { continue }
    guard status > 0 else { throw ProtocolFixtureError.invalid }
    var byte: UInt8 = 0
    guard Darwin.read(fd, &byte, 1) == 1 else { throw ProtocolFixtureError.invalid }
    bytes.append(byte)
   }
   guard bytes.last == 10, let port = Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else { throw ProtocolFixtureError.invalid }
   baseURL = "http://127.0.0.1:" + String(port)
  } catch {
   if process.isRunning { process.terminate(); process.waitUntilExit() }
   throw error
  }
 }
 func close() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}
#endif
#endif
