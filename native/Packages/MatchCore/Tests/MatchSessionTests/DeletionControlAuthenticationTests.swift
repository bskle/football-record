import Foundation
import CryptoKit
import XCTest
import MatchCore
import MatchStore
@testable import MatchSession

final class DeletionControlAuthenticationTests:XCTestCase,@unchecked Sendable {
    struct Fixture {
        let repository:SQLiteSessionRepository
        let session:MatchSession
        let key:Curve25519.Signing.PrivateKey
        let trust:AuthorityTrustConfiguration
        let binding:AccountBindingV4
        let saga:DeletionSagaV4
        let gateway:FakeGateway
    }
    func signed(_ key:Curve25519.Signing.PrivateKey,body:[String:Any],domain:String="football-record.authority.receipt.v1")throws->Data {
        let bytes=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try key.signature(for:AuthorityWire.signedInput(domain,body:bytes))
        return try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(signature)],options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func authorityReceipt(_ f:Fixture,requestID:String,digest:String,operation:AuthorityOperation,result:AuthorityResult,extra:[String:Any]=[:])throws->VerifiedAuthorityReceiptV1 {
        var body:[String:Any]=["version":1,"environment":"development","keyID":"control-key","receiptID":"receipt-"+requestID,"requestID":requestID,"requestDigest":digest,"operation":operation.rawValue,"accountID":f.binding.accountID,"activationEpoch":1,"matchID":"","lockID":"","recordingDeviceID":"","result":result.rawValue,"issuedAt":1000];body.merge(extra,uniquingKeysWith:{$1})
        return try VerifiedAuthorityReceiptV1.verify(signed(f.key,body:body),expected:AuthorityExpectedIntent(requestID:requestID,digest:digest,operation:operation,accountID:f.binding.accountID,epoch:1),trust:f.trust)
    }
    func fixture() async throws->Fixture {
        let key=Curve25519.Signing.PrivateKey(),trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:["control-key":AuthorityWire.base64URL(key.publicKey.rawRepresentation)]),binding=try AccountBindingV4(accountID:"original-account",cloudSpaceID:"original-cloud",deviceID:"original-phone",activationEpoch:1,role:.phone,environment:.development)
        let repo=try SQLiteSessionRepository(rootDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),databaseNamespace:"control-retired",authorityTrust:trust),gateway=FakeGateway(),session=MatchSession(store:repo,deviceIdentity:Identity(value:binding.deviceID),clock:TestClock(),ids:TestIDs(),permits:DevelopmentStartPermitProvider(),workout:gateway,environment:.development(databaseNamespace:"control-retired"))
        let cap=AuthorityWire.base64URL(Data(repeating:17,count:32));var fields=AuthorityFields();fields.reauthenticationID="original-expired-reauth";fields.recoveryCapabilityDigest=AuthorityWire.hash(Data(cap.utf8))
        let scope=try CloudScopeV1(accountID:binding.accountID,cloudSpaceID:binding.cloudSpaceID,zoneID:"matches",activationEpoch:1),saga=try DeletionSagaV4(intent:ControlIntentV1(requestID:"original-delete",operation:.deleteAccount,fields:fields),accountID:binding.accountID,activationEpoch:1,recoveryCapability:cap,cloudChoice:.keep,localChoice:.delete,healthChoice:.keep,healthConfirmed:false,originalScope:scope)
        let f=Fixture(repository:repo,session:session,key:key,trust:trust,binding:binding,saga:saga,gateway:gateway),a=try AuthAttemptV4(requestID:"original-auth",deviceID:binding.deviceID,publicKey:AuthorityWire.base64URL(key.publicKey.rawRepresentation),cloudSpaceID:binding.cloudSpaceID,challengeID:"original-challenge",requestDigest:String(repeating:"a",count:64),environment:.development)
        try await session.saveAuthAttempt(a,expectedIdentityGeneration:0);let receipt=try authorityReceipt(f,requestID:a.requestID,digest:a.requestDigest,operation:.authApple,result:.registered)
        try await session.acceptAuthentication(attempt:a,binding:binding,receipt:receipt,expectedIdentityGeneration:0);try await repo.createDeletionSagaV4(saga);return f
    }
    func attempt(_ c:DeletionControlContextV1)throws->DeletionControlAttemptV1 {
        try DeletionControlAttemptV1(context:c,challengeRequestID:"control-challenge-request",authentication:AuthAttemptV4(requestID:"control-attempt",deviceID:c.binding.deviceID,publicKey:c.publicKey,cloudSpaceID:c.binding.cloudSpaceID,challengeID:"control-challenge",requestDigest:String(repeating:"b",count:64),environment:c.binding.environment))
    }
    func testRetiredOriginalSessionAllowsOnlyParentBoundControlAndKeepsOrdinaryIdentityAndRecordingGate() async throws {
        let f=try await fixture(),c=try await f.repository.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c)
        try await f.session.retireBusiness();try await f.session.saveDeletionControlAttempt(a)
        let saved=try await f.repository.deletionControlAttemptV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID);XCTAssertEqual(saved,a)
        do {try await f.session.saveAuthAttempt(a.authentication,expectedIdentityGeneration:0);XCTFail("ordinary business identity remains retired")}catch{XCTAssertEqual(error as? SessionError,.retired)}
        do {_=try await f.session.prepareStart(starter:true);XCTFail("control cannot reopen recording")}catch{XCTAssertEqual(error as? SessionError,.retired)}
        let identity=await f.session.syncRepositoryIdentity(),original=await f.repository.syncRepositoryIdentity(),binding=try await f.repository.accountBindingV4(),gen=try await f.repository.identityGenerationV4(),matches=try await f.repository.matchIDs(),performed=await f.gateway.performed
        XCTAssertEqual(identity,original);XCTAssertEqual(binding,f.binding);XCTAssertEqual(gen,0);XCTAssertTrue(matches.isEmpty);XCTAssertTrue(performed.isEmpty);try await f.repository.close()
    }
    func testOriginalAccountMutexAwaitCannotAdmitControlAfterBackendDeletionAndGenerationChange() async throws {
        let f=try await fixture(),c=try await f.repository.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c);try await f.session.retireBusiness()
        await f.session.acquire("_authority-account");let task=Task {try await f.session.saveDeletionControlAttempt(a)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(2));while await f.session.controlDeletionWaiterCount()==0&&ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
        let waiting=await f.session.controlDeletionWaiterCount();XCTAssertEqual(waiting,1)
        let receipt=try authorityReceipt(f,requestID:f.saga.intent.requestID,digest:f.saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        _=try await f.repository.acceptDeletionV4(requestID:f.saga.intent.requestID,receipt:receipt,expectedRevision:0);await f.session.release("_authority-account")
        do {try await task.value;XCTFail("SQL must recheck parent and generation")}catch{}
        let saved=try await f.repository.deletionControlAttemptsV4(parentID:f.saga.intent.requestID);XCTAssertTrue(saved.isEmpty);try await f.repository.close()
    }
}
private extension MatchSession {func controlDeletionWaiterCount()->Int {waiters["_authority-account"]?.count ?? 0}}
