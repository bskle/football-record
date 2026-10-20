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
        for n in 0..<64 {try await s.saveDeletionControlAttemptV4(attempt(c,id:"control-\(n)"))}
        do {try await s.saveDeletionControlAttemptV4(attempt(c,id:"overflow"));XCTFail("parent attempt budget")}catch{}
        let one=try attempt(c,id:"control-0"),auth=try AuthAttemptV4(requestID:"control-0",deviceID:c.binding.deviceID,publicKey:c.publicKey,cloudSpaceID:c.binding.cloudSpaceID,challengeID:"changed",requestDigest:String(repeating:"c",count:64),environment:.development),changed=try DeletionControlAttemptV1(context:c,challengeRequestID:"other-challenge",authentication:auth)
        do {try await s.saveDeletionControlAttemptV4(changed);XCTFail("immutable first intent")}catch{}
        let saved=try await s.deletionControlAttemptV4(parentID:f.saga.intent.requestID,authRequestID:"control-0");XCTAssertEqual(saved,one);try await s.close()
    }
}
