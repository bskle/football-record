import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
@testable import AccountKit

actor DropWatchMutationRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    var postDropped=false,queryDropped=false
    let dropPost:Bool
    init(_ upstream:any AuthorityHTTPRelay,dropPost:Bool){self.upstream=upstream;self.dropPost=dropPost}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {
        if dropPost,request.path=="/v1/devices/watches",!postDropped {postDropped=true;throw URLError(.networkConnectionLost)}
        let response=try await upstream.send(request)
        if !dropPost,request.method=="GET",response.status==200,!queryDropped {queryDropped=true;throw URLError(.networkConnectionLost)}
        return response
    }
}

actor WrongWatchCredentialRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    init(_ upstream:any AuthorityHTTPRelay){self.upstream=upstream}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {
        let response=try await upstream.send(request)
        guard request.path=="/v1/devices/watches",response.status==200,var object=try JSONSerialization.jsonObject(with:response.body) as? [String:Any],var credential=object["credential"] as? [String:Any] else {return response}
        credential["keyID"]=String(repeating:"f",count:64);object["credential"]=credential
        return AuthorityHTTPResponse(status:200,body:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]))
    }
}

final class WatchRegistrationTests:XCTestCase,@unchecked Sendable {
    struct WatchHarness {let repo:SQLiteSessionRepository;let session:MatchSession;let vault:any DeviceCredentialVault;let signer:DevelopmentDeviceSigner;let service:WatchRegistrationService;let root:URL}
    func watch(_ f:NodeAuthorityFixture,phone:PhoneWatchRegistrationService,root:URL?=nil,signer:DevelopmentDeviceSigner?=nil,vault suppliedVault:(any DeviceCredentialVault)?=nil,date suppliedDate:Date?=nil) async throws->WatchHarness {
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),signer=try signer ?? DevelopmentDeviceSigner(namespace:"watch-registration"),vault=suppliedVault ?? MemoryDeviceCredentialVault(),trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:[f.metadata.keyID:f.metadata.publicKey]),date=suppliedDate ?? Date(timeIntervalSince1970:Double(f.metadata.now))
        let repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"registration-watch",authorityTrust:trust),client=AuthorityClient(relay:try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),vault:vault,signer:signer,trust:trust,now:{date}),provider=AuthorityStartPermitProvider(client:client,repository:repo,now:{date})
        let session=MatchSession(store:repo,deviceIdentity:FixedIdentity(value:"client-watch"),clock:FixedClock(date:date),ids:UUIDSessionIDFactory(),permits:provider,workout:TrackingGateway(),environment:.development(databaseNamespace:"registration-watch")),service=WatchRegistrationService(client:client,repository:repo,coordinator:session,deviceID:"client-watch",cloudSpaceID:"fixture-cloud",authorizer:phone)
        try await provider.attach(session)
        try await service.admitCurrentIdentity(context:phone.registrationContext())
        return WatchHarness(repo:repo,session:session,vault:vault,signer:signer,service:service,root:root)
    }
    func phone(_ f:NodeAuthorityFixture,root:URL?=nil,relay:(any AuthorityHTTPRelay)?=nil) async throws->(HTTPAuthorityIntegrationTests.Harness,PhoneWatchRegistrationService) {
        let h=try await HTTPAuthorityIntegrationTests().harness(f,root:root,gateway:TrackingGateway())
        let client=AuthorityClient(relay:try relay ?? URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),vault:h.client.vault,signer:h.client.signer,trust:h.client.trust,now:{h.date}),service=PhoneWatchRegistrationService(client:client,repository:h.repo,coordinator:h.session)
        try await service.admitCurrentIdentity(accountID:f.metadata.credential.accountID)
        return (h,service)
    }
    func testRealWatchPossessionRegistrationInstallsOnlyWatchCredentialAndKeepsOriginalBytes() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let (p,phone)=try await phone(f),w=try await watch(f,phone:phone),phoneBefore=try await p.client.vault.credential()
        let registered=try await w.service.register(requestID:"watch-registration",challengeRequestID:"watch-challenge")
        XCTAssertEqual(registered.binding.role,.watch);XCTAssertEqual(registered.binding.deviceID,"client-watch")
        let watchCredential=try await w.vault.credential(),phoneAfter=try await p.client.vault.credential();XCTAssertEqual(watchCredential.deviceID,"client-watch");XCTAssertTrue(phoneBefore==phoneAfter)
        let original=try await w.repo.watchRegistrationAttemptV4(requestID:"watch-registration"),phoneAttempt=try await p.repo.watchRegistrationAttemptV4(requestID:"watch-registration");XCTAssertTrue(original==phoneAttempt)
        let recovered=try await w.service.recover(requestID:"watch-registration");XCTAssertEqual(recovered.receipt.raw,registered.receipt.raw)
        let same=try await w.vault.credential();XCTAssertTrue(same==watchCredential)
        let start=try await w.session.prepareStart(starter:true);_=try await w.session.execute(start);try await waitForCapture(w.repo,matchID:start.matchID)
        let facts=try await w.repo.snapshotV2(matchID:start.matchID);XCTAssertEqual(facts.business.descriptor.recordingDeviceID,"client-watch");XCTAssertFalse(facts.business.events.isEmpty)
        try await w.repo.close();try await p.repo.close()
        for root in [w.root,p.root] {for file in FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? [] where !file.hasDirectoryPath {let bytes=try Data(contentsOf:file);XCTAssertNil(bytes.range(of:Data(watchCredential.token.utf8)),"Watch credential cannot be persisted in a business DB")}}
    }
    func testCommitLostReopenRecoversOriginalWatchIDAndRejectsWrongKeyOrNewUnknownID() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let (p,phone)=try await phone(f),w=try await watch(f,phone:phone)
        _=try f.command(["op":"fault","value":"registerWatch"])
        do {_=try await w.service.register(requestID:"watch-lost",challengeRequestID:"watch-lost-challenge");XCTFail()}catch{}
        do {_=try await w.service.register(requestID:"watch-forbidden-new",challengeRequestID:"watch-forbidden-challenge");XCTFail()}catch{}
        let pending=try await w.repo.pendingWatchRegistrationAttemptsV4();XCTAssertEqual(pending.map(\.requestID),["watch-lost"])
        try await w.repo.close();try await p.repo.close();_=try f.command(["op":"fault","value":NSNull()])
        let (reopened,phoneAgain)=try await self.phone(f,root:p.root)
        do {_=try await watch(f,phone:phoneAgain,root:w.root);XCTFail("an existing attempt cannot replace its Watch key")}catch{}
        let after=try await watch(f,phone:phoneAgain,root:w.root,signer:w.signer),result=try await after.service.recover(requestID:"watch-lost")
        XCTAssertEqual(result.binding.deviceID,"client-watch");let credential=try await after.vault.credential();XCTAssertEqual(credential.keyID,try AuthorityWire.deviceKeyID(publicKey:w.signer.publicKey))
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT count(*) AS n FROM sessions WHERE device_id='client-watch'"])["rows"] as? [[String:Any]]);XCTAssertEqual(rows.first?["n"] as? Int,1)
        try await after.repo.close();try await reopened.repo.close()
    }
    func testLateRegistrationCannotCrossWatchOrPhoneIdentityGeneration() async throws {
        for phoneChanges in [false,true] {
            let f=try NodeAuthorityFixture();defer {f.close()};let gate=GatedAuthResponseRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),path:"/v1/devices/watches"),(p,phone)=try await self.phone(f,relay:gate),w=try await watch(f,phone:phone)
            let task=Task {try await w.service.register(requestID:"watch-late",challengeRequestID:"watch-late-challenge")}
            let deadline=Date().addingTimeInterval(3)
            while !(await gate.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
            let entered=await gate.entered;XCTAssertTrue(entered)
            if phoneChanges {try await p.session.suspendAccount();try await p.client.vault.advanceIdentityFence(to:p.repo.identityGenerationV4())}
            else {try await w.session.suspendAccount();try await w.vault.advanceIdentityFence(to:w.repo.identityGenerationV4())}
            await gate.release();do {_=try await task.value;XCTFail("old registration callback cannot install a credential")}catch{}
            let binding=try await w.repo.accountBindingV4();XCTAssertTrue(binding==nil || binding?.suspended==true)
            do {_=try await w.vault.credential();XCTFail()}catch{}
            try await w.repo.close();try await p.repo.close()
        }
    }
    func testNotSubmittedAndLostOriginalQueryRemainPendingUntilSameBodyRecovery() async throws {
        for dropPost in [false,true] {
            let f=try NodeAuthorityFixture();defer {f.close()};let relay=DropWatchMutationRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),dropPost:dropPost),(p,phone)=try await self.phone(f,relay:relay),w=try await watch(f,phone:phone)
            if !dropPost {_=try f.command(["op":"fault","value":"registerWatch"])}
            do {_=try await w.service.register(requestID:"watch-unknown",challengeRequestID:"watch-unknown-challenge");XCTFail()}catch{}
            _=try f.command(["op":"fault","value":NSNull()])
            if !dropPost {do {_=try await w.service.recover(requestID:"watch-unknown");XCTFail("GET response was lost")}catch{}}
            do {_=try await w.service.register(requestID:"watch-new-forbidden",challengeRequestID:"watch-new-forbidden-challenge");XCTFail()}catch{}
            let pending=try await w.repo.pendingWatchRegistrationAttemptsV4();XCTAssertEqual(pending.map(\.requestID),["watch-unknown"])
            let result=try await w.service.recover(requestID:"watch-unknown");XCTAssertEqual(result.binding.role,.watch)
            let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT count(*) AS n FROM sessions WHERE device_id='client-watch'"])["rows"] as? [[String:Any]]);XCTAssertEqual(rows.first?["n"] as? Int,1)
            try await w.repo.close();try await p.repo.close()
        }
    }
    func testWatchVaultWriteDelayedAfterStoreCannotCrossIdentityFence() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let (p,phone)=try await self.phone(f),vault=GatedCredentialVault(),w=try await watch(f,phone:phone,vault:vault)
        let task=Task {try await w.service.register(requestID:"watch-vault-late",challengeRequestID:"watch-vault-late-challenge")}
        let deadline=Date().addingTimeInterval(3)
        while !(await vault.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let entered=await vault.entered;XCTAssertTrue(entered)
        try await w.session.suspendAccount();try await vault.advanceIdentityFence(to:w.repo.identityGenerationV4());await vault.release()
        do {_=try await task.value;XCTFail()}catch{}
        do {_=try await vault.credential();XCTFail()}catch{}
        let binding=try await w.repo.accountBindingV4();XCTAssertEqual(binding?.suspended,true)
        try await w.repo.close();try await p.repo.close()
    }

    func testConfirmedExpiredOriginalRegistrationAllowsOnlyExplicitFreshChallengeAndID() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let (p,phone)=try await self.phone(f),w=try await watch(f,phone:phone)
        _=try f.command(["op":"fault","value":"registerWatch"])
        do {_=try await w.service.register(requestID:"watch-expiring",challengeRequestID:"watch-expiring-challenge");XCTFail()}catch{}
        _=try f.command(["op":"fault","value":NSNull()])
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT expires_at,session_id FROM sessions WHERE device_id='client-watch'"])["rows"] as? [[String:Any]]),expires=try XCTUnwrap(rows.first?["expires_at"] as? Int64),oldSession=try XCTUnwrap(rows.first?["session_id"] as? String),date=Date(timeIntervalSince1970:Double(expires+1));_=try f.command(["op":"clock","now":expires+1]);try await w.repo.close()
        let client=AuthorityClient(relay:p.client.relay,vault:p.client.vault,signer:p.client.signer,trust:p.client.trust,now:{date}),auth=AccountService(client:client,repository:p.repo,coordinator:p.session,deviceID:f.metadata.credential.deviceID,cloudSpaceID:"fixture-cloud",apple:FixtureAppleSignIn(f,subject:"fixture-subject-never-stored"))
        try await auth.admitCurrentIdentity(accountID:f.metadata.credential.accountID);_=try await auth.signIn(requestID:"phone-renewal",challengeRequestID:"phone-renewal-challenge")
        let freshPhone=PhoneWatchRegistrationService(client:client,repository:p.repo,coordinator:p.session);try await freshPhone.admitCurrentIdentity(accountID:f.metadata.credential.accountID)
        let after=try await watch(f,phone:freshPhone,root:w.root,signer:w.signer,date:date)
        do {_=try await after.service.recover(requestID:"watch-expiring");XCTFail()}catch {XCTAssertEqual(error as? AuthorityError,.staleAttestation)}
        let pending=try await after.repo.pendingWatchRegistrationAttemptsV4();XCTAssertTrue(pending.isEmpty,"a verified committed but expired original is known, not an unresolved attempt")
        let fresh=try await after.service.register(requestID:"watch-explicit-fresh",challengeRequestID:"watch-explicit-fresh-challenge");XCTAssertEqual(fresh.binding.role,.watch)
        let current=try await after.vault.credential();XCTAssertTrue(current.sessionID != oldSession)
        try await after.repo.close();try await p.repo.close()
    }

    func testActualRegistrationResponseWithWrongWatchCredentialKeyCannotInstallOrOverwritePhone() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let relay=WrongWatchCredentialRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development)),(p,phone)=try await self.phone(f,relay:relay),w=try await watch(f,phone:phone),before=try await p.client.vault.credential()
        do {_=try await w.service.register(requestID:"watch-wrong-credential",challengeRequestID:"watch-wrong-credential-challenge");XCTFail()}catch{}
        do {_=try await w.vault.credential();XCTFail()}catch{}
        let binding=try await w.repo.accountBindingV4(),after=try await p.client.vault.credential(),pending=try await w.repo.pendingWatchRegistrationAttemptsV4();XCTAssertNil(binding);XCTAssertTrue(before==after);XCTAssertEqual(pending.map(\.requestID),["watch-wrong-credential"])
        let good=PhoneWatchRegistrationService(client:p.client,repository:p.repo,coordinator:p.session);try await good.admitCurrentIdentity(accountID:f.metadata.credential.accountID)
        try await w.repo.close();let recovered=try await watch(f,phone:good,root:w.root,signer:w.signer);_=try await recovered.service.recover(requestID:"watch-wrong-credential")
        let credential=try await recovered.vault.credential();XCTAssertEqual(credential.keyID,try AuthorityWire.deviceKeyID(publicKey:w.signer.publicKey))
        try await recovered.repo.close();try await p.repo.close()
    }

}
