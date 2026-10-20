import Foundation
import MatchCore
import MatchStore
public protocol ProductionPeerInboundCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func authorizeProductionMatch(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws
    func receiveProductionPeer(_ envelope:VerifiedPeerEnvelopeV1,matchID:String) async throws->InboundReceiptV3
    func acknowledgeProductionPeer(_ envelope:VerifiedPeerEnvelopeV1) async throws
}
extension MatchSession:ProductionPeerInboundCoordinator {
    func productionPeerRepository()throws->any ProductionPeerRepository {guard let repository=store as? any ProductionPeerRepository else {throw StoreError.trustUnavailable};return repository}
    func validateProductionEnvironment() async throws {
        try await validateEnvironment();guard case .production=environment,await store.databaseNamespace()==SQLiteSessionRepository.productionNamespace else {throw StoreError.trustUnavailable}
    }
    public func authorizeProductionMatch(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws {
        try beginBusiness(); defer { endBusiness() }
        try await validateProductionEnvironment();let repository=try productionPeerRepository()
        await acquire(intent.matchID);defer {release(intent.matchID)}
        try requireBusinessActive()
        try await repository.authorizeProductionMatchV4(intent:intent,receipt:receipt)
    }
    public func receiveProductionPeer(_ envelope:VerifiedPeerEnvelopeV1,matchID:String) async throws->InboundReceiptV3 {
        try beginBusiness(); defer { endBusiness() }
        try await validateProductionEnvironment();let repository=try productionPeerRepository(),local=try await identity()
        guard envelope.envelope.body.targetDeviceID==local else {throw StoreError.invalidPeerAuthorization}
        let packet=try JSONDecoder().decode(MatchPacketV2.self,from:envelope.payload)
        await acquire(matchID)
        defer {release(matchID);if packet.body.descriptor.recordingDeviceID==local {scheduleCapture(matchID)}}
        try requireBusinessActive()
        let receipt=try await repository.receiveProductionEnvelopeV4(envelope,matchID:matchID,now:clock.now()),snapshot=try await store.snapshotV2(matchID:matchID)
        try await updateAuthorityFence(snapshot);publish(try projected(snapshot))
        if snapshot.business.descriptor.recordingDeviceID==local {
            while try await planTerminalCleanupLocked(matchID,excluding:[]) != nil {}
            scheduleCapture(matchID)
        }
        return receipt
    }
    public func acknowledgeProductionPeer(_ envelope:VerifiedPeerEnvelopeV1) async throws {
        try beginBusiness(); defer { endBusiness() }
        try await validateProductionEnvironment();let repository=try productionPeerRepository(),ack=try JSONDecoder().decode(DurableACKV2.self,from:envelope.payload)
        await acquire(ack.body.matchID);defer {release(ack.body.matchID)}
        try requireBusinessActive()
        try await repository.acknowledgeProductionEnvelopeV4(envelope,now:clock.now())
    }
}
extension SQLiteSessionRepository:ProductionPeerRepository {
    public func authorizeProductionMatchV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws {try await store.authorizeProductionMatchV4(intent:intent,receipt:receipt)}
    public func unroutedProductionOutboxV4(matchID:String) async throws->[BusinessOutboxItem] {try await store.unroutedProductionOutboxV4(matchID:matchID)}
    public func routeProductionOutboxV4(outboxID:String,grant:VerifiedPeerGrantV1,now:Date) async throws->RouteReceiptV3 {try await store.routeProductionOutboxV4(outboxID:outboxID,grant:grant,now:now)}
    public func pendingProductionPacketsV4(matchID:String,grant:VerifiedPeerGrantV1,now:Date) async throws->[MatchPacketV2] {try await store.pendingProductionPacketsV4(matchID:matchID,grant:grant,now:now)}
    public func receiveProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,matchID:String,now:Date) async throws->InboundReceiptV3 {try await store.receiveProductionEnvelopeV4(envelope,matchID:matchID,now:now)}
    public func acknowledgeProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,now:Date) async throws {try await store.acknowledgeProductionEnvelopeV4(envelope,now:now)}
}
