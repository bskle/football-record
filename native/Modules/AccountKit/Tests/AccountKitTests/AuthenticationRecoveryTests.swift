import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import AccountKit
actor DropBeforeAuthRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    var original:AuthorityHTTPRequest?
    init(_ upstream:any AuthorityHTTPRelay){self.upstream=upstream}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {if request.path=="/v1/auth/apple",original==nil {original=request;throw URLError(.networkConnectionLost)};return try await upstream.send(request)}
}
actor FixtureAppleSignIn:AppleSignInDriver {
    let fixture:NodeAuthorityFixture,subject:String
    var lastToken:String?
    var failBeforeCommit=false
    func failNextAuthCommit(){failBeforeCommit=true}
    init(_ fixture:NodeAuthorityFixture,subject:String="new-auth-subject"){self.fixture=fixture;self.subject=subject}
    func authorize(nonceSHA256:String) async throws->AppleAuthorization {
        let response=try fixture.command(["op":"apple","nonce":nonceSHA256,"subject":subject]);let token=try XCTUnwrap(response["identityToken"] as? String);lastToken=token
        if failBeforeCommit {failBeforeCommit=false;_=try fixture.command(["op":"databaseFault","value":true])}
        return AppleAuthorization(identityToken:token,authorizationCode:response["authorizationCode"] as? String ?? "client-transient-code-never-durable")
    }
}
final class AuthenticationRecoveryTests:XCTestCase,@unchecked Sendable {
    struct Harness {let repo:SQLiteSessionRepository;let service:AccountService;let vault:MemoryDeviceCredentialVault;let signer:DevelopmentDeviceSigner;let session:MatchSession;let apple:FixtureAppleSignIn;let root:URL;let client:AuthorityClient}
    func harness(_ f:NodeAuthorityFixture,root:URL?=nil,signer:DevelopmentDeviceSigner?=nil,subject:String="new-auth-subject",now:Date?=nil,deviceID:String="new-client",relay:(any AuthorityHTTPRelay)?=nil) async throws->Harness {
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),date=now ?? Date(timeIntervalSince1970:Double(f.metadata.now))
        let signer=try signer ?? DevelopmentDeviceSigner(namespace:"auth-tests"),vault=MemoryDeviceCredentialVault(),apple=FixtureAppleSignIn(f,subject:subject)
        let trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:[f.metadata.keyID:f.metadata.publicKey]),repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"auth-session",authorityTrust:trust,cloudSavePolicy:.development(databaseNamespace:"auth-session"))
        let client=AuthorityClient(relay:try relay ?? URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),vault:vault,signer:signer,trust:trust,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:deviceID),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"auth-session"))
        let service=AccountService(client:client,repository:repo,coordinator:session,deviceID:deviceID,cloudSpaceID:"fixture-cloud",apple:apple)
        return Harness(repo:repo,service:service,vault:vault,signer:signer,session:session,apple:apple,root:root,client:client)
    }
    func testRealAppleChallengeProofAndAuthRecoverUseOriginalCanonicalDigestWithoutPersistingSecrets() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        let first=try await h.service.signIn(requestID:"client-auth",challengeRequestID:"client-challenge")
        XCTAssertEqual(first.binding.role,.phone);let credential=try await h.vault.credential()
        try await h.repo.close()
        let after=try await harness(f,root:h.root,signer:h.signer)
        guard case .authenticated(let recovered)=try await after.service.recover(authRequestID:"client-auth") else {return XCTFail()}
        XCTAssertEqual(recovered.receipt.raw,first.receipt.raw);let same=try await after.vault.credential();XCTAssertEqual(same,credential)
        let attempt=try await after.repo.authAttemptV4(requestID:"client-auth");XCTAssertEqual(attempt?.publicKey,h.signer.publicKey)
        let lastToken=await h.apple.lastToken,jwt=try XCTUnwrap(lastToken);try await after.repo.close()
        for url in (FileManager.default.enumerator(at:h.root,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []) where !url.hasDirectoryPath {
            let bytes=try Data(contentsOf:url);for secret in [jwt,"client-transient-code-never-durable",credential.token] {XCTAssertNil(bytes.range(of:Data(secret.utf8)))}
        }
    }
    func testAuthCOMMITLostResponseReopensByOriginalRequestAndKeyWithoutNewChallenge() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        _=try f.command(["op":"fault","value":"authenticate"])
        do {_=try await h.service.signIn(requestID:"lost-auth",challengeRequestID:"lost-challenge");XCTFail()}catch{}
        let saved=try await h.repo.authAttemptV4(requestID:"lost-auth");XCTAssertNotNil(saved);try await h.repo.close()
        _=try f.command(["op":"fault","value":NSNull()]);let after=try await harness(f,root:h.root,signer:h.signer)
        guard case .authenticated=try await after.service.recover(authRequestID:"lost-auth") else {return XCTFail()}
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT auth_request_id FROM auth_records WHERE auth_request_id='lost-auth'"])["rows"] as? [[String:Any]])
        XCTAssertEqual(rows.count,1)
        try await after.repo.close()
        let wrong=try await harness(f,root:h.root)
        do {_=try await wrong.service.recover(authRequestID:"lost-auth");XCTFail()}catch{}
    }
    func testUnknownUncommittedAuthDoesNotSilentlyCreateNewRequestOrConsumeAnotherChallenge() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        await h.apple.failNextAuthCommit()
        do {_=try await h.service.signIn(requestID:"uncommitted-auth",challengeRequestID:"uncommitted-challenge");XCTFail()}catch{}
        _=try f.command(["op":"databaseFault","value":false])
        _=try f.command(["op":"fault","value":"recover"])
        guard case .unresolved=try await h.service.recover(authRequestID:"uncommitted-auth") else {return XCTFail()}
        do {_=try await h.service.signIn(requestID:"must-not-switch",challengeRequestID:"must-not-consume");XCTFail("unknown original result requires reconciliation before a new auth ID")}catch{}
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT auth_request_id FROM auth_records WHERE auth_request_id='must-not-switch'"])["rows"] as? [[String:Any]])
        XCTAssertTrue(rows.isEmpty)
        _=try f.command(["op":"fault","value":NSNull()])
        guard case .knownAbandoned=try await h.service.recover(authRequestID:"uncommitted-auth") else {return XCTFail("fresh possession proof must permanently abandon only this original tuple")}
        try await h.repo.close();let after=try await harness(f,root:h.root,signer:h.signer)
        let fresh=try await after.service.signIn(requestID:"explicit-new-auth",challengeRequestID:"explicit-new-challenge");XCTAssertEqual(fresh.binding.role,.phone)

    }

    func testNotSentAuthAbandonsOriginalTupleAndLateOriginalBytesCannotCommit() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()}
        let upstream=try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),drop=DropBeforeAuthRelay(upstream),h=try await harness(f,relay:drop)
        do {_=try await h.service.signIn(requestID:"not-sent",challengeRequestID:"not-sent-challenge");XCTFail()}catch{}
        guard case .knownAbandoned=try await h.service.recover(authRequestID:"not-sent") else {return XCTFail()}
        let originalValue=await drop.original,original=try XCTUnwrap(originalValue),late=try await upstream.send(original);XCTAssertEqual(late.status,401)
        let wrong=try await harness(f,root:h.root);do {_=try await wrong.service.recover(authRequestID:"not-sent");XCTFail()}catch{}
        let pending=try await h.repo.pendingAuthAttemptsV4();XCTAssertTrue(pending.isEmpty)
        let fresh=try await h.service.signIn(requestID:"not-sent-explicit-fresh",challengeRequestID:"not-sent-fresh-challenge");XCTAssertEqual(fresh.binding.role,.phone)
    }
    func testKnownExpiredAllowsExplicitFreshAppleFlowWithOriginalDeviceKey() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        _=try await h.service.signIn(requestID:"expire-original",challengeRequestID:"expire-original-challenge")
        let credential=try await h.vault.credential();try await h.repo.close();_=try f.command(["op":"clock","now":credential.expiresAt+1])
        let after=try await harness(f,root:h.root,signer:h.signer,now:Date(timeIntervalSince1970:Double(credential.expiresAt+1)))
        guard case .knownExpired=try await after.service.recover(authRequestID:"expire-original") else {return XCTFail()}
        let fresh=try await after.service.signIn(requestID:"expire-explicit-fresh",challengeRequestID:"expire-fresh-challenge");XCTAssertEqual(fresh.binding.deviceID,credential.deviceID)
    }

}
