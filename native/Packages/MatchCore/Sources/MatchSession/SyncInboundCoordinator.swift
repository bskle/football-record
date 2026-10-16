import Foundation
import MatchCore
import MatchStore

extension MatchSession: SyncInboundCoordinator {
    public func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await store.syncRepositoryIdentity() }
    /// The trusted caller revalidates account/pair/epoch; Session also binds its own identity/DB.
    func validateSyncAuthorization(_ peer: PeerAuthorization) async throws -> String {
        try await validateEnvironment()
        let local = try await identity(), namespace = await store.databaseNamespace()
        guard peer.localDeviceID == local, peer.issuedAt <= clock.now(), peer.expiresAt > clock.now(),
              peer.environment == .development(databaseNamespace: namespace) else { throw StoreError.invalidPeerAuthorization }
        guard case .development = environment else { throw StoreError.trustUnavailable }
        return local
    }
    public func receiveSyncPacket(_ bytes: Data, peer: PeerAuthorization, matchID: String) async throws -> InboundReceiptV3 {
        let local = try await validateSyncAuthorization(peer)
        guard bytes.count <= 8 * 1024 * 1024 else { throw StoreError.syncQuotaExceeded }
        let packet = try JSONDecoder().decode(MatchPacketV2.self, from: bytes)
        guard packet.body.descriptor.matchID == matchID, packet.body.targetDeviceID == local,
              packet.body.sourceDeviceID == peer.remoteDeviceID, bytes == (try packet.canonicalBytes()) else { throw StoreError.invalidPacket }
        await acquire(matchID)
        defer {
            release(matchID)
            // Includes responseLost and a failure after COMMIT but before reload/cleanup.
            if packet.body.descriptor.recordingDeviceID == local { scheduleCapture(matchID) }
        }
        let receipt = try await store.receiveV2(bytes, peer: peer, expectedMatchID: matchID, now: clock.now())
        publish(try projected(await store.snapshotV2(matchID: matchID)))
        if packet.body.descriptor.recordingDeviceID == local {
            while try await planTerminalCleanupLocked(matchID, excluding: []) != nil {}
        }
        return receipt
    }
    public func receiveSyncACK(_ bytes: Data, peer: PeerAuthorization) async throws {
        _ = try await validateSyncAuthorization(peer)
        guard bytes.count <= 8 * 1024 * 1024 else { throw StoreError.syncQuotaExceeded }
        let ack = try JSONDecoder().decode(DurableACKV2.self, from: bytes)
        await acquire(ack.body.matchID); defer { release(ack.body.matchID) }
        try await store.acknowledgeV2(bytes, peer: peer, now: clock.now())
    }
}
