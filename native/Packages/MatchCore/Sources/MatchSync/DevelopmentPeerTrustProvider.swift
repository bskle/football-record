#if DEBUG
import Foundation
import MatchStore

/// Explicit local test pair only. Reads both identity files on every authorization/validation;
/// a missing identity never creates or assumes a replacement device.
public struct DevelopmentPeerTrustProvider: PeerTrustProvider {
    let localURL, remoteURL: URL
    let localID, remoteID, namespace, account, pair, epoch: String
    let clock: any SyncClock
    public init(localIdentityURL: URL, remoteIdentityURL: URL, localDeviceID: String, remoteDeviceID: String, databaseNamespace: String, accountSubject: String, pairingID: String, trustEpoch: String, clock: any SyncClock) throws {
        guard databaseNamespace != "production", !databaseNamespace.isEmpty,
              databaseNamespace.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw StoreError.invalidPeerAuthorization }
        _ = try PeerAuthorization(localDeviceID: localDeviceID, remoteDeviceID: remoteDeviceID, accountSubject: accountSubject, pairingID: pairingID, trustEpoch: trustEpoch, environment: .development(databaseNamespace: databaseNamespace), issuedAt: clock.now(), expiresAt: clock.now().addingTimeInterval(300))
        localURL = localIdentityURL; remoteURL = remoteIdentityURL; localID = localDeviceID; remoteID = remoteDeviceID
        namespace = databaseNamespace; account = accountSubject; pair = pairingID; epoch = trustEpoch; self.clock = clock
    }
    func read(_ url: URL, expected: String) throws {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), raw == "football-record.identity.v1:" + expected,
              UUID(uuidString: expected) != nil else { throw StoreError.trustUnavailable }
    }
    public func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws -> PeerAuthorization {
        try read(localURL, expected: localID); try read(remoteURL, expected: remoteID)
        guard remoteDeviceID == nil || remoteDeviceID == remoteID else { throw StoreError.invalidPeerAuthorization }
        let now = clock.now()
        return try PeerAuthorization(localDeviceID: localID, remoteDeviceID: remoteID, accountSubject: account, pairingID: pair, trustEpoch: epoch, environment: .development(databaseNamespace: namespace), issuedAt: now, expiresAt: now.addingTimeInterval(300))
    }
    public func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws {
        let current = try await authorize(operation, remoteDeviceID: authorization.remoteDeviceID)
        guard authorization.localDeviceID == current.localDeviceID, authorization.accountSubject == account, authorization.pairingID == pair,
              authorization.trustEpoch == epoch, authorization.environment == current.environment,
              authorization.issuedAt <= clock.now(), authorization.expiresAt > clock.now() else { throw StoreError.invalidPeerAuthorization }
    }
}
#endif
