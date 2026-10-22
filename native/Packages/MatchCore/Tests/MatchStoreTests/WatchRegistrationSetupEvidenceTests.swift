import Foundation
import XCTest
import CryptoKit
@testable import MatchStore

final class WatchRegistrationSetupEvidenceTests: XCTestCase, @unchecked Sendable {
    let helper = CurrentWatchRegistrationEvidenceTests()

    func testFreshNativeStoreReturnsCheckedEmptyAndWritesNothing() async throws {
        let c = try helper.h.context(), key = Curve25519.Signing.PrivateKey()
        let publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
        let store = try helper.h.store(c)
        let before = try await store.setupEvidenceTestState()
        do {
            let value = try await store.watchRegistrationSetupEvidenceV4(
                expectedIdentityGeneration: 0, deviceID: "watch", publicKey: publicKey)
            XCTAssertEqual(value.state, .empty)
            XCTAssertNil(value.admittedContext)
            XCTAssertEqual(value.identityGeneration, 0)
            XCTAssertEqual(value.watchDeviceID, "watch")
            XCTAssertEqual(value.watchPublicKey, publicKey)
        } catch { XCTFail("an original empty Store must be checked locally without Phone context: \(error)") }
        let after = try await store.setupEvidenceTestState()
        XCTAssertEqual(before, after)
        try await store.close()
    }

    func testPureOriginalAdmissionIsSetupOnlyAnd055StillRejects() async throws {
        let c = try helper.h.context(), key = Curve25519.Signing.PrivateKey()
        let attempt = try helper.attempt(c, key: key)
        let store = try helper.h.store(c)
        _ = try await store.admitWatchRegistrationContextV4(
            attempt.context, deviceID: attempt.payload.watchID, publicKey: attempt.payload.watchPublicKey)
        let before = try await store.setupEvidenceTestState()
        do {
            let value = try await store.watchRegistrationSetupEvidenceV4(
                expectedIdentityGeneration: 0, deviceID: attempt.payload.watchID,
                publicKey: attempt.payload.watchPublicKey)
            XCTAssertEqual(value.state, .admissionOnly)
            XCTAssertEqual(value.admittedContext, attempt.context)
            XCTAssertEqual(value.watchDeviceKeyID,
                try AuthorityWire.deviceKeyID(publicKey: attempt.payload.watchPublicKey))
        } catch { XCTFail("the exact original admission must remain setup-retryable: \(error)") }
        do {
            _ = try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
            XCTFail("setup evidence cannot become current registration provenance")
        } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
        let after = try await store.setupEvidenceTestState()
        XCTAssertEqual(before, after)
        try await store.close()
    }

