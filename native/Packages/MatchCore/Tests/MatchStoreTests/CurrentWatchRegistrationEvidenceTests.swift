import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore

final class CurrentWatchRegistrationEvidenceTests: XCTestCase, @unchecked Sendable {
    let h = LifecycleStateTests()
    struct Fixture {
        let context: LifecycleStateTests.Context
        let deviceKey: Curve25519.Signing.PrivateKey
        let attempt: WatchRegistrationAttemptV4
        let binding: AccountBindingV4
        let receipt: VerifiedAuthorityReceiptV1
        let store: MatchStore
    }
    func attempt(_ c: LifecycleStateTests.Context, key: Curve25519.Signing.PrivateKey, requestID: String = "watch-original", context supplied: WatchRegistrationContextV4? = nil) throws -> WatchRegistrationAttemptV4 {
        let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation), hash = String(repeating: "a", count: 64)
        let context = try supplied ?? WatchRegistrationContextV4(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, phoneID: c.binding.deviceID, activationEpoch: 1, environment: .development)
        let signing: [String: Any] = ["version": 1, "requestID": requestID, "watchID": "watch", "watchPublicKey": publicKey, "challengeID": "challenge", "challengeSHA256": hash]
        let bytes = try JSONSerialization.data(withJSONObject: signing, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: bytes))
        return try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: requestID, watchID: "watch", watchPublicKey: publicKey, challengeID: "challenge", deviceProof: AuthorityWire.base64URL(signature)), challengeRequestID: "watch-challenge", challengeSHA256: hash)
    }
    func signed(_ c: LifecycleStateTests.Context, attempt: WatchRegistrationAttemptV4, result: AuthorityResult = .registered, extra: [String: Any] = [:]) throws -> VerifiedAuthorityReceiptV1 {
        var fields: [String: Any] = ["registration": ["watchID": attempt.payload.watchID, "watchPublicKey": attempt.payload.watchPublicKey]]
        fields.merge(extra, uniquingKeysWith: { $1 })
        return try h.receipt(c, requestID: attempt.requestID, digest: attempt.requestDigest, operation: .registerWatch, result: result, extra: fields)
    }
    func fixture(accept: Bool = true) async throws -> Fixture {
        let c = try h.context(), key = Curve25519.Signing.PrivateKey(), a = try attempt(c, key: key)
        let b = try AccountBindingV4(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, deviceID: "watch", activationEpoch: 1, role: .watch, environment: .development)
        let receipt = try signed(c, attempt: a), s = try h.store(c)
        _ = try await s.admitWatchRegistrationContextV4(a.context, deviceID: "watch", publicKey: a.payload.watchPublicKey)
        try await s.saveWatchRegistrationAttemptV4(a, expectedIdentityGeneration: 0)
        if accept { try await s.acceptWatchRegistrationV4(a, receipt: receipt, watchBinding: b, expectedIdentityGeneration: 0) }
        return Fixture(context: c, deviceKey: key, attempt: a, binding: b, receipt: receipt, store: s)
    }
    func marker(_ url: URL) throws -> Data? {
        let db = try SQLite(url: url, fault: nil)
        defer { try? db.close() }
        return try db.rows("SELECT payload FROM lifecycle_steps_v4 WHERE id='watch-current-v1'").first?[0].data
    }
    func testFirstWatchBindingAcceptancePersistsMarkerAtomically() async throws {
        let f = try await fixture()
        try await f.store.close()
        XCTAssertNotNil(try marker(f.context.url), "the original binding acceptance transaction must persist its provenance")
        let reopened = try h.store(f.context)
        let binding = try await reopened.accountBindingV4(), raw = try await reopened.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
        XCTAssertEqual(binding, f.binding); XCTAssertEqual(raw, f.receipt.raw)
        try await reopened.close()
    }
    func testMarkerCommitFaultsReopenAtomicallyAndReplayDoesNotRewrite() async throws {
        for fault in [StoreFault.beforeCommit, .afterReceipt, .afterCommit] {
            let f = try await fixture(accept: false); try await f.store.close()
            let failing = try h.store(f.context, fault: fault)
            do { try await failing.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0); XCTFail("expected original transaction fault") } catch {}
            try await failing.close()
            let reopened = try h.store(f.context)
            let binding = try await reopened.accountBindingV4(), raw = try await reopened.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
            let before = try marker(f.context.url)
            XCTAssertEqual(before != nil, fault == .afterCommit); XCTAssertEqual(binding != nil, fault == .afterCommit); XCTAssertEqual(raw != nil, fault == .afterCommit)
            try await reopened.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
            let accepted = try marker(f.context.url); XCTAssertNotNil(accepted)
            try await reopened.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
            XCTAssertEqual(try marker(f.context.url), accepted)
            if let before { XCTAssertEqual(before, accepted) }
            try await reopened.close()
        }
    }
    func testCommittedWatchEvidenceReopensOriginalAcceptance() async throws {
        let f = try await fixture(); try await f.store.close()
        let reopened = try h.store(f.context)
        let evidence = try await reopened.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        let value = try XCTUnwrap(evidence)
        XCTAssertEqual(value.binding, f.binding); XCTAssertEqual(value.attempt, f.attempt)
        XCTAssertEqual(value.currentWatchRequestID, f.attempt.requestID)
        XCTAssertEqual(value.identityGeneration, 0); XCTAssertEqual(value.acceptedGeneration, 0)
        XCTAssertEqual(value.admittedContext, f.attempt.context)
        XCTAssertEqual(value.watchDeviceKeyID, try AuthorityWire.deviceKeyID(publicKey: f.attempt.payload.watchPublicKey))
        XCTAssertNotEqual(value.watchDeviceKeyID, f.receipt.body.keyID)
        XCTAssertEqual(value.receipt.raw, f.receipt.raw); XCTAssertNil(value.latestMigration)
        try await reopened.close()
    }
    func write<T: Encodable>(_ db: SQLite, table: String = "lifecycle_steps_v4", id: String, value: T) throws {
        let raw = try Canonical.data(value)
        try db.execute("INSERT INTO " + table + " (id,payload,checksum) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum", [.text(id), .blob(raw), .text(Canonical.hash(raw))])
    }
    func writeObject(_ db: SQLite, id: String, object: [String: Any]) throws {
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id=?", [.blob(raw), .text(Canonical.hash(raw)), .text(id)])
    }
    func mutate(_ f: Fixture, _ change: (SQLite) throws -> Void) async throws -> MatchStore {
        try await f.store.close()
        let db = try SQLite(url: f.context.url, fault: nil)
        do { try db.transaction { try change(db) }; try db.close() } catch { try db.close(); throw error }
        return try h.store(f.context)
    }
    func rejected(_ store: MatchStore, generation: Int64 = 0, error expected: AuthorityError? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: generation); XCTFail("inconsistent local current evidence must be blocked", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? AuthorityError, expected, file: file, line: line) } }
    }
    func object(_ db: SQLite, id: String = "watch-current-v1") throws -> [String: Any] {
        let row = try XCTUnwrap(try db.rows("SELECT payload FROM lifecycle_steps_v4 WHERE id=?", [.text(id)]).first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(row[0].data)) as? [String: Any])
    }
    func testFreshStoreReturnsNilWithoutClaimingNamespaceEmpty() async throws {
        let s = try MatchStore(url: h.h.path())
        let before = try await s.watchEvidenceTestState()
        let value = try await s.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        let after = try await s.watchEvidenceTestState()
        XCTAssertNil(value); XCTAssertEqual(before.rows, after.rows); XCTAssertEqual(before.changes, after.changes)
        try await s.close()
        let c = try h.context(), phone = try h.store(c); try await phone.bindAccountV4(c.binding)
        let phoneValue = try await phone.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertNil(phoneValue); try await phone.close()
    }
    func testLegacyReceiptRemainsHistoricalAndReplayCannotBackfill() async throws {
        let f = try await fixture()
        let s = try await mutate(f) { try $0.execute("DELETE FROM lifecycle_steps_v4 WHERE id='watch-current-v1'") }
        let before = try await s.watchEvidenceTestState()
        await rejected(s, error: .unavailable)
        let after = try await s.watchEvidenceTestState(), raw = try await s.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
        XCTAssertEqual(raw, f.receipt.raw); XCTAssertEqual(before.rows, after.rows); XCTAssertEqual(before.changes, after.changes)
        try await s.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
        XCTAssertNil(try marker(f.context.url)); await rejected(s, error: .unavailable); try await s.close()
    }
    func testReceiptOnlyPhoneAuthorizerAndKnownAbandonedNeverCreateMarker() async throws {
        for branch in ["receipt-only", "phone", "knownAbandoned"] {
            let f = try await fixture(accept: false)
            if branch == "phone" { try await f.store.bindAccountV4(f.context.binding) }
            if branch == "knownAbandoned" {
                let abandoned = try signed(f.context, attempt: f.attempt, result: .knownAbandoned)
                try await f.store.closeWatchRegistrationV4(f.attempt, receipt: abandoned, expectedIdentityGeneration: 0)
            } else { try await f.store.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: nil, expectedIdentityGeneration: 0) }
            XCTAssertNil(try marker(f.context.url)); await rejected(f.store, error: .unavailable)
            let raw = try await f.store.watchRegistrationReceiptV4(requestID: f.attempt.requestID); XCTAssertNotNil(raw)
            try await f.store.close()
        }
    }
    func testNewAcceptanceReplacesMarkerAndOldReplayCannotPointItBack() async throws {
        let f = try await fixture(), next = try attempt(f.context, key: f.deviceKey, requestID: "watch-next")
        let receipt = try signed(f.context, attempt: next)
        try await f.store.saveWatchRegistrationAttemptV4(next, expectedIdentityGeneration: 0)
        try await f.store.acceptWatchRegistrationV4(next, receipt: receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
        let accepted = try marker(f.context.url)
        try await f.store.acceptWatchRegistrationV4(f.attempt, receipt: f.receipt, watchBinding: f.binding, expectedIdentityGeneration: 0)
        XCTAssertEqual(try marker(f.context.url), accepted)
        let value = try await f.store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTAssertEqual(value?.currentWatchRequestID, next.requestID); XCTAssertEqual(value?.receipt.raw, receipt.raw)
        try await f.store.close()
    }
    func testChangedAdmissionAndGenerationFenceCurrentButKeepHistory() async throws {
        let f = try await fixture(), next = try WatchRegistrationContextV4(accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, phoneID: "next-phone", activationEpoch: 2, environment: .development)
        let generation = try await f.store.admitWatchRegistrationContextV4(next, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey)
        XCTAssertEqual(generation, 1)
        let raw = try await f.store.watchRegistrationReceiptV4(requestID: f.attempt.requestID); XCTAssertEqual(raw, f.receipt.raw)
        await rejected(f.store, error: .identityChanged); await rejected(f.store, generation: 1, error: .identityChanged)
        let inventory = try await f.store.captureInventoryV4(); XCTAssertTrue(inventory.isEmpty)
        try await f.store.close()
    }
    func testMissingOriginalPartsAreNotRecoveredFromAnotherReceipt() async throws {
        for removed in ["binding", "watch-attempt:watch-original", "watch-receipt:watch-original", "watch-admission:watch"] {
            let f = try await fixture()
            let s = try await mutate(f) { db in
                if removed == "binding" { try db.execute("DELETE FROM account_binding_v4 WHERE id='current'") }
                else { try db.execute("DELETE FROM lifecycle_steps_v4 WHERE id=?", [.text(removed)]) }
            }
            await rejected(s); try await s.close()
        }
        for gen in [Int64(-1), 9_007_199_254_740_992] { let f = try await fixture(); await rejected(f.store, generation: gen, error: .invalidWire); try await f.store.close() }
    }
    func testCanonicalCurrentTupleAndAdmissionMustMatchAcceptedProvenance() async throws {
        for field in ["account", "cloud", "device", "epoch", "role", "environment", "suspended", "generation", "parent", "admission-key"] {
            let f = try await fixture()
            let s = try await mutate(f) { db in
                if field == "generation" { try write(db, id: "identity-generation", value: Int64(1)); return }
                if field == "parent" || field == "admission-key" {
                    let context = try WatchRegistrationContextV4(accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, phoneID: field == "parent" ? "other-phone" : f.attempt.context.phoneID, activationEpoch: 1, environment: .development)
                    try write(db, id: "watch-admission:watch", value: MatchStore.StoredWatchAdmission(context: context, publicKey: field == "admission-key" ? AuthorityWire.base64URL(Data(repeating: 17, count: 32)) : f.attempt.payload.watchPublicKey)); return
                }
                let binding = try AccountBindingV4(accountID: field == "account" ? "other-account" : f.binding.accountID, cloudSpaceID: field == "cloud" ? "other-cloud" : f.binding.cloudSpaceID, deviceID: field == "device" ? "other-watch" : "watch", activationEpoch: field == "epoch" ? 2 : 1, role: field == "role" ? .phone : .watch, environment: field == "environment" ? .production : .development, suspended: field == "suspended")
                try write(db, table: "account_binding_v4", id: "current", value: binding)
            }
            await rejected(s); try await s.close()
        }
    }
    func testMarkerOriginalAttemptAndDeviceKeyAreIndependentlyChecked() async throws {
        for field in ["version", "requestID", "requestDigest", "acceptedGeneration", "receiptDigest", "watchPublicKey", "watchDeviceKeyID", "attempt", "acceptedBinding", "admittedContext"] {
            let f = try await fixture()
            let s = try await mutate(f) { db in
                if field == "attempt" { try write(db, id: "watch-attempt:watch-original", value: attempt(f.context, key: f.deviceKey, requestID: "another-request")); return }
                var obj = try object(db)
                switch field {
                case "version": obj[field] = 2
                case "acceptedGeneration": obj[field] = 1
                case "requestID": obj[field] = "another-request"
                case "acceptedBinding": var binding = try XCTUnwrap(obj[field] as? [String: Any]); binding["cloudSpaceID"] = "other-cloud"; obj[field] = binding
                case "admittedContext": var context = try XCTUnwrap(obj[field] as? [String: Any]); context["phoneID"] = "other-phone"; obj[field] = context
                default: obj[field] = field == "watchPublicKey" ? AuthorityWire.base64URL(Data(repeating: 31, count: 32)) : String(repeating: "b", count: 64)
                }
                try writeObject(db, id: "watch-current-v1", object: obj)
            }
            await rejected(s); try await s.close()
        }
    }
    func testBadSignatureAuthorityKeyAndPurposeCannotBorrowMarker() async throws {
        for field in ["signature", "keyID", "operation", "result", "matchID", "lockID", "recordingDeviceID", "registration"] {
            let f = try await fixture()
            let s = try await mutate(f) { db in
                var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: f.receipt.raw) as? [String: Any]), body = try XCTUnwrap(envelope["body"] as? [String: Any])
                switch field {
                case "keyID": body[field] = "unknown-authority-key"
                case "operation": body[field] = "authApple"
                case "result": body[field] = "knownAbandoned"
                case "registration": body[field] = ["watchID": "other-watch", "watchPublicKey": f.attempt.payload.watchPublicKey]
                case "signature": break
                default: body[field] = "unexpected"
                }
                let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
                envelope["body"] = body; envelope["signature"] = field == "signature" ? AuthorityWire.base64URL(Data(repeating: 0, count: 64)) : AuthorityWire.base64URL(try f.context.key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bytes)))
                let raw = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
                try write(db, id: "watch-receipt:watch-original", value: raw)
                var marker = try object(db); marker["receiptDigest"] = AuthorityWire.hash(raw); try writeObject(db, id: "watch-current-v1", object: marker)
            }
            await rejected(s); try await s.close()
        }
    }
    func testOversizedUnknownAndNoncanonicalRowsFailWithoutMutation() async throws {
        for field in ["extra-marker", "oversized-marker", "oversized-receipt", "checksum", "noncanonical", "oversized-binding", "oversized-attempt", "oversized-admission", "oversized-migration"] {
            let f = try await fixture()
            let s = try await mutate(f) { db in
                if field == "extra-marker" { try write(db, id: "watch-current-v2", value: "unknown"); return }
                if field == "checksum" { try db.execute("UPDATE lifecycle_steps_v4 SET checksum=? WHERE id='watch-current-v1'", [.text(String(repeating: "0", count: 64))]); return }
                if field == "noncanonical" { var obj = try object(db); obj["unexpected"] = true; try writeObject(db, id: "watch-current-v1", object: obj); return }
                if field == "oversized-receipt" { try write(db, id: "watch-receipt:watch-original", value: Data(repeating: 0, count: 16_385)); return }
                let raw = Data(repeating: 32, count: 32_769)
                let key = ["oversized-marker": "watch-current-v1", "oversized-binding": "current", "oversized-attempt": "watch-attempt:watch-original", "oversized-admission": "watch-admission:watch", "oversized-migration": "migration-latest"][field]!
                try db.execute("INSERT INTO " + (field == "oversized-binding" ? "account_binding_v4" : "lifecycle_steps_v4") + " VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum", [.text(key), .blob(raw), .text(Canonical.hash(raw))])
            }
            let before = try await s.watchEvidenceTestState(); await rejected(s)
            let after = try await s.watchEvidenceTestState(); XCTAssertEqual(before.rows, after.rows); XCTAssertEqual(before.changes, after.changes)
            try await s.close()
        }
    }
    func testReadSnapshotNeverMixesConcurrentGenerationAndBinding() async throws {
        let f = try await fixture(), other = try SQLite(url: f.context.url, fault: nil)
        let binding = try AccountBindingV4(accountID: f.binding.accountID, cloudSpaceID: f.binding.cloudSpaceID, deviceID: "watch", activationEpoch: 2, role: .watch, environment: .development)
        let bytes = try Canonical.data(binding), generation = try Canonical.data(Int64(1))
        let value = try await f.store.checkedCurrentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0, afterSnapshot: {
            try other.transaction {
                try other.execute("UPDATE account_binding_v4 SET payload=?,checksum=? WHERE id='current'", [.blob(bytes), .text(Canonical.hash(bytes))])
                try other.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text("identity-generation"), .blob(generation), .text(Canonical.hash(generation))])
            }
        })
        XCTAssertEqual(value?.binding, f.binding); XCTAssertEqual(value?.receipt.raw, f.receipt.raw)
        await rejected(f.store, error: .identityChanged); await rejected(f.store, generation: 1, error: .identityChanged)
        try other.close(); try await f.store.close()
    }
    func testReadNeedsNoWriterAndReleasesSnapshotAfterFailure() async throws {
        let f = try await fixture(), writer = try SQLite(url: f.context.url, fault: nil)
        let before = try await f.store.watchEvidenceTestState()
        try writer.execute("BEGIN IMMEDIATE")
        do {
            let value = try await f.store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
            XCTAssertEqual(value?.receipt.raw, f.receipt.raw); await rejected(f.store, generation: 1, error: .identityChanged)
            try writer.execute("ROLLBACK")
        } catch { try writer.execute("ROLLBACK"); try writer.close(); throw error }
        let after = try await f.store.watchEvidenceTestState()
        XCTAssertEqual(before.rows, after.rows); XCTAssertEqual(before.changes, after.changes)
        try writer.close(); try await f.store.setAnalyticsEnabledV4(true)
        let enabled = try await f.store.analyticsEnabledV4(); XCTAssertTrue(enabled); try await f.store.close()
    }
}

extension MatchStore {
    fileprivate func watchEvidenceTestState() throws -> (rows: [String], changes: Int64) {
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
