import Foundation
import CryptoKit

public struct WatchRegistrationContextV4:Codable,Sendable,Equatable {
    public let accountID,cloudSpaceID,phoneID:String
    public let activationEpoch:Int64
    public let environment:AuthorityEnvironment
    public init(accountID:String,cloudSpaceID:String,phoneID:String,activationEpoch:Int64,environment:AuthorityEnvironment)throws {
        for id in [accountID,cloudSpaceID,phoneID] {try AuthorityWire.identifier(id)}
        guard activationEpoch>0,activationEpoch<=9_007_199_254_740_991 else {throw AuthorityError.invalidWire}
        self.accountID=accountID;self.cloudSpaceID=cloudSpaceID;self.phoneID=phoneID;self.activationEpoch=activationEpoch;self.environment=environment
    }
}
public struct WatchRegistrationPayloadV4:Codable,Sendable,Equatable {
    public let version:Int
    public let requestID,watchID,watchPublicKey,challengeID,deviceProof:String
    public init(requestID:String,watchID:String,watchPublicKey:String,challengeID:String,deviceProof:String) {
        version=1;self.requestID=requestID;self.watchID=watchID;self.watchPublicKey=watchPublicKey;self.challengeID=challengeID;self.deviceProof=deviceProof
    }
}
/// Contains public possession proof, never an Apple authorization or credential token.
public struct WatchRegistrationAttemptV4:Codable,Sendable,Equatable {
    public let context:WatchRegistrationContextV4
    public let payload:WatchRegistrationPayloadV4
    public let challengeRequestID,challengeSHA256:String
    public let canonicalRequest:Data
    public var requestID:String {payload.requestID}
    public var requestDigest:String {AuthorityWire.hash(canonicalRequest)}
    public init(context:WatchRegistrationContextV4,payload:WatchRegistrationPayloadV4,challengeRequestID:String,challengeSHA256:String)throws {
        self.context=context;self.payload=payload;self.challengeRequestID=challengeRequestID;self.challengeSHA256=challengeSHA256;canonicalRequest=try AuthorityWire.encode(payload);try validate()
    }
    public func validate()throws {
        _=try WatchRegistrationContextV4(accountID:context.accountID,cloudSpaceID:context.cloudSpaceID,phoneID:context.phoneID,activationEpoch:context.activationEpoch,environment:context.environment)
        for id in [payload.requestID,payload.watchID,payload.challengeID,challengeRequestID] {try AuthorityWire.identifier(id)}
        guard payload.version==1,payload.watchID != context.phoneID,canonicalRequest.count<=4096,canonicalRequest == (try AuthorityWire.encode(payload)),challengeSHA256.utf8.count==64,challengeSHA256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw AuthorityError.invalidWire}
        let key=try Curve25519.Signing.PublicKey(rawRepresentation:AuthorityWire.decodeBase64URL(payload.watchPublicKey,count:32)),signature=try AuthorityWire.decodeBase64URL(payload.deviceProof,count:64)
        var object=try JSONSerialization.jsonObject(with:canonicalRequest) as! [String:Any];object["deviceProof"]=nil;object["challengeSHA256"]=challengeSHA256
        let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        guard key.isValidSignature(signature,for:AuthorityWire.signedInput("football-record.device.challenge.v1",body:bytes)) else {throw AuthorityError.invalidSignature}
    }
}
public protocol WatchRegistrationRepository:Sendable {
    func admitWatchRegistrationContextV4(_ context:WatchRegistrationContextV4,deviceID:String,publicKey:String) async throws->Int64
    func watchRegistrationAttemptV4(requestID:String) async throws->WatchRegistrationAttemptV4?
    func pendingWatchRegistrationAttemptsV4() async throws->[WatchRegistrationAttemptV4]
    func watchRegistrationReceiptV4(requestID:String) async throws->Data?
    func saveWatchRegistrationAttemptV4(_ attempt:WatchRegistrationAttemptV4,expectedIdentityGeneration:Int64) async throws
    func closeWatchRegistrationV4(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64) async throws
    func acceptWatchRegistrationV4(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,watchBinding:AccountBindingV4?,expectedIdentityGeneration:Int64) async throws
}
