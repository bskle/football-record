import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore

final class DeletionControlAuthenticationTests:XCTestCase,@unchecked Sendable {
    let h=LifecycleStateTests()
    struct Fixture {let context:LifecycleStateTests.Context;let saga:DeletionSagaV4;let original:AuthAttemptV4}
    func fixture() async throws->Fixture {
        let c=try h.context(),s=try h.store(c),saga=try h.saga(c)
        let a=try AuthAttemptV4(requestID:"original-auth",deviceID:c.binding.deviceID,publicKey:AuthorityWire.base64URL(c.key.publicKey.rawRepresentation),cloudSpaceID:c.binding.cloudSpaceID,challengeID:"original-challenge",requestDigest:String(repeating:"a",count:64),environment:.development)
        try await s.saveAuthAttemptV4(a);let receipt=try h.receipt(c,requestID:a.requestID,digest:a.requestDigest,operation:.authApple,result:.registered)
        try await s.acceptAuthenticationV4(attempt:a,binding:c.binding,receipt:receipt);try await s.createDeletionSagaV4(saga);try await s.close()
        return Fixture(context:c,saga:saga,original:a)
    }
    func attempt(_ c:DeletionControlContextV1,id:String="control-auth")throws->DeletionControlAttemptV1 {
        let auth=try AuthAttemptV4(requestID:id,deviceID:c.binding.deviceID,publicKey:c.publicKey,cloudSpaceID:c.binding.cloudSpaceID,challengeID:"challenge-"+id,requestDigest:String(repeating:"b",count:64),environment:c.binding.environment)
        return try DeletionControlAttemptV1(context:c,challengeRequestID:"challenge-request-"+id,authentication:auth)
    }
    func testOriginalSagaContextAndAttemptPersistWithoutBindingGenerationOrAuthCurrentProjection() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0)
        XCTAssertEqual(c.saga,f.saga);XCTAssertEqual(c.publicKey,f.original.publicKey)
        let a=try attempt(c);try await s.saveDeletionControlAttemptV4(a);try await s.saveDeletionControlAttemptV4(a);try await s.close()
        let reopened=try h.store(f.context),saved=try await reopened.deletionControlAttemptV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID)
        XCTAssertEqual(saved,a);let binding=try await reopened.accountBindingV4(),generation=try await reopened.identityGenerationV4(),current=try await reopened.currentAuthRequestIDV4()
        XCTAssertEqual(binding,f.context.binding);XCTAssertEqual(generation,0);XCTAssertEqual(current,f.original.requestID)
        let capture=try await reopened.captureInventoryV4();XCTAssertTrue(capture.isEmpty);try await reopened.close()
    }
    func testChangedIdentityCannotAdmitOldControlAttemptAndCommittedBackendCannotCreateFreshControlRows() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c)
        try await s.suspendAccountV4()
        do {try await s.saveDeletionControlAttemptV4(a);XCTFail("old generation must reject")}catch{}
        let fresh=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:1);XCTAssertTrue(fresh.binding.suspended)
        let receipt=try h.receipt(f.context,requestID:f.saga.intent.requestID,digest:f.saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        _=try await s.acceptDeletionV4(requestID:f.saga.intent.requestID,receipt:receipt,expectedRevision:0)
        do {_=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:2);XCTFail("backend-completed parent is terminal for fresh auth")}catch{}
        try await s.close()
    }
    func testUnknownRetainedControlKindBlocksFullCaptureInventoryAndLocalErasurePreservingRawRow() async throws {
        let f=try await fixture(),s=try h.store(f.context);try await s.close()
        let db=try SQLite(url:f.context.url,fault:nil),raw=try Canonical.data("future-owned-control")
        try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)",[.text("delete-control-v1:future:unknown"),.blob(raw),.text(Canonical.hash(raw))]);try db.close()
        let reopened=try h.store(f.context)
        do {_=try await reopened.captureInventoryV4();XCTFail("full inventory cannot skip unknown control")}catch{}
        let signed=try h.receipt(f.context,requestID:f.saga.intent.requestID,digest:f.saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        let backend=try await reopened.acceptDeletionV4(requestID:f.saga.intent.requestID,receipt:signed,expectedRevision:0)
        do {_=try await reopened.eraseLocalBusinessV4(requestID:f.saga.intent.requestID,expectedRevision:backend.revision);XCTFail("erase cannot complete over unknown control")}catch{}
        try await reopened.close();let check=try SQLite(url:f.context.url,fault:nil)
        XCTAssertEqual(try check.scalar("SELECT payload FROM lifecycle_steps_v4 WHERE id='delete-control-v1:future:unknown'").data,raw);try check.close()
    }
    func testAttemptBudgetIsAtomicAndFirstRawAttemptCannotBeReplaced() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0)
        for n in 0..<64 {
            let a=try attempt(c,id:"control-\(n)");try await s.saveDeletionControlAttemptV4(a)
            let raw=try authorization(f,a,changes:["result":"knownAbandoned","stage":"unreserved","sessionID":NSNull(),"reauthenticationID":NSNull(),"reauthenticationExpiresAt":NSNull(),"expiresAt":Int64(h.h.t.timeIntervalSince1970)])
            let proof=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
            try await s.resolveDeletionControlAttemptV4(parentID:f.saga.intent.requestID,authorization:proof,expectedIdentityGeneration:0)
        }
        do {try await s.saveDeletionControlAttemptV4(attempt(c,id:"overflow"));XCTFail("parent attempt budget")}catch{}
        let one=try attempt(c,id:"control-0"),auth=try AuthAttemptV4(requestID:"control-0",deviceID:c.binding.deviceID,publicKey:c.publicKey,cloudSpaceID:c.binding.cloudSpaceID,challengeID:"changed",requestDigest:String(repeating:"c",count:64),environment:.development),changed=try DeletionControlAttemptV1(context:c,challengeRequestID:"other-challenge",authentication:auth)
        do {try await s.saveDeletionControlAttemptV4(changed);XCTFail("immutable first intent")}catch{}
        let saved=try await s.deletionControlAttemptV4(parentID:f.saga.intent.requestID,authRequestID:"control-0");XCTAssertEqual(saved,one);try await s.close()
    }
    func authorization(_ f:Fixture,_ a:DeletionControlAttemptV1,changes:[String:Any]=[:])throws->Data {
        let at=Int64(h.h.t.timeIntervalSince1970)
        var body:[String:Any]=["version":1,"purpose":"deleteControl.v1","environment":"development","keyID":"lifecycle-key","proofID":"control-proof","requestID":a.authentication.requestID,"requestDigest":a.authentication.requestDigest,"parentRequestID":f.saga.intent.requestID,"parentDigest":f.saga.intent.digest,"recoveryCapabilityDigest":f.saga.intent.fields.recoveryCapabilityDigest!,"accountID":f.context.binding.accountID,"deviceID":f.context.binding.deviceID,"deviceKeyID":a.keyID,"activationEpoch":1,"cloudSpaceID":f.context.binding.cloudSpaceID,"result":"ready","stage":"requested","issuedAt":at,"expiresAt":at+300,"sessionID":"dc.00000000-0000-4000-8000-000000000001","reauthenticationID":"fresh-control-reauth","reauthenticationExpiresAt":at+300,"lockState":"none","lock":NSNull()]
        body.merge(changes,uniquingKeysWith:{$1});let raw=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try f.context.key.signature(for:AuthorityWire.signedInput("football-record.deletion-control-auth.v1",body:raw))
        return try JSONSerialization.data(withJSONObject:["body":body,"signature":AuthorityWire.base64URL(signature)],options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func testDedicatedProofChecksExactPurposeScopeAndSignatureWithoutBecomingOrdinaryAuthentication() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c)
        let raw=try authorization(f,a),verified=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
        XCTAssertEqual(verified.body.result,.ready);XCTAssertEqual(verified.raw,raw)
        let mutations:[[String:Any]]=[["purpose":"ordinary"],["cloudSpaceID":"other"],["parentDigest":String(repeating:"d",count:64)],["deviceKeyID":String(repeating:"a",count:64)],["futureField":true]]
        for changes in mutations {
            XCTAssertThrowsError(try VerifiedDeletionControlAuthorizationV1.verify(authorization(f,a,changes:changes),expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust))
        }
        XCTAssertThrowsError(try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(requestID:a.authentication.requestID,digest:a.authentication.requestDigest,operation:.authApple,accountID:f.saga.accountID,epoch:1),trust:f.context.trust));try await s.close()
    }
    func testProofCommitFaultsReadBackOriginalCanonicalWithoutChangingIdentity() async throws {
        for fault in [StoreFault.beforeCommit,.afterReceipt,.afterCommit] {
            let f=try await fixture(),seed=try h.store(f.context),c=try await seed.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c),raw=try authorization(f,a),proof=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
            try await seed.saveDeletionControlAttemptV4(a);try await seed.close();let failing=try h.store(f.context,fault:fault)
            do {try await failing.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:proof,originalAcquire:nil,expectedIdentityGeneration:0,at:h.h.t);XCTFail("injected fault")}catch{}
            try await failing.close();let reopened=try h.store(f.context),saved=try await reopened.deletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID)
            XCTAssertEqual(saved?.authorization.raw,fault == .afterCommit ? raw:nil)
            try await reopened.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:proof,originalAcquire:nil,expectedIdentityGeneration:0,at:h.h.t)
            let first=try await reopened.deletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID),binding=try await reopened.accountBindingV4(),gen=try await reopened.identityGenerationV4(),current=try await reopened.currentAuthRequestIDV4()
            XCTAssertEqual(first?.authorization.raw,raw);XCTAssertEqual(binding,f.context.binding);XCTAssertEqual(gen,0);XCTAssertEqual(current,f.original.requestID);try await reopened.close()
        }
    }

    func testUnknownOriginalControlAttemptCannotBeBypassedByAnotherID() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c,id:"unknown")
        try await s.saveDeletionControlAttemptV4(a)
        do {try await s.saveDeletionControlAttemptV4(attempt(c,id:"new-ID"));XCTFail("unknown must recover same ID")}catch{}
        let all=try await s.deletionControlAttemptsV4(parentID:f.saga.intent.requestID);XCTAssertEqual(all,[a]);try await s.close()
    }

    func testControlProofHistorySurvivesBackendAndLocalWitnessWithoutBecomingActiveAgain() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c),raw=try authorization(f,a),proof=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
        try await s.saveDeletionControlAttemptV4(a);try await s.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:proof,originalAcquire:nil,expectedIdentityGeneration:0,at:h.h.t)
        let signed=try h.receipt(f.context,requestID:f.saga.intent.requestID,digest:f.saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]]),backend=try await s.acceptDeletionV4(requestID:f.saga.intent.requestID,receipt:signed,expectedRevision:0)
        let local=try await s.eraseLocalBusinessV4(requestID:f.saga.intent.requestID,expectedRevision:backend.revision),witness=try await s.validateLocalBusinessErasedV4(requestID:f.saga.intent.requestID,requestDigest:f.saga.intent.digest,scope:c.originalScope)
        XCTAssertEqual(witness.currentSagaRevision,local.revision)
        let old=try await s.deletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID);XCTAssertEqual(old?.authorization.raw,raw)
        do {_=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:1);XCTFail("historical proof never grants fresh control after backend deletion")}catch{}
        do {try await s.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:proof,originalAcquire:nil,expectedIdentityGeneration:1,at:h.h.t);XCTFail("completed parent cannot write more auth facts")}catch{}
        let inventory=try await s.captureInventoryV4();XCTAssertTrue(inventory.isEmpty);try await s.close()
    }
    func testClosingResolutionRetainsOriginalReadyAndBlocksOldGenerationWhileAllowingExplicitFreshAttempt() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c),raw=try authorization(f,a),ready=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
        try await s.saveDeletionControlAttemptV4(a);try await s.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:ready,originalAcquire:nil,expectedIdentityGeneration:0,at:h.h.t)
        let closedRaw=try authorization(f,a,changes:["result":"knownExpired","sessionID":NSNull(),"reauthenticationID":NSNull(),"reauthenticationExpiresAt":NSNull(),"expiresAt":Int64(h.h.t.timeIntervalSince1970)]),closed=try VerifiedDeletionControlAuthorizationV1.verify(closedRaw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
        try await s.resolveDeletionControlAttemptV4(parentID:f.saga.intent.requestID,authorization:closed,expectedIdentityGeneration:0);try await s.close()
        let reopened=try h.store(f.context),record=try await reopened.deletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authRequestID:a.authentication.requestID)
        XCTAssertEqual(record?.authorization.raw,raw);XCTAssertEqual(record?.resolution?.raw,closedRaw)
        try await reopened.saveDeletionControlAttemptV4(attempt(c,id:"explicit-fresh"));try await reopened.suspendAccountV4()
        do {try await reopened.resolveDeletionControlAttemptV4(parentID:f.saga.intent.requestID,authorization:closed,expectedIdentityGeneration:0);XCTFail("old generation cannot mutate despite cached signed proof")}catch{}
        try await reopened.close()
    }
    func testExplicitOriginalLockControlPersistsWithoutCreatingMatchPermitOrNormalCompletion() async throws {
        let f=try await fixture(),s=try h.store(f.context),c=try await s.deletionControlContextV4(parentID:f.saga.intent.requestID,expectedIdentityGeneration:0),a=try attempt(c)
        var fields=AuthorityFields();fields.matchID="server-original-match";fields.recordingDeviceID="original-watch";fields.activationEpoch=1
        let acquire=try ControlIntentV1(requestID:"server-acquire",operation:.acquire,fields:fields),held=try h.receipt(f.context,requestID:acquire.requestID,digest:acquire.digest,operation:.acquire,result:.held,extra:["matchID":"server-original-match","lockID":"original-lock","recordingDeviceID":"original-watch"])
        let pin:[String:Any]=["matchID":"server-original-match","lockID":"original-lock","recordingDeviceID":"original-watch","activationEpoch":1,"acquireRequestID":acquire.requestID,"acquireRequestDigest":acquire.digest,"acquireReceiptDigest":AuthorityWire.hash(held.raw)]
        let raw=try authorization(f,a,changes:["lockState":"pinned","lock":pin]),proof=try VerifiedDeletionControlAuthorizationV1.verify(raw,expectedParent:f.saga,expectedAttempt:a,trust:f.context.trust)
        try await s.saveDeletionControlAttemptV4(a);try await s.acceptDeletionControlAuthorizationV4(parentID:f.saga.intent.requestID,authorization:proof,originalAcquire:held.raw,expectedIdentityGeneration:0,at:h.h.t)
        fields.lockID="original-lock";fields.mode="abnormal"
        let intent=try ControlIntentV1(requestID:"explicit-abnormal",operation:.terminate,fields:fields),confirmation=try DeletionControlLockConfirmationV1(parentRequestID:f.saga.intent.requestID,parentDigest:f.saga.intent.digest,confirmationID:"user-confirmation",confirmedAt:Int64(h.h.t.timeIntervalSince1970),intent:intent,acquireRaw:held.raw)
        let released=try h.receipt(f.context,requestID:intent.requestID,digest:intent.digest,operation:.terminate,result:.releasedAbnormal,extra:["matchID":"server-original-match","lockID":"original-lock","recordingDeviceID":"original-watch"])
        do {try await s.acceptDeletionControlAbnormalResultV4(parentID:f.saga.intent.requestID,receipt:released,expectedIdentityGeneration:0);XCTFail("explicit durable confirmation required")}catch{}
        try await s.saveDeletionControlLockConfirmationV4(parentID:f.saga.intent.requestID,confirmation:confirmation,expectedIdentityGeneration:0);try await s.acceptDeletionControlAbnormalResultV4(parentID:f.saga.intent.requestID,receipt:released,expectedIdentityGeneration:0);try await s.close()
        let reopened=try h.store(f.context),saved=try await reopened.deletionControlLockConfirmationV4(parentID:f.saga.intent.requestID),matches=try await reopened.matchIDs(),inventory=try await reopened.captureInventoryV4()
        XCTAssertEqual(saved,confirmation);XCTAssertTrue(matches.isEmpty);XCTAssertTrue(inventory.isEmpty)
        let normal=try h.receipt(f.context,requestID:intent.requestID,digest:intent.digest,operation:.terminate,result:.releasedNormal,extra:["matchID":"server-original-match","lockID":"original-lock","recordingDeviceID":"original-watch"])
        do {try await reopened.acceptDeletionControlAbnormalResultV4(parentID:f.saga.intent.requestID,receipt:normal,expectedIdentityGeneration:0);XCTFail("normal completion is forbidden")}catch{}
        try await reopened.close()
    }

}
