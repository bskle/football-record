#if DEBUG
import Foundation
import Darwin
import CryptoKit
import MatchCore
import MatchStore
import MatchSession
import MatchSync
import AccountKit
import CloudSync

public struct DevelopmentAuthorityConfiguration: Codable, Sendable {
  public var dataset, namespace, baseURL, keyID, publicKey, cloudSpaceID, subject, role: String
  public init(dataset: String, namespace: String, baseURL: String, keyID: String, publicKey: String, cloudSpaceID: String, subject: String, role: String) {
    self.dataset = dataset; self.namespace = namespace; self.baseURL = baseURL; self.keyID = keyID; self.publicKey = publicKey; self.cloudSpaceID = cloudSpaceID; self.subject = subject; self.role = role
  }
  func validate() throws {
    guard !dataset.isEmpty, dataset.utf8.count <= 30, dataset.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), ["phone","watch"].contains(role), namespace == "m4-ui-" + dataset + "-" + role, namespace != "production" else { throw SessionError.developmentIsolationRequired }
    try AuthorityWire.identifier(cloudSpaceID); try AuthorityWire.identifier(subject)
  }
}
public enum DevelopmentAuthorityScenario {
  public static func protocolClients(configuration: DevelopmentAuthorityConfiguration, rootDirectory: URL) throws -> DevelopmentAuthorityProtocolClients {
    try DevelopmentAuthorityProtocolClients(configuration: configuration, rootDirectory: rootDirectory)
  }
  @MainActor public static func fromPrivateFile(rootDirectory: URL? = nil) async throws -> AccountAppContext {
    let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record")
    let url = root.appendingPathComponent("development/m4-fixture.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw SessionError.developmentIsolationRequired }
    let data = try Data(contentsOf: url); guard data.count <= 16_384 else { throw SessionError.invalidRequest }
    return try await make(configuration: JSONDecoder().decode(DevelopmentAuthorityConfiguration.self, from: data), rootDirectory: root)
  }
  @MainActor public static func make(configuration: DevelopmentAuthorityConfiguration, rootDirectory: URL) async throws -> AccountAppContext {
    try configuration.validate()
    let runtime = try await DevelopmentAuthorityRuntime(configuration, root: rootDirectory)
    let account = AccountStatusModel(repository: runtime.repository, development: true, identityVerified: false, action: { [weak runtime] value in
      guard let runtime else { throw AuthorityError.unavailable }; try await runtime.runAccount(value)
    })
    let lifecycle = LifecycleStatusModel(repository: runtime.repository, development: true, ledger: runtime.ledger, action: { [weak runtime] value in
      guard let runtime else { throw AuthorityError.unavailable }; try await runtime.runLifecycle(value)
    })
    runtime.accountModel = account; runtime.lifecycleModel = lifecycle
    try await runtime.restoreLocalAdmission()
    runtime.startInbox()
    let result = AccountAppContext(repository: runtime.repository, session: runtime.session, recording: runtime.recording, account: account, lifecycle: lifecycle, close: { await runtime.shutdown() })
    await result.refresh(); return result
  }
}

public enum DevelopmentAuthorityProtocolError: Error, Sendable, Equatable { case closed, undrainedMailbox }
public enum DevelopmentAuthorityProtocolCloseState: Sendable, Equatable { case drained, undrained }
/// Protocol clients only; the original Session, credentials and Saga belong to the caller.
public actor DevelopmentAuthorityProtocolClients: AppleSignInDriver, AuthorityHTTPRelay, CloudDriver, CloudAccountDeletionDriver, WatchRegistrationAuthorizing {
  public nonisolated let namespace: String
  private let mailbox: DevelopmentMailbox
  private let relay: URLSessionAuthorityRelay
  private let mailboxRoot: URL
  private let mailboxInventory: [String: ProtocolClientDirectoryIdentity]
  private var closed = false
  private var closing: Task<Void, Never>?
  private struct Pending: Sendable {
    let cancel: @Sendable () -> Void
    let join: Task<Void, Never>
  }
  private var operations: [UUID: Pending] = [:]
  fileprivate init(configuration: DevelopmentAuthorityConfiguration, rootDirectory: URL) throws {
    try configuration.validate()
    guard rootDirectory.isFileURL, let base = URL(string: configuration.baseURL) else { throw SessionError.invalidRequest }
    _ = try AuthorityTrustConfiguration(environment: .development, publicKeys: [configuration.keyID: configuration.publicKey])
    _ = try protocolClientDirectoryExists(rootDirectory)
    let mailboxRoot = rootDirectory.appendingPathComponent("development/mailbox")
    guard try protocolClientMailboxEmpty(mailboxRoot) else { throw DevelopmentAuthorityProtocolError.undrainedMailbox }
    let relay = try URLSessionAuthorityRelay(baseURL: base, environment: .development)
    do {
      mailbox = try DevelopmentMailbox(root: mailboxRoot, dataset: configuration.dataset)
      guard try protocolClientMailboxEmpty(mailboxRoot) else { throw DevelopmentAuthorityProtocolError.undrainedMailbox }
      mailboxInventory = try protocolClientPublishedInventory(mailboxRoot)
    } catch { relay.shutdown(); throw error }
    self.relay = relay; self.mailboxRoot = mailboxRoot; namespace = configuration.namespace
  }
  func owned<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    guard !closed else { throw DevelopmentAuthorityProtocolError.closed }
    try Task.checkCancellation()
    let id = UUID(), task = Task { try await work() }
    operations[id] = Pending(cancel: { task.cancel() }, join: Task { _ = try? await task.value })
    defer { operations.removeValue(forKey: id) }
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard !closed else { throw DevelopmentAuthorityProtocolError.closed }
      try Task.checkCancellation()
      return value
    } catch {
      if closed { throw DevelopmentAuthorityProtocolError.closed }
      throw error
    }
  }
  public func authorize(nonceSHA256: String) async throws -> AppleAuthorization {
    let driver = DevelopmentAppleDriver(mailbox: mailbox)
    return try await owned { try await driver.authorize(nonceSHA256: nonceSHA256) }
  }
  public func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    let relay = relay
    return try await owned { try await relay.send(request) }
  }
  public func registrationContext() async throws -> WatchRegistrationContextV4 {
    let driver = DevelopmentWatchAuthorizer(mailbox: mailbox)
    return try await owned { try await driver.registrationContext() }
  }
  public func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async throws -> Data {
    let driver = DevelopmentWatchAuthorizer(mailbox: mailbox)
    return try await owned { try await driver.authorizeRegistration(attempt, action: action) }
  }
  public func fetch(scope: CloudScope, cursor: CloudCursor) async throws -> CloudFetchBatch {
    let driver = DevelopmentFileCloud(mailbox: mailbox)
    return try await owned { try await driver.fetch(scope: scope, cursor: cursor) }
  }
  public func save(_ upload: CloudUpload) async throws -> CloudSaveResult {
    let driver = DevelopmentFileCloud(mailbox: mailbox)
    return try await owned { try await driver.save(upload) }
  }
  public func deletePrivateZone(scope: CloudScope) async throws {
    let driver = DevelopmentFileCloud(mailbox: mailbox)
    try await owned { try await driver.deletePrivateZone(scope: scope) }
  }
  /// Point-in-time inspection only: it neither closes nor cancels clients needed by the original Saga.
  /// Callers must gate business admission before checking; later calls can change this state.
  public func drainState() -> DevelopmentAuthorityProtocolCloseState {
    guard operations.isEmpty,
          (try? protocolClientPublishedInventory(mailboxRoot)) == mailboxInventory,
          (try? protocolClientMailboxEmpty(mailboxRoot)) == true,
          (try? protocolClientPublishedInventory(mailboxRoot)) == mailboxInventory else { return .undrained }
    return .drained
  }
  /// Final close, not business quiescence: retain these clients while the original Saga needs them.
  /// The state is a fresh mailbox snapshot, not a durable whole-device erasure receipt.
  public func close() async -> DevelopmentAuthorityProtocolCloseState {
    if closing == nil {
      closed = true
      let pending = Array(operations.values), mailbox = mailbox
      pending.forEach { $0.cancel() }; relay.shutdown()
      closing = Task {
        await mailbox.close()
        for call in pending { await call.join.value }
      }
    }
    await closing?.value
    operations.removeAll()
    return drainState()
  }
}

private struct ProtocolClientDirectoryIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
}
/// Published instances require the same complete directory inventory; a missing
/// or substituted empty directory cannot prove that the original copies drained.
private func protocolClientPublishedInventory(_ root: URL) throws -> [String: ProtocolClientDirectoryIdentity] {
  let names = ["outgoing", "responses", "incoming", "incoming-responses"]
  var result: [String: ProtocolClientDirectoryIdentity] = [:]
  for name in [""] + names {
    let url = name.isEmpty ? root : root.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0, Int(info.st_mode) & Int(S_IFMT) == Int(S_IFDIR) else { throw DevelopmentAuthorityProtocolError.undrainedMailbox }
    result[name] = ProtocolClientDirectoryIdentity(device: info.st_dev, inode: info.st_ino)
  }
  return result
}
private func protocolClientDirectoryExists(_ url: URL) throws -> Bool {
  var info = stat()
  if lstat(url.path, &info) != 0 {
    if errno == ENOENT { return false }
    throw DevelopmentAuthorityProtocolError.undrainedMailbox
  }
  guard Int(info.st_mode) & Int(S_IFMT) == Int(S_IFDIR) else { throw DevelopmentAuthorityProtocolError.undrainedMailbox }
  return true
}
private func protocolClientMailboxEmpty(_ root: URL) throws -> Bool {
  _ = try protocolClientDirectoryExists(root.deletingLastPathComponent())
  guard try protocolClientDirectoryExists(root) else { return true }
  let names = Set(["outgoing", "responses", "incoming", "incoming-responses"])
  do {
    for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard names.contains(child.lastPathComponent), try protocolClientDirectoryExists(child),
            try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty else { return false }
    }
    return true
  } catch { throw DevelopmentAuthorityProtocolError.undrainedMailbox }
}

