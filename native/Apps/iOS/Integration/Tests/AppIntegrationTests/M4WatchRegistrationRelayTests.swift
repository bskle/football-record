import Foundation
import CryptoKit
import XCTest
import AccountKit
import MatchStore
import MatchCore
import MatchSession
@testable import AppIntegration

@MainActor final class M4WatchRegistrationRelayTests: XCTestCase {
  func testContextAndOriginalSubmitRecoverTravelThroughTypedEndpoint() async throws {
    let authorizer = RelayAuthorizer(), endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: authorizer)
    let channel = RelayLoopback(endpoint: endpoint), relay = M4WatchRegistrationRelay(channel: channel)
    let context = try await relay.registrationContext()
    XCTAssertEqual(context, try relayContext())
    let attempt = try relayAttempt()
    for action in [WatchRegistrationAction.submit, .recover] {
      let raw = try await relay.authorizeRegistration(attempt, action: action)
      XCTAssertEqual(raw, Data("original-private-reply".utf8))
    }
    let calls = await authorizer.calls
    XCTAssertEqual(calls.map { $0.0.canonicalRequest }, [attempt.canonicalRequest, attempt.canonicalRequest])
    XCTAssertEqual(calls.map { $0.0.requestID }, [attempt.requestID, attempt.requestID])
    XCTAssertEqual(calls.map { $0.1 }, [.submit, .recover])
    await relay.close(); await endpoint.close()
  }
  func testDefaultUnavailableDoesNotCreateAnAuthorizationResult() async throws {
    let relay = M4WatchRegistrationRelay()
    do { _ = try await relay.registrationContext(); XCTFail("disabled transport") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .unavailable) }
    await relay.close()
  }
  func testForeignCorrelationDigestActionAndOversizeResponseAreRejected() async throws {
    for mode in 0...4 {
      let relay = M4WatchRegistrationRelay(channel: RelayMalformedChannel(mode: mode))
      do { _ = try await relay.authorizeRegistration(relayAttempt(), action: .submit); XCTFail("unbound reply \(mode)") }
      catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .invalidMessage) }
      await relay.close()
    }
  }
  func testDecodedNoncanonicalAttemptIsRejectedBeforeEndpointOrChannel() async throws {
    let attempt = try relayAttempt()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
    object["canonicalRequest"] = Data("{}".utf8).base64EncodedString()
    let invalid = try JSONDecoder().decode(WatchRegistrationAttemptV4.self, from: JSONSerialization.data(withJSONObject: object))
    let authorizer = RelayAuthorizer(), endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: authorizer)
    do { _ = try await endpoint.handle(.authorize(UUID(), invalid, .submit)); XCTFail("invalid attempt") } catch {}
    let calls = await authorizer.calls; XCTAssertTrue(calls.isEmpty)
    await endpoint.close()
  }
}
private func relayContext() throws -> WatchRegistrationContextV4 {
  try WatchRegistrationContextV4(accountID: "relay-account", cloudSpaceID: "relay-cloud", phoneID: "relay-phone", activationEpoch: 1, environment: .development)
}
private func relayAttempt() throws -> WatchRegistrationAttemptV4 {
  let key = Curve25519.Signing.PrivateKey(), hash = AuthorityWire.hash(Data("fixture-challenge".utf8))
  let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
  let object: [String: Any] = ["version": 1, "requestID": "relay-request", "watchID": "relay-watch", "watchPublicKey": publicKey, "challengeID": "relay-challenge", "challengeSHA256": hash]
  let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  let signature = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: body))
  return try WatchRegistrationAttemptV4(context: relayContext(), payload: WatchRegistrationPayloadV4(requestID: "relay-request", watchID: "relay-watch", watchPublicKey: publicKey, challengeID: "relay-challenge", deviceProof: AuthorityWire.base64URL(signature)), challengeRequestID: "relay-challenge-request", challengeSHA256: hash)
}
private actor RelayAuthorizer: WatchRegistrationAuthorizing {
  var calls: [(WatchRegistrationAttemptV4, WatchRegistrationAction)] = []
  func registrationContext() throws -> WatchRegistrationContextV4 { try relayContext() }
  func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) -> Data {
    calls.append((attempt, action)); return Data("original-private-reply".utf8)
  }
}
private actor RelayLoopback: M4WatchRegistrationChannel {
  let endpoint: M4PhoneWatchRegistrationEndpoint
  init(endpoint: M4PhoneWatchRegistrationEndpoint) { self.endpoint = endpoint }
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse { try await endpoint.handle(request) }
  func cancel(_ id: UUID) async { await endpoint.cancel(id) }
  func close() async { await endpoint.close() }
}
private struct RelayMalformedChannel: M4WatchRegistrationChannel {
  let mode: Int
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    guard case let .authorize(id, attempt, action) = request else { throw M4WatchRegistrationRelayError.invalidMessage }
    return .authorized(mode == 0 ? UUID() : id, mode == 1 ? "other-request" : attempt.requestID, mode == 2 ? String(repeating: "0", count: 64) : attempt.requestDigest, mode == 3 ? .recover : action, mode == 4 ? Data(repeating: 0, count: 65537) : Data("reply".utf8))
  }
  func cancel(_ id: UUID) async {}
  func close() async {}
}

