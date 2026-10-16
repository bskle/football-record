import Foundation
import MatchCore
import MatchSession
import XCTest

@testable import MatchStore

actor GatedPermits: StartPermitProvider {
  var calls: [StartIntent] = []
  var continuation: CheckedContinuation<TrustedStartPermit, Error>?
  var waiter: CheckedContinuation<Void, Never>?
  func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    calls.append(intent)
    waiter?.resume()
    waiter = nil
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func waitForCall() async {
    if !calls.isEmpty { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func complete(fail: Bool = false) {
    if fail {
      continuation?.resume(throwing: SessionError.permitUnavailable)
    } else {
      continuation?.resume(returning: DevelopmentStartFixture.permit(for: calls[0]))
    }
    continuation = nil
  }
}
final class SessionRecoveryTests: XCTestCase, @unchecked Sendable {
  func testGlobalAdmissionBlocksDifferentMatchAndSameRequestReentryBeforeProviderReturns()
    async throws
  {
    let permits = GatedPermits()
    let h = try Harness(permits: permits)
    let first = try await h.session.prepareStart(starter: true)
    let second = try await h.session.prepareStart(starter: false)
    let task = Task { try await h.session.execute(first) }
    await permits.waitForCall()
    do {
      _ = try await h.session.execute(first)
      XCTFail("same request reentry")
    } catch let e as SessionError { XCTAssertEqual(e, .requestInFlight) }
    do {
      _ = try await h.session.execute(second)
      XCTFail("second match must not persist intent")
    } catch let e as SessionError { XCTAssertEqual(e, .multipleCandidates) }
    let matches = try await h.repo.matchIDs()
    XCTAssertEqual(matches, [first.matchID])
    let calls = await permits.calls
    XCTAssertEqual(calls.count, 1)
    await permits.complete(fail: true)
    do {
      _ = try await task.value
      XCTFail("provider unavailable")
    } catch let e as SessionError { XCTAssertEqual(e, .permitUnavailable) }
    guard case .intentAwaitingPermit(let original) = try await h.newSession().recover() else {
      return XCTFail("durable intent")
    }
    XCTAssertEqual(original, first.startIntent)
    let descriptor = try await h.repo.snapshotV2(matchID: first.matchID).business.descriptor
    let resumed = try SessionRequest.start(intent: original, starter: descriptor.starter)
    XCTAssertEqual(resumed, first)
    _ = try await h.newSession().execute(resumed)
  }
  func testNamespaceChecksAndProductionRejectsDevelopmentPermit() async throws {
    let h = try Harness()
    for environment in [
      SessionEnvironment.production, .development(databaseNamespace: "other"),
      .development(databaseNamespace: "production"),
    ] {
      do {
        _ = try await h.newSession(environment: environment).prepareStart(starter: true)
        XCTFail("wrong actual namespace")
      } catch let e as SessionError { XCTAssertEqual(e, .developmentIsolationRequired) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let production = try SQLiteSessionRepository(
      rootDirectory: root, databaseNamespace: "production")
    let development = try SQLiteSessionRepository(
      rootDirectory: root, databaseNamespace: "development-test")
    let p = await production.databaseURL
    let d = await development.databaseURL
    XCTAssertNotEqual(p, d)
    let session = MatchSession(
      store: production, deviceIdentity: Identity(value: "watch"), clock: h.clock, ids: h.ids,
      permits: DevelopmentStartPermitProvider(), workout: h.gateway, environment: .production)
    let request = try await session.prepareStart(starter: true)
    do {
      _ = try await session.execute(request)
      XCTFail("fixture in production")
    } catch let e as SessionError { XCTAssertEqual(e, .developmentIsolationRequired) }
    let saved = try await production.snapshotV2(matchID: request.matchID)
    XCTAssertTrue(saved.business.events.isEmpty)
    let devIDs = try await development.matchIDs()
    XCTAssertTrue(devIDs.isEmpty)
    try await production.close()
    try await development.close()
  }
  func testPersistentIdentityReopenMissingAndCorruptDoNotAdoptOldMatches() async throws {
    let h = try Harness()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("identity")
    let first = try await PersistentDeviceIdentityProvider(url: path, repository: h.repo)
      .localDeviceID()
    let second = try await PersistentDeviceIdentityProvider(url: path, repository: h.repo)
      .localDeviceID()
    XCTAssertEqual(first, second)
    let request = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(request)
    let missing = path.deletingLastPathComponent().appendingPathComponent("missing")
    do {
      _ = try await PersistentDeviceIdentityProvider(url: missing, repository: h.repo)
        .localDeviceID()
      XCTFail("must not replace lost identity")
    } catch let e as SessionError { XCTAssertEqual(e, .identityUnavailable) }
    try Data("damaged".utf8).write(to: path)
    do {
      _ = try await PersistentDeviceIdentityProvider(url: path, repository: h.repo).localDeviceID()
      XCTFail("corrupt identity")
    } catch let e as SessionError { XCTAssertEqual(e, .identityUnavailable) }
  }
  func testWrongDeviceReadOnlyAndMultipleCandidatesAreExplicit() async throws {
    let h = try Harness()
    let start = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(start)
    let foreign = h.newSession(device: "phone")
    let read = try await foreign.snapshot(matchID: start.matchID)
    XCTAssertEqual(read.store.business.descriptor.recordingDeviceID, "watch")
    do {
      _ = try await foreign.recover()
      XCTFail("wrong owner")
    } catch let e as SessionError { XCTAssertEqual(e, .wrongRecordingDevice) }
    let intent = StartIntent(
      id: "other", matchID: "other-match", recordingDeviceID: "watch", requestedAt: h.clock.now())
    let descriptor = MatchDescriptor(startIntent: intent, starter: true)
    _ = try await h.repo.commitV2(
      StoreCommitV2(
        commandID: "other/intent", expectedGeneration: 0, descriptor: descriptor, events: [],
        captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [],
        businessOutbox: []))
    do {
      _ = try await h.newSession().recover()
      XCTFail("no recent-wins")
    } catch let e as SessionError { XCTAssertEqual(e, .multipleCandidates) }
  }
  func testBlockingDiagnosticsPreventRecoveryAndFurtherCommands() async throws {
    let h = try Harness()
    let r = try await h.session.prepareStart(starter: true)
    _ = try await h.session.execute(r)
    try await h.waitCaptureSettled(r.matchID)
    let raw = try SQLite(url: h.url, fault: nil)
    try raw.execute(
      "INSERT INTO diagnostics VALUES (?,?,?,?,?)",
      [
        .text(r.matchID), .text("test-corruption"), .text("damaged"), .blob(Data([1])),
        .text("blocking"),
      ])
    try raw.close()
    do {
      _ = try await h.newSession().recover()
      XCTFail("blocked")
    } catch let e as SessionError { XCTAssertEqual(e, .blockedDiagnostics) }
    do {
      _ = try await h.session.prepare(.end, matchID: r.matchID)
      XCTFail("read-only until repaired")
    } catch let e as SessionError { XCTAssertEqual(e, .blockedDiagnostics) }
  }
  func testExistingPendingIntentCannotBypassNewlyDiscoveredMultipleCandidates() async throws {
    let h = try Harness(permits: UnavailableStartPermitProvider())
    let original = try await h.session.prepareStart(starter: true)
    do { _ = try await h.session.execute(original) } catch {}
    let intent = StartIntent(
      id: "other", matchID: "other-match", recordingDeviceID: "watch", requestedAt: h.clock.now())
    _ = try await h.repo.commitV2(
      StoreCommitV2(
        commandID: "other/intent", expectedGeneration: 0,
        descriptor: MatchDescriptor(startIntent: intent, starter: false), events: [],
        captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [],
        businessOutbox: []))
    do {
      _ = try await h.newSession().execute(original)
      XCTFail("existing intent also validates unique admission")
    } catch let e as SessionError { XCTAssertEqual(e, .multipleCandidates) }
  }

}
