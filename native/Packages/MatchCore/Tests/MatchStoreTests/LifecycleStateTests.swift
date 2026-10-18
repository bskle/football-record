import Foundation
import XCTest
import CryptoKit
@testable import MatchStore
final class LifecycleStateTests:XCTestCase,@unchecked Sendable {
    let h=TransactionTests()
    struct Context {let url:URL;let key:Curve25519.Signing.PrivateKey;let trust:AuthorityTrustConfiguration;let binding:AccountBindingV4}
    func context()throws->Context {let key=Curve25519.Signing.PrivateKey();return Context(url:h.path(),key:key,trust:try AuthorityTrustConfiguration(environment:.development,publicKeys:["lifecycle-key":AuthorityWire.base64URL(key.publicKey.rawRepresentation)]),binding:try AccountBindingV4(accountID:"lifecycle-account",cloudSpaceID:"cloud",deviceID:"phone",activationEpoch:1,role:.phone,environment:.development))}
    func store(_ c:Context,fault:StoreFault?=nil)throws->MatchStore {if let fault {return try MatchStore(url:c.url,fault:fault,syncEnvironment:.development(databaseNamespace:"lifecycle"),authorityTrust:c.trust)};return try MatchStore(url:c.url,syncEnvironment:.development(databaseNamespace:"lifecycle"),authorityTrust:c.trust)}
    func receipt(_ c:Context,requestID:String,digest:String,operation:AuthorityOperation,result:AuthorityResult,extra:[String:Any]=[:])throws->VerifiedAuthorityReceiptV1 {
        var body:[String:Any]=["version":1,"environment":"development","keyID":"lifecycle-key","receiptID":requestID+"-receipt","requestID":requestID,"requestDigest":digest,"operation":operation.rawValue,"accountID":c.binding.accountID,"activationEpoch":1,"matchID":"","lockID":"","recordingDeviceID":"","result":result.rawValue,"issuedAt":Int64(h.t.timeIntervalSince1970)]
        body.merge(extra,uniquingKeysWith:{$1});let bytes=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try c.key.signature(for:AuthorityWire.signedInput("football-record.authority.receipt.v1",body:bytes))
        let raw=try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(signature)],options:[.sortedKeys,.withoutEscapingSlashes])
        return try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:requestID,digest:digest,operation:operation,accountID:c.binding.accountID,epoch:1),trust:c.trust)
    }
    func saga(_ c:Context)throws->DeletionSagaV4 {let cap=AuthorityWire.base64URL(Data(repeating:41,count:32));var fields=AuthorityFields();fields.reauthenticationID="fresh-reauth";fields.recoveryCapabilityDigest=AuthorityWire.hash(Data(cap.utf8));return try DeletionSagaV4(intent:ControlIntentV1(requestID:"delete",operation:.deleteAccount,fields:fields),accountID:c.binding.accountID,activationEpoch:1,recoveryCapability:cap,cloudChoice:.delete,localChoice:.delete,healthChoice:.delete,healthConfirmed:true)}
    func testAnalyticsDefaultsOffDiscardsOnlyOptionalQueueAndPersistsAcrossReopen() async throws {
        let c=try context(),s=try store(c);try await s.bindAccountV4(c.binding)
        let event=try AnalyticsEventV4(requestID:"metric",metric:.activeDay,appVersion:"1.0",osFamily:"iOS",osMajor:17,qualification:"free")
        let initial=try await s.analyticsEnabledV4();XCTAssertFalse(initial);try await s.enqueueAnalyticsV4(event)
        let off=try await s.pendingAnalyticsV4();XCTAssertTrue(off.isEmpty)
        try await s.setAnalyticsEnabledV4(true);try await s.enqueueAnalyticsV4(event);try await s.enqueueAnalyticsV4(event);try await s.close()
        let r=try store(c);let queue=try await r.pendingAnalyticsV4();XCTAssertEqual(queue,[event]);try await r.setAnalyticsEnabledV4(false)
        let after=try await r.pendingAnalyticsV4(),binding=try await r.accountBindingV4();XCTAssertTrue(after.isEmpty);XCTAssertEqual(binding,c.binding)
    }
    func testDeletionStagesCASAndLocalEraseRetainCapabilityUntilIndependentChoicesFinish() async throws {
        let c=try context(),s=try store(c),saga=try saga(c);try await s.bindAccountV4(c.binding);try await s.createDeletionSagaV4(saga)
        do {_=try await s.eraseLocalBusinessV4(requestID:"delete",expectedRevision:0);XCTFail()}catch{}
        let receipt=try receipt(c,requestID:"delete",digest:saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        let backend=try await s.acceptDeletionV4(requestID:"delete",receipt:receipt,expectedRevision:0);XCTAssertTrue(backend.backendDeleted);XCTAssertFalse(backend.finished)
        let local=try await s.eraseLocalBusinessV4(requestID:"delete",expectedRevision:backend.revision);XCTAssertEqual(local.localProgress,.completed);try await s.close()
        let r=try store(c),saved=try await r.deletionSagaV4(requestID:"delete"),reopened=try XCTUnwrap(saved);XCTAssertEqual(reopened.recoveryCapability,saga.recoveryCapability);XCTAssertEqual(reopened.cloudProgress,.pending);XCTAssertEqual(reopened.healthProgress,.pending)
        var next=reopened;next.cloudProgress = .failed;next.revision += 1;try await r.updateDeletionSagaV4(next,expectedRevision:reopened.revision)
        do {try await r.updateDeletionSagaV4(next,expectedRevision:reopened.revision);XCTFail()}catch{}
    }
    func testAuthAcceptFaultsReopenWithoutPartialBindingAndOriginalAttemptRemainsRecoverable() async throws {
        for fault in [StoreFault.beforeCommit,.afterReceipt,.afterCommit] {
            let c=try context(),seed=try store(c),attempt=try AuthAttemptV4(requestID:"auth",deviceID:"phone",publicKey:AuthorityWire.base64URL(c.key.publicKey.rawRepresentation),cloudSpaceID:"cloud",challengeID:"challenge",requestDigest:String(repeating:"a",count:64),environment:.development)
            try await seed.saveAuthAttemptV4(attempt);try await seed.close()
            let signed=try receipt(c,requestID:"auth",digest:attempt.requestDigest,operation:.authApple,result:.registered),failing=try store(c,fault:fault)
            do {try await failing.acceptAuthenticationV4(attempt:attempt,binding:c.binding,receipt:signed);XCTFail()}catch{};try await failing.close()
            let r=try store(c),binding=try await r.accountBindingV4(),original=try await r.authAttemptV4(requestID:"auth");XCTAssertEqual(binding != nil,fault == .afterCommit);XCTAssertEqual(original,attempt)
            try await r.acceptAuthenticationV4(attempt:attempt,binding:c.binding,receipt:signed);try await r.close()
        }
    }
}