extension M4WatchRegistrationRelayTests {
  func testRelayCloseJoinsOwnedExchangeAndRejectsLateReplyAndNewWork() async throws {
    let channel = RelayHeldChannel(), relay = M4WatchRegistrationRelay(channel: channel)
    let pending = Task { try await relay.registrationContext() }
    await waitRelay { await channel.started }
    async let first: Void = relay.close()
    async let second: Void = relay.close()
    _ = await (first, second)
    do { _ = try await pending.value; XCTFail("late pre-close reply") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .closed) }
    do { _ = try await relay.registrationContext(); XCTFail("closed relay restarted") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .closed) }
    let closes = await channel.closeCount, cancels = await channel.cancelled
    XCTAssertEqual(closes, 1); XCTAssertEqual(cancels.count, 1)
  }
  func testCallerCancellationCancelsOnlyItsCorrelationAndSettlesWaiter() async throws {
    let channel = RelayHeldChannel(), relay = M4WatchRegistrationRelay(channel: channel)
    let pending = Task { try await relay.registrationContext() }
    await waitRelay { await channel.started }; pending.cancel()
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while await channel.cancelled.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    let cancelled = await channel.cancelled
    XCTAssertEqual(cancelled.count, 1)
    await channel.release() // Bound the old implementation's waiter even when it ignores cancellation.
    do { _ = try await pending.value; XCTFail("cancelled caller got a result") } catch {}
    await relay.close()
  }
  func testEndpointCloseWaitsForOwnedTaskAndNeverPublishesLateAuthorization() async throws {
    let authorizer = RelayHeldAuthorizer(), endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: authorizer)
    let request = M4WatchRegistrationRequest.authorize(UUID(), try relayAttempt(), .submit)
    let pending = Task { try await endpoint.handle(request) }
    await waitRelay { await authorizer.started }
    var returned = false
    let closing = Task { await endpoint.close(); returned = true }
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(returned, "close must join the owned operation")
    await authorizer.release(); await closing.value
    do { _ = try await pending.value; XCTFail("late private reply") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .closed) }
    do { _ = try await endpoint.handle(.context(UUID())); XCTFail("closed endpoint restarted") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .closed) }
    let calls = await authorizer.calls; XCTAssertEqual(calls, 1)
  }
  func testEndpointRejectsSimultaneousSameCorrelationWithoutSecondCall() async throws {
    let authorizer = RelayHeldAuthorizer(), endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: authorizer)
    let request = M4WatchRegistrationRequest.authorize(UUID(), try relayAttempt(), .recover)
    let pending = Task { try await endpoint.handle(request) }; await waitRelay { await authorizer.started }
    // A second call must fail without entering the held authorizer.
    let second = Task { try await endpoint.handle(request) }
    for _ in 0..<100 { await Task.yield() }
    let calls = await authorizer.calls; XCTAssertEqual(calls, 1)
    await authorizer.release()
    _ = try await pending.value
    do { _ = try await second.value; XCTFail("duplicate correlation") }
    catch { XCTAssertEqual(error as? M4WatchRegistrationRelayError, .invalidMessage) }
    await endpoint.close()
  }
  private func waitRelay(_ condition: @escaping @Sendable () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    let ready = await condition(); XCTAssertTrue(ready)
  }
}
private actor RelayHeldChannel: M4WatchRegistrationChannel {
  var started = false, closeCount = 0
  var cancelled: [UUID] = []
  private var continuations: [UUID: CheckedContinuation<M4WatchRegistrationResponse, any Error>] = [:]
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    started = true
    if closeCount > 0 { return .context(request.correlationID, try relayContext()) }
    return try await withCheckedThrowingContinuation { continuations[request.correlationID] = $0 }
  }
  func cancel(_ id: UUID) async {
    cancelled.append(id); continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
  func release() {
    let saved = continuations; continuations.removeAll()
    for (id, continuation) in saved { continuation.resume(returning: .context(id, try! relayContext())) }
  }
  func close() { closeCount += 1; release() }
}
private actor RelayHeldAuthorizer: WatchRegistrationAuthorizing {
  var started = false, calls = 0, released = false
  private var continuations: [CheckedContinuation<Data, Never>] = []
  func registrationContext() throws -> WatchRegistrationContextV4 { calls += 1; return try relayContext() }
  func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async -> Data {
    calls += 1; started = true
    if released { return Data("late-private-reply".utf8) }
    return await withCheckedContinuation { continuations.append($0) }
  }
  func release() { released = true; let saved = continuations; continuations.removeAll(); saved.forEach { $0.resume(returning: Data("late-private-reply".utf8)) } }
}

