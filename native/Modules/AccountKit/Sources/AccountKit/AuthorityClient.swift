import Foundation
import MatchStore

public final class URLSessionAuthorityRelay: AuthorityHTTPRelay, @unchecked Sendable {
    let baseURL:URL
    let session:URLSession
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void) { completionHandler(nil) }
    }
    public init(baseURL:URL,environment:AuthorityEnvironment,productionHosts:Set<String>=[]) throws {
        guard let host=baseURL.host,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil,baseURL.path.isEmpty || baseURL.path == "/" else { throw AuthorityError.invalidWire }
        switch environment { case .development:guard baseURL.scheme=="http",["127.0.0.1","::1","[::1]"].contains(host) else { throw AuthorityError.invalidWire }
        case .production:guard baseURL.scheme=="https",productionHosts.contains(host) else { throw AuthorityError.invalidWire } }
        self.baseURL=baseURL
        let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=10;c.urlCache=nil;c.httpCookieStorage=nil
        session=URLSession(configuration:c,delegate:NoRedirect(),delegateQueue:nil)
    }
    public func send(_ request:AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
        guard request.path.hasPrefix("/v1/"),!request.path.contains("?"),!request.path.contains("#"),request.body.count <= 16384 else { throw AuthorityError.invalidWire }
        var r=URLRequest(url:baseURL.appendingPathComponent(String(request.path.dropFirst())))
        r.httpMethod=request.method;r.httpBody=request.method == "GET" ? nil : request.body
        r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let auth=request.authorization { r.setValue(auth,forHTTPHeaderField:"Authorization") }
        if let proof=request.deviceProof { r.setValue(proof,forHTTPHeaderField:"X-Device-PoP") }
        let (data,response)=try await session.data(for:r)
        guard data.count <= 65536,let response=response as? HTTPURLResponse else { throw AuthorityError.invalidWire }
        return AuthorityHTTPResponse(status:response.statusCode,body:data)
    }
}
public struct AuthorityClient: Sendable {
    public let trust:AuthorityTrustConfiguration
    let relay:any AuthorityHTTPRelay
    let vault:any DeviceCredentialVault
    let signer:any DeviceProofSigner
    let now:@Sendable ()->Date
    let nonce:@Sendable ()->String
    public init(relay:any AuthorityHTTPRelay,vault:any DeviceCredentialVault,signer:any DeviceProofSigner,trust:AuthorityTrustConfiguration,now:@escaping @Sendable ()->Date={Date()},nonce:@escaping @Sendable ()->String={UUID().uuidString}) {
        self.relay=relay;self.vault=vault;self.signer=signer;self.trust=trust;self.now=now;self.nonce=nonce
    }
    private struct PoPFields:Encodable {
        let method,path,requestID,bodySHA256,sessionID:String
        let activationEpoch:Int64
        let keyID,nonce:String
        let issuedAt:Int64
    }
    private struct PoP:Encodable { let keyID,nonce:String;let issuedAt:Int64;let signature:String }
    public func signedRequest(path:String,body:Data,requestID:String,method:String="POST") async throws -> AuthorityHTTPRequest {
        try AuthorityWire.identifier(requestID)
        guard ["POST","GET"].contains(method),body.count <= 16384,method != "GET" || body.isEmpty else { throw AuthorityError.invalidWire }
        let c=try await vault.credential(),date=now().timeIntervalSince1970
        guard date.isFinite,date>=0,date<9_007_199_254_740_991,Double(c.expiresAt)>date,
              c.keyID == (try AuthorityWire.deviceKeyID(publicKey:signer.publicKey)) else { throw AuthorityError.identityChanged }
        let fresh=nonce();try AuthorityWire.identifier(fresh)
        let fields=PoPFields(method:method,path:path,requestID:requestID,bodySHA256:AuthorityWire.hash(body),sessionID:c.sessionID,activationEpoch:c.activationEpoch,keyID:c.keyID,nonce:fresh,issuedAt:Int64(date))
        let signature=try await signer.sign(AuthorityWire.signedInput("football-record.device.pop.v1",body:AuthorityWire.encode(fields)))
        let proof=PoP(keyID:c.keyID,nonce:fresh,issuedAt:Int64(date),signature:AuthorityWire.base64URL(signature))
        return AuthorityHTTPRequest(method:method,path:path,body:body,authorization:"Bearer "+c.token,deviceProof:AuthorityWire.base64URL(try AuthorityWire.encode(proof)))
    }
    public func response(_ request:AuthorityHTTPRequest) async throws -> Data {
        let response=try await relay.send(request)
        guard response.status==200 else {
            if let failure=try? JSONDecoder().decode(AuthorityHTTPFailure.self,from:response.body) { throw failure };throw AuthorityError.unavailable
        };return response.body
    }
    public func signed(path:String,body:Data,requestID:String,method:String="POST") async throws -> Data {
        try await response(signedRequest(path:path,body:body,requestID:requestID,method:method))
    }
    public func unsigned(path:String,body:Data) async throws -> Data {
        guard ["/v1/auth/challenges","/v1/auth/apple","/v1/auth/recover","/v1/accounts/delete-status"].contains(path),body.count<=16384 else { throw AuthorityError.invalidWire }
        return try await response(AuthorityHTTPRequest(method:"POST",path:path,body:body))
    }
    public func send(_ intent:ControlIntentV1) async throws -> Data { try await signed(path:intent.operation.path,body:intent.canonicalRequest,requestID:intent.requestID) }
    public func query(requestID:String) async throws -> Data {
        try AuthorityWire.identifier(requestID);return try await signed(path:"/v1/requests/"+requestID,body:Data(),requestID:requestID,method:"GET")
    }
    public func liveStatus(_ query:LiveLockQueryV1,accountID:String) async throws -> VerifiedLiveLockV1 {
        let raw=try await signed(path:"/v1/locks/status",body:AuthorityWire.encode(query),requestID:query.requestID)
        return try VerifiedLiveLockV1.verify(raw,query:query,accountID:accountID,trust:trust,now:now())
    }
}

extension AuthorityOperation {
    public var path:String {
        switch self {
        case .acquire:return "/v1/locks/acquire"
        case .terminate:return "/v1/locks/terminate"
        case .authApple:return "/v1/auth/apple"
        case .registerWatch:return "/v1/devices/watches"
        case .prepareMigration:return "/v1/migrations/prepare"
        case .checkpointMigration:return "/v1/migrations/checkpoint"
        case .activateMigration:return "/v1/migrations/activate"
        case .requestLostMigration:return "/v1/migrations/lost"
        case .lostRecovery:return "/v1/migrations/lost-recovery"
        case .terminateLost:return "/v1/locks/terminate-lost"
        case .forceMigration:return "/v1/migrations/force"
        case .deleteAccount:return "/v1/accounts/delete"
        case .peerGrant:return "/v1/peers/grants"
        }
    }
}
