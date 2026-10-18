import Foundation
import MatchStore
import MatchSession

/// Transient by design: Apple authorization is never Codable or part of a durable DTO.
public struct AppleAuthorization:Sendable {
    public let identityToken,authorizationCode:String
    public init(identityToken:String,authorizationCode:String){self.identityToken=identityToken;self.authorizationCode=authorizationCode}
}
public protocol AppleSignInDriver:Sendable {func authorize(nonceSHA256:String) async throws->AppleAuthorization}
public struct AccountAuthentication:Sendable {
    public let binding:AccountBindingV4
    public let receipt:VerifiedAuthorityReceiptV1
    public let reauthenticationID:String?
}
public enum AuthenticationRecovery:Sendable {case authenticated(AccountAuthentication),knownRevoked,knownExpired,knownNotFound,knownAbandoned,unresolved}
public actor AccountService {
    let client:AuthorityClient
    let repository:any AccountLifecycleRepository & AuthorityRepository
    let coordinator:any AccountLifecycleCoordinator
    let deviceID,cloudSpaceID:String
    let apple:any AppleSignInDriver
    public init(client:AuthorityClient,repository:any AccountLifecycleRepository & AuthorityRepository,coordinator:any AccountLifecycleCoordinator,deviceID:String,cloudSpaceID:String,apple:any AppleSignInDriver){self.client=client;self.repository=repository;self.coordinator=coordinator;self.deviceID=deviceID;self.cloudSpaceID=cloudSpaceID;self.apple=apple}

    struct ChallengeRequest:Encodable {let version=1;let requestID,deviceID,devicePublicKey:String}
    struct Challenge:Codable {let version:Int;let requestID,challengeID:String;let expiresAt:Int64;let challenge:String?;let status:String?}
    struct AuthRequest:Encodable {let version=1;let requestID,challengeID,identityToken,authorizationCode,deviceID,devicePublicKey,cloudSpaceID:String}
    struct RecoverRequest:Encodable {let version=1;let requestID,authRequestID,deviceID,keyID,nonce,devicePublicKey:String;let issuedAt:Int64}
    struct SessionClaims:Decodable {let sessionID:String;let expiresAt:Int64}
    struct Context:Decodable {let accountID,deviceID,keyID:String;let activationEpoch:Int64}
    func ensureFacade() async throws {guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else {throw AuthorityError.identityChanged};try AuthorityWire.identifier(deviceID);try AuthorityWire.identifier(cloudSpaceID)}
    func seconds()throws->Int64 {let value=client.now().timeIntervalSince1970;guard value.isFinite,value>=0,value<=9_007_199_254_740_991 else {throw AuthorityError.invalidWire};return Int64(value)}
    func object<T:Encodable>(_ value:T)throws->[String:Any] {try JSONSerialization.jsonObject(with:AuthorityWire.encode(value)) as! [String:Any]}
    func bytes(_ value:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    public func signIn(requestID:String,challengeRequestID:String) async throws->AccountAuthentication {
        try await ensureFacade()
        if try await repository.authAttemptV4(requestID:requestID) != nil {
            guard case .authenticated(let result)=try await recover(authRequestID:requestID) else {throw AuthorityError.identityChanged};return result
        }
        guard try await repository.pendingAuthAttemptsV4().allSatisfy({$0.requestID==requestID}) else {throw AuthorityError.conflict}
        let request=ChallengeRequest(requestID:challengeRequestID,deviceID:deviceID,devicePublicKey:client.signer.publicKey)
        let challenge=try AuthorityWire.decode(Challenge.self,await client.unsigned(path:"/v1/auth/challenges",body:AuthorityWire.encode(request)))
        let now=try seconds()
        guard challenge.version==1,challenge.requestID==challengeRequestID,challenge.expiresAt>=now,challenge.expiresAt-now<=300,let secret=challenge.challenge,challenge.status==nil else {throw AuthorityError.staleAttestation}
        let hash=AuthorityWire.hash(Data(secret.utf8)),authorization=try await apple.authorize(nonceSHA256:hash)
        let auth=AuthRequest(requestID:requestID,challengeID:challenge.challengeID,identityToken:authorization.identityToken,authorizationCode:authorization.authorizationCode,deviceID:deviceID,devicePublicKey:client.signer.publicKey,cloudSpaceID:cloudSpaceID)
        var signing=try object(auth);signing["challengeSHA256"]=hash
        let signature=try await client.signer.sign(AuthorityWire.signedInput("football-record.device.challenge.v1",body:bytes(signing)))
        var full=try object(auth);full["deviceProof"]=AuthorityWire.base64URL(signature)
        let raw=try bytes(full),attempt=try AuthAttemptV4(requestID:requestID,deviceID:deviceID,publicKey:client.signer.publicKey,cloudSpaceID:cloudSpaceID,challengeID:challenge.challengeID,requestDigest:AuthorityWire.hash(raw),environment:client.trust.environment)
        // Persist only the immutable binding/digest before the first network mutation.
        try await coordinator.saveAuthAttempt(attempt)
        let response=try await client.unsigned(path:"/v1/auth/apple",body:raw)
        return try await accept(response,attempt:attempt)
    }
    public func recover(authRequestID:String) async throws->AuthenticationRecovery {
        try await ensureFacade()
        guard let attempt=try await repository.authAttemptV4(requestID:authRequestID),attempt.deviceID==deviceID,attempt.cloudSpaceID==cloudSpaceID,attempt.publicKey==client.signer.publicKey,attempt.environment==client.trust.environment else {throw AuthorityError.identityChanged}
        let request=RecoverRequest(requestID:UUID().uuidString,authRequestID:authRequestID,deviceID:deviceID,keyID:attempt.keyID,nonce:UUID().uuidString,devicePublicKey:attempt.publicKey,issuedAt:try seconds())
        let unsigned=try object(request),signature=try await client.signer.sign(AuthorityWire.signedInput("football-record.device.auth-recover.v1",body:bytes(unsigned)))
        var full=unsigned;full["deviceProof"]=AuthorityWire.base64URL(signature)
        let raw:Data
        do {raw=try await client.unsigned(path:"/v1/auth/recover",body:bytes(full))}
        catch let failure as AuthorityHTTPFailure {
            if failure.code=="notFound" {try await coordinator.resolveAuthAttempt(requestID:authRequestID,resolution:.knownNotFound);return .knownNotFound}
            if failure.code=="unauthorized" || failure.retryable {return .unresolved}
            throw failure
        } catch is URLError {return .unresolved}
        if let object=try JSONSerialization.jsonObject(with:raw) as? [String:Any],Set(object.keys)==["status"] {
            if object["status"] as? String=="knownAbandoned" {try await coordinator.resolveAuthAttempt(requestID:authRequestID,resolution:.knownAbandoned);return .knownAbandoned}
            if object["status"] as? String=="knownRevoked" {try await terminalCredential(authRequestID:authRequestID,resolution:.knownRevoked);return .knownRevoked}
            if object["status"] as? String=="knownExpired" {try await terminalCredential(authRequestID:authRequestID,resolution:.knownExpired);return .knownExpired}
            throw AuthorityError.invalidWire
        }
        return .authenticated(try await accept(raw,attempt:attempt))
    }
    func terminalCredential(authRequestID:String,resolution:AuthResolutionV4) async throws {
        try await coordinator.resolveAuthAttempt(requestID:authRequestID,resolution:resolution)
        if let lifecycle=coordinator as? any LifecycleInboundCoordinator {try await lifecycle.suspendAccount();try await lifecycle.setAnalyticsEnabled(false)}
        try await client.vault.replace(nil)
    }
    func accept(_ raw:Data,attempt:AuthAttemptV4) async throws->AccountAuthentication {
        guard raw.count<=65536,let value=try JSONSerialization.jsonObject(with:raw) as? [String:Any],try bytes(value)==raw,
              Set(value.keys)==Set(["receipt","sessionClaims","credential","context"]+(value["reauthenticationID"] == nil ? []:["reauthenticationID"])) else {throw AuthorityError.invalidWire}
        func decode<T:Decodable>(_ type:T.Type,_ key:String)throws->T {guard let object=value[key] else {throw AuthorityError.invalidWire};return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]))}
        let credential=try decode(DeviceCredential.self,"credential"),claims=try decode(SessionClaims.self,"sessionClaims"),context=try decode(Context.self,"context")
        guard let receiptValue=value["receipt"],Set((value["credential"] as? [String:Any] ?? [:]).keys)==Set(["token","sessionID","accountID","deviceID","keyID","activationEpoch","expiresAt"]),
              context.deviceID==deviceID,context.accountID==credential.accountID,context.keyID==attempt.keyID,context.activationEpoch==credential.activationEpoch,
              credential.deviceID==deviceID,credential.keyID==attempt.keyID,claims.sessionID==credential.sessionID,claims.expiresAt==credential.expiresAt,credential.expiresAt >= (try seconds()),!credential.token.isEmpty else {throw AuthorityError.identityChanged}
        let receipt=try VerifiedAuthorityReceiptV1.verify(JSONSerialization.data(withJSONObject:receiptValue,options:[.sortedKeys,.withoutEscapingSlashes]),expected:AuthorityExpectedIntent(requestID:attempt.requestID,digest:attempt.requestDigest,operation:.authApple,accountID:credential.accountID,epoch:credential.activationEpoch),trust:client.trust)
        let role:AccountBindingV4.Role
        switch receipt.body.result {case .registered:role = .phone;case .waitingMigration:role = .waiting;default:throw AuthorityError.intentMismatch}
        let binding=try AccountBindingV4(accountID:credential.accountID,cloudSpaceID:attempt.cloudSpaceID,deviceID:deviceID,activationEpoch:credential.activationEpoch,role:role,environment:client.trust.environment)
        let reauth=value["reauthenticationID"] as? String;if let reauth {try AuthorityWire.identifier(reauth)}
        try await coordinator.acceptAuthentication(attempt:attempt,binding:binding,receipt:receipt)
        try await client.vault.replace(credential)
        return AccountAuthentication(binding:binding,receipt:receipt,reauthenticationID:reauth)
    }
}