    struct Fixture {
        let original: LifecycleStateTests.Context
        let attempt: WatchRegistrationAttemptV4
        let store: MatchStore
    }
    func fixture(admitted: Bool = true) async throws -> Fixture {
        let c = try helper.h.context(), key = Curve25519.Signing.PrivateKey()
        let attempt = try helper.attempt(c, key: key), store = try helper.h.store(c)
        if admitted {
            _ = try await store.admitWatchRegistrationContextV4(attempt.context, deviceID: "watch", publicKey: attempt.payload.watchPublicKey)
        }
        return Fixture(original: c, attempt: attempt, store: store)
    }
    func read(_ f: Fixture, generation: Int64 = 0) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
        try await f.store.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: generation, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey)
    }
    func mutate(_ f: Fixture, _ body: (SQLite) throws -> Void) throws {
        let db = try SQLite(url: f.original.url, fault: nil)
        defer { try? db.close() }
        try db.transaction { try body(db) }
    }
    func rejected(_ f: Fixture, generation: Int64 = 0, deviceID: String = "watch", publicKey: String? = nil,
                  expected: AuthorityError? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try await f.store.setupEvidenceTestState()
        do {
            _ = try await f.store.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: generation, deviceID: deviceID, publicKey: publicKey ?? f.attempt.payload.watchPublicKey)
            XCTFail("incompatible setup facts must fail closed", file: file, line: line)
        } catch {
            XCTAssertTrue(error is AuthorityError || error is StoreError, "typed failure required: \(error)", file: file, line: line)
            if let expected { XCTAssertEqual(error as? AuthorityError, expected, file: file, line: line) }
        }
        let after = try await f.store.setupEvidenceTestState()
        XCTAssertEqual(before, after, "a read must not repair or delete facts", file: file, line: line)
    }
    func admissionObject(_ f: Fixture) throws -> [String: Any] {
        let raw = try Canonical.data(MatchStore.StoredWatchAdmission(context: f.attempt.context, publicKey: f.attempt.payload.watchPublicKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }
    func writeObject(_ db: SQLite, _ object: [String: Any], id: String = "watch-admission:watch") throws {
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum", [.text(id), .blob(raw), .text(Canonical.hash(raw))])
    }
    func testEmptyAndOriginalAdmissionReopenWithoutCreatingAnyFacts() async throws {
        for admitted in [false, true] {
            let f = try await fixture(admitted: admitted)
            let first = try await read(f), before = try await f.store.setupEvidenceTestState()
            try await f.store.close()
            let reopened = try helper.h.store(f.original)
            let actual = try await reopened.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey)
            XCTAssertEqual(actual.state, first.state)
            XCTAssertEqual(actual.admittedContext, admitted ? f.attempt.context : nil)
            XCTAssertEqual(actual.watchDeviceKeyID, first.watchDeviceKeyID)
            let after = try await reopened.setupEvidenceTestState()
            XCTAssertEqual(before.rows, after.rows); XCTAssertEqual(before.version, after.version)
            XCTAssertEqual(after.changes, 0)
            try await reopened.close()
        }
    }
    func testValidStoredContextIsReturnedWithoutClaimingFreshPhoneObservation() async throws {
        let f = try await fixture()
        let context = try WatchRegistrationContextV4(accountID: "other-account", cloudSpaceID: "other-cloud", phoneID: "other-phone", activationEpoch: 9, environment: .development)
        try mutate(f) { db in try helper.write(db, id: "watch-admission:watch", value: MatchStore.StoredWatchAdmission(context: context, publicKey: f.attempt.payload.watchPublicKey)) }
        let before = try await f.store.setupEvidenceTestState(), value = try await read(f)
        XCTAssertEqual(value.admittedContext, context)
        XCTAssertNotEqual(value.admittedContext, f.attempt.context, "fresh context comparison belongs to the consumer")
        let after = try await f.store.setupEvidenceTestState(); XCTAssertEqual(before, after)
        try await f.store.close()
    }
    func testGenerationAndCallerIdentityMustBeValidAndExact() async throws {
        let f = try await fixture()
        for generation in [Int64(-1), 9_007_199_254_740_992] { try await rejected(f, generation: generation, expected: .invalidWire) }
        try await rejected(f, generation: 1, expected: .identityChanged)
        for id in ["", "bad id", String(repeating: "a", count: 129)] { try await rejected(f, deviceID: id, expected: .invalidWire) }
        for key in ["", "bad=", AuthorityWire.base64URL(Data(repeating: 0, count: 31))] { try await rejected(f, publicKey: key, expected: .invalidWire) }
        let foreignKey = AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        try await rejected(f, publicKey: foreignKey, expected: .identityChanged)
        try await rejected(f, deviceID: "other-watch", expected: .unavailable)
        try mutate(f) { db in try helper.write(db, id: "identity-generation", value: Int64(4)) }
        try await rejected(f, expected: .identityChanged)
        let actual = try await read(f, generation: 4)
        XCTAssertEqual(actual.identityGeneration, 4); XCTAssertEqual(actual.admittedContext, f.attempt.context)
        try await f.store.close()
    }
    func testStoredContextInitializerAndFixedEnvironmentAreRechecked() async throws {
        let cases: [(String, Any)] = [("accountID", "bad account"), ("cloudSpaceID", ""), ("phoneID", "bad phone"), ("phoneID", "watch"), ("activationEpoch", 0), ("activationEpoch", 9_007_199_254_740_992 as Int64), ("environment", "production")]
        for (field, bad) in cases {
            let f = try await fixture(); var object = try admissionObject(f)
            var context = try XCTUnwrap(object["context"] as? [String: Any]); context[field] = bad; object["context"] = context
            try mutate(f) { try writeObject($0, object) }
            try await rejected(f); try await f.store.close()
        }
        let f = try await fixture(admitted: false); try await f.store.close()
        let noTrust = try MatchStore(url: f.original.url, syncEnvironment: .development(databaseNamespace: "lifecycle"))
        do { _ = try await noTrust.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey); XCTFail("fixed Store trust is required even for empty setup") }
        catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
        try await noTrust.close()
        let wrongMode = try MatchStore(url: f.original.url, authorityTrust: f.original.trust)
        do { _ = try await wrongMode.watchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey); XCTFail("development trust cannot authorize production setup") }
        catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
        try await wrongMode.close()
    }
    func testRealPendingClosedReceiptOnlyAcceptedAndLegacyHistoryBlock() async throws {
        for mode in ["pending", "closed", "receipt-only", "accepted", "legacy"] {
            let f = try await fixture()
            try await f.store.saveWatchRegistrationAttemptV4(f.attempt, expectedIdentityGeneration: 0)
            let receipt = try helper.signed(f.original, attempt: f.attempt, result: mode == "closed" ? .knownAbandoned : .registered)
            if mode == "closed" {
                try await f.store.closeWatchRegistrationV4(f.attempt, receipt: receipt, expectedIdentityGeneration: 0)
            } else if mode != "pending" {
                let binding = try AccountBindingV4(accountID: f.attempt.context.accountID, cloudSpaceID: f.attempt.context.cloudSpaceID, deviceID: "watch", activationEpoch: 1, role: .watch, environment: .development)
                try await f.store.acceptWatchRegistrationV4(f.attempt, receipt: receipt, watchBinding: mode == "receipt-only" ? nil : binding, expectedIdentityGeneration: 0)
            }
            if mode == "legacy" { try mutate(f) { try $0.execute("DELETE FROM lifecycle_steps_v4 WHERE id='watch-current-v1'") } }
            try await rejected(f)
            let pending = try await f.store.pendingWatchRegistrationAttemptsV4()
            XCTAssertEqual(pending.count, mode == "pending" ? 1 : 0, "pending-empty must not be treated as no history")
            if mode != "pending" {
                let raw = try await f.store.watchRegistrationReceiptV4(requestID: f.attempt.requestID)
                XCTAssertEqual(raw, receipt.raw)
            }
            if mode == "accepted" {
                let original = try await f.store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
                XCTAssertEqual(original?.receipt.raw, receipt.raw)
            } else {
                do { _ = try await f.store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0); XCTFail("055 remains unavailable without actual current provenance") }
                catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
            }
            try await f.store.close()
        }
    }
    func testAllLifecycleHistoryAndUnknownFamiliesAreRejectedWithoutDecodingThem() async throws {
        let ids = ["watch-attempt:x", "watch-receipt:x", "watch-current-v1", "watch-current-v9", "watch-current", "watch-admission:other", "auth-current", "auth-attempt:x", "auth-admission:x", "auth-receipt:x", "auth-resolved:x", "control-queue:x", "lifecycle-result:x", "normal-intent:x", "migration-latest", "migration-checkpoint:x", "deletion:x", "delete-control-v1:parent:x", "delete-control-v1:attempt:x", "delete-control-v1:confirmation:x", "delete-control-v1:proof:x", "delete-control-v99:x", "analytics-state", "future-unknown"]
        for id in ids {
            let f = try await fixture()
            try mutate(f) { db in try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text(id), .blob(Data([0xff])), .text("damaged")]) }
            try await rejected(f, expected: .unavailable)
            try await f.store.close()
        }
    }
    func testRawKeysMultipleAdmissionsAndRowBudgetsAreStrict() async throws {
        for id in ["", String(repeating: "x", count: 161), "WATCH-admission:watch", "watch-admission:watch\0hidden"] {
            let f = try await fixture(admitted: false)
            try mutate(f) { db in try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text(id), .blob(Data("0".utf8)), .text(Canonical.hash(Data("0".utf8)))]) }
            try await rejected(f); try await f.store.close()
        }
        let invalidUTF8 = try await fixture(admitted: false)
        try mutate(invalidUTF8) { db in try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (CAST(? AS TEXT),?,?)", [.blob(Data([0xff])), .blob(Data()), .text(String(repeating: "a", count: 64))]) }
        try await rejected(invalidUTF8, expected: .invalidWire); try await invalidUTF8.store.close()
        let multiple = try await fixture()
        try mutate(multiple) { db in try helper.write(db, id: "watch-admission:other", value: MatchStore.StoredWatchAdmission(context: multiple.attempt.context, publicKey: multiple.attempt.payload.watchPublicKey)) }
        try await rejected(multiple, expected: .unavailable)
        try mutate(multiple) { db in try helper.write(db, id: "identity-generation", value: Int64(0)) }
        try await rejected(multiple, expected: .invalidWire); try await multiple.store.close()
    }
    func testAllowedRowsRequireCanonicalChecksumTypesAndPayloadBudgets() async throws {
        for corruption in ["checksum", "noncanonical", "extra", "missing", "null", "text", "checksum-blob", "oversize", "generation-negative", "generation-oversize"] {
            let f = try await fixture()
            try mutate(f) { db in
                switch corruption {
                case "checksum": try db.execute("UPDATE lifecycle_steps_v4 SET checksum=?", [.text(String(repeating: "0", count: 64))])
                case "text": try db.execute("UPDATE lifecycle_steps_v4 SET payload=?", [.text("{}")])
                case "checksum-blob": try db.execute("UPDATE lifecycle_steps_v4 SET checksum=?", [.blob(Data(repeating: 97, count: 64))])
                case "generation-negative": try helper.write(db, id: "identity-generation", value: Int64(-1))
                case "generation-oversize":
                    let raw = Data(repeating: 32, count: 32_769)
                    try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text("identity-generation"), .blob(raw), .text(Canonical.hash(raw))])
                default:
                    var object = try admissionObject(f)
                    let raw: Data
                    if corruption == "extra" { object["unknown"] = true; raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
                    else if corruption == "missing" { object["context"] = nil; raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
                    else if corruption == "null" { raw = Data("null".utf8) }
                    else if corruption == "oversize" { raw = Data(repeating: 32, count: 32_769) }
                    else { raw = Data(" ".utf8) + (try Canonical.data(MatchStore.StoredWatchAdmission(context: f.attempt.context, publicKey: f.attempt.payload.watchPublicKey))) }
                    try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=?", [.blob(raw), .text(Canonical.hash(raw))])
                }
            }
            try await rejected(f); try await f.store.close()
        }
    }
    func testEveryNonLifecycleSchemaTableBlocksSetupByPresence() async throws {
        let tables = ["account_binding_v4", "control_intents_v4", "authority_results_v4", "authority_projection_v4", "peer_grants_v4", "peer_contexts_v4", "peer_inbox_v4", "cloud_applied_batches_v4", "cloud_checkpoints_v4", "cloud_records_v4", "cloud_history_v4", "cloud_cursors_v4", "cloud_deletions_v4", "matches", "events", "commands", "outbox", "inbound", "diagnostics", "completion", "capture_identities", "capture_revisions", "capture_operations", "capture_operation_history", "business_outbox", "commands_v2", "completion_confirmations", "completion_v2", "sync_delivery_v3", "sync_fragments_v3", "sync_context_v3", "sync_registry_v3", "sync_routes_v3", "sync_sequences_v3", "sync_inbox_v3", "sync_acknowledgements_v3", "sync_ack_controls_v3", "sync_receive_progress_v3"]
        XCTAssertEqual(Set(tables).count, 38)
        for table in tables {
            let f = try await fixture()
            try mutate(f) { db in
                let columns = try db.rows("PRAGMA table_info(" + table + ")")
                let names = try columns.map { row -> String in try XCTUnwrap(row[1].string) }
                let values: [SQLValue] = columns.map { row in
                    switch row[2].string { case "INTEGER": .integer(1); case "BLOB": .blob(Data([0xff])); default: .text("foreign") }
                }
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
                try db.execute("INSERT INTO " + table + " (" + names.joined(separator: ",") + ") VALUES (" + placeholders + ")", values)
            }
            try await rejected(f, expected: .unavailable); try await f.store.close()
        }
    }
    func testPhoneWaitingWatchAndSuspendedBindingsCannotBecomeSetup() async throws {
        for role in [AccountBindingV4.Role.phone, .waiting, .watch] {
            for suspended in [false, true] {
                let f = try await fixture()
                let binding = try AccountBindingV4(accountID: f.attempt.context.accountID, cloudSpaceID: f.attempt.context.cloudSpaceID, deviceID: role == .watch ? "watch" : "phone", activationEpoch: 1, role: role, environment: .development, suspended: suspended)
                try await f.store.bindAccountV4(binding)
                try await rejected(f, expected: .unavailable); try await f.store.close()
            }
        }
    }
    func testReadSnapshotNeverMixesConcurrentGenerationAndAdmission() async throws {
        let f = try await fixture(), other = try SQLite(url: f.original.url, fault: nil)
        let context = try WatchRegistrationContextV4(accountID: "new-account", cloudSpaceID: "new-cloud", phoneID: "new-phone", activationEpoch: 2, environment: .development)
        let raw = try Canonical.data(MatchStore.StoredWatchAdmission(context: context, publicKey: f.attempt.payload.watchPublicKey)), generation = try Canonical.data(Int64(1))
        let value = try await f.store.checkedWatchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey, afterSnapshot: {
            try other.transaction {
                try other.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='watch-admission:watch'", [.blob(raw), .text(Canonical.hash(raw))])
                try other.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text("identity-generation"), .blob(generation), .text(Canonical.hash(generation))])
            }
        })
        XCTAssertEqual(value.identityGeneration, 0); XCTAssertEqual(value.admittedContext, f.attempt.context)
        try await rejected(f, expected: .identityChanged)
        let next = try await read(f, generation: 1)
        XCTAssertEqual(next.identityGeneration, 1); XCTAssertEqual(next.admittedContext, context)
        XCTAssertNotEqual(value.admittedContext, next.admittedContext)
        let foreignKey = AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        try other.transaction { try helper.write(other, id: "watch-admission:watch", value: MatchStore.StoredWatchAdmission(context: context, publicKey: foreignKey)) }
        try await rejected(f, generation: 1, expected: .identityChanged)
        try other.close(); try await f.store.close()
    }
    func testDeferredReadNeedsNoWriterAndReleasesSnapshotOnEveryFailure() async throws {
        let f = try await fixture(), writer = try SQLite(url: f.original.url, fault: nil)
        try writer.execute("BEGIN IMMEDIATE")
        do {
            let value = try await read(f); XCTAssertEqual(value.admittedContext, f.attempt.context)
            try await rejected(f, generation: 1, expected: .identityChanged)
            try writer.execute("COMMIT")
        } catch { try writer.execute("ROLLBACK"); try writer.close(); throw error }
        do {
            _ = try await f.store.checkedWatchRegistrationSetupEvidenceV4(expectedIdentityGeneration: 0, deviceID: "watch", publicKey: f.attempt.payload.watchPublicKey, afterSnapshot: { throw AuthorityError.conflict })
            XCTFail("the injected snapshot error must remain an error")
        } catch { XCTAssertEqual(error as? AuthorityError, .conflict) }
        let again = try await read(f); XCTAssertEqual(again.admittedContext, f.attempt.context)
        try writer.close(); try await f.store.close()
        do { _ = try await read(f); XCTFail("closed Store cannot supply setup") }
        catch { XCTAssertEqual(error as? StoreError, .closed) }
    }
    func testUnknownAndPartialLayoutsFailWithoutSchemaRepair() async throws {
        for kind in ["table", "trigger", "missing", "version"] {
            let f = try await fixture()
            try mutate(f) { db in
                switch kind {
                case "table": try db.execute("CREATE TABLE future_setup (id TEXT)")
                case "trigger": try db.execute("CREATE TRIGGER future_setup AFTER INSERT ON matches BEGIN SELECT 1; END")
                case "missing": try db.execute("DROP TABLE cloud_cursors_v4")
                default: try db.execute("PRAGMA user_version=3")
                }
            }
            try await rejected(f); try await f.store.close()
        }
    }
}

private struct SetupEvidenceTestState: Equatable {
    let version: Int64
    let rows: [String]
    let changes: Int64
}

extension MatchStore {
    fileprivate func setupEvidenceTestState() throws -> SetupEvidenceTestState {
        func value(_ item: SQLValue) -> String {
            switch item {
            case .text(let text): "text:" + Data(text.utf8).base64EncodedString()
            case .blob(let bytes): "blob:" + bytes.base64EncodedString()
            case .integer(let n): "int:" + String(n)
            case .null: "null"
            }
        }
        let schema = try db.rows("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
        var rows = schema.map { "schema:" + $0.map(value).joined(separator: "|") }
        for entry in schema where entry[0].string == "table" {
            let name = try XCTUnwrap(entry[1].string), quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            rows += try db.rows("SELECT * FROM " + quoted + " ORDER BY rowid").map { name + ":" + $0.map(value).joined(separator: "|") }
        }
        return SetupEvidenceTestState(version: try db.scalar("PRAGMA user_version").number ?? -1, rows: rows, changes: try db.scalar("SELECT total_changes()").number ?? -1)
    }
}
