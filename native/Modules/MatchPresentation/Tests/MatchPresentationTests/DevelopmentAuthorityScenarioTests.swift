#if DEBUG
import Foundation
import Observation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import AccountKit
import CloudSync
@testable import MatchPresentation

@MainActor final class DevelopmentAuthorityScenarioTests: XCTestCase {
  func testRealHTTPCloudOnlyCannotCompleteAndNormalReleaseThenCompletes() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    host.serve()
    await context.account.perform(.signIn)
    XCTAssertTrue(context.account.canEnterRecording, context.account.issue ?? context.account.title)
    await context.recording.load(); await context.recording.start(starter: true)
    let id = try XCTUnwrap(context.recording.snapshot?.replay.matchID)
    try await settled(context.repository, id)
    await context.recording.perform(.end); try await settled(context.repository, id)
    await context.lifecycle.perform(.saveCloudOnly(id), matchID: id)
    let cloudOnly = try await context.repository.snapshotV2(matchID: id)
    XCTAssertEqual(try cloudOnly.business.replay(now: Date()).state, .endedPendingSync)
    XCTAssertEqual(context.lifecycle.cloudSaved, true)
    await context.recording.start(starter: false)
    XCTAssertEqual(context.recording.snapshot?.replay.matchID, id, "Cloud proof alone cannot open a new match")
    let feedback = context.recording.feedbackCount
    await context.lifecycle.perform(.synchronize(id), matchID: id)
    let complete = try await context.repository.snapshotV2(matchID: id)
    XCTAssertEqual(try complete.business.replay(now: Date()).state, .completed, context.lifecycle.issue ?? "")
    XCTAssertEqual(context.lifecycle.backendStatus, .releasedNormal)
    XCTAssertEqual(context.recording.feedbackCount, feedback)
    XCTAssertGreaterThan(host.cloudRecordCount, 0)
    await context.recording.start(starter: false)
    XCTAssertNotEqual(context.recording.snapshot?.replay.matchID, id)
    XCTAssertEqual(context.recording.snapshot?.replay.state, .running)
    XCTAssertEqual(context.recording.feedbackCount, feedback + 1)
    await context.shutdown()
  }
  func testSignedOutStatisticsFailureAndAccountFailureRemainIndependent() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    XCTAssertNil(context.recording.snapshot)
    await context.lifecycle.perform(.analytics(true))
    XCTAssertEqual(context.lifecycle.analyticsEnabled, false)
    let dataIssue = try XCTUnwrap(context.lifecycle.issue)
    XCTAssertNil(context.account.issue)
    await context.account.perform(.recover)
    let accountIssue = try XCTUnwrap(context.account.issue)
    XCTAssertEqual(context.lifecycle.issue, dataIssue)
    await context.lifecycle.refresh()
    XCTAssertNil(context.lifecycle.issue); XCTAssertEqual(context.account.issue, accountIssue)
    await context.lifecycle.perform(.analytics(true)); await context.account.refresh()
    XCTAssertNotNil(context.lifecycle.issue); XCTAssertNil(context.account.issue)
    XCTAssertNil(context.recording.snapshot)
    await context.shutdown()
  }
  func testExistingEmptyDatabaseNeverRegeneratesMissingOriginalIdentityKeyOrPin() async throws {
    for file in ["development.key", "device.identity", "authority.fixture"] {
      let host = try DevelopmentFixtureHost(); defer { host.close() }
      let first = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
      let matches = try await first.repository.matchIDs(); XCTAssertTrue(matches.isEmpty)
      await first.shutdown()
      let original = host.appRoot.appendingPathComponent(host.configuration.namespace).appendingPathComponent(file)
      try FileManager.default.removeItem(at: original)
      do {
        let invalid = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
        await invalid.shutdown(); XCTFail("Existing database must retain its original identity/key/pin")
      } catch { XCTAssertEqual(error as? SessionError, .identityUnavailable) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "No missing original file may be regenerated")
    }
  }
  func testExpiredChallengeRequiresExplicitFreshAuthentication() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    _ = try host.command(["op":"clock", "now":Int(Date().timeIntervalSince1970)-600])
    await context.account.perform(.signIn)
    XCTAssertFalse(context.account.canEnterRecording)
    XCTAssertEqual(context.account.issue, "原验证已过期，请明确重新验证。")
    let pending = try await context.repository.pendingAuthAttemptsV4(); XCTAssertTrue(pending.isEmpty)
    let ids = host.appRoot.appendingPathComponent(host.configuration.namespace).appendingPathComponent("development-requests.json")
    let original = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: ids))
    _ = try host.command(["op":"clock", "now":Int(Date().timeIntervalSince1970)])
    await context.account.perform(.renew)
    XCTAssertTrue(context.account.canEnterRecording, context.account.issue ?? "")
    let renewed = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: ids))
    XCTAssertNotEqual(original["auth"], renewed["auth"]); XCTAssertNotEqual(original["challenge"], renewed["challenge"])
    let attempt = try await context.repository.authAttemptV4(requestID: XCTUnwrap(renewed["auth"]))
    XCTAssertNotNil(attempt)
    await context.shutdown()
  }
  func testInitiallyUnverifiedAccountGatePublishesRealHTTPAdmission() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    let changed = expectation(description: "Root account gate must observe admission")
    XCTAssertFalse(context.account.canEnterRecording)
    withObservationTracking { _ = context.account.canEnterRecording } onChange: { changed.fulfill() }
    await context.account.perform(.signIn)
    XCTAssertTrue(context.account.canEnterRecording)
    await fulfillment(of: [changed], timeout: 1)
    await context.shutdown()
  }
  func testAbnormalReleaseStopsRecordingWithoutCloudCompletionAndAllowsFreshStart() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await context.account.perform(.signIn); await context.recording.start(starter: true)
    let id = try XCTUnwrap(context.recording.snapshot?.replay.matchID)
    try await settled(context.repository, id)
    XCTAssertFalse(context.recording.canStartNext)
    await context.recording.refreshAuthority()
    XCTAssertEqual(context.recording.authorityStatus, .held)
    let feedback = context.recording.feedbackCount
    await context.lifecycle.perform(.abnormal(id), matchID: id)
    XCTAssertEqual(context.recording.authorityStatus, .releasedAbnormal)
    XCTAssertFalse(context.recording.canRecord); XCTAssertTrue(context.recording.canStartNext)
    XCTAssertNotEqual(context.recording.snapshot?.replay.state, .completed)
    XCTAssertEqual(context.recording.feedbackCount, feedback)
    let snapshot = try XCTUnwrap(context.recording.snapshot)
    let projected = MatchProjection(snapshot: snapshot, now: Date(), authorityStatus: context.recording.authorityStatus)
    XCTAssertTrue(projected.terminal); XCTAssertTrue(projected.status.contains("不完整"))
    await context.recording.start(starter: false)
    XCTAssertNotEqual(context.recording.snapshot?.replay.matchID, id)
    XCTAssertEqual(context.recording.snapshot?.replay.state, .running)
    let acquire = try await context.repository.authorityStateV4(matchID: XCTUnwrap(context.recording.snapshot?.replay.matchID), now: Date())
    XCTAssertEqual(acquire.status, .held)
    XCTAssertNotEqual(acquire.acquire?.body.matchID, id)
    await context.shutdown()
  }
  func testLostAuthenticationResponseReopensSameIDsAndMissingKeyFailsClosed() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let first = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    _ = try host.command(["op":"fault", "value":"authenticate"])
    await first.account.perform(.signIn)
    XCTAssertFalse(first.account.canEnterRecording)
    let attempts = try await first.repository.pendingAuthAttemptsV4()
    let original = try XCTUnwrap(attempts.first)
    await first.shutdown()
    _ = try host.command(["op":"fault", "value":NSNull()])
    let reopened = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    XCTAssertFalse(reopened.account.canEnterRecording)
    await reopened.account.perform(.recover)
    XCTAssertTrue(reopened.account.canEnterRecording, reopened.account.issue ?? "")
    let saved = try await reopened.repository.authAttemptV4(requestID: original.requestID)
    XCTAssertEqual(saved, original)
    let localID = reopened.account.binding?.deviceID
    await reopened.shutdown()
    let key = host.appRoot.appendingPathComponent(host.configuration.namespace).appendingPathComponent("development.key")
    try FileManager.default.removeItem(at: key)
    do { _ = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot); XCTFail("Existing data must not get a new key") }
    catch { XCTAssertEqual(error as? SessionError, .identityUnavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
    XCTAssertNotNil(localID)
  }
  func testTypedWatchSubmitRecoveryAndItsOwnSessionUseOriginalIDs() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let phone = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await phone.account.perform(.signIn)
    var config = host.configuration; config.role = "watch"; config.namespace = "m4-ui-host-test-watch"
    host.extraRoots.append(host.watchRoot)
    let watch = try await DevelopmentAuthorityScenario.make(configuration: config, rootDirectory: host.watchRoot)
    await watch.account.perform(.registerWatch)
    XCTAssertTrue(watch.account.canEnterRecording, watch.account.issue ?? "")
    XCTAssertEqual(watch.account.binding?.role, .watch)
    XCTAssertNotEqual(phone.account.binding?.deviceID, watch.account.binding?.deviceID)
    await watch.recording.load(); await watch.recording.start(starter: false)
    XCTAssertNotNil(watch.recording.snapshot?.replay.matchID)
    let ids = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: host.watchRoot.appendingPathComponent(config.namespace + "/development-requests.json")))
    let original = try XCTUnwrap(ids["watch-register"])
    let receipt = try await watch.repository.watchRegistrationReceiptV4(requestID: original)
    XCTAssertNotNil(receipt)
    await watch.shutdown()
    let reopened = try await DevelopmentAuthorityScenario.make(configuration: config, rootDirectory: host.watchRoot)
    await reopened.account.perform(.recover)
    XCTAssertTrue(reopened.account.canEnterRecording, reopened.account.issue ?? "")
    let same = try await reopened.repository.watchRegistrationReceiptV4(requestID: original)
    XCTAssertEqual(same, receipt)
    XCTAssertEqual(host.watchActions, ["submit", "recover"])
    await reopened.shutdown(); await phone.shutdown()
  }
  func testCloudErrorDoesNotBlockLocalCommitOrCreateExtraFeedback() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await context.account.perform(.signIn); await context.recording.load(); await context.recording.start(starter: true)
    let id = try XCTUnwrap(context.recording.snapshot?.replay.matchID); try await settled(context.repository, id)
    let feedback = context.recording.feedbackCount
    host.cloudUnavailable = true
    await context.lifecycle.perform(.saveCloudOnly(id), matchID: id)
    XCTAssertNotNil(context.lifecycle.issue)
    XCTAssertNotEqual(context.lifecycle.cloudSaved, true)
    XCTAssertEqual(context.recording.feedbackCount, feedback)
    XCTAssertTrue(context.recording.canRecord)
    await context.recording.perform(.leaveField)
    XCTAssertEqual(context.recording.feedbackCount, feedback + 1)
    XCTAssertNil(context.recording.issue)
    await context.shutdown()
  }
  func testDeletionReopensFourIndependentPartsAndStatisticsStayOff() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let context = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await context.account.perform(.signIn)
    XCTAssertEqual(context.lifecycle.analyticsEnabled, false)
    await context.lifecycle.perform(.analytics(true))
    let enabled = try await context.repository.analyticsEnabledV4(); XCTAssertTrue(enabled)
    let event = try AnalyticsEventV4(requestID: "optional-stat", metric: .activeDay, appVersion: "test", osFamily: "iOS", osMajor: 27, qualification: "free")
    try await context.repository.enqueueAnalyticsV4(event)
    await context.lifecycle.perform(.analytics(false))
    let pending = try await context.repository.pendingAnalyticsV4(); XCTAssertTrue(pending.isEmpty)
    await context.account.perform(.renew)
    await context.lifecycle.perform(.delete(cloud: .keep, local: .delete, health: .delete, healthConfirmed: true))
    let sagas = try await context.repository.deletionSagasV4()
    let saga = try XCTUnwrap(sagas.first)
    XCTAssertTrue(saga.backendDeleted, context.lifecycle.issue ?? "")
    XCTAssertEqual(saga.cloudProgress, .retained)
    XCTAssertEqual(saga.localDataProgress, .completed)
    XCTAssertEqual(saga.healthProgress, .failed)
    XCTAssertFalse(saga.finished)
    await context.shutdown()
    let reopened = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await reopened.lifecycle.perform(.resumeDeletion(saga.intent.requestID))
    let after = try XCTUnwrap(reopened.lifecycle.deletions.first)
    XCTAssertEqual(after.intent, saga.intent); XCTAssertEqual(after.originalScope, saga.originalScope)
    XCTAssertEqual(after.localDataProgress, .completed); XCTAssertEqual(after.healthProgress, .failed)
    XCTAssertNil(reopened.lifecycle.issue, "The persisted saga itself must resume; Health's finite failure remains in its row")
    XCTAssertEqual(reopened.lifecycle.analyticsEnabled, false)
    await reopened.shutdown()
  }
  func testNormalMigrationTransfersVerifiedCheckpointBeforeNewEpochActivation() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let old = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await old.account.perform(.signIn)
    let newRoot = host.root.appendingPathComponent("new-phone"); host.extraRoots.append(newRoot)
    let new = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: newRoot)
    await new.account.perform(.signIn)
    XCTAssertEqual(new.account.phase, .waitingMigration)
    let device = try XCTUnwrap(new.account.binding?.deviceID), epoch = try XCTUnwrap(new.account.binding?.activationEpoch)
    await old.lifecycle.perform(.prepareMigration(device))
    await old.lifecycle.perform(.checkpoint)
    XCTAssertEqual(old.lifecycle.migration?.state, "oldPhoneDeactivated", old.lifecycle.issue ?? "")
    await new.lifecycle.perform(.importMigration)
    XCTAssertEqual(new.lifecycle.migration?.state, "oldPhoneDeactivated", new.lifecycle.issue ?? "")
    await new.lifecycle.perform(.activateMigration)
    XCTAssertEqual(new.lifecycle.migration?.state, "activated", new.lifecycle.issue ?? "")
    XCTAssertFalse(new.account.canEnterRecording, "Activation requires explicit fresh identity admission")
    await new.shutdown()
    let admitted = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: newRoot)
    await admitted.account.perform(.renew)
    XCTAssertTrue(admitted.account.canEnterRecording, admitted.account.issue ?? "")
    XCTAssertEqual(admitted.account.binding?.role, .phone)
    XCTAssertGreaterThan(admitted.account.binding?.activationEpoch ?? 0, epoch)
    let matches = try await admitted.repository.matchIDs(); XCTAssertTrue(matches.isEmpty, "Account checkpoint must not fabricate a match")
    await admitted.shutdown(); await old.shutdown()
  }
  func testLostMigrationKeepsServerSevenDayBoundaryAndFreshReauthentication() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }; host.serve()
    let old = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: host.appRoot)
    await old.account.perform(.signIn)
    let newRoot = host.root.appendingPathComponent("lost-phone"); host.extraRoots.append(newRoot)
    let new = try await DevelopmentAuthorityScenario.make(configuration: host.configuration, rootDirectory: newRoot)
    await new.account.perform(.signIn); await new.lifecycle.perform(.requestLost)
    let migration = try XCTUnwrap(new.lifecycle.migration)
    XCTAssertEqual(migration.kind, "lost")
    XCTAssertGreaterThan(new.lifecycle.remainingWait(now: Date()) ?? 0, 6*86400)
    await new.account.perform(.renew)
    await new.lifecycle.perform(.forceMigration)
    XCTAssertNotNil(new.lifecycle.issue)
    XCTAssertFalse(new.account.canEnterRecording)
    XCTAssertEqual(new.lifecycle.migration?.eligibleAt, migration.eligibleAt)
    await new.shutdown(); await old.shutdown()
  }
  func testProductionNamespaceAndMissingPrivateFixtureAreRejected() async throws {
    let host = try DevelopmentFixtureHost(); defer { host.close() }
    var config = host.configuration; config.namespace = "production"
    do { _ = try await DevelopmentAuthorityScenario.make(configuration: config, rootDirectory: host.appRoot); XCTFail() } catch {}
    do { _ = try await DevelopmentAuthorityScenario.fromPrivateFile(rootDirectory: host.appRoot); XCTFail() } catch {}
  }
  private func settled(_ repo: SQLiteSessionRepository, _ id: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while ContinuousClock.now < deadline {
      let s = try await repo.snapshotV2(matchID: id)
      if !s.captureOperations.isEmpty && s.captureOperations.allSatisfy({ [.settled,.failed,.cancelled].contains($0.state) }) { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw AuthorityError.unavailable
  }
}

/// Host-only fixture; no Process or test helper is linked into either mobile target.
@MainActor private final class DevelopmentFixtureHost {
  let process = Process(), input = Pipe(), output = Pipe()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var appRoot: URL { root.appendingPathComponent("app") }
  let configuration: DevelopmentAuthorityConfiguration
  var task: Task<Void,Never>?
  var extraRoots: [URL] = []
  var watchRoot: URL { root.appendingPathComponent("watch") }
  var cloudUnavailable = false
  var watchActions: [String] = []
  var cloudRecordCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cloud").path).count) ?? 0 }
  init() throws {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { repo.deleteLastPathComponent() }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", repo.appendingPathComponent("native/Modules/AccountKit/Tests/AccountKitTests/Support/authority-fixture.mjs").path, repo.path]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
    try process.run()
    let meta = try JSONSerialization.jsonObject(with: Self.line(output.fileHandleForReading)) as! [String:Any]
    configuration = DevelopmentAuthorityConfiguration(dataset: "host-test", namespace: "m4-ui-host-test-phone", baseURL: meta["baseURL"] as! String, keyID: meta["keyID"] as! String, publicKey: meta["publicKey"] as! String, cloudSpaceID: "fixture-cloud", subject: "ui-host-" + UUID().uuidString, role: "phone")
    try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: root.appendingPathComponent("cloud"), withIntermediateDirectories: true)
    _ = try command(["op":"clock", "now":Int(Date().timeIntervalSince1970)])
    _ = try command(["op":"revoker"])
  }
  static func line(_ handle: FileHandle) throws -> Data {
    var bytes = Data()
    while let b = try handle.read(upToCount: 1), !b.isEmpty { if b[0] == 10 { return bytes }; bytes.append(b) }
    throw AuthorityError.unavailable
  }
  func command(_ value: [String:Any]) throws -> [String:Any] {
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    return try JSONSerialization.jsonObject(with: Self.line(output.fileHandleForReading)) as! [String:Any]
  }
  func serve() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        for app in [self.appRoot] + self.extraRoots {
        let requestRoot = app.appendingPathComponent("development/mailbox/outgoing")
        let responseRoot = app.appendingPathComponent("development/mailbox/responses")
        for file in (try? FileManager.default.contentsOfDirectory(at: requestRoot, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
          do {
            let requestBytes: Data
            do { requestBytes = try Data(contentsOf: file) }
            catch { let e = error as NSError
              // A successful caller removes its request after consuming the reply.
              // Directory enumeration may still contain that already-consumed file.
              if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { continue }
              throw error
            }
            let request = try JSONSerialization.jsonObject(with: requestBytes) as! [String:Any]
            let id = request["id"] as! String
            guard UUID(uuidString: id) != nil else { continue }
            let response = responseRoot.appendingPathComponent(id + ".json")
            if FileManager.default.fileExists(atPath: response.path) { continue }
            let payload = Data(base64Encoded: request["payload"] as! String)!
            let bytes: Data
            do { let data = try await handle(request["operation"] as! String, payload); bytes = try JSONSerialization.data(withJSONObject: ["payload":data.base64EncodedString()]) }
            catch { bytes = try JSONSerialization.data(withJSONObject: ["issue":"unavailable"]) }
            try FileManager.default.createDirectory(at: responseRoot, withIntermediateDirectories: true)
            try bytes.write(to: response, options: .atomic)
          } catch { let e = error as NSError; print("NATIVE-025 host mailbox failure domain=\(e.domain) code=\(e.code)"); XCTFail("Controlled host mailbox failed without logging auth payload") }
        }
        }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      }
    }
  }
  func handle(_ op: String, _ bytes: Data) async throws -> Data {
    _ = try command(["op":"clock", "now":Int(Date().timeIntervalSince1970)])
    switch op {
    case "apple":
      let r = try JSONSerialization.jsonObject(with: bytes) as! [String:Any]
      let response = try command(["op":"apple", "nonce":r["nonce"]!, "subject":configuration.subject])
      return try JSONSerialization.data(withJSONObject: response)
    case "phone-context", "phone-register", "phone-migration":
      if op == "phone-register", let object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any], let action = object["action"] as? String { watchActions.append(action) }
      let id = UUID().uuidString
      let request = appRoot.appendingPathComponent("development/mailbox/incoming/" + id + ".json")
      let response = appRoot.appendingPathComponent("development/mailbox/incoming-responses/" + id + ".json")
      defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
      let encoded = try JSONSerialization.data(withJSONObject: ["id":id,"operation":op,"dataset":configuration.dataset,"payload":bytes.base64EncodedString()])
      try FileManager.default.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoded.write(to: request, options: .atomic)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while ContinuousClock.now < deadline {
        if let raw = try? Data(contentsOf: response), let reply = try JSONSerialization.jsonObject(with: raw) as? [String:Any], let payload = reply["payload"] as? String, let data = Data(base64Encoded: payload) { return data }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw AuthorityError.unavailable
    case "cloud-save":
      if cloudUnavailable { throw AuthorityError.unavailable }
      let upload = try JSONDecoder().decode(CloudUpload.self, from: bytes)
      let file = root.appendingPathComponent("cloud/" + upload.record.recordID + ".json")
      try bytes.write(to: file, options: .atomic)
      return try Data(contentsOf: file)
    case "cloud-fetch":
      let scope = try JSONDecoder().decode(CloudScope.self, from: bytes)
      let records = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cloud"), includingPropertiesForKeys: nil).map { try JSONDecoder().decode(CloudUpload.self, from: Data(contentsOf: $0)).record }.filter { $0.scope.stableZoneKey == scope.stableZoneKey }
      return try JSONEncoder().encode(records)
    case "cloud-delete":
      let scope = try JSONDecoder().decode(CloudScope.self, from: bytes)
      for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cloud"), includingPropertiesForKeys: nil) {
        let u = try JSONDecoder().decode(CloudUpload.self, from: Data(contentsOf: file))
        if u.scope.stableZoneKey == scope.stableZoneKey { try FileManager.default.removeItem(at: file) }
      }
      return Data()
    default: throw AuthorityError.unavailable
    }
  }
  func close() { task?.cancel(); if process.isRunning { _ = try? command(["op":"close"]); process.waitUntilExit() } }
}
#endif
