#if DEBUG
import Foundation
import MatchStore
import MatchSync
import DeviceSync

/// Explicit development pairing, entered independently on both installations.
/// This is never inferred from WCSession status, received packets or another sandbox.
struct DevicePeerConfiguration: Codable, Equatable, Sendable {
  let localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch: String
  init(localDeviceID: String, remoteDeviceID: String, accountSubject: String, pairingID: String, trustEpoch: String) throws {
    guard let local = UUID(uuidString: localDeviceID), let remote = UUID(uuidString: remoteDeviceID), local != remote else { throw StoreError.invalidPeerAuthorization }
    self.localDeviceID = local.uuidString; self.remoteDeviceID = remote.uuidString
    self.accountSubject = accountSubject; self.pairingID = pairingID; self.trustEpoch = trustEpoch
    _ = try PeerAuthorization(localDeviceID: self.localDeviceID, remoteDeviceID: self.remoteDeviceID, accountSubject: accountSubject, pairingID: pairingID, trustEpoch: trustEpoch, environment: .development(databaseNamespace: "configuration-validation"), issuedAt: Date(), expiresAt: Date().addingTimeInterval(300))
  }
  enum CodingKeys: String, CodingKey { case localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(localDeviceID: c.decode(String.self, forKey: .localDeviceID), remoteDeviceID: c.decode(String.self, forKey: .remoteDeviceID), accountSubject: c.decode(String.self, forKey: .accountSubject), pairingID: c.decode(String.self, forKey: .pairingID), trustEpoch: c.decode(String.self, forKey: .trustEpoch))
  }
}

actor DevicePeerTrustProvider: RevocablePeerTrust {
  let directory: URL, namespace: String, configuration: DevicePeerConfiguration?
  let clock: any SyncClock
  var revoked = false
  static let filename = "development-peer.json"
  static let invalidationFilename = "development-peer.invalidated"
  init(directory: URL, namespace: String, requested: DevicePeerConfiguration?, clock: any SyncClock = SystemSyncClock()) throws {
    guard namespace != "production", !namespace.isEmpty, namespace.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw StoreError.invalidPeerAuthorization }
    self.directory = directory; self.namespace = namespace; self.clock = clock
    let file = directory.appendingPathComponent(Self.filename)
    let existing: DevicePeerConfiguration?
    if FileManager.default.fileExists(atPath: file.path) { existing = try JSONDecoder().decode(DevicePeerConfiguration.self, from: Data(contentsOf: file)) }
    else { existing = nil }
    if let existing, let requested, existing != requested {
      try Data("configurationChanged".utf8).write(to: directory.appendingPathComponent(Self.invalidationFilename), options: .atomic)
      throw StoreError.trustUnavailable
    }
    configuration = existing ?? requested
    if existing == nil, let requested {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(requested).write(to: file, options: .withoutOverwriting)
    }
  }
  func invalidate(_ reason: TrustInvalidationReason) {
    revoked = true
    // No reset/rebind operation exists. Preserve the original configuration and outbox.
    try? Data(String(describing: reason).utf8).write(to: directory.appendingPathComponent(Self.invalidationFilename), options: .atomic)
  }
  private func checkedConfiguration() throws -> DevicePeerConfiguration {
    guard !revoked, !FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.invalidationFilename).path), let configuration else { throw StoreError.trustUnavailable }
    do {
      let stored = try JSONDecoder().decode(DevicePeerConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent(Self.filename)))
      let identity = try String(contentsOf: directory.appendingPathComponent("device.identity"), encoding: .utf8)
      guard stored == configuration, identity == "football-record.identity.v1:" + configuration.localDeviceID else {
        invalidate(stored == configuration ? .localIdentityChanged : .accountChanged)
        throw StoreError.trustUnavailable
      }
      return configuration
    } catch {
      invalidate(.localIdentityChanged)
      throw StoreError.trustUnavailable
    }
  }
  func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization {
    let c = try checkedConfiguration()
    guard remoteDeviceID == nil || remoteDeviceID == c.remoteDeviceID else { throw StoreError.invalidPeerAuthorization }
    let now = clock.now()
    return try PeerAuthorization(localDeviceID: c.localDeviceID, remoteDeviceID: c.remoteDeviceID, accountSubject: c.accountSubject, pairingID: c.pairingID, trustEpoch: c.trustEpoch, environment: .development(databaseNamespace: namespace), issuedAt: now, expiresAt: now.addingTimeInterval(300))
  }
  func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws {
    let current = try await authorize(operation, remoteDeviceID: authorization.remoteDeviceID)
    guard authorization.localDeviceID == current.localDeviceID, authorization.remoteDeviceID == current.remoteDeviceID,
      authorization.accountSubject == current.accountSubject, authorization.pairingID == current.pairingID,
      authorization.trustEpoch == current.trustEpoch, authorization.environment == current.environment,
      authorization.issuedAt <= clock.now(), authorization.expiresAt > clock.now() else { throw StoreError.invalidPeerAuthorization }
  }
}
#endif
