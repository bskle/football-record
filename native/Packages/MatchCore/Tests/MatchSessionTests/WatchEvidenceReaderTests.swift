import Foundation
import XCTest
import CryptoKit
import MatchStore
import MatchSession

final class WatchEvidenceReaderTests: XCTestCase, @unchecked Sendable {
    func testOriginalFacadeExposesOnlyItsOwnWatchEvidenceReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-evidence-facade-" + UUID().uuidString, isDirectory: true)
        let authority = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey()
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["facade-authority": AuthorityWire.base64URL(authority.publicKey.rawRepresentation)])
        let facade = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-evidence", authorityTrust: trust)
        let object: Any = facade
        let capability = object as? any CurrentWatchRegistrationEvidenceReadingV4
        XCTAssertNotNil(capability, "the original facade must forward only its original Store reader")
        guard let reader = capability else { try await facade.close(); return }
        let empty = try await reader.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0); XCTAssertNil(empty)
        let publicKey = AuthorityWire.base64URL(device.publicKey.rawRepresentation), hash = String(repeating: "a", count: 64)
        let context = try WatchRegistrationContextV4(accountID: "account", cloudSpaceID: "cloud", phoneID: "phone", activationEpoch: 1, environment: .development)
        let challenge: [String: Any] = ["version": 1, "requestID": "register-watch", "watchID": "watch", "watchPublicKey": publicKey, "challengeID": "challenge", "challengeSHA256": hash]
        let challengeBytes = try JSONSerialization.data(withJSONObject: challenge, options: [.sortedKeys, .withoutEscapingSlashes])
        let attempt = try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: "register-watch", watchID: "watch", watchPublicKey: publicKey, challengeID: "challenge", deviceProof: AuthorityWire.base64URL(try device.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: challengeBytes)))), challengeRequestID: "watch-challenge", challengeSHA256: hash)
        let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "facade-authority", "receiptID": "register-receipt", "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "registerWatch", "accountID": "account", "activationEpoch": 1, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "registered", "issuedAt": 1_800_000_000, "registration": ["watchID": "watch", "watchPublicKey": publicKey]]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let raw = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(try authority.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes)))], options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: attempt.requestID, digest: attempt.requestDigest, operation: .registerWatch, accountID: "account", epoch: 1), trust: trust)
        let binding = try AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: "watch", activationEpoch: 1, role: .watch, environment: .development)
        _ = try await facade.admitWatchRegistrationContextV4(context, deviceID: "watch", publicKey: publicKey)
        try await facade.saveWatchRegistrationAttemptV4(attempt, expectedIdentityGeneration: 0)
        try await facade.acceptWatchRegistrationV4(attempt, receipt: receipt, watchBinding: binding, expectedIdentityGeneration: 0)
        let value = try await reader.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        let actualBinding = try await facade.accountBindingV4(), generation = try await facade.identityGenerationV4()
        XCTAssertEqual(value?.binding, actualBinding); XCTAssertEqual(value?.identityGeneration, generation)
        XCTAssertEqual(value?.receipt.raw, raw); XCTAssertEqual(value?.attempt, attempt)
        try await facade.close()
        let reopened = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-evidence", authorityTrust: trust)
        let reopenedObject: Any = reopened
        let reopenedReader = try XCTUnwrap(reopenedObject as? any CurrentWatchRegistrationEvidenceReadingV4)
        let persisted = try await reopenedReader.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertEqual(persisted?.receipt.raw, raw); XCTAssertEqual(persisted?.binding, binding)
        try await reopened.close()
    }
}
