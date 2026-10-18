import Foundation
import CryptoKit
import MatchCore

/// Separate from M3's development assertion. This value cannot be decoded or publicly initialized.
public struct VerifiedPeerGrantV1:Sendable,Equatable {
    public let receipt:VerifiedAuthorityReceiptV1
    public let intent:ControlIntentV1
    public var grant:AuthorityPeerGrantV1 {receipt.body.peerGrant!}
    private init(receipt:VerifiedAuthorityReceiptV1,intent:ControlIntentV1){self.receipt=receipt;self.intent=intent}
    public static func verify(_ raw:Data,intent:ControlIntentV1,trust:AuthorityTrustConfiguration,binding:AccountBindingV4,now:Date)throws->Self {
        let date=now.timeIntervalSince1970
        guard trust.environment == .production,binding.environment == .production,!binding.suspended,date.isFinite,date>=0,date<=9_007_199_254_740_991,intent.operation == .peerGrant else {throw AuthorityError.identityChanged}
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:binding.accountID,epoch:binding.activationEpoch),trust:trust),r=receipt.body
        guard r.result == .grantIssued,r.matchID.isEmpty,r.lockID.isEmpty,r.recordingDeviceID.isEmpty,let g=r.peerGrant,
              g.pairingID==intent.fields.pairingID,g.localDeviceID==intent.fields.localDeviceID,g.remoteDeviceID==intent.fields.remoteDeviceID,g.localDeviceID != g.remoteDeviceID,
              Set([g.localRole,g.remoteRole])==Set(["phone","watch"]),g.activePhoneID==(g.localRole=="phone" ? g.localDeviceID:g.remoteDeviceID),
              (g.localDeviceID==binding.deviceID && g.localRole==binding.role.rawValue) || (g.remoteDeviceID==binding.deviceID && g.remoteRole==binding.role.rawValue),
              g.expiresAt>r.issuedAt,g.expiresAt<=9_007_199_254_740_991,g.expiresAt-r.issuedAt<=3600,Double(r.issuedAt)<=date,Double(g.expiresAt)>date else {throw AuthorityError.staleAttestation}
        for id in [g.grantID,g.pairingID,g.localDeviceID,g.remoteDeviceID,g.activePhoneID] {try AuthorityWire.identifier(id)}
        _=try AuthorityWire.decodeBase64URL(g.localPublicKey,count:32);_=try AuthorityWire.decodeBase64URL(g.remotePublicKey,count:32)
        return Self(receipt:receipt,intent:intent)
    }
}
public enum ProductionPeerPayloadKindV1:String,Codable,Sendable {case packet,ack}
public struct ProductionPeerEnvelopeV1:Codable,Sendable,Equatable {
    public struct Body:Codable,Sendable,Equatable {
        public let version:Int
        public let accountID:String
        public let activationEpoch:Int64
        public let pairingID,grantID,sourceDeviceID,targetDeviceID:String
        public let kind:ProductionPeerPayloadKindV1
        public let bodySHA256,payload:String
    }
    public let body:Body
    public let signature:String
    public init(body:Body,signature:String){self.body=body;self.signature=signature}
    public static func body(grant:VerifiedPeerGrantV1,sourceDeviceID:String,kind:ProductionPeerPayloadKindV1,bytes:Data)throws->Body {
        let g=grant.grant;guard [g.localDeviceID,g.remoteDeviceID].contains(sourceDeviceID),!bytes.isEmpty,bytes.count<=8*1024*1024 else {throw AuthorityError.invalidWire}
        return Body(version:1,accountID:grant.receipt.body.accountID,activationEpoch:grant.receipt.body.activationEpoch,pairingID:g.pairingID,grantID:g.grantID,sourceDeviceID:sourceDeviceID,targetDeviceID:sourceDeviceID==g.localDeviceID ? g.remoteDeviceID:g.localDeviceID,kind:kind,bodySHA256:AuthorityWire.hash(bytes),payload:AuthorityWire.base64URL(bytes))
    }
    public static func signingBytes(_ body:Body)throws->Data {AuthorityWire.signedInput("football-record.peer-envelope.v1",body:try AuthorityWire.encode(body))}
}
public struct VerifiedPeerEnvelopeV1:Sendable,Equatable {
    public let raw:Data
    public let envelope:ProductionPeerEnvelopeV1
    public let grant:VerifiedPeerGrantV1
    public let payload:Data
    private init(raw:Data,envelope:ProductionPeerEnvelopeV1,grant:VerifiedPeerGrantV1,payload:Data){self.raw=raw;self.envelope=envelope;self.grant=grant;self.payload=payload}
    public static func verify(_ raw:Data,grant:VerifiedPeerGrantV1,trust:AuthorityTrustConfiguration,binding:AccountBindingV4,now:Date)throws->Self {
        let verified=try VerifiedPeerGrantV1.verify(grant.receipt.raw,intent:grant.intent,trust:trust,binding:binding,now:now),g=verified.grant
        let e=try AuthorityWire.decode(ProductionPeerEnvelopeV1.self,raw,limit:12*1024*1024),b=e.body
        guard b.version==1,b.accountID==binding.accountID,b.activationEpoch==binding.activationEpoch,b.grantID==g.grantID,b.pairingID==g.pairingID,
              Set([b.sourceDeviceID,b.targetDeviceID])==Set([g.localDeviceID,g.remoteDeviceID]),b.sourceDeviceID != b.targetDeviceID,b.targetDeviceID==binding.deviceID,
              b.payload.count<=12*1024*1024 else {throw AuthorityError.intentMismatch}
        let payload=try AuthorityWire.decodeBase64URL(b.payload);guard payload.count<=8*1024*1024,b.bodySHA256==AuthorityWire.hash(payload) else {throw AuthorityError.invalidWire}
        let key=try Curve25519.Signing.PublicKey(rawRepresentation:AuthorityWire.decodeBase64URL(b.sourceDeviceID==g.localDeviceID ? g.localPublicKey:g.remotePublicKey,count:32))
        guard key.isValidSignature(try AuthorityWire.decodeBase64URL(e.signature,count:64),for:try ProductionPeerEnvelopeV1.signingBytes(b)) else {throw AuthorityError.invalidSignature}
        switch b.kind {
        case .packet:let p=try JSONDecoder().decode(MatchPacketV2.self,from:payload);guard try p.canonicalBytes()==payload,p.body.sourceDeviceID==b.sourceDeviceID,p.body.targetDeviceID==b.targetDeviceID else {throw StoreError.invalidPacket}
        case .ack:let a=try JSONDecoder().decode(DurableACKV2.self,from:payload);guard try a.canonicalBytes()==payload,a.body.sourceDeviceID==b.sourceDeviceID,a.body.targetDeviceID==b.targetDeviceID else {throw StoreError.invalidACK}
        }
        return Self(raw:raw,envelope:e,grant:verified,payload:payload)
    }
}
public protocol ProductionPeerRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func authorizeProductionMatchV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws
    func unroutedProductionOutboxV4(matchID:String) async throws->[BusinessOutboxItem]
    func routeProductionOutboxV4(outboxID:String,grant:VerifiedPeerGrantV1,now:Date) async throws->RouteReceiptV3
    func pendingProductionPacketsV4(matchID:String,grant:VerifiedPeerGrantV1,now:Date) async throws->[MatchPacketV2]
    func receiveProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,matchID:String,now:Date) async throws->InboundReceiptV3
    func acknowledgeProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,now:Date) async throws
}