private struct MailboxRequest: Codable { let id, operation, dataset: String; let payload: Data }
private struct MailboxReply: Codable { let payload: Data?; let issue: String? }
private actor DevelopmentMailbox {
  let root: URL
  let dataset: String
  var closed = false
  init(root: URL, dataset: String) throws {
    self.root = root; self.dataset = dataset
    for name in ["outgoing","responses","incoming","incoming-responses"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
  }
  func close() { closed = true }
  func call(_ operation: String, payload: Data) async throws -> Data {
    guard !closed, payload.count <= 16*1024*1024 else { throw AuthorityError.unavailable }
    let id = UUID().uuidString, request = root.appendingPathComponent("outgoing/" + id + ".json"), response = root.appendingPathComponent("responses/" + id + ".json")
    defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
    try privateWrite(JSONEncoder().encode(MailboxRequest(id: id, operation: operation, dataset: dataset, payload: payload)), to: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    while !closed, ContinuousClock.now < deadline {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: response.path) {
        let bytes = try Data(contentsOf: response); guard bytes.count <= 24*1024*1024 else { throw AuthorityError.invalidWire }
        let reply = try JSONDecoder().decode(MailboxReply.self, from: bytes)
        guard reply.issue == nil, let payload = reply.payload else { throw AuthorityError.unavailable }; return payload
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw AuthorityError.unavailable
  }
}
private func privateWrite(_ bytes: Data, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try bytes.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
private struct DevelopmentAppleDriver: AppleSignInDriver {
  let mailbox: DevelopmentMailbox
  func authorize(nonceSHA256: String) async throws -> AppleAuthorization {
    struct Request: Encodable { let nonce: String }
    struct Reply: Decodable { let identityToken: String; let authorizationCode: String? }
    let bytes = try await mailbox.call("apple", payload: JSONEncoder().encode(Request(nonce: nonceSHA256)))
    let reply = try JSONDecoder().decode(Reply.self, from: bytes)
    return AppleAuthorization(identityToken: reply.identityToken, authorizationCode: reply.authorizationCode ?? "development-transient-code")
  }
}
private struct DevelopmentWatchAuthorizer: WatchRegistrationAuthorizing {
  let mailbox: DevelopmentMailbox
  func registrationContext() async throws -> WatchRegistrationContextV4 { try JSONDecoder().decode(WatchRegistrationContextV4.self, from: await mailbox.call("phone-context", payload: Data())) }
  func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async throws -> Data {
    try await mailbox.call("phone-register", payload: JSONEncoder().encode(WatchForward(attempt: attempt, action: action)))
  }
}
private struct MigrationTransfer: Codable { let intent: ControlIntentV1; let raw: Data }
private struct WatchForward: Codable { let attempt: WatchRegistrationAttemptV4; let action: WatchRegistrationAction }
/// This private Debug control file is not business SQLite or a Keychain SDK claim.
private actor DevelopmentFileVault: DeviceCredentialVault {
  struct Saved: Codable {
    let token, sessionID, accountID, deviceID, keyID: String
    let activationEpoch, expiresAt: Int64
    init(_ c: DeviceCredential) { token=c.token;sessionID=c.sessionID;accountID=c.accountID;deviceID=c.deviceID;keyID=c.keyID;activationEpoch=c.activationEpoch;expiresAt=c.expiresAt }
    var value: DeviceCredential { DeviceCredential(token: token, sessionID: sessionID, accountID: accountID, deviceID: deviceID, keyID: keyID, activationEpoch: activationEpoch, expiresAt: expiresAt) }
  }
  struct State: Codable { var generation: Int64 = 0; var credential: Saved? }
  let url: URL
  var state: State
  init(url: URL) throws { self.url = url; state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State() }
  func credential() throws -> DeviceCredential { guard let value = state.credential else { throw AuthorityError.unavailable }; return value.value }
  func advanceIdentityFence(to generation: Int64) throws {
    guard generation >= state.generation else { throw AuthorityError.identityChanged }
    if generation > state.generation { var next = state; next.generation = generation; next.credential = nil; try save(next) }
  }
  func replace(_ credential: DeviceCredential?, expectedIdentityGeneration: Int64) throws {
    guard expectedIdentityGeneration == state.generation else { throw AuthorityError.identityChanged }
    var next = state; next.credential = credential.map(Saved.init); try save(next)
  }
  private func save(_ value: State) throws { try privateWrite(JSONEncoder().encode(value), to: url); state = value }
}
private struct DevelopmentFileCloud: CloudDriver, CloudAccountDeletionDriver {
  let mailbox: DevelopmentMailbox
  func fetch(scope: CloudScope, cursor: CloudCursor) async throws -> CloudFetchBatch {
    let bytes = try await mailbox.call("cloud-fetch", payload: JSONEncoder().encode(scope))
    let records = try JSONDecoder().decode([CloudRecord].self, from: bytes)
    return try CloudFetchBatch(scope: scope, batchID: UUID().uuidString, records: records, expectedAppliedToken: cursor.appliedToken, nextToken: Data(AuthorityWire.hash(bytes).utf8), fetchGeneration: cursor.fetchGeneration, moreComing: false)
  }
  func save(_ upload: CloudUpload) async throws -> CloudSaveResult {
    let bytes = try await mailbox.call("cloud-save", payload: JSONEncoder().encode(upload))
    let readback = try JSONDecoder().decode(CloudUpload.self, from: bytes)
    guard readback == upload else { throw CloudError(.conflict) }
    let raw = readback.record.canonicalBytes
    let ref = try CloudAssetReference(partID: "part-" + upload.record.recordID, index: 0, byteCount: raw.count, digest: AuthorityWire.hash(raw))
    let manifest = try CloudSaveManifest(upload: upload, parts: [ref])
    return .complete(CloudSaveReadback(scope: upload.scope, recordID: upload.record.recordID, manifestRecordID: upload.checkpointID, manifestBytes: try AuthorityWire.encode(manifest), manifestChangeTag: "development-manifest-" + upload.record.digest, manifestCondition: .ifServerRecordUnchanged, parts: [CloudSavedPart(reference: ref, changeTag: "development-part-" + upload.record.digest, condition: .ifServerRecordUnchanged, readBackBytes: raw)], confirmationID: "development-confirm-" + upload.record.digest, recordChangeTag: "development-record-" + upload.record.digest, recordCondition: .ifServerRecordUnchanged))
  }
  func deletePrivateZone(scope: CloudScope) async throws { _ = try await mailbox.call("cloud-delete", payload: JSONEncoder().encode(scope)) }
}
private struct DevelopmentOwnedLedgerDeletion: LocalTransportDeletionDriver {
  let ledger: SQLiteCloudLedger
  func purgeBusinessCopies(_ request: LocalTransportDeletionRequest) async throws {
    let child = "development-ledger-" + AuthorityWire.hash(Data((request.requestID + request.requestDigest + request.scope.stableZoneKey).utf8))
    let result = try await ledger.eraseLocalTransport(CloudLocalTransportEraseRequest(requestID: child, scope: request.scope))
    guard result.requestID == child, result.stableZoneKey == request.scope.stableZoneKey else { throw AuthorityError.intentMismatch }
  }
}

@MainActor private final class DevelopmentAuthorityRuntime {
  let configuration: DevelopmentAuthorityConfiguration
  let root: URL
  let repository: SQLiteSessionRepository
  let session: MatchSession
  let recording: RecordingModel
  let relay: URLSessionAuthorityRelay
  let client: AuthorityClient
  let signer: DevelopmentDeviceSigner
  let vault: DevelopmentFileVault
  let mailbox: DevelopmentMailbox
  let ledger: SQLiteCloudLedger
  let bridge: CloudSessionBridge
  let control: AuthorityControlService
  let accountService: AccountService
  let phoneService: PhoneWatchRegistrationService
  let watchService: WatchRegistrationService
  weak var accountModel: AccountStatusModel?
  weak var lifecycleModel: LifecycleStatusModel?
  var scope: CloudScope?
  var lifecycleService: LifecycleService?
  var cloudService: CloudSyncService?
  var reauthenticationID: String?
  var inbox: Task<Void,Never>?
  var operations: [UUID:Task<Void,Error>] = [:]
  var closed = false
  init(_ configuration: DevelopmentAuthorityConfiguration, root: URL) async throws {
    self.configuration = configuration; self.root = root
    let directory = root.appendingPathComponent(configuration.namespace)
    let existingDatabase = FileManager.default.fileExists(atPath: directory.appendingPathComponent("matches.sqlite").path)
    if existingDatabase {
      for original in ["development.key", "device.identity", "authority.fixture"] {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(original).path) else { throw SessionError.identityUnavailable }
      }
    }
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: [configuration.keyID: configuration.publicKey])
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: configuration.namespace, authorityTrust: trust, cloudSavePolicy: .development(databaseNamespace: configuration.namespace))
    repository = repo
    let matches = try await repo.matchIDs(), binding = try await repo.accountBindingV4()
    let attempts = try await repo.authAttemptsV4(), registrations = try await repo.pendingWatchRegistrationAttemptsV4()
    let hasData = existingDatabase || !matches.isEmpty || binding != nil || !attempts.isEmpty || !registrations.isEmpty
    let fingerprint = Data((configuration.keyID + "\n" + configuration.publicKey + "\n" + configuration.cloudSpaceID + "\n" + configuration.subject).utf8)
    let pin = directory.appendingPathComponent("authority.fixture")
    if FileManager.default.fileExists(atPath: pin.path) { guard try Data(contentsOf: pin) == fingerprint else { throw SessionError.identityUnavailable } }
    else { guard !hasData else { throw SessionError.identityUnavailable }; try privateWrite(fingerprint, to: pin) }
    let keyURL = directory.appendingPathComponent("development.key")
    let raw: Data
    if FileManager.default.fileExists(atPath: keyURL.path) { raw = try Data(contentsOf: keyURL) }
    else { guard !hasData else { throw SessionError.identityUnavailable }; raw = Curve25519.Signing.PrivateKey().rawRepresentation; try privateWrite(raw, to: keyURL) }
    let identity = PersistentDeviceIdentityProvider(url: directory.appendingPathComponent("device.identity"), repository: repo)
    let id = try await identity.localDeviceID()
    mailbox = try DevelopmentMailbox(root: root.appendingPathComponent("development/mailbox"), dataset: configuration.dataset)
    vault = try DevelopmentFileVault(url: directory.appendingPathComponent("development.vault"))
    guard let baseURL = URL(string: configuration.baseURL) else { throw SessionError.invalidRequest }
    relay = try URLSessionAuthorityRelay(baseURL: baseURL, environment: .development)
    signer = try DevelopmentDeviceSigner(namespace: configuration.namespace, rawRepresentation: raw)
    let client = AuthorityClient(relay: relay, vault: vault, signer: signer, trust: trust)
    self.client = client
    let provider = AuthorityStartPermitProvider(client: client, repository: repo)
    let session = MatchSession(store: repo, deviceIdentity: identity, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: provider, workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: configuration.namespace))
    self.session = session; try await provider.attach(session)
    let sync = MatchSyncService(repository: repo, inbound: session)
    recording = RecordingModel(session: session, repository: repo, development: true, sync: sync, developmentPair: false)
    ledger = try SQLiteCloudLedger(url: directory.appendingPathComponent("cloud-transport.sqlite"))
    bridge = CloudSessionBridge(repository: repo, client: client, policy: .development(databaseNamespace: configuration.namespace)); try await bridge.attach(session)
    control = AuthorityControlService(client: client, repository: repo, coordinator: session)
    accountService = AccountService(client: client, repository: repo, coordinator: session, deviceID: id, cloudSpaceID: configuration.cloudSpaceID, apple: DevelopmentAppleDriver(mailbox: mailbox))
    phoneService = PhoneWatchRegistrationService(client: client, repository: repo, coordinator: session)
    watchService = WatchRegistrationService(client: client, repository: repo, coordinator: session, deviceID: id, cloudSpaceID: configuration.cloudSpaceID, authorizer: DevelopmentWatchAuthorizer(mailbox: mailbox))
  }
  func stableID(_ key: String, fresh: Bool = false) throws -> String {
    let url = root.appendingPathComponent(configuration.namespace).appendingPathComponent("development-requests.json")
    var values = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode([String:String].self, from: Data(contentsOf: url)) : [:]
    if !fresh, let value = values[key] { return value }
    let value = UUID().uuidString; values[key] = value; try privateWrite(JSONEncoder().encode(values), to: url); return value
  }
  func ensureServices(allowSuspended: Bool = false) async throws {
    guard !closed, let binding = try await repository.accountBindingV4(), (allowSuspended || !binding.suspended), binding.cloudSpaceID == configuration.cloudSpaceID else { throw AuthorityError.identityChanged }
    let current = try CloudScope(accountID: binding.accountID, cloudSpaceID: binding.cloudSpaceID, zoneID: "matches", activationEpoch: binding.activationEpoch)
    guard scope != current else { return }
    scope = current
    let driver = DevelopmentFileCloud(mailbox: mailbox)
    lifecycleService = LifecycleService(client: client, repository: repository, coordinator: session, scope: current, ledger: ledger, cloudDeletion: driver, localTransportDeletion: DevelopmentOwnedLedgerDeletion(ledger: ledger))
    cloudService = CloudSyncService(scope: current, ledger: ledger, driver: driver, sink: bridge)
    lifecycleModel?.setCloudScope(current)
  }
  func restoreLocalAdmission() async throws {
    // Retained saga scope can be presented/retried after backend deletion; it never
    // admits a suspended account to recording or grants a fresh business action.
    if try await repository.accountBindingV4() != nil { try await ensureServices(allowSuspended: true) }
    if let b = try await repository.accountBindingV4(), !b.suspended,
       let c = try? await vault.credential(), c.accountID == b.accountID, c.deviceID == b.deviceID, c.activationEpoch == b.activationEpoch, c.keyID == (try AuthorityWire.deviceKeyID(publicKey: signer.publicKey)), Double(c.expiresAt) > Date().timeIntervalSince1970 {
      if b.role == .phone || b.role == .waiting { try await accountService.admitCurrentIdentity(accountID: b.accountID) }
      accountModel?.confirmIdentity(); try await ensureServices()
      if b.role == .phone { try await phoneService.admitCurrentIdentity(accountID: b.accountID); try await publishPhoneReady() }
    }
  }
  func owned(_ work: @escaping @MainActor () async throws -> Void) async throws {
    guard !closed else { throw AuthorityError.unavailable }
    let id = UUID(), task = Task { try await work() }; operations[id] = task; defer { operations[id] = nil }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
  func runAccount(_ action: AccountUserAction) async throws {
    do { try await owned { try await self.accountAction(action) } }
    catch {
      let value = error as NSError
      // Private finite diagnostic: no error descriptions, URLs, tokens or request bodies.
      try? privateWrite(JSONSerialization.data(withJSONObject: ["stage":"account","domain":value.domain,"code":value.code]), to: root.appendingPathComponent("development/last-failure.json"))
      throw error
    }
  }
  func accountAction(_ action: AccountUserAction) async throws {
    if action == .identityChanged {
      accountModel?.pauseIdentity(); try await ensureServices(); try await lifecycleService?.identityChanged(); await recording.shutdown(); accountModel?.requireReload(); return
    }
    let result: AccountAuthentication
    if configuration.role == "watch" {
      let context = try await DevelopmentWatchAuthorizer(mailbox: mailbox).registrationContext()
      try await watchService.admitCurrentIdentity(context: context)
      let pending = try await repository.pendingWatchRegistrationAttemptsV4()
      if let original = pending.first { result = try await watchService.recover(requestID: original.requestID) }
      else {
        let requestID = try stableID("watch-register", fresh: action == .renew)
        let prior = try await repository.watchRegistrationAttemptV4(requestID: requestID)
        if action == .recover || prior != nil { result = try await watchService.recover(requestID: requestID) }
        else { result = try await watchService.register(requestID: requestID, challengeRequestID: stableID("watch-challenge", fresh: action == .renew)) }
      }
    } else {
      let binding = try await repository.accountBindingV4(); try await accountService.admitCurrentIdentity(accountID: binding?.accountID)
      let pending = try await repository.pendingAuthAttemptsV4()
      if let original = pending.first { result = try await authenticated(accountService.recover(authRequestID: original.requestID)) }
      else if action == .recover {
        let original = try await repository.currentAuthRequestIDV4() ?? stableID("auth")
        result = try await authenticated(accountService.recover(authRequestID: original))
      } else {
        let id = try stableID("auth", fresh: action == .renew)
        result = try await accountService.signIn(requestID: id, challengeRequestID: stableID("challenge", fresh: action == .renew))
      }
    }
    reauthenticationID = result.reauthenticationID
    accountModel?.confirmIdentity(); try await ensureServices()
    if result.binding.role == .phone { try await phoneService.admitCurrentIdentity(accountID: result.binding.accountID); try await publishPhoneReady() }
  }
  func authenticated(_ recovery: AuthenticationRecovery) throws -> AccountAuthentication {
    switch recovery { case .authenticated(let result): return result; case .knownExpired, .knownRevoked: throw AuthorityError.staleAttestation; default: throw AuthorityError.unavailable }
  }
  func saveCloud(_ upload: CloudUpload) async throws -> DevelopmentCloudSaveEvidence {
    guard let cloudService else { throw AuthorityError.unavailable }
    try await ledger.enqueue(upload)
    for _ in 0..<64 {
      try Task.checkCancellation(); guard !closed else { throw CancellationError() }
      if let saved = try await ledger.saveEvidence(scope: upload.scope).first(where: { $0.uploadID == upload.id }) { return saved }
      let outcome = try await cloudService.synchronize(); if let issue = outcome.issue { throw CloudError(issue) }
      await Task.yield()
    }
    throw AuthorityError.unavailable
  }
  func runLifecycle(_ action: LifecycleUserAction) async throws { try await owned { try await self.lifecycleAction(action) } }
  func lifecycleAction(_ action: LifecycleUserAction) async throws {
    if case .resumeDeletion = action { try await ensureServices(allowSuspended: true) }
    else { try await ensureServices() }
    guard let lifecycleService, let scope else { throw AuthorityError.unavailable }
    switch action {
    case .saveCloudOnly(let id), .synchronize(let id):
      let upload = try await bridge.prepareUpload(matchID: id, scope: scope)
      let evidence = try await saveCloud(upload); _ = try await bridge.acceptDevelopmentSave(upload: upload, evidence: evidence, ledger: ledger)
      if case .synchronize = action {
        let state = try await session.snapshot(matchID: id)
        if state.replay.state == .endedPendingSync { _ = try await control.normal(matchID: id, requestID: stableID("normal-" + id)) }
      }
      recording.accept(try await session.snapshot(matchID: id))
    case .retryControls: _ = try await control.reconcilePending(); _ = try await lifecycleService.retryPendingControls()
    case .abnormal(let id): _ = try await control.abnormal(matchID: id, requestID: stableID("abnormal-" + id)); recording.accept(try await session.snapshot(matchID: id))
    case .analytics(let value): try await lifecycleService.setAnalyticsEnabled(value)
    case .prepareMigration(let phone): _ = try await lifecycleService.prepareMigration(newPhoneID: phone, requestID: stableID("migration-prepare"))
    case .checkpoint:
      guard let migration = try await repository.latestMigrationV4(), let id = UUID(uuidString: try stableID("checkpoint-uuid")) else { throw LifecycleClientError.invalidCheckpoint }
      let upload = try await lifecycleService.prepareFinalCheckpoint(checkpointID: id), evidence = try await saveCloud(upload)
      try await lifecycleService.acceptDevelopmentFinalCheckpoint(upload: upload, evidence: evidence, migrationID: migration.migrationID)
      _ = try await lifecycleService.commitMigrationCheckpoint(migrationID: migration.migrationID, requestID: stableID("migration-checkpoint"))
    case .importMigration:
      let bytes = try await mailbox.call("phone-migration", payload: Data())
      let transfers = try JSONDecoder().decode([MigrationTransfer].self, from: bytes)
      guard !transfers.isEmpty else { throw LifecycleClientError.invalidCheckpoint }
      for transfer in transfers { try await lifecycleService.learnMigration(intent: transfer.intent, raw: transfer.raw) }
    case .activateMigration:
      guard let migration = try await repository.latestMigrationV4() else { throw LifecycleClientError.invalidCheckpoint }
      _ = try await cloudService?.synchronize()
      _ = try await lifecycleService.activateMigration(migrationID: migration.migrationID, requestID: stableID("migration-activate"))
    case .requestLost: _ = try await lifecycleService.requestLostMigration(requestID: stableID("migration-lost"))
    case .confirmLostEnd:
      guard let migration = try await repository.latestMigrationV4(), let reauthenticationID,
        let history = try await repository.cloudHistoryV4(scope: CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch)).first else { throw LifecycleClientError.reauthenticationRequired }
      let intent = try ControlIntentV1.acquire(history.facts.startIntent, epoch: history.scope.activationEpoch)
      let acquire = try VerifiedAuthorityReceiptV1.verify(history.originalAcquire, expected: AuthorityExpectedIntent(intent, accountID: scope.accountID, epoch: history.scope.activationEpoch), trust: client.trust)
      let grant = try await lifecycleService.requestLostRecovery(migrationID: migration.migrationID, originalAcquire: acquire, reauthenticationID: reauthenticationID, confirmedAt: Int64(Date().timeIntervalSince1970), requestID: stableID("lost-recovery"))
      _ = try await lifecycleService.terminateLost(grant: grant, requestID: stableID("lost-terminate"))
    case .forceMigration:
      guard let migration = try await repository.latestMigrationV4(), let reauthenticationID else { throw LifecycleClientError.reauthenticationRequired }
      _ = try await lifecycleService.forceMigration(migrationID: migration.migrationID, reauthenticationID: reauthenticationID, requestID: stableID("migration-force"))
    case .delete(let cloud, let local, let health, let confirmed):
      guard let reauthenticationID else { throw LifecycleClientError.reauthenticationRequired }
      let id = try stableID("deletion")
      _ = try await lifecycleService.requestDeletion(requestID: id, reauthenticationID: reauthenticationID, cloud: cloud, local: local, health: health, healthConfirmed: confirmed)
      _ = try await lifecycleService.resumeDeletion(requestID: id)
    case .resumeDeletion(let id): _ = try await lifecycleService.resumeDeletion(requestID: id)
    }
    await recording.refreshAuthority()
    await accountModel?.refresh()
  }
  func publishPhoneReady() async throws {
    try privateWrite(AuthorityWire.encode(await phoneService.registrationContext()), to: root.appendingPathComponent("development/phone-ready.json"))
  }
  func startInbox() {
    guard configuration.role == "phone", inbox == nil else { return }
    inbox = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.closed else { return }
        let directory = self.root.appendingPathComponent("development/mailbox/incoming")
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
          do {
            let bytes = try Data(contentsOf: file); guard bytes.count <= 1_048_576 else { continue }
            let request = try JSONDecoder().decode(MailboxRequest.self, from: bytes)
            guard UUID(uuidString: request.id) != nil, request.dataset == self.configuration.dataset else { continue }
            let response = self.root.appendingPathComponent("development/mailbox/incoming-responses/" + request.id + ".json")
            guard !FileManager.default.fileExists(atPath: response.path) else { continue }
            let reply: MailboxReply
            do {
              let data: Data
              if request.operation == "phone-context" { data = try AuthorityWire.encode(await self.phoneService.registrationContext()) }
              else if request.operation == "phone-register" { let forward = try JSONDecoder().decode(WatchForward.self, from: request.payload); data = try await self.phoneService.authorizeRegistration(forward.attempt, action: forward.action) }
              else if request.operation == "phone-migration" {
                guard let migration = try await self.repository.latestMigrationV4(), let binding = try await self.repository.accountBindingV4() else { throw LifecycleClientError.invalidCheckpoint }
                let queue = try await self.repository.controlQueueV4()
                var transfers: [MigrationTransfer] = []
                for operation in [AuthorityOperation.prepareMigration, .checkpointMigration] {
                  for entry in queue where entry.intent.operation == operation {
                    guard let raw = try await self.repository.lifecycleReceiptV4(requestID: entry.intent.requestID) else { continue }
                    let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(entry.intent, accountID: binding.accountID, epoch: migration.oldActivationEpoch), trust: self.client.trust)
                    if receipt.body.migration?.migrationID == migration.migrationID { transfers.append(MigrationTransfer(intent: entry.intent, raw: raw)) }
                  }
                }
                data = try JSONEncoder().encode(transfers)
              }
              else { throw AuthorityError.unavailable }
              reply = MailboxReply(payload: data, issue: nil)
            } catch { reply = MailboxReply(payload: nil, issue: "unavailable") }
            try privateWrite(JSONEncoder().encode(reply), to: response)
          } catch { /* Malformed private fixture requests never become an account action. */ }
        }
        do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
      }
    }
  }
  func shutdown() async {
    guard !closed else { return }; closed = true
    let tasks = Array(operations.values); tasks.forEach { $0.cancel() }; inbox?.cancel(); relay.shutdown(); await mailbox.close()
    for task in tasks { _ = try? await task.value }; await inbox?.value; inbox = nil
    try? await ledger.close(); try? await repository.close()
  }
}
#endif
