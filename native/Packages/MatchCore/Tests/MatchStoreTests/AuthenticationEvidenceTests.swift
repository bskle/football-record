import Foundation
import XCTest
import CryptoKit
import MatchSession
@testable import MatchStore

final class AuthenticationEvidenceTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let url: URL
        let trust: AuthorityTrustConfiguration
        let binding: AccountBindingV4
        let attempt: AuthAttemptV4
        let receipt: VerifiedAuthorityReceiptV1
        let receiptKey: Data
        let store: MatchStore
        func reopen() throws -> MatchStore {
            try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "auth-evidence"), authorityTrust: trust)
        }
    }
    private func acceptedFixture(result: AuthorityResult = .registered, accept: Bool = true, url suppliedURL: URL? = nil) async throws -> Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["evidence-key": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        let binding = try AccountBindingV4(accountID: "evidence-account", cloudSpaceID: "evidence-cloud", deviceID: "original-phone", activationEpoch: 7, role: result == .registered ? .phone : .waiting, environment: .development)
        let attempt = try AuthAttemptV4(requestID: "original-auth", deviceID: binding.deviceID, publicKey: AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation), cloudSpaceID: binding.cloudSpaceID, challengeID: "original-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
        let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "evidence-key", "receiptID": "original-auth-receipt", "requestID": attempt.requestID, "requestDigest": attempt.requestDigest, "operation": "authApple", "accountID": binding.accountID, "activationEpoch": binding.activationEpoch, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": result.rawValue, "issuedAt": 1]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes))
        let raw = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(signature)], options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: attempt.requestID, digest: attempt.requestDigest, operation: .authApple, accountID: binding.accountID, epoch: binding.activationEpoch), trust: trust)
        let url = suppliedURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("authentication-evidence-" + UUID().uuidString + ".sqlite")
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "auth-evidence"), authorityTrust: trust)
        try await store.saveAuthAttemptV4(attempt)
        if accept { try await store.acceptAuthenticationV4(attempt: attempt, binding: binding, receipt: receipt) }
        return Fixture(url: url, trust: trust, binding: binding, attempt: attempt, receipt: receipt, receiptKey: key.rawRepresentation, store: store)
    }

    func testCommittedAuthenticationEvidenceReopensOriginalGrant() async throws {
        let fixture = try await acceptedFixture()
        try await fixture.store.close()
        let reopened = try fixture.reopen()
        let evidence = try await reopened.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        let value = try XCTUnwrap(evidence)
        XCTAssertEqual(value.binding, fixture.binding)
        XCTAssertEqual(value.attempt, fixture.attempt)
        XCTAssertEqual(value.currentAuthRequestID, fixture.attempt.requestID)
        XCTAssertEqual(value.identityGeneration, 0)
        XCTAssertEqual(value.admissionGeneration, 0)
        XCTAssertEqual(value.receipt.raw, fixture.receipt.raw)
        try await reopened.close()
    }

    private func write<T: Encodable>(_ db: SQLite, table: String = "lifecycle_steps_v4", id: String, value: T) throws {
        let bytes = try Canonical.data(value)
        try db.execute("INSERT INTO " + table + " (id,payload,checksum) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum", [.text(id), .blob(bytes), .text(Canonical.hash(bytes))])
    }
    private func mutate(_ fixture: Fixture, _ body: (SQLite) throws -> Void) async throws -> MatchStore {
        try await fixture.store.close()
        let db = try SQLite(url: fixture.url, fault: nil)
        do { try db.transaction { try body(db) }; try db.close() }
        catch { try db.close(); throw error }
        return try fixture.reopen()
    }
    private func rejected(_ store: MatchStore, generation: Int64 = 0, error expected: AuthorityError? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: generation); XCTFail("inconsistent current state must not return evidence", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? AuthorityError, expected, file: file, line: line) } }
    }
    private func changedReceipt(_ fixture: Fixture, changes: [String: Any]) throws -> Data {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.receipt.raw) as? [String: Any])
        var body = try XCTUnwrap(original["body"] as? [String: Any])
        body.merge(changes, uniquingKeysWith: { $1 })
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: fixture.receiptKey)
        let signature = try key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes))
        return try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(signature)], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testFreshStoreHasNoCurrentAuthenticationEvidence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("authentication-empty-" + UUID().uuidString + ".sqlite")
        let store = try MatchStore(url: url)
        let before = try await store.authenticationEvidenceTestState()
        let result = try await store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        let after = try await store.authenticationEvidenceTestState()
        XCTAssertNil(result); XCTAssertEqual(after.rows, before.rows); XCTAssertEqual(after.changes, before.changes)
        try await store.close()
    }

    func testPendingOrPartialAuthenticationDoesNotBecomeEvidence() async throws {
        let pending = try await acceptedFixture(accept: false)
        await rejected(pending.store, error: .unavailable)
        try await pending.store.close()
        for removed in ["binding", "auth-current", "auth-attempt:original-auth", "auth-admission:original-auth", "auth-receipt:original-auth"] {
            let f = try await acceptedFixture()
            let store = try await mutate(f) { db in
                if removed == "binding" { try db.execute("DELETE FROM account_binding_v4 WHERE id='current'") }
                else { try db.execute("DELETE FROM lifecycle_steps_v4 WHERE id=?", [.text(removed)]) }
            }
            await rejected(store, error: .intentMismatch); try await store.close()
        }
    }

    func testCommitResponseLossRetainsExactOriginalEvidence() async throws {
        let f = try await acceptedFixture(accept: false); try await f.store.close()
        let failing = try MatchStore(url: f.url, fault: .afterCommit, syncEnvironment: .development(databaseNamespace: "auth-evidence"), authorityTrust: f.trust)
        do { try await failing.acceptAuthenticationV4(attempt: f.attempt, binding: f.binding, receipt: f.receipt); XCTFail("expected actual COMMIT response loss") }
        catch { XCTAssertEqual(error as? StoreError, .responseLost) }
        try await failing.close()
        let reopened = try f.reopen(), value = try await reopened.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertEqual(value?.receipt.raw, f.receipt.raw); XCTAssertEqual(value?.currentAuthRequestID, f.attempt.requestID)
        XCTAssertEqual(value?.binding, f.binding); try await reopened.close()
    }

    func testBeforeCommitFaultCannotPublishEvidence() async throws {
        for fault in [StoreFault.beforeCommit, .afterReceipt] {
            let f = try await acceptedFixture(accept: false); try await f.store.close()
            let failing = try MatchStore(url: f.url, fault: fault, syncEnvironment: .development(databaseNamespace: "auth-evidence"), authorityTrust: f.trust)
            do { try await failing.acceptAuthenticationV4(attempt: f.attempt, binding: f.binding, receipt: f.receipt); XCTFail("expected original transaction fault") } catch {}
            try await failing.close()
            let reopened = try f.reopen(); await rejected(reopened, error: .unavailable)
            let binding = try await reopened.accountBindingV4(), attempt = try await reopened.authAttemptV4(requestID: f.attempt.requestID)
            XCTAssertNil(binding); XCTAssertEqual(attempt, f.attempt); try await reopened.close()
        }
    }

    func testWaitingGrantNeverProjectsRegisteredPhone() async throws {
        let f = try await acceptedFixture(result: .waitingMigration)
        let value = try await f.store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertEqual(value?.binding.role, .waiting); XCTAssertEqual(value?.receipt.body.result, .waitingMigration)
        let store = try await mutate(f) { db in
            try write(db, table: "account_binding_v4", id: "current", value: AccountBindingV4(accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, deviceID: f.binding.deviceID, activationEpoch: f.binding.activationEpoch, role: .phone, environment: .development))
        }
        await rejected(store, error: .intentMismatch); try await store.close()
    }

    func testSuspendedOrAdvancedGenerationNeverBorrowsHistoricalGrant() async throws {
        let f = try await acceptedFixture(); try await f.store.suspendAccountV4()
        await rejected(f.store, error: .identityChanged)
        await rejected(f.store, generation: 1, error: .identityChanged)
        let generation = try await f.store.identityGenerationV4(), attempt = try await f.store.authAttemptV4(requestID: f.attempt.requestID)
        XCTAssertEqual(generation, 1); XCTAssertEqual(attempt, f.attempt); try await f.store.close()
        for generation in [Int64(-1), 9_007_199_254_740_992] {
            let fresh = try await acceptedFixture(); await rejected(fresh.store, generation: generation, error: .invalidWire); try await fresh.store.close()
        }
    }

    func testCanonicalForgedBindingAndPointerCannotBorrowGrant() async throws {
        for changed in ["account", "cloud", "device", "epoch", "environment", "role", "pointer"] {
            let f = try await acceptedFixture()
            _ = try await f.store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
            let store = try await mutate(f) { db in
                if changed == "pointer" { try write(db, id: "auth-current", value: "another-auth"); return }
                let b = try AccountBindingV4(accountID: changed == "account" ? "other-account" : f.binding.accountID, cloudSpaceID: changed == "cloud" ? "other-cloud" : f.binding.cloudSpaceID, deviceID: changed == "device" ? "other-phone" : f.binding.deviceID, activationEpoch: changed == "epoch" ? 8 : 7, role: changed == "role" ? .waiting : .phone, environment: changed == "environment" ? .production : .development)
                try write(db, table: "account_binding_v4", id: "current", value: b)
            }
            await rejected(store); try await store.close()
        }
    }

    func testOriginalAttemptKeyAndAdmissionMustMatch() async throws {
        for changed in ["keyID", "publicKey", "digest", "requestID", "admission", "generation", "resolution"] {
            let f = try await acceptedFixture()
            let store = try await mutate(f) { db in
                if changed == "admission" { try write(db, id: "auth-admission:" + f.attempt.requestID, value: Int64(1)); return }
                if changed == "generation" { try write(db, id: "identity-generation", value: Int64(1)); return }
                if changed == "resolution" { try write(db, id: "auth-resolved:" + f.attempt.requestID, value: AuthResolutionV4.knownAbandoned); return }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(f.attempt)) as? [String: Any])
                if changed == "keyID" { object["keyID"] = String(repeating: "b", count: 64) }
                if changed == "publicKey" { object["publicKey"] = AuthorityWire.base64URL(Data(repeating: 13, count: 32)) }
                if changed == "digest" { object["requestDigest"] = String(repeating: "b", count: 64) }
                if changed == "requestID" { object["requestID"] = "another-auth" }
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id=?", [.blob(bytes), .text(Canonical.hash(bytes)), .text("auth-attempt:" + f.attempt.requestID)])
            }
            await rejected(store); try await store.close()
        }
    }

    func testSignatureUnknownKeyAndUnexpectedPurposeFieldsFailClosed() async throws {
        for changed in ["signature", "unknown-key", "operation", "result", "match", "lock", "recordingDevice", "registration"] {
            let f = try await acceptedFixture()
            let store = try await mutate(f) { db in
                var changes: [String: Any] = [:]
                if changed == "unknown-key" { changes["keyID"] = "unknown-key" }
                if changed == "operation" { changes["operation"] = "registerWatch" }
                if changed == "result" { changes["result"] = "deleted" }
                if changed == "match" { changes["matchID"] = "unexpected-match" }
                if changed == "lock" { changes["lockID"] = "unexpected-lock" }
                if changed == "recordingDevice" { changes["recordingDeviceID"] = f.binding.deviceID }
                if changed == "registration" { changes["registration"] = ["watchID": "unexpected-watch", "watchPublicKey": f.attempt.publicKey] }
                var raw = try changedReceipt(f, changes: changes)
                if changed == "signature" {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any]); object["signature"] = AuthorityWire.base64URL(Data(repeating: 0, count: 64))
                    raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                }
                try write(db, id: "auth-receipt:" + f.attempt.requestID, value: raw)
            }
            await rejected(store); try await store.close()
        }
    }

    func testOversizedAndNoncanonicalRowsRemainUnmodified() async throws {
        for changed in ["oversized", "receipt-limit", "unknown-field", "checksum"] {
            let f = try await acceptedFixture()
            let store = try await mutate(f) { db in
                if changed == "oversized" {
                    let raw = Data(repeating: 32, count: 32_769)
                    try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-current'", [.blob(raw), .text(Canonical.hash(raw))]); return
                }
                if changed == "receipt-limit" { try write(db, id: "auth-receipt:" + f.attempt.requestID, value: Data(repeating: 32, count: 16_385)); return }
                if changed == "checksum" { try db.execute("UPDATE account_binding_v4 SET checksum=? WHERE id='current'", [.text(String(repeating: "0", count: 64))]); return }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(f.binding)) as? [String: Any]); object["futureField"] = "unknown"
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                try db.execute("UPDATE account_binding_v4 SET payload=?,checksum=? WHERE id='current'", [.blob(bytes), .text(Canonical.hash(bytes))])
            }
            let before = try await store.authenticationEvidenceTestState()
            await rejected(store)
            let after = try await store.authenticationEvidenceTestState()
            XCTAssertEqual(after.rows, before.rows); XCTAssertEqual(after.changes, before.changes); try await store.close()
        }
    }

    func testReadSnapshotCannotMixConcurrentBindingAndGeneration() async throws {
        let f = try await acceptedFixture(), other = try SQLite(url: f.url, fault: nil)
        let newBinding = try AccountBindingV4(accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, deviceID: f.binding.deviceID, activationEpoch: 8, role: .phone, environment: .development)
        let bindingBytes = try Canonical.data(newBinding), generationBytes = try Canonical.data(Int64(1))
        let value = try await f.store.checkedCurrentAuthenticationEvidenceV4(expectedIdentityGeneration: 0, afterSnapshot: {
            try other.transaction {
                try other.execute("UPDATE account_binding_v4 SET payload=?,checksum=? WHERE id='current'", [.blob(bindingBytes), .text(Canonical.hash(bindingBytes))])
                try other.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text("identity-generation"), .blob(generationBytes), .text(Canonical.hash(generationBytes))])
            }
        })
        XCTAssertEqual(value?.binding, f.binding); XCTAssertEqual(value?.identityGeneration, 0); XCTAssertEqual(value?.receipt.raw, f.receipt.raw)
        await rejected(f.store, error: .identityChanged)
        await rejected(f.store, generation: 1, error: .identityChanged)
        try other.close(); try await f.store.close()
    }

    func testReadSucceedsWhileAnotherConnectionHoldsWriter() async throws {
        let f = try await acceptedFixture(), writer = try SQLite(url: f.url, fault: nil)
        try writer.execute("BEGIN IMMEDIATE")
        do {
            let value = try await f.store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
            XCTAssertEqual(value?.receipt.raw, f.receipt.raw)
            try writer.execute("ROLLBACK"); try writer.close(); try await f.store.close()
        } catch { try writer.execute("ROLLBACK"); try writer.close(); try await f.store.close(); throw error }
    }

    func testReadHasNoSQLWritesAndReleasesSnapshotAfterFailure() async throws {
        let f = try await acceptedFixture(), before = try await f.store.authenticationEvidenceTestState()
        _ = try await f.store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        await rejected(f.store, generation: 1, error: .identityChanged)
        let after = try await f.store.authenticationEvidenceTestState()
        XCTAssertEqual(after.rows, before.rows); XCTAssertEqual(after.changes, before.changes)
        try await f.store.setAnalyticsEnabledV4(true)
        let enabled = try await f.store.analyticsEnabledV4(); XCTAssertTrue(enabled)
        try await f.store.close()
    }

    func testOriginalSQLiteSessionFacadeForwardsSameEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auth-facade-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("auth-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = try await acceptedFixture(accept: false, url: directory.appendingPathComponent("matches.sqlite")); try await f.store.close()
        let facade = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "auth-evidence", authorityTrust: f.trust)
        try await facade.acceptAuthenticationV4(attempt: f.attempt, binding: f.binding, receipt: f.receipt)
        let object: Any = facade
        let reader = try XCTUnwrap(object as? any CurrentAuthenticationEvidenceReadingV4, "the original facade must expose only its own Store reader")
        let value = try await reader.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        let binding = try await facade.accountBindingV4(), generation = try await facade.identityGenerationV4()
        XCTAssertEqual(value?.binding, binding); XCTAssertEqual(value?.identityGeneration, generation); XCTAssertEqual(value?.receipt.raw, f.receipt.raw)
        try await facade.close()
    }
}

extension MatchStore {
    fileprivate func authenticationEvidenceTestState() throws -> (rows: [String], changes: Int64) {
        let tables = try db.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap { $0[0].string }
        var rows = ["version:\(try db.scalar("PRAGMA user_version").number ?? -1)"]
        for table in tables {
            guard table.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw StoreError.invalidRequest }
            for row in try db.rows("SELECT * FROM " + table + " ORDER BY rowid") {
                rows.append(table + ":" + row.map { value in
                    switch value {
                    case .text(let v): "text:" + v
                    case .blob(let v): "blob:" + v.base64EncodedString()
                    case .integer(let v): "integer:" + String(v)
                    case .null: "null"
                    }
                }.joined(separator: "|"))
            }
        }
        return (rows, try db.scalar("SELECT total_changes()").number ?? -1)
    }
}
