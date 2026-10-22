#if DEBUG && os(macOS)
import Foundation
import Darwin
import CryptoKit
import AccountKit
import MatchStore
import MatchPresentation
@testable import AppIntegration

enum M4HTTPFixtureError: Error, Equatable { case configuration, shape, correlation, duplicate, rejected, timeout, closed, processFailure, mailboxChanged }

/// All stdio is transient memory. Neither tokens nor raw protocol lines become
/// diagnostics. Nonblocking readers and every wait belong to this one owner.
@MainActor final class M4HTTPFixtureCLI {
  struct Metadata: Sendable { let baseURL, publicKey, keyID, namespace: String }
  private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
  private var bytes = Data(), stdoutEOF = false, stderrEOF = false, busy = false, stopped = false
  private var used = Set<String>(), abandoned = Set<String>()
  private(set) var requestCount = 0
  struct Report { let pid: Int32; let exited: Bool; let status: Int32; let readersJoined: Bool; let closeAcknowledged: Bool }
  init(root: URL) throws {
    guard let binary = ProcessInfo.processInfo.environment["NATIVE_NODE_BINARY"], binary == "/Users/liam/.hermes/node/bin/node",
          SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: binary))).map({ String(format: "%02x", $0) }).joined() == "2e3f1286a7eb3736346ed1803e458a0ff909e2b2d5bc746144dcb76970e9b99d" else { throw M4HTTPFixtureError.configuration }
    var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while repository.path != "/", !FileManager.default.fileExists(atPath: repository.appendingPathComponent("scripts/native/m4-authority-fixture.mjs").path) { repository.deleteLastPathComponent() }
    guard repository.path != "/" else { throw M4HTTPFixtureError.configuration }
    let temporary = root.appendingPathComponent("node-private")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    process.executableURL = URL(fileURLWithPath: binary); process.arguments = [repository.appendingPathComponent("scripts/native/m4-authority-fixture.mjs").path]
    var environment = ProcessInfo.processInfo.environment; environment["TMPDIR"] = temporary.path
    process.environment = environment; process.currentDirectoryURL = repository
    process.standardInput = input; process.standardOutput = output; process.standardError = errors
    for handle in [output.fileHandleForReading, errors.fileHandleForReading] { guard fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw M4HTTPFixtureError.configuration } }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()
    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
  }
  static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard data.count <= 65_536, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(value.keys) == keys else { throw M4HTTPFixtureError.shape }
    return value
  }
  private func pump(_ handle: FileHandle, stdout: Bool) throws {
    var buffer = [UInt8](repeating: 0, count: 4096), remaining = 65_536
    while remaining > 0 {
      let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        remaining -= count
        if stdout { bytes.append(contentsOf: buffer.prefix(count)); guard bytes.count <= 65_536 else { throw M4HTTPFixtureError.shape } }
        // stderr deliberately discarded, including Node warnings; never raw logs.
      } else if count == 0 { if stdout { stdoutEOF = true } else { stderrEOF = true }; return }
      else if errno == EAGAIN || errno == EWOULDBLOCK { return }
      else if errno != EINTR { throw M4HTTPFixtureError.processFailure }
    }
    throw M4HTTPFixtureError.shape
  }
  private func line(deadline: ContinuousClock.Instant) async throws -> Data {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation(); try pump(output.fileHandleForReading, stdout: true); try pump(errors.fileHandleForReading, stdout: false)
      if let end = bytes.firstIndex(of: 10) { let result = Data(bytes[..<end]); bytes.removeSubrange(...end); return result }
      guard !stdoutEOF else { throw M4HTTPFixtureError.processFailure }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw M4HTTPFixtureError.timeout
  }
  func ready() async throws -> Metadata {
    let value = try Self.object(try await line(deadline: .now.advanced(by: .seconds(8))), keys: ["version", "type", "environment", "namespace", "baseURL", "publicKey", "keyID", "now"])
    guard value["version"] as? Int == 1, value["type"] as? String == "ready", value["environment"] as? String == "development",
          let namespace = value["namespace"] as? String, namespace.hasPrefix("m4-fixture-"), UUID(uuidString: String(namespace.dropFirst(11))) != nil,
          let baseURL = value["baseURL"] as? String, let url = URL(string: baseURL), url.scheme == "http", url.host == "127.0.0.1", let port = url.port, port > 0,
          let key = value["publicKey"] as? String, let id = value["keyID"] as? String, value["now"] as? Int64 != nil else { throw M4HTTPFixtureError.shape }
    _ = try AuthorityTrustConfiguration(environment: .development, publicKeys: [id: key])
    return Metadata(baseURL: baseURL, publicKey: key, keyID: id, namespace: namespace)
  }
  func command(_ operation: String, fields: [String: String] = [:], requestID: String = UUID().uuidString) async throws -> Data {
    guard !stopped, !busy else { throw M4HTTPFixtureError.closed }
    guard used.insert(requestID).inserted else { throw M4HTTPFixtureError.duplicate }
    busy = true; defer { busy = false }
    var object: [String: Any] = ["version": 1, "requestID": requestID, "op": operation]; fields.forEach { object[$0] = $1 }
    let request = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); guard request.count <= 16_384 else { throw M4HTTPFixtureError.shape }
    requestCount += 1
    do {
      try input.fileHandleForWriting.write(contentsOf: request + Data([10]))
      let deadline = ContinuousClock.now.advanced(by: .seconds(8))
      while true {
        let raw = try await line(deadline: deadline)
        guard let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], envelope["version"] as? Int == 1, let id = envelope["requestID"] as? String else { throw M4HTTPFixtureError.shape }
        if abandoned.remove(id) != nil { continue }
        guard id == requestID else { throw M4HTTPFixtureError.correlation }
        guard envelope["ok"] as? Bool == true else { throw M4HTTPFixtureError.rejected }
        guard Set(envelope.keys) == ["version", "requestID", "ok", "result"], let result = envelope["result"] else { throw M4HTTPFixtureError.shape }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
      }
    } catch { abandoned.insert(requestID); throw error }
  }
  func close() async -> Report {
    var acknowledged = false
    if !stopped, process.isRunning, !busy {
      if let raw = try? await command("close"), let value = try? Self.object(raw, keys: ["closed"]) { acknowledged = value["closed"] as? Bool == true }
    }
    stopped = true; try? input.fileHandleForWriting.close()
    var deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    if process.isRunning { process.terminate() }
    deadline = .now.advanced(by: .seconds(2))
    while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    deadline = .now.advanced(by: .seconds(2))
    while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    let exited = !process.isRunning
    if exited { process.waitUntilExit(); try? pump(output.fileHandleForReading, stdout: true); try? pump(errors.fileHandleForReading, stdout: false) }
    bytes.removeAll(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
    return Report(pid: process.processIdentifier, exited: exited, status: exited ? process.terminationStatus : -1, readersJoined: exited && stdoutEOF && stderrEOF, closeAcknowledged: acknowledged)
  }
}

