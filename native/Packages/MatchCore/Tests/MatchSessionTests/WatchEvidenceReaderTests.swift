import Foundation
import XCTest
import CryptoKit
@testable import MatchStore
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

    func testOriginalFacadeSetupReaderUsesPersistentIdentityAndCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-setup-facade-" + UUID().uuidString, isDirectory: true)
        let authority = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey()
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["setup-authority": AuthorityWire.base64URL(authority.publicKey.rawRepresentation)])
        let facade = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-setup-evidence", authorityTrust: trust)
        let object: Any = facade
        guard let reader = object as? any WatchRegistrationSetupEvidenceReadingV4 else {
            XCTFail("the original facade must expose its original setup reader before relay context exists")
            try await facade.close(); return
        }
        let identityURL = root.appendingPathComponent("original-device-identity")
        let provider = PersistentDeviceIdentityProvider(url: identityURL, repository: facade)
        let deviceID = try await provider.localDeviceID(), originalIdentity = try Data(contentsOf: identityURL)
        let publicKey = AuthorityWire.base64URL(device.publicKey.rawRepresentation)
        let before = try setupFacadeRows(root.appendingPathComponent("watch-setup-evidence/matches.sqlite"))
        let empty = try await reader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: deviceID, publicKey: publicKey)
        XCTAssertEqual(empty.state, .empty); XCTAssertNil(empty.admittedContext)
        XCTAssertEqual(before, try setupFacadeRows(root.appendingPathComponent("watch-setup-evidence/matches.sqlite")))
        let session = MatchSession(store: facade, deviceIdentity: provider, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(), workout: UnavailableWorkoutGateway(), environment: .development(databaseNamespace: "watch-setup-evidence"))
        let context = try WatchRegistrationContextV4(accountID: "setup-account", cloudSpaceID: "setup-cloud", phoneID: "setup-phone", activationEpoch: 1, environment: .development)
        _ = try await session.admitWatchRegistrationContext(context, deviceID: deviceID, publicKey: publicKey)
        let facadeIdentity = await facade.syncRepositoryIdentity(), coordinatorIdentity = await session.syncRepositoryIdentity()
        XCTAssertEqual(facadeIdentity, coordinatorIdentity)
        let admitted = try await reader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: deviceID, publicKey: publicKey)
        XCTAssertEqual(admitted.state, .admissionOnly); XCTAssertEqual(admitted.admittedContext, context)
        XCTAssertEqual(admitted.watchDeviceID, deviceID); XCTAssertEqual(admitted.watchPublicKey, publicKey)
        let retainedRows = try setupFacadeRows(root.appendingPathComponent("watch-setup-evidence/matches.sqlite"))
        let other = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-setup-other", authorityTrust: trust)
        let otherObject: Any = other
        let otherReader = try XCTUnwrap(otherObject as? any WatchRegistrationSetupEvidenceReadingV4)
        let independent = try await otherReader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: deviceID, publicKey: publicKey)
        let otherIdentity = await other.syncRepositoryIdentity()
        XCTAssertEqual(independent.state, .empty); XCTAssertNil(independent.admittedContext)
        XCTAssertNotEqual(otherIdentity, facadeIdentity)
        try await other.close(); try await session.retireBusiness(); try await facade.close()
        let reopened = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-setup-evidence", authorityTrust: trust)
        let reopenedProvider = PersistentDeviceIdentityProvider(url: identityURL, repository: reopened)
        let reopenedID = try await reopenedProvider.localDeviceID()
        XCTAssertEqual(reopenedID, deviceID); XCTAssertEqual(try Data(contentsOf: identityURL), originalIdentity)
        let reopenedObject: Any = reopened
        let reopenedReader = try XCTUnwrap(reopenedObject as? any WatchRegistrationSetupEvidenceReadingV4)
        let value = try await reopenedReader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: reopenedID, publicKey: publicKey)
        XCTAssertEqual(value.admittedContext, context); XCTAssertEqual(value.watchDeviceKeyID, admitted.watchDeviceKeyID)
        XCTAssertEqual(retainedRows, try setupFacadeRows(root.appendingPathComponent("watch-setup-evidence/matches.sqlite")))
        try await reopened.close()
    }

    func testSetupEvidenceDoesNotChangeOriginal055Behavior() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-setup-current-" + UUID().uuidString, isDirectory: true)
        let authority = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey()
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["setup-authority": AuthorityWire.base64URL(authority.publicKey.rawRepresentation)])
        let facade = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "watch-setup-evidence", authorityTrust: trust)
        let object: Any = facade
        guard let reader = object as? any WatchRegistrationSetupEvidenceReadingV4 else {
            XCTFail("the original facade setup capability must coexist with 055")
            try await facade.close(); return
        }
        let current = try XCTUnwrap(object as? any CurrentWatchRegistrationEvidenceReadingV4)
        let emptyCurrent = try await current.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertNil(emptyCurrent)
        let context = try WatchRegistrationContextV4(accountID: "setup-account", cloudSpaceID: "setup-cloud", phoneID: "setup-phone", activationEpoch: 1, environment: .development)
        let publicKey = AuthorityWire.base64URL(device.publicKey.rawRepresentation)
        _ = try await facade.admitWatchRegistrationContextV4(context, deviceID: "setup-watch", publicKey: publicKey)
        let admitted = try await reader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "setup-watch", publicKey: publicKey)
        XCTAssertEqual(admitted.admittedContext, context)
        do { _ = try await current.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0); XCTFail("pure setup is not current registration") }
        catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
        let hash = String(repeating: "a", count: 64)
        let challenge: [String: Any] = ["version": 1, "requestID": "setup-register", "watchID": "setup-watch", "watchPublicKey": publicKey, "challengeID": "setup-challenge", "challengeSHA256": hash]
        let challengeBytes = try JSONSerialization.data(withJSONObject: challenge, options: [.sortedKeys, .withoutEscapingSlashes])
        let attempt = try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: "setup-register", watchID: "setup-watch", watchPublicKey: publicKey, challengeID: "setup-challenge", deviceProof: AuthorityWire.base64URL(try device.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: challengeBytes)))), challengeRequestID: "setup-challenge-request", challengeSHA256: hash)
        let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "setup-authority", "receiptID": "setup-receipt", "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "registerWatch", "accountID": context.accountID, "activationEpoch": context.activationEpoch, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "registered", "issuedAt": 1_800_000_000, "registration": ["watchID": "setup-watch", "watchPublicKey": publicKey]]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let raw = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(try authority.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes)))], options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: attempt.requestID, digest: attempt.requestDigest, operation: .registerWatch, accountID: context.accountID, epoch: 1), trust: trust)
        let binding = try AccountBindingV4(accountID: context.accountID, cloudSpaceID: context.cloudSpaceID, deviceID: "setup-watch", activationEpoch: 1, role: .watch, environment: .development)
        try await facade.saveWatchRegistrationAttemptV4(attempt, expectedIdentityGeneration: 0)
        try await facade.acceptWatchRegistrationV4(attempt, receipt: receipt, watchBinding: binding, expectedIdentityGeneration: 0)
        let accepted = try await current.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertEqual(accepted?.receipt.raw, raw); XCTAssertEqual(accepted?.attempt, attempt)
        do { _ = try await reader.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "setup-watch", publicKey: publicKey); XCTFail("accepted registration is never setup") }
        catch { XCTAssertTrue(error is AuthorityError || error is StoreError) }
        try await facade.close()
    }

    private func setupFacadeRows(_ url: URL) throws -> [String] {
        let db = try SQLite(url: url, fault: nil)
        defer { try? db.close() }
        let tables = try db.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap { $0[0].string }
        var result = ["version:" + String(try db.scalar("PRAGMA user_version").number ?? -1)]
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            result += try db.rows("SELECT * FROM " + quoted + " ORDER BY rowid").map { row in
                table + ":" + row.map { value in
                    switch value { case .text(let v): "text:" + Data(v.utf8).base64EncodedString(); case .blob(let v): "blob:" + v.base64EncodedString(); case .integer(let v): "int:" + String(v); case .null: "null" }
                }.joined(separator: "|")
            }
        }
        return result
    }
}
