import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import AccountKit
actor FixtureAppleSignIn:AppleSignInDriver {
    let fixture:NodeAuthorityFixture,subject:String
    var lastToken:String?
    init(_ fixture:NodeAuthorityFixture,subject:String="new-auth-subject"){self.fixture=fixture;self.subject=subject}
    func authorize(nonceSHA256:String) async throws->AppleAuthorization {
        let response=try fixture.command(["op":"apple","nonce":nonceSHA256,"subject":subject]);let token=try XCTUnwrap(response["identityToken"] as? String);lastToken=token
        return AppleAuthorization(identityToken:token,authorizationCode:"client-transient-code-never-durable")
    }
}
final class AuthenticationRecoveryTests:XCTestCase,@unchecked Sendable {
    struct Harness {let repo:SQLiteSessionRepository;let service:AccountService;let vault:MemoryDeviceCredentialVault;let signer:DevelopmentDeviceSigner;let session:MatchSession;let apple:FixtureAppleSignIn;let root:URL}
    func harness(_ f:NodeAuthorityFixture,root:URL?=nil,signer:DevelopmentDeviceSigner?=nil,subject:String="new-auth-subject",now:Date?=nil) async throws->Harness {
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),date=now ?? Date(timeIntervalSince1970:Double(f.metadata.now))
        let signer=try signer ?? DevelopmentDeviceSigner(namespace:"auth-tests"),vault=MemoryDeviceCredentialVault(),apple=FixtureAppleSignIn(f,subject:subject)
        let trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:[f.metadata.keyID:f.metadata.publicKey]),repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"auth-session",authorityTrust:trust)
        let client=AuthorityClient(relay:try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),vault:vault,signer:signer,trust:trust,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:"new-client"),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:"auth-session"))
        let service=AccountService(client:client,repository:repo,coordinator:session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:apple)
        return Harness(repo:repo,service:service,vault:vault,signer:signer,session:session,apple:apple,root:root)
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
}