@MainActor final class M4HTTPFixtureHarness {
  struct Observation: Sendable { let id, accountID: String; let observedAt, expiresAt: Int64 }
  struct Anchor: Equatable { let device: dev_t; let inode: ino_t }
  let root, nativeRoot: URL
  let cli: M4HTTPFixtureCLI
  let metadata: M4HTTPFixtureCLI.Metadata
  let configuration: DevelopmentAuthorityConfiguration
  let cloudSpaceID = "independently-controlled-cloud", zoneID = "independently-controlled-zone"
  private(set) var owner: M4ApplicationContext?
  private var worker: Task<Void, Never>?, seen = Set<String>(), closing = false
  private var anchors: [URL: Anchor] = [:]
  private(set) var observations = 0, replies = 0, rejected = 0, suppressed = 0, held = false
  var holdReplies = false
  private(set) var authenticationSubjectDiffersFromHint = false
  private var identityFiles: [URL: Anchor] = [:]
  private var logins: [UUID: Task<Observation, any Error>] = [:]
  private let rootAnchor: Anchor
  private init(root: URL, cli: M4HTTPFixtureCLI, metadata: M4HTTPFixtureCLI.Metadata) throws {
    rootAnchor = try Self.anchor(root, directory: true)
    self.root = root; nativeRoot = root.appendingPathComponent("native"); self.cli = cli; self.metadata = metadata
    let dataset = "http-" + UUID().uuidString.lowercased().prefix(12)
    configuration = DevelopmentAuthorityConfiguration(dataset: String(dataset), namespace: "m4-ui-" + dataset + "-phone", baseURL: metadata.baseURL, keyID: metadata.keyID, publicKey: metadata.publicKey, cloudSpaceID: "independently-controlled-cloud", subject: "pin-hint-is-not-the-idp-subject", role: "phone")
  }
  static func start() async throws -> M4HTTPFixtureHarness {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("m4-http-S1-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let cli: M4HTTPFixtureCLI
    do { cli = try M4HTTPFixtureCLI(root: root) } catch { try? FileManager.default.removeItem(at: root); throw error }
    do { return try M4HTTPFixtureHarness(root: root, cli: cli, metadata: try await cli.ready()) }
    catch { _ = await cli.close(); try? FileManager.default.removeItem(at: root); throw error }
  }
  static func anchor(_ url: URL, directory: Bool = false) throws -> Anchor {
    var value = stat(); guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), value.st_uid == geteuid(), value.st_mode & 0o7777 == (directory ? 0o700 : 0o600) else { throw M4HTTPFixtureError.mailboxChanged }
    return Anchor(device: value.st_dev, inode: value.st_ino)
  }
  static func read(_ url: URL, maximum: Int = 1_048_576) throws -> (Data, Anchor) {
    let original = try anchor(url), fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw M4HTTPFixtureError.mailboxChanged }; defer { Darwin.close(fd) }
    var state = stat(); guard fstat(fd, &state) == 0, state.st_nlink == 1, state.st_dev == original.device, state.st_ino == original.inode, state.st_size > 0, state.st_size <= maximum else { throw M4HTTPFixtureError.mailboxChanged }
    var data = Data(count: Int(state.st_size)); let count = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
    guard count == data.count, try anchor(url) == original else { throw M4HTTPFixtureError.mailboxChanged }; return (data, original)
  }
  static func observation(_ raw: Data, metadata: M4HTTPFixtureCLI.Metadata) throws -> Observation {
    let value = try M4HTTPFixtureCLI.object(raw, keys: ["kind", "environment", "namespace", "observationID", "accountID", "observedAt", "expiresAt"])
    guard value["kind"] as? String == "currentIdentity", value["environment"] as? String == "development", value["namespace"] as? String == metadata.namespace,
          let original = value["observationID"] as? String, let id = UUID(uuidString: original), let account = value["accountID"] as? String,
          let observed = value["observedAt"] as? Int64, let expires = value["expiresAt"] as? Int64, observed >= 0, expires > observed,
          expires <= 9_007_199_254_740_991, expires - observed <= 60,
          Double(expires) > Date().timeIntervalSince1970, Double(observed) <= Date().timeIntervalSince1970 + 1 else { throw M4HTTPFixtureError.shape }
    try AuthorityWire.identifier(account)
    return Observation(id: id.uuidString, accountID: account, observedAt: observed, expiresAt: expires)
  }
  func observe(identity: String = "primary") async throws -> Observation {
    let begin = try M4HTTPFixtureCLI.object(try await cli.command("identity.begin"), keys: ["observationID", "nonce", "issuedAt", "expiresAt"])
    guard let id = begin["observationID"] as? String, let nonce = begin["nonce"] as? String else { throw M4HTTPFixtureError.shape }
    let apple = try M4HTTPFixtureCLI.object(try await cli.command("apple", fields: ["purpose": "observation", "nonce": nonce, "identity": identity]), keys: ["identityToken", "authorizationCode"])
    guard let token = apple["identityToken"] as? String else { throw M4HTTPFixtureError.shape }
    let result = try Self.observation(try await cli.command("identity.observe", fields: ["observationID": id, "identityToken": token]), metadata: metadata)
    guard UUID(uuidString: result.id) == UUID(uuidString: id) else { throw M4HTTPFixtureError.correlation }
    observations += 1; return result
  }
  private func write(_ data: Data, to url: URL, original: Anchor?) throws {
    if let original { guard try Self.anchor(url) == original else { throw M4HTTPFixtureError.mailboxChanged } }
    let flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (original == nil ? O_CREAT | O_EXCL : 0)
    let fd = Darwin.open(url.path, flags, 0o600); guard fd >= 0 else { throw M4HTTPFixtureError.mailboxChanged }; defer { Darwin.close(fd) }
    var stat = Darwin.stat(); guard fstat(fd, &stat) == 0, original == nil || Anchor(device: stat.st_dev, inode: stat.st_ino) == original else { throw M4HTTPFixtureError.mailboxChanged }
    guard ftruncate(fd, 0) == 0, data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == data.count, fsync(fd) == 0 else { throw M4HTTPFixtureError.mailboxChanged }
    if let original { guard try Self.anchor(url) == original else { throw M4HTTPFixtureError.mailboxChanged } }
  }
  @discardableResult func refreshIdentity(_ identity: String = "primary") async throws -> Observation {
    let value = try await observe(identity: identity), directory = nativeRoot.appendingPathComponent("development/current-identity")
    // Logical operation boundaries only: finish both same-inode files before
    // invoking the owner. Provider rereads are not fresh server observations.
    for url in [nativeRoot, nativeRoot.appendingPathComponent("development"), directory] {
      if FileManager.default.fileExists(atPath: url.path) { _ = try Self.anchor(url, directory: true) }
      else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    let pair: [(String, [String: Any])] = [("apple-account.json", ["version": 1, "environment": "development", "namespace": configuration.namespace, "observationID": value.id, "accountID": value.accountID]), ("cloud-space.json", ["version": 1, "environment": "development", "namespace": configuration.namespace, "observationID": value.id, "cloudSpaceID": cloudSpaceID, "zoneID": zoneID])]
    for (name, object) in pair { let url = directory.appendingPathComponent(name); try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), to: url, original: identityFiles[url]); identityFiles[url] = try Self.anchor(url) }
    guard Double(value.expiresAt) > Date().timeIntervalSince1970 else { throw M4HTTPFixtureError.timeout }; return value
  }
  func bootstrap(observationIdentity: String = "primary") async throws -> M4ApplicationContext {
    _ = try await refreshIdentity(observationIdentity)
    let value = try await M4ApplicationBootstrap.controlled(configuration: configuration, rootDirectory: nativeRoot); owner = value
    let mailbox = nativeRoot.appendingPathComponent("development/mailbox")
    for url in [root, nativeRoot, nativeRoot.appendingPathComponent("development"), mailbox, mailbox.appendingPathComponent("outgoing"), mailbox.appendingPathComponent("responses")] { anchors[url] = try Self.anchor(url, directory: true) }
    worker = Task { @MainActor in await self.work() }
    try await value.activateControlled(); return value
  }
  func signIn(observationIdentity: String = "primary") async throws -> Observation {
    guard let owner else { throw M4HTTPFixtureError.closed }
    let observed = try await refreshIdentity(observationIdentity)
    await owner.context.account.perform(.signIn); return observed
  }
  func beginSignIn() -> Task<Observation, any Error> {
    let id = UUID(), task = Task { try await self.signIn() }; logins[id] = task; return task
  }
  private func work() async {
    while !Task.isCancelled, !closing {
      let outgoing = nativeRoot.appendingPathComponent("development/mailbox/outgoing")
      for file in (try? FileManager.default.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
        do {
          guard !seen.contains(file.lastPathComponent) else { continue }
          let (raw, anchor) = try Self.read(file); seen.insert(file.lastPathComponent)
          let request = try M4HTTPFixtureCLI.object(raw, keys: ["id", "operation", "dataset", "payload"])
          guard let id = request["id"] as? String, UUID(uuidString: id)?.uuidString == id, file.lastPathComponent == id + ".json", request["dataset"] as? String == configuration.dataset,
                request["operation"] as? String == "apple", let encoded = request["payload"] as? String, let payload = Data(base64Encoded: encoded) else { throw M4HTTPFixtureError.shape }
          let body = try M4HTTPFixtureCLI.object(payload, keys: ["nonce"])
          guard let nonce = body["nonce"] as? String, nonce.count == 64, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw M4HTTPFixtureError.shape }
          let token = try await cli.command("apple", fields: ["purpose": "authentication", "nonce": nonce, "identity": "primary"])
          let apple = try M4HTTPFixtureCLI.object(token, keys: ["identityToken", "authorizationCode"])
          guard let jwt = apple["identityToken"] as? String else { throw M4HTTPFixtureError.shape }
          let pieces = jwt.split(separator: "."); guard pieces.count == 3 else { throw M4HTTPFixtureError.shape }
          var segment = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
          guard let claims = Data(base64Encoded: segment), let subject = (try? JSONSerialization.jsonObject(with: claims) as? [String: Any])?["sub"] as? String, subject != configuration.subject else { throw M4HTTPFixtureError.configuration }
          authenticationSubjectDiffersFromHint = true
          held = true; let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          while holdReplies, !closing, ContinuousClock.now < deadline { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
          held = false; try Task.checkCancellation(); guard ContinuousClock.now < deadline else { throw M4HTTPFixtureError.timeout }
          guard !closing, anchors.allSatisfy({ (try? Self.anchor($0.key, directory: true)) == $0.value }),
                let current = try? Self.read(file), current.0 == raw, current.1 == anchor else { suppressed += 1; continue }
          // Same original id/dataset/raw bytes and directory/request inodes were
          // rechecked after token wait. Publication has no await before rename.
          let response = nativeRoot.appendingPathComponent("development/mailbox/responses/" + id + ".json")
          let temporary = response.deletingLastPathComponent().appendingPathComponent("reply-" + UUID().uuidString + ".tmp")
          defer { try? FileManager.default.removeItem(at: temporary) }
          try write(JSONSerialization.data(withJSONObject: ["payload": token.base64EncodedString()], options: [.sortedKeys]), to: temporary, original: nil)
          guard let last = try? Self.read(file), last.0 == raw, last.1 == anchor, !closing, !Task.isCancelled,
                anchors.allSatisfy({ (try? Self.anchor($0.key, directory: true)) == $0.value }) else { suppressed += 1; continue }
          guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, response.path, UInt32(RENAME_EXCL)) == 0 else { throw M4HTTPFixtureError.mailboxChanged }
          replies += 1
        } catch is CancellationError { return }
        catch { rejected += 1 }
      }
      do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
    }
  }
  func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
    guard condition() else { throw M4HTTPFixtureError.timeout }
  }
  struct Report { let ownerClosed, workerJoined, requestsJoined: Bool; let process: M4HTTPFixtureCLI.Report }
  func close() async -> Report {
    var ownerClosed = true
    if let owner { do { try await owner.shutdown() } catch { ownerClosed = false } }
    let requests = Array(logins.values); requests.forEach { $0.cancel() }
    for request in requests { _ = await request.result }; logins.removeAll()
    closing = true; holdReplies = false; worker?.cancel(); await worker?.value; worker = nil
    let report = await cli.close()
    if ownerClosed, report.exited, report.readersJoined, (try? Self.anchor(root, directory: true)) == rootAnchor { try? FileManager.default.removeItem(at: root) }
    return Report(ownerClosed: ownerClosed, workerJoined: worker == nil, requestsJoined: logins.isEmpty, process: report)
  }
}
#endif
