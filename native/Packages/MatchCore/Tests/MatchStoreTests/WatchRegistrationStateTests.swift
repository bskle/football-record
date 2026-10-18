import Foundation
import XCTest
import CryptoKit
@testable import MatchStore
final class WatchRegistrationStateTests:XCTestCase,@unchecked Sendable {
    let h=LifecycleStateTests()
    func attempt(_ c:LifecycleStateTests.Context,key:Curve25519.Signing.PrivateKey)throws->WatchRegistrationAttemptV4 {
        let publicKey=AuthorityWire.base64URL(key.publicKey.rawRepresentation),hash=String(repeating:"a",count:64),context=try WatchRegistrationContextV4(accountID:c.binding.accountID,cloudSpaceID:c.binding.cloudSpaceID,phoneID:c.binding.deviceID,activationEpoch:1,environment:.development)
        let signing:[String:Any]=["version":1,"requestID":"register-watch","watchID":"watch","watchPublicKey":publicKey,"challengeID":"challenge","challengeSHA256":hash],raw=try JSONSerialization.data(withJSONObject:signing,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try key.signature(for:AuthorityWire.signedInput("football-record.device.challenge.v1",body:raw))
        return try WatchRegistrationAttemptV4(context:context,payload:WatchRegistrationPayloadV4(requestID:"register-watch",watchID:"watch",watchPublicKey:publicKey,challengeID:"challenge",deviceProof:AuthorityWire.base64URL(signature)),challengeRequestID:"watch-challenge",challengeSHA256:hash)
    }
    func testRegistrationReceiptFaultsReopenAtomicallyWithoutChangingPhoneBinding() async throws {
        for asWatch in [false,true] {for fault in [StoreFault.beforeCommit,.afterReceipt,.afterCommit] {
            let c=try h.context(),key=Curve25519.Signing.PrivateKey(),a=try attempt(c,key:key),seed=try h.store(c)
            let watchBinding=try AccountBindingV4(accountID:c.binding.accountID,cloudSpaceID:c.binding.cloudSpaceID,deviceID:"watch",activationEpoch:1,role:.watch,environment:.development)
            if asWatch {_=try await seed.admitWatchRegistrationContextV4(a.context,deviceID:"watch",publicKey:a.payload.watchPublicKey)}else {try await seed.bindAccountV4(c.binding)}
            try await seed.saveWatchRegistrationAttemptV4(a,expectedIdentityGeneration:0);try await seed.close()
            let receipt=try h.receipt(c,requestID:a.requestID,digest:a.requestDigest,operation:.registerWatch,result:.registered,extra:["registration":["watchID":"watch","watchPublicKey":a.payload.watchPublicKey]]),failing=try h.store(c,fault:fault)
            do {try await failing.acceptWatchRegistrationV4(a,receipt:receipt,watchBinding:asWatch ? watchBinding:nil,expectedIdentityGeneration:0);XCTFail()}catch{};try await failing.close()
            let reopened=try h.store(c),saved=try await reopened.watchRegistrationReceiptV4(requestID:a.requestID),pending=try await reopened.pendingWatchRegistrationAttemptsV4(),binding=try await reopened.accountBindingV4()
            XCTAssertEqual(saved != nil,fault == .afterCommit);XCTAssertEqual(pending.isEmpty,fault == .afterCommit);XCTAssertEqual(binding,asWatch ? (fault == .afterCommit ? watchBinding:nil):c.binding)
            try await reopened.acceptWatchRegistrationV4(a,receipt:receipt,watchBinding:asWatch ? watchBinding:nil,expectedIdentityGeneration:0);let original=try await reopened.watchRegistrationReceiptV4(requestID:a.requestID);XCTAssertEqual(original,receipt.raw);try await reopened.close()
        }}
    }
    func testWatchAdmissionPinsKeyAndAdvancingEpochFencesOldCallbackEvenWithNewGeneration() async throws {
        let c=try h.context(),key=Curve25519.Signing.PrivateKey(),a=try attempt(c,key:key),store=try h.store(c)
        let generation=try await store.admitWatchRegistrationContextV4(a.context,deviceID:"watch",publicKey:a.payload.watchPublicKey);try await store.saveWatchRegistrationAttemptV4(a,expectedIdentityGeneration:generation)
        let receipt=try h.receipt(c,requestID:a.requestID,digest:a.requestDigest,operation:.registerWatch,result:.registered,extra:["registration":["watchID":"watch","watchPublicKey":a.payload.watchPublicKey]]),binding=try AccountBindingV4(accountID:c.binding.accountID,cloudSpaceID:c.binding.cloudSpaceID,deviceID:"watch",activationEpoch:1,role:.watch,environment:.development)
        try await store.acceptWatchRegistrationV4(a,receipt:receipt,watchBinding:binding,expectedIdentityGeneration:generation);try await store.close()
        let reopened=try h.store(c)
        do {_=try await reopened.admitWatchRegistrationContextV4(a.context,deviceID:"watch",publicKey:AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation));XCTFail()}catch{}
        let next=try WatchRegistrationContextV4(accountID:c.binding.accountID,cloudSpaceID:c.binding.cloudSpaceID,phoneID:"next-phone",activationEpoch:2,environment:.development),newGeneration=try await reopened.admitWatchRegistrationContextV4(next,deviceID:"watch",publicKey:a.payload.watchPublicKey)
        XCTAssertEqual(newGeneration,1)
        for expected in [generation,newGeneration] {do {try await reopened.acceptWatchRegistrationV4(a,receipt:receipt,watchBinding:binding,expectedIdentityGeneration:expected);XCTFail("old epoch cannot borrow a new admission")}catch{}}
        let suspended=try await reopened.accountBindingV4();XCTAssertEqual(suspended?.suspended,true);XCTAssertEqual(suspended?.activationEpoch,1)
        let original=try await reopened.watchRegistrationReceiptV4(requestID:a.requestID);XCTAssertEqual(original,receipt.raw);try await reopened.close()
    }
}