extension M4WatchRegistrationRelayTests {
  func testEndpointCancellationJoinsAndDiscardsUncooperativeLateResult() async throws {
    let authorizer = RelayHeldAuthorizer(), endpoint = M4PhoneWatchRegistrationEndpoint(authorizer: authorizer)
    let id = UUID(), request = M4WatchRegistrationRequest.authorize(id, try relayAttempt(), .recover)
    let pending = Task { try await endpoint.handle(request) }
    await waitRelay { await authorizer.started }
    var returned = false
    let cancelling = Task { await endpoint.cancel(id); returned = true }
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(returned)
    await authorizer.release(); await cancelling.value
    do { _ = try await pending.value; XCTFail("cancelled operation published a private reply") }
    catch { XCTAssertTrue(error is CancellationError) }
    await endpoint.close()
  }
}

extension M4WatchRegistrationRelayTests {
  func testRealHTTPRegistrationPreservesBodyAndPhoneCredentialWhileWatchInstallsItsOwn() async throws {
    let fixture = try RelayNodeFixture(); defer { fixture.close() }
    let phone = try await phoneHarness(fixture), channel = RelayHTTPChannel(endpoint: phone.endpoint)
    let relay = M4WatchRegistrationRelay(channel: channel), watch = try await watchHarness(fixture, relay: relay)
    let before = try await phone.vault.credential()
    let result = try await watch.service.register(requestID: "relay-real", challengeRequestID: "relay-real-challenge")
    XCTAssertEqual(result.binding.role, .watch); XCTAssertEqual(result.binding.deviceID, "relay-client-watch")
    let credential = try await watch.vault.credential(), after = try await phone.vault.credential()
    XCTAssertTrue(before == after); XCTAssertEqual(credential.deviceID, "relay-client-watch")
    let originalValue = try await watch.repo.watchRegistrationAttemptV4(requestID: "relay-real")
    let original = try XCTUnwrap(originalValue)
    let phoneAttempt = try await phone.repo.watchRegistrationAttemptV4(requestID: "relay-real")
    XCTAssertEqual(original.canonicalRequest, phoneAttempt?.canonicalRequest)
    let recovered = try await watch.service.recover(requestID: original.requestID)
    XCTAssertEqual(recovered.receipt.raw, result.receipt.raw)
    let sent = await channel.attempts
    XCTAssertEqual(sent.map { $0.0.canonicalRequest }, [original.canonicalRequest, original.canonicalRequest])
    XCTAssertEqual(sent.map { $0.1 }, [.submit, .recover])
    let proofs = await phone.http.proofs
    XCTAssertGreaterThanOrEqual(proofs.count, 2); XCTAssertEqual(Set(proofs).count, proofs.count, "each HTTP call needs a fresh Phone PoP")
    await relay.close(); try await watch.repo.close(); try await phone.repo.close()
    for root in [phone.root, watch.root] {
      for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [] {
        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
          XCTAssertNil(try Data(contentsOf: file).range(of: Data(credential.token.utf8)), "Watch credential must not enter business files")
        }
      }
    }
  }
  func testLostCommittedReplyReopensOnlyOriginalAttemptWithNewRelay() async throws {
    let fixture = try RelayNodeFixture(); defer { fixture.close() }
    let phone = try await phoneHarness(fixture), channel = RelayHTTPChannel(endpoint: phone.endpoint, loseAfter: true)
    let relay = M4WatchRegistrationRelay(channel: channel), watch = try await watchHarness(fixture, relay: relay)
    do { _ = try await watch.service.register(requestID: "relay-lost", challengeRequestID: "relay-lost-challenge"); XCTFail() } catch {}
    let pending = try await watch.repo.pendingWatchRegistrationAttemptsV4(); XCTAssertEqual(pending.map(\.requestID), ["relay-lost"])
    do { _ = try await watch.service.register(requestID: "relay-new-forbidden", challengeRequestID: "relay-new-challenge"); XCTFail() } catch {}
    await relay.close(); try await watch.repo.close(); try await phone.repo.close()
    let nextPhone = try await phoneHarness(fixture, root: phone.root), nextRelay = M4WatchRegistrationRelay(channel: RelayHTTPChannel(endpoint: nextPhone.endpoint))
    let nextWatch = try await watchHarness(fixture, relay: nextRelay, root: watch.root, signer: watch.signer, vault: watch.vault)
    let recovered = try await nextWatch.service.recover(requestID: "relay-lost")
    XCTAssertEqual(recovered.binding.deviceID, "relay-client-watch")
    let original = try await nextWatch.repo.watchRegistrationAttemptV4(requestID: "relay-lost")
    XCTAssertEqual(original?.canonicalRequest, pending.first?.canonicalRequest)
    let rows = try fixture.command(["op":"inspect", "sql":"SELECT count(*) AS n FROM sessions WHERE device_id='relay-client-watch'"])["rows"] as? [[String:Any]]
    XCTAssertEqual(rows?.first?["n"] as? Int, 1)
    await nextRelay.close(); try await nextWatch.repo.close(); try await nextPhone.repo.close()
  }
  func test404401AndTimeoutCannotCloseOriginalPendingAttempt() async throws {
    for mode in [404, 401, 0] {
      let fixture = try RelayNodeFixture(); defer { fixture.close() }
      let phone = try await phoneHarness(fixture, failure: mode), relay = M4WatchRegistrationRelay(channel: RelayHTTPChannel(endpoint: phone.endpoint))
      let watch = try await watchHarness(fixture, relay: relay)
      do { _ = try await watch.service.register(requestID: "relay-unknown", challengeRequestID: "relay-unknown-challenge"); XCTFail() } catch { XCTAssertFalse(error is WatchRegistrationError) }
      let before = try await watch.repo.pendingWatchRegistrationAttemptsV4()
      do { _ = try await watch.service.recover(requestID: "relay-unknown"); XCTFail() } catch { XCTAssertFalse(error is WatchRegistrationError) }
      let after = try await watch.repo.pendingWatchRegistrationAttemptsV4()
      XCTAssertEqual(after.map(\.canonicalRequest), before.map(\.canonicalRequest)); XCTAssertEqual(after.map(\.requestID), ["relay-unknown"])
      let receipt = try await watch.repo.watchRegistrationReceiptV4(requestID: "relay-unknown"); XCTAssertNil(receipt)
      do { _ = try await watch.vault.credential(); XCTFail() } catch {}
      await relay.close(); try await watch.repo.close(); try await phone.repo.close()
    }
  }
  func testExpiredUnsubmittedAttemptClosesOnlyWithPinnedOriginalRecoveryProof() async throws {
    let fixture = try RelayNodeFixture(); defer { fixture.close() }
    let phone = try await phoneHarness(fixture), channel = RelayHTTPChannel(endpoint: phone.endpoint, loseBefore: true)
    let relay = M4WatchRegistrationRelay(channel: channel), watch = try await watchHarness(fixture, relay: relay)
    do { _ = try await watch.service.register(requestID: "relay-expired", challengeRequestID: "relay-expired-challenge"); XCTFail() } catch {}
    let pending = try await watch.repo.pendingWatchRegistrationAttemptsV4(); XCTAssertEqual(pending.count, 1)
    fixture.clock.set(fixture.metadata.now + 301); _ = try fixture.command(["op":"clock", "now":fixture.metadata.now + 301])
    do { _ = try await watch.service.recover(requestID: "relay-expired"); XCTFail() }
    catch { XCTAssertEqual(error as? WatchRegistrationError, .knownAbandoned) }
    let after = try await watch.repo.pendingWatchRegistrationAttemptsV4(), receipt = try await watch.repo.watchRegistrationReceiptV4(requestID: "relay-expired")
    XCTAssertTrue(after.isEmpty); XCTAssertNotNil(receipt)
    let raw = try await relay.authorizeRegistration(XCTUnwrap(pending.first), action: .submit)
    let object = try JSONSerialization.jsonObject(with: raw) as? [String:Any]; XCTAssertEqual(object?["status"] as? String, "knownAbandoned")
    let rows = try fixture.command(["op":"inspect", "sql":"SELECT count(*) AS n FROM sessions WHERE device_id='relay-client-watch'"])["rows"] as? [[String:Any]]
    XCTAssertEqual(rows?.first?["n"] as? Int, 0)
    await relay.close(); try await watch.repo.close(); try await phone.repo.close()
  }
  private struct PhoneHarness { let root: URL; let repo: SQLiteSessionRepository; let vault: MemoryDeviceCredentialVault; let endpoint: M4PhoneWatchRegistrationEndpoint; let http: RelayRecordingHTTP }
  private func phoneHarness(_ f: RelayNodeFixture, root: URL? = nil, failure: Int? = nil) async throws -> PhoneHarness {
    let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-phone-" + UUID().uuidString)
    let signer = try DevelopmentDeviceSigner(namespace: "relay-phone", rawRepresentation: AuthorityWire.decodeBase64URL(f.metadata.privateKey, count: 32)), vault = MemoryDeviceCredentialVault(f.metadata.credential)
    let http = RelayRecordingHTTP(try URLSessionAuthorityRelay(baseURL: URL(string:f.metadata.baseURL)!, environment: .development), failure: failure)
    let client = AuthorityClient(relay: http, vault: vault, signer: signer, trust: try f.trust(), now: { f.clock.date })
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "relay-phone", authorityTrust: client.trust)
    let c = f.metadata.credential
    try await repo.bindAccountV4(AccountBindingV4(accountID: c.accountID, cloudSpaceID: "fixture-cloud", deviceID: c.deviceID, activationEpoch: c.activationEpoch, role: .phone, environment: .development))
    let session = MatchSession(store: repo, deviceIdentity: RelayDeviceID(value: c.deviceID), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "relay-phone"))
    let service = PhoneWatchRegistrationService(client: client, repository: repo, coordinator: session)
    try await service.admitCurrentIdentity(accountID: c.accountID)
    return PhoneHarness(root: root, repo: repo, vault: vault, endpoint: M4PhoneWatchRegistrationEndpoint(authorizer: service), http: http)
  }
  private struct WatchHarness { let root: URL; let repo: SQLiteSessionRepository; let signer: DevelopmentDeviceSigner; let vault: MemoryDeviceCredentialVault; let session: MatchSession; let service: WatchRegistrationService }
  private func watchHarness(_ f: RelayNodeFixture, relay: M4WatchRegistrationRelay, root: URL? = nil, signer: DevelopmentDeviceSigner? = nil, vault: MemoryDeviceCredentialVault? = nil) async throws -> WatchHarness {
    let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-watch-" + UUID().uuidString), signer = try signer ?? DevelopmentDeviceSigner(namespace: "relay-watch"), vault = vault ?? MemoryDeviceCredentialVault()
    let client = AuthorityClient(relay: try URLSessionAuthorityRelay(baseURL: URL(string:f.metadata.baseURL)!, environment: .development), vault: vault, signer: signer, trust: try f.trust(), now: { f.clock.date })
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "relay-watch", authorityTrust: client.trust)
    let session = MatchSession(store: repo, deviceIdentity: RelayDeviceID(value: "relay-client-watch"), clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "relay-watch"))
    let service = WatchRegistrationService(client: client, repository: repo, coordinator: session, deviceID: "relay-client-watch", cloudSpaceID: "fixture-cloud", authorizer: relay)
    try await service.admitCurrentIdentity(context: relay.registrationContext())
    return WatchHarness(root: root, repo: repo, signer: signer, vault: vault, session: session, service: service)
  }
}
private struct RelayDeviceID: DeviceIdentityProvider { let value: String; func localDeviceID() async throws -> String { value } }
private final class RelayClock: @unchecked Sendable {
  private let lock = NSLock(); private var value: Int64
  init(_ value: Int64) { self.value = value }
  var date: Date { lock.withLock { Date(timeIntervalSince1970: Double(value)) } }
  func set(_ value: Int64) { lock.withLock { self.value = value } }
}
private final class RelayNodeFixture: @unchecked Sendable {
  struct Metadata: Decodable { let baseURL, publicKey, keyID, privateKey: String; let credential: DeviceCredential; let now: Int64 }
  let metadata: Metadata, clock: RelayClock
  private let process = Process(), input = Pipe(), output = Pipe(), terminated = DispatchSemaphore(value: 0)
  init() throws {
    var root = URL(fileURLWithPath: #filePath); for _ in 0..<7 { root.deleteLastPathComponent() }
    let script = root.appendingPathComponent("native/Modules/AccountKit/Tests/AccountKitTests/Support/authority-fixture.mjs")
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", script.path, root.path]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
    let done = terminated; process.terminationHandler = { _ in done.signal() }
    try process.run(); metadata = try JSONDecoder().decode(Metadata.self, from: Self.line(output.fileHandleForReading)); clock = RelayClock(metadata.now)
  }
  private static func line(_ handle: FileHandle) throws -> Data {
    var data = Data()
    while let next = try handle.read(upToCount: 1), !next.isEmpty {
      if next[0] == 10 { return data }; data.append(next)
      guard data.count <= 65536 else { throw AuthorityError.invalidWire }
    }; throw AuthorityError.unavailable
  }
  func command(_ value: [String:Any]) throws -> [String:Any] {
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Self.line(output.fileHandleForReading)) as? [String:Any])
  }
  func trust() throws -> AuthorityTrustConfiguration { try AuthorityTrustConfiguration(environment: .development, publicKeys: [metadata.keyID:metadata.publicKey]) }
  func close() {
    guard process.isRunning else { return }
    _ = try? command(["op":"close"])
    if terminated.wait(timeout: .now()+3) == .timedOut, process.isRunning { process.terminate(); XCTFail("owned fixture did not close") }
  }
  deinit { if process.isRunning { process.terminate() } }
}
private actor RelayHTTPChannel: M4WatchRegistrationChannel {
  let endpoint: M4PhoneWatchRegistrationEndpoint
  private var loseBefore: Bool, loseAfter: Bool
  var attempts: [(WatchRegistrationAttemptV4, WatchRegistrationAction)] = []
  init(endpoint: M4PhoneWatchRegistrationEndpoint, loseBefore: Bool = false, loseAfter: Bool = false) { self.endpoint = endpoint; self.loseBefore = loseBefore; self.loseAfter = loseAfter }
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    if case let .authorize(_, attempt, action) = request {
      attempts.append((attempt, action))
      if loseBefore { loseBefore = false; throw URLError(.networkConnectionLost) }
    }
    let result = try await endpoint.handle(request)
    if case .authorize = request, loseAfter { loseAfter = false; throw URLError(.networkConnectionLost) }
    return result
  }
  func cancel(_ id: UUID) async { await endpoint.cancel(id) }
  func close() async { await endpoint.close() }
}
private actor RelayRecordingHTTP: AuthorityHTTPRelay {
  let upstream: any AuthorityHTTPRelay, failure: Int?
  var proofs: [String] = []
  init(_ upstream: any AuthorityHTTPRelay, failure: Int?) { self.upstream = upstream; self.failure = failure }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    if let proof = request.deviceProof { proofs.append(proof) }
    if let failure, request.path.hasPrefix("/v1/devices/watches") || request.path.hasPrefix("/v1/requests/") {
      if failure == 0 { throw URLError(.timedOut) }
      return AuthorityHTTPResponse(status: failure, body: try JSONSerialization.data(withJSONObject: ["code":failure == 404 ? "notFound":"unauthorized", "requestID":"relay-unknown", "retryable":false]))
    }
    return try await upstream.send(request)
  }
}

