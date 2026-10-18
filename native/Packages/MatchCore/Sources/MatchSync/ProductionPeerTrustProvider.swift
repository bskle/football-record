import Foundation
import MatchStore
/// Device key custody and concrete WC transport are supplied by 024/026, independently of M3.
public protocol ProductionPeerTrustProvider:Sendable {
    func currentGrant() async throws->VerifiedPeerGrantV1
    func signEnvelopeBody(_ signingBytes:Data) async throws->Data
}
public struct UnavailableProductionPeerTrustProvider:ProductionPeerTrustProvider {
    public init(){}
    public func currentGrant() async throws->VerifiedPeerGrantV1 {throw StoreError.trustUnavailable}
    public func signEnvelopeBody(_ signingBytes:Data) async throws->Data {throw StoreError.trustUnavailable}
}
public protocol ProductionPeerTransport:Sendable {func sendEnvelope(_ originalBytes:Data,deliveryID:String) async throws}
public struct UnavailableProductionPeerTransport:ProductionPeerTransport {public init(){};public func sendEnvelope(_ originalBytes:Data,deliveryID:String) async throws {throw StoreError.syncTransportUnavailable}}
public actor ProductionPeerSyncService {
    let repository:any ProductionPeerRepository
    let provider:any ProductionPeerTrustProvider
    let transport:any ProductionPeerTransport
    let clock:any SyncClock
    public init(repository:any ProductionPeerRepository,provider:any ProductionPeerTrustProvider=UnavailableProductionPeerTrustProvider(),transport:any ProductionPeerTransport=UnavailableProductionPeerTransport(),clock:any SyncClock=SystemSyncClock()){self.repository=repository;self.provider=provider;self.transport=transport;self.clock=clock}
    public func envelope(bytes:Data,kind:ProductionPeerPayloadKindV1,sourceDeviceID:String) async throws->Data {
        let grant=try await provider.currentGrant(),body=try ProductionPeerEnvelopeV1.body(grant:grant,sourceDeviceID:sourceDeviceID,kind:kind,bytes:bytes),signature=try await provider.signEnvelopeBody(ProductionPeerEnvelopeV1.signingBytes(body))
        return try AuthorityWire.encode(ProductionPeerEnvelopeV1(body:body,signature:AuthorityWire.base64URL(signature)))
    }
    public func synchronize(matchID:String) async throws {
        let grant=try await provider.currentGrant()
        for item in try await repository.unroutedProductionOutboxV4(matchID:matchID) {_=try await repository.routeProductionOutboxV4(outboxID:item.id,grant:grant,now:clock.now())}
        for packet in try await repository.pendingProductionPacketsV4(matchID:matchID,grant:grant,now:clock.now()) {
            let body=try ProductionPeerEnvelopeV1.body(grant:grant,sourceDeviceID:packet.body.sourceDeviceID,kind:.packet,bytes:packet.canonicalBytes()),signature=try await provider.signEnvelopeBody(ProductionPeerEnvelopeV1.signingBytes(body)),wire=try AuthorityWire.encode(ProductionPeerEnvelopeV1(body:body,signature:AuthorityWire.base64URL(signature)))
            // Re-read the durable epoch/grant fence after key/SDK awaits and before transport dispatch.
            guard try await repository.pendingProductionPacketsV4(matchID:matchID,grant:grant,now:clock.now()).contains(packet) else {throw StoreError.invalidPeerAuthorization}
            try await transport.sendEnvelope(wire,deliveryID:packet.body.packetID)
        }
    }
}
