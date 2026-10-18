import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import CloudSync
@testable import AccountKit
actor DropBeforeAuthRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    var original:AuthorityHTTPRequest?
    init(_ upstream:any AuthorityHTTPRelay){self.upstream=upstream}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {if request.path=="/v1/auth/apple",original==nil {original=request;throw URLError(.networkConnectionLost)};return try await upstream.send(request)}
}
actor RecoverNotFoundRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    init(_ upstream:any AuthorityHTTPRelay){self.upstream=upstream}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {if request.path=="/v1/auth/recover" {return try await upstream.send(AuthorityHTTPRequest(method:"POST",path:"/v1/unknown-recovery-route",body:request.body))};return try await upstream.send(request)}
}
actor GatedAppleSignIn:AppleSignInDriver {
    let fixture:NodeAuthorityFixture
    var gates:[Int:CheckedContinuation<Void,Never>]=[:]
    var count=0
    init(_ fixture:NodeAuthorityFixture){self.fixture=fixture}
    func authorize(nonceSHA256:String) async throws->AppleAuthorization {
        let index=count;count += 1
        await withCheckedContinuation {gates[index]=$0}
        let value=try fixture.command(["op":"apple","nonce":nonceSHA256,"subject":"concurrent-subject"])
        return AppleAuthorization(identityToken:try XCTUnwrap(value["identityToken"] as? String),authorizationCode:"transient-only")
    }
    func release(_ index:Int){gates.removeValue(forKey:index)?.resume()}
}
actor GatedAuthResponseRelay:AuthorityHTTPRelay {
    let upstream:any AuthorityHTTPRelay
    let path:String
    var entered=false
    var gate:CheckedContinuation<Void,Never>?
    init(_ upstream:any AuthorityHTTPRelay,path:String){self.upstream=upstream;self.path=path}
    func send(_ request:AuthorityHTTPRequest) async throws->AuthorityHTTPResponse {
        let response=try await upstream.send(request)
        if request.path==path,!entered {entered=true;await withCheckedContinuation {gate=$0}}
        return response
    }
    func release(){gate?.resume();gate=nil}
}
actor GatedCredentialVault:DeviceCredentialVault {
    let inner=MemoryDeviceCredentialVault()
    var entered=false
    var gate:CheckedContinuation<Void,Never>?
    func credential() async throws->DeviceCredential {try await inner.credential()}
    func advanceIdentityFence(to generation:Int64) async throws {try await inner.advanceIdentityFence(to:generation)}
    func replace(_ value:DeviceCredential?,expectedIdentityGeneration:Int64) async throws {
        if !entered {entered=true;await withCheckedContinuation {gate=$0}}
        try await inner.replace(value,expectedIdentityGeneration:expectedIdentityGeneration)
    }
    func release(){gate?.resume();gate=nil}
}
actor GatedTerminalCoordinator:AccountLifecycleCoordinator,LifecycleInboundCoordinator {
    let base:MatchSession
    var entered=false
    var gate:CheckedContinuation<Void,Never>?
    init(_ base:MatchSession){self.base=base}
    func hold() async {entered=true;await withCheckedContinuation {gate=$0}}
    func release(){gate?.resume();gate=nil}
    func syncRepositoryIdentity() async->SyncRepositoryIdentity {await base.syncRepositoryIdentity()}
    func resolveAuthAttempt(requestID:String,resolution:AuthResolutionV4) async throws {try await base.resolveAuthAttempt(requestID:requestID,resolution:resolution)}
    func saveAuthAttempt(_ attempt:AuthAttemptV4,expectedIdentityGeneration:Int64) async throws {try await base.saveAuthAttempt(attempt,expectedIdentityGeneration:expectedIdentityGeneration)}
    func acceptAuthentication(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64) async throws {try await base.acceptAuthentication(attempt:attempt,binding:binding,receipt:receipt,expectedIdentityGeneration:expectedIdentityGeneration)}
    func resolveTerminalAuthentication(requestID:String,resolution:AuthResolutionV4,expectedIdentityGeneration:Int64) async throws->Int64? {await hold();return try await base.resolveTerminalAuthentication(requestID:requestID,resolution:resolution,expectedIdentityGeneration:expectedIdentityGeneration)}
    func suspendAccount() async throws {await hold();try await base.suspendAccount()}
    func prepareLifecycleControl(_ intent:ControlIntentV1) async throws->ControlIntentReceiptV4 {try await base.prepareLifecycleControl(intent)}
    func acceptMigrationCheckpoint(migrationID:String,proof:VerifiedAccountCheckpointV4) async throws {try await base.acceptMigrationCheckpoint(migrationID:migrationID,proof:proof)}
    func acceptLifecycleResult(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1) async throws {try await base.acceptLifecycleResult(intent:intent,receipt:receipt)}
    func createDeletionSaga(_ saga:DeletionSagaV4) async throws {try await base.createDeletionSaga(saga)}
    func updateDeletionSaga(_ saga:DeletionSagaV4,expectedRevision:Int64) async throws {try await base.updateDeletionSaga(saga,expectedRevision:expectedRevision)}
    func acceptDeletion(requestID:String,receipt:VerifiedAuthorityReceiptV1,expectedRevision:Int64) async throws->DeletionSagaV4 {try await base.acceptDeletion(requestID:requestID,receipt:receipt,expectedRevision:expectedRevision)}
    func eraseLocalBusiness(requestID:String,expectedRevision:Int64) async throws->DeletionSagaV4 {try await base.eraseLocalBusiness(requestID:requestID,expectedRevision:expectedRevision)}
    func setAnalyticsEnabled(_ enabled:Bool) async throws {try await base.setAnalyticsEnabled(enabled)}
    func enqueueAnalytics(_ event:AnalyticsEventV4) async throws {try await base.enqueueAnalytics(event)}
    func acknowledgeAnalytics(requestID:String) async throws {try await base.acknowledgeAnalytics(requestID:requestID)}
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
        try await service.admitCurrentIdentity(accountID:try await repo.accountBindingV4()?.accountID)
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
        do {let wrong=try await harness(f,root:h.root);_=try await wrong.service.recover(authRequestID:"lost-auth");XCTFail()}catch{}
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
        do {let wrong=try await harness(f,root:h.root);_=try await wrong.service.recover(authRequestID:"not-sent");XCTFail()}catch{}
        let pending=try await h.repo.pendingAuthAttemptsV4();XCTAssertTrue(pending.isEmpty)
        let fresh=try await h.service.signIn(requestID:"not-sent-explicit-fresh",challengeRequestID:"not-sent-fresh-challenge");XCTAssertEqual(fresh.binding.role,.phone)
    }
    func testKnownExpiredAllowsExplicitFreshAppleFlowWithOriginalDeviceKey() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        _=try await h.service.signIn(requestID:"expire-original",challengeRequestID:"expire-original-challenge")
        let credential=try await h.vault.credential();try await h.repo.close();_=try f.command(["op":"clock","now":credential.expiresAt+1])
        let after=try await harness(f,root:h.root,signer:h.signer,now:Date(timeIntervalSince1970:Double(credential.expiresAt+1)))
        guard case .knownExpired=try await after.service.recover(authRequestID:"expire-original") else {return XCTFail()}
        try await after.service.admitCurrentIdentity(accountID:try await after.repo.accountBindingV4()?.accountID)
        let fresh=try await after.service.signIn(requestID:"expire-explicit-fresh",challengeRequestID:"expire-fresh-challenge");XCTAssertEqual(fresh.binding.deviceID,credential.deviceID)
    }

    func testHTTP404RecoveryRemainsUnknownAfterReopenAndCannotAuthorizeAnotherID() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
        _=try f.command(["op":"fault","value":"authenticate"])
        do {_=try await h.service.signIn(requestID:"unknown-404",challengeRequestID:"unknown-404-challenge");XCTFail()}catch{}
        _=try f.command(["op":"fault","value":NSNull()]);try await h.repo.close()
        let relay=RecoverNotFoundRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development)),after=try await harness(f,root:h.root,signer:h.signer,relay:relay)
        guard case .unresolved=try await after.service.recover(authRequestID:"unknown-404") else {return XCTFail("404 has no permanent fence")}
        try await after.repo.close();let reopened=try await harness(f,root:h.root,signer:h.signer)
        do {_=try await reopened.service.signIn(requestID:"forbidden-after-404",challengeRequestID:"forbidden-404-challenge");XCTFail()}catch{}
        let pending=try await reopened.repo.pendingAuthAttemptsV4();XCTAssertEqual(pending.map(\.requestID),["unknown-404"])
    }
    func testConcurrentAppleAwaitsAdmitOnlyOneUnresolvedAttemptInFileTransaction() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f),apple=GatedAppleSignIn(f)
        let service=AccountService(client:h.client,repository:h.repo,coordinator:h.session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:apple)
        try await service.admitCurrentIdentity(accountID:nil)
        _=try f.command(["op":"fault","value":"authenticate"])
        let first=Task {try await service.signIn(requestID:"concurrent-A",challengeRequestID:"concurrent-challenge-A")}
        while await apple.count<1 {await Task.yield()}
        let second=Task {try await service.signIn(requestID:"concurrent-B",challengeRequestID:"concurrent-challenge-B")}
        while await apple.count<2 {await Task.yield()}
        await apple.release(0);do {_=try await first.value;XCTFail()}catch{}
        await apple.release(1);do {_=try await second.value;XCTFail()}catch{}
        let rows=try XCTUnwrap(f.command(["op":"inspect","sql":"SELECT auth_request_id FROM auth_records WHERE auth_request_id LIKE 'concurrent-%' ORDER BY auth_request_id"])["rows"] as? [[String:Any]])
        XCTAssertEqual(rows.compactMap{$0["auth_request_id"] as? String},["concurrent-A"])
        try await h.repo.close();let after=try await harness(f,root:h.root,signer:h.signer),pending=try await after.repo.pendingAuthAttemptsV4();XCTAssertEqual(pending.map(\.requestID),["concurrent-A"])
    }

    func testLateAuthAndRecoverResponsesCannotUndoCompletedIdentityFenceOrRestoreVault() async throws {
        for recovery in [false,true] {
            let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f)
            if recovery {_=try await h.service.signIn(requestID:"fenced-auth",challengeRequestID:"fenced-auth-challenge")}
            let gate=GatedAuthResponseRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),path:recovery ? "/v1/auth/recover":"/v1/auth/apple")
            let client=AuthorityClient(relay:gate,vault:h.vault,signer:h.signer,trust:h.client.trust,now:{Date(timeIntervalSince1970:Double(f.metadata.now))}),service=AccountService(client:client,repository:h.repo,coordinator:h.session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:h.apple)
            try await service.admitCurrentIdentity(accountID:try await h.repo.accountBindingV4()?.accountID)
            let task=Task {if recovery {_=try await service.recover(authRequestID:"fenced-auth")}else {_=try await service.signIn(requestID:"fenced-auth",challengeRequestID:"fenced-auth-challenge")}}
            let deadline=Date().addingTimeInterval(3)
            while !(await gate.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
            let entered=await gate.entered;XCTAssertTrue(entered)
            let scope=try CloudBridgeTests().scope(f),ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("identity-cloud.sqlite")),lifecycle=LifecycleService(client:client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
            try await lifecycle.identityChanged();await gate.release()
            do {try await task.value;XCTFail("old callback must fail after the identity fence")}catch{}
            let binding=try await h.repo.accountBindingV4();XCTAssertTrue(binding==nil || binding?.suspended==true)
            do {_=try await h.vault.credential();XCTFail("old callback cannot restore a cleared credential")}catch{}
            do {_=try await service.recover(authRequestID:"fenced-auth");XCTFail("the old service cannot automatically renew its own admission")}catch{}
            let freshService=AccountService(client:h.client,repository:h.repo,coordinator:h.session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:h.apple)
            try await freshService.admitCurrentIdentity(accountID:binding?.accountID)
            guard case .authenticated=try await freshService.recover(authRequestID:"fenced-auth") else {return XCTFail()}
            let fresh=try await freshService.signIn(requestID:"fenced-explicit-fresh",challengeRequestID:"fenced-explicit-challenge");XCTAssertFalse(fresh.binding.suspended)
            try await ledger.close()
        }
    }

    func testVaultWriteDelayedAfterSQLCannotCrossTheCompletedIdentityFence() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let h=try await harness(f),vault=GatedCredentialVault()
        let client=AuthorityClient(relay:try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),vault:vault,signer:h.signer,trust:h.client.trust,now:{Date(timeIntervalSince1970:Double(f.metadata.now))}),service=AccountService(client:client,repository:h.repo,coordinator:h.session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:h.apple)
        try await service.admitCurrentIdentity()
        let pending=Task {try await service.signIn(requestID:"vault-late",challengeRequestID:"vault-late-challenge")}
        let deadline=Date().addingTimeInterval(3)
        while !(await vault.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let entered=await vault.entered;XCTAssertTrue(entered)
        let scope=try CloudBridgeTests().scope(f),ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("vault-cloud.sqlite")),lifecycle=LifecycleService(client:client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        try await lifecycle.identityChanged();await vault.release()
        do {_=try await pending.value;XCTFail()}catch{}
        do {_=try await vault.credential();XCTFail()}catch{}
        let binding=try await h.repo.accountBindingV4();XCTAssertEqual(binding?.suspended,true)
        try await ledger.close()
    }

    func testOldTerminalRecoveryCannotSuspendFreshAuthenticationCommittedDuringItsAwait() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let original=try await harness(f)
        _=try await original.service.signIn(requestID:"terminal-A",challengeRequestID:"terminal-A-challenge")
        let old=try await original.vault.credential();try await original.repo.close();_=try f.command(["op":"clock","now":old.expiresAt+1])
        let h=try await harness(f,root:original.root,signer:original.signer,now:Date(timeIntervalSince1970:Double(old.expiresAt+1))),gate=GatedTerminalCoordinator(h.session),service=AccountService(client:h.client,repository:h.repo,coordinator:gate,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:h.apple)
        try await service.admitCurrentIdentity(accountID:try await h.repo.accountBindingV4()?.accountID)
        let pending=Task {try await service.recover(authRequestID:"terminal-A")}
        let deadline=Date().addingTimeInterval(3)
        while !(await gate.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let entered=await gate.entered;XCTAssertTrue(entered)
        let fresh=try await h.service.signIn(requestID:"fresh-B",challengeRequestID:"fresh-B-challenge"),credential=try await h.vault.credential()
        await gate.release();_=try await pending.value
        let binding=try await h.repo.accountBindingV4(),current=try? await h.vault.credential(),generation=try await h.repo.identityGenerationV4()
        XCTAssertEqual(binding,fresh.binding);XCTAssertTrue(current==credential,"the current credential must remain");XCTAssertEqual(generation,0)
        try await h.repo.close();let after=try await harness(f,root:h.root,signer:h.signer,now:Date(timeIntervalSince1970:Double(old.expiresAt+1))),persisted=try await after.repo.accountBindingV4();XCTAssertEqual(persisted,fresh.binding)
    }

    func testOldTerminalResponseCannotBorrowExplicitNewAdmissionWhileFreshAuthIsPending() async throws {
        let f=try NodeAuthorityFixture();defer {f.close()};let original=try await harness(f)
        _=try await original.service.signIn(requestID:"generation-A",challengeRequestID:"generation-A-challenge")
        let old=try await original.vault.credential();try await original.repo.close();_=try f.command(["op":"clock","now":old.expiresAt+1])
        let h=try await harness(f,root:original.root,signer:original.signer,now:Date(timeIntervalSince1970:Double(old.expiresAt+1)))
        let freshGate=GatedAuthResponseRelay(try URLSessionAuthorityRelay(baseURL:URL(string:f.metadata.baseURL)!,environment:.development),path:"/v1/auth/apple"),oldGate=GatedAuthResponseRelay(freshGate,path:"/v1/auth/recover")
        let client=AuthorityClient(relay:oldGate,vault:h.vault,signer:h.signer,trust:h.client.trust,now:{Date(timeIntervalSince1970:Double(old.expiresAt+1))}),service=AccountService(client:client,repository:h.repo,coordinator:h.session,deviceID:"new-client",cloudSpaceID:"fixture-cloud",apple:h.apple)
        let accountID=try await h.repo.accountBindingV4()?.accountID
        try await service.admitCurrentIdentity(accountID:accountID)
        let pendingOld=Task {try await service.recover(authRequestID:"generation-A")}
        var deadline=Date().addingTimeInterval(3)
        while !(await oldGate.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let oldEntered=await oldGate.entered;XCTAssertTrue(oldEntered)
        let ledger=try SQLiteCloudLedger(url:h.root.appendingPathComponent("generation-cloud.sqlite")),scope=try CloudBridgeTests().scope(f),lifecycle=LifecycleService(client:client,repository:h.repo,coordinator:h.session,scope:scope,ledger:ledger)
        try await lifecycle.identityChanged()
        try await service.admitCurrentIdentity(accountID:accountID)
        let pendingFresh=Task {try await service.signIn(requestID:"generation-B",challengeRequestID:"generation-B-challenge")}
        deadline=Date().addingTimeInterval(3)
        while !(await freshGate.entered),Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        let freshEntered=await freshGate.entered;XCTAssertTrue(freshEntered)
        let pending=try await h.repo.pendingAuthAttemptsV4();XCTAssertEqual(pending.map(\.requestID),["generation-B"])
        await oldGate.release();_=try await pendingOld.value
        let generation=try await h.repo.identityGenerationV4();XCTAssertEqual(generation,1,"old response must retain its original admission generation")
        await freshGate.release()
        do {let fresh=try await pendingFresh.value;XCTAssertFalse(fresh.binding.suspended)}catch {XCTFail("explicit new-generation authentication must remain admissible: \(error)")}
        let binding=try await h.repo.accountBindingV4(),current=try? await h.vault.credential();XCTAssertEqual(binding?.suspended,false);XCTAssertNotNil(current)
        try await ledger.close()
    }

}