extension M4WatchRegistrationRelayTests {
  func testRealHTTPLateWatchCredentialCannotCrossPersistedIdentityFence() async throws {
    let fixture = try RelayNodeFixture(); defer { fixture.close() }
    let phone = try await phoneHarness(fixture), channel = RelayLateHTTPChannel(endpoint: phone.endpoint)
    let relay = M4WatchRegistrationRelay(channel: channel), watch = try await watchHarness(fixture, relay: relay)
    let before = try await phone.vault.credential()
    let pending = Task { try await watch.service.register(requestID: "relay-late-identity", challengeRequestID: "relay-late-challenge") }
    await waitRelay { await channel.entered }
    try await watch.session.suspendAccount()
    let generation = try await watch.repo.identityGenerationV4(); try await watch.vault.advanceIdentityFence(to: generation)
    await channel.release()
    do { _ = try await pending.value; XCTFail("late old identity credential") } catch {}
    do { _ = try await watch.vault.credential(); XCTFail("Watch vault remains fenced") } catch {}
    let after = try await phone.vault.credential(), binding = try await watch.repo.accountBindingV4()
    XCTAssertTrue(before == after); XCTAssertTrue(binding == nil || binding?.suspended == true)
    await relay.close(); try await watch.repo.close(); try await phone.repo.close()
  }
}
private actor RelayLateHTTPChannel: M4WatchRegistrationChannel {
  let endpoint: M4PhoneWatchRegistrationEndpoint
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  init(endpoint: M4PhoneWatchRegistrationEndpoint) { self.endpoint = endpoint }
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    let response = try await endpoint.handle(request)
    if case .authorize = request { entered = true; await withCheckedContinuation { continuation = $0 } }
    return response
  }
  func release() { continuation?.resume(); continuation = nil }
  func cancel(_ id: UUID) async { release(); await endpoint.cancel(id) }
  func close() async { release(); await endpoint.close() }
}
