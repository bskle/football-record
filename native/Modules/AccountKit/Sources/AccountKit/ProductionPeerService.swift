import Foundation
import MatchCore
import MatchStore
import MatchSession
/// Network retrieval never holds the Session match queue or a SQL transaction.
public actor ProductionPeerService {
    let client:AuthorityClient
    let repository:any AuthorityRepository & ProductionPeerRepository
    let coordinator:any ProductionPeerInboundCoordinator
    public init(client:AuthorityClient,repository:any AuthorityRepository & ProductionPeerRepository,coordinator:any ProductionPeerInboundCoordinator){self.client=client;self.repository=repository;self.coordinator=coordinator}
    func binding() async throws->AccountBindingV4 {
        guard client.trust.environment == .production,await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity(),let binding=try await repository.accountBindingV4(),binding.environment == .production,!binding.suspended else {throw StoreError.trustUnavailable};return binding
    }
    public func requestGrant(localDeviceID:String,remoteDeviceID:String,pairingID:String,requestID:String) async throws->VerifiedPeerGrantV1 {
        let b=try await binding();guard b.role == .phone,let authority=coordinator as? any AuthorityInboundCoordinator else {throw AuthorityError.identityChanged}
        var fields=AuthorityFields();fields.localDeviceID=localDeviceID;fields.remoteDeviceID=remoteDeviceID;fields.pairingID=pairingID;fields.activationEpoch=b.activationEpoch
        let intent=try ControlIntentV1(requestID:requestID,operation:.peerGrant,fields:fields)
        _=try await authority.prepareAuthorityControl(intent);try await ControlQueueSupport.begin(intent,coordinator:authority,at:client.now())
        do {
            let raw:Data
            do {raw=try await client.query(requestID:requestID)}catch let failure as AuthorityHTTPFailure where failure.code=="notFound" {raw=try await client.send(intent)}
            let verified=try VerifiedPeerGrantV1.verify(raw,intent:intent,trust:client.trust,binding:b,now:client.now())
            guard try await binding()==b else {throw AuthorityError.identityChanged}
            _=try await authority.acceptAuthorityResult(verified.receipt);return verified
        }catch {try await ControlQueueSupport.failed(intent,error:error,coordinator:authority,at:client.now());throw error}
    }
    public func receive(_ raw:Data,grantRaw:Data,grantIntent:ControlIntentV1) async throws->InboundReceiptV3? {
        let b=try await binding(),grant=try VerifiedPeerGrantV1.verify(grantRaw,intent:grantIntent,trust:client.trust,binding:b,now:client.now()),envelope=try VerifiedPeerEnvelopeV1.verify(raw,grant:grant,trust:client.trust,binding:b,now:client.now())
        if envelope.envelope.body.kind == .ack {try await coordinator.acknowledgeProductionPeer(envelope);return nil}
        let packet=try JSONDecoder().decode(MatchPacketV2.self,from:envelope.payload),intent=try ControlIntentV1.acquire(packet.body.descriptor.startIntent,epoch:b.activationEpoch)
        let original=try await client.query(requestID:intent.requestID),receipt=try VerifiedAuthorityReceiptV1.verify(original,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:b.activationEpoch),trust:client.trust)
        guard try await binding()==b else {throw AuthorityError.identityChanged}
        try await coordinator.authorizeProductionMatch(intent:intent,receipt:receipt)
        return try await coordinator.receiveProductionPeer(envelope,matchID:packet.body.descriptor.matchID)
    }
}
