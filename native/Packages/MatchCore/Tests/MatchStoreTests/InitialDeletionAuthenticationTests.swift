import Foundation
import XCTest
import CryptoKit
import MatchCore
@testable import MatchStore

final class InitialDeletionAuthenticationTests: XCTestCase, @unchecked Sendable {
    private let h = LifecycleStateTests()
    private struct Fixture {
        let context: LifecycleStateTests.Context
        let store: MatchStore
        let source: VerifiedLocalAuthenticationEvidenceV4
        let request: InitialDeletionRequestV1
    }
    private func fixture() async throws -> Fixture {
        let c = try h.context(), store = try h.store(c)
        let attempt = try AuthAttemptV4(requestID: "original-auth", deviceID: c.binding.deviceID,
            publicKey: AuthorityWire.base64URL(c.key.publicKey.rawRepresentation), cloudSpaceID: c.binding.cloudSpaceID,
            challengeID: "original-challenge", requestDigest: String(repeating: "a", count: 64), environment: .development)
        try await store.saveAuthAttemptV4(attempt)
        let signed = try h.receipt(c, requestID: attempt.requestID, digest: attempt.requestDigest, operation: .authApple, result: .registered)
        try await store.acceptAuthenticationV4(attempt: attempt, binding: c.binding, receipt: signed)
        let evidence = try await store.currentAuthenticationEvidenceV4(expectedIdentityGeneration: 0)
        let scope = try CloudScopeV1(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, zoneID: "matches", activationEpoch: 1)
        return Fixture(context: c, store: store, source: try XCTUnwrap(evidence),
            request: try InitialDeletionRequestV1(creationID: "delete", originalScope: scope,
                cloud: .keep, local: .delete, health: .keep, healthConfirmed: false, confirmedAt: 1_700_000_000))
    }
    private func prepare(_ f: Fixture, auth: String = "fresh-auth", challenge: String = "fresh-challenge") async throws -> InitialDeletionContextV1 {
        try await f.store.prepareInitialDeletionAuthenticationV4(request: f.request, expectedSource: f.source,
            authRequestID: auth, challengeRequestID: challenge)
    }
    private func attempt(_ f: Fixture, id: String = "fresh-auth", digest: String = String(repeating: "b", count: 64)) throws -> AuthAttemptV4 {
        try AuthAttemptV4(requestID: id, deviceID: f.source.attempt.deviceID, publicKey: f.source.attempt.publicKey,
            cloudSpaceID: f.source.attempt.cloudSpaceID, challengeID: "server-challenge-" + id,
            requestDigest: digest, environment: .development)
    }
    private func sql<T>(_ f: Fixture, _ action: (SQLite) throws -> T) throws -> T {
        let db = try SQLite(url: f.context.url, fault: nil)
        defer { try? db.close() }
        return try action(db)
    }
    private func rawRows(_ f: Fixture, table: String = "lifecycle_steps_v4", excludingPurpose: Bool = false) throws -> [[String]] {
        try sql(f) { db in
            let condition = excludingPurpose ? " WHERE substr(CAST(id AS BLOB),1,19) != CAST('initial-delete-auth' AS BLOB)" : ""
            return try db.rows("SELECT quote(id),quote(payload),quote(checksum) FROM " + table + condition + " ORDER BY id")
                .map { $0.map { $0.string! } }
        }
    }
    private func insert(_ f: Fixture, key: SQLValue, payload: Data, keyExpression: String = "?") throws {
        try sql(f) { db in
            try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (" + keyExpression + ",?,?)", [key, .blob(payload), .text(Canonical.hash(payload))])
        }
    }
    private func rejected(_ body: () async throws -> Void, issue: InitialDeletionIssueV1? = nil,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("must reject without changing original authorization", file: file, line: line) }
        catch { if let issue { XCTAssertEqual(error as? InitialDeletionIssueV1, issue, file: file, line: line) } }
    }
    private func canonicalObject(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(value)) as? [String: Any])
    }
    private func update(_ f: Fixture, key: String, _ change: (inout [String: Any]) throws -> Void) throws {
        try sql(f) { db in
            let raw = try XCTUnwrap(db.scalar("SELECT payload FROM lifecycle_steps_v4 WHERE id=?", [.text(key)]).data)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any]); try change(&object)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id=?", [.blob(bytes), .text(Canonical.hash(bytes)), .text(key)])
        }
    }
    private func associated(_ f: Fixture, opaqueID: String? = "fresh-reauth") async throws -> InitialDeletionReservationV1? {
        _ = try await prepare(f)
        let fresh = try attempt(f)
        try await f.store.saveInitialDeletionAttemptV4(creationID: "delete", authentication: fresh, expectedIdentityGeneration: 0)
        let receipt = try h.receipt(f.context, requestID: fresh.requestID, digest: fresh.requestDigest, operation: .authApple, result: .registered)
        try await f.store.acceptInitialDeletionAuthenticationV4(creationID: "delete", authRequestID: fresh.requestID, receipt: receipt,
            opaqueReauthenticationID: opaqueID, expectedIdentityGeneration: 0)
        if opaqueID == nil { return nil }
        return try await f.store.reserveInitialDeletionV4(creationID: "delete", expectedIdentityGeneration: 0)
    }
    private func saga(_ f: Fixture, id: String = "delete", opaqueID: String = "fresh-reauth") throws -> DeletionSagaV4 {
        let cap = AuthorityWire.base64URL(Data(repeating: 41, count: 32))
        var fields = AuthorityFields(); fields.reauthenticationID = opaqueID; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(cap.utf8))
        return try DeletionSagaV4(intent: ControlIntentV1(requestID: id, operation: .deleteAccount, fields: fields),
            accountID: f.source.binding.accountID, activationEpoch: f.source.binding.activationEpoch, recoveryCapability: cap,
            cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: f.request.originalScope)
    }
    private func reservationBytes(_ value: InitialDeletionReservationV1) throws -> Data {
        try Canonical.data([AuthorityWire.encode(value.request).base64EncodedString(), String(value.identityGeneration),
            value.originalAuthRequestID, value.originalAuthReceiptDigest, value.initialAuthRequestID, value.initialAuthRequestDigest,
            value.initialAuthReceiptDigest, value.opaqueReauthenticationID])
    }
    private func watch(_ f: Fixture, requestID: String, challengeID: String) throws -> WatchRegistrationAttemptV4 {
        let key = Curve25519.Signing.PrivateKey(), publicKey = AuthorityWire.base64URL(key.publicKey.rawRepresentation)
        let hash = String(repeating: "c", count: 64)
        let unsigned: [String: Any] = ["version": 1, "requestID": requestID, "watchID": "watch", "watchPublicKey": publicKey,
            "challengeID": "watch-server-challenge", "challengeSHA256": hash]
        let bytes = try JSONSerialization.data(withJSONObject: unsigned, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = try key.signature(for: AuthorityWire.signedInput("football-record.device.challenge.v1", body: bytes))
        let context = try WatchRegistrationContextV4(accountID: f.source.binding.accountID, cloudSpaceID: f.source.binding.cloudSpaceID,
            phoneID: f.source.binding.deviceID, activationEpoch: 1, environment: .development)
        return try WatchRegistrationAttemptV4(context: context, payload: WatchRegistrationPayloadV4(requestID: requestID,
            watchID: "watch", watchPublicKey: publicKey, challengeID: "watch-server-challenge", deviceProof: AuthorityWire.base64URL(signature)),
            challengeRequestID: challengeID, challengeSHA256: hash)
    }

    func testSchemaSourceAndStrictPrefix() async throws {
        // S01: schema4 and original normal proof survive a real close/reopen.
        let f = try await fixture()
        let schema = try sql(f) { try $0.rows("SELECT quote(type),quote(name),quote(tbl_name),quote(sql) FROM sqlite_master ORDER BY name").map { $0.map { $0.string! } } }
        let normal = try rawRows(f), binding = try rawRows(f, table: "account_binding_v4")
        let first = try await prepare(f)
        XCTAssertEqual(first.request, f.request); XCTAssertEqual(first.phase, .preparing)
        XCTAssertEqual(first.originalAuthentication.receipt.raw, f.source.receipt.raw)
        XCTAssertEqual(first.attempts.count, 1); XCTAssertNil(first.attempts[0].authentication)
        try await f.store.close()
        let reopened = try h.store(f.context)
        let saved = try await reopened.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
        XCTAssertEqual(saved?.request, f.request); XCTAssertEqual(saved?.originalAuthentication.attempt, f.source.attempt)
        XCTAssertEqual(saved?.originalAuthentication.admissionGeneration, 0)
        XCTAssertEqual(try rawRows(f, excludingPurpose: true), normal)
        XCTAssertEqual(try rawRows(f, table: "account_binding_v4"), binding)
        XCTAssertEqual(try sql(f) { try $0.scalar("PRAGMA user_version").number }, 4)
        XCTAssertEqual(try sql(f) { try $0.rows("SELECT quote(type),quote(name),quote(tbl_name),quote(sql) FROM sqlite_master ORDER BY name").map { $0.map { $0.string! } } }, schema)
        try await reopened.close()

        // S02: every part of the original source is re-read in the write transaction.
        for key in ["auth-current", "auth-attempt:original-auth", "auth-receipt:original-auth", "auth-admission:original-auth", "identity-generation", "binding"] {
            let x = try await fixture()
            if key == "binding" {
                try sql(x) { try $0.execute("DELETE FROM account_binding_v4 WHERE id='current'") }
            } else if key == "identity-generation" {
                let bytes = try Canonical.data(Int64(1))
                try insert(x, key: .text(key), payload: bytes)
            } else {
                try sql(x) { try $0.execute("DELETE FROM lifecycle_steps_v4 WHERE id=?", [.text(key)]) }
            }
            let before = try rawRows(x)
            await rejected { _ = try await self.prepare(x) }
            XCTAssertEqual(try rawRows(x), before)
            try await x.store.close()
        }
        for role in [AccountBindingV4.Role.waiting, .watch] {
            let x = try await fixture()
            let value = try AccountBindingV4(accountID: x.source.binding.accountID, cloudSpaceID: x.source.binding.cloudSpaceID,
                deviceID: x.source.binding.deviceID, activationEpoch: 1, role: role, environment: .development)
            let bytes = try Canonical.data(value)
            try sql(x) { try $0.execute("UPDATE account_binding_v4 SET payload=?,checksum=? WHERE id='current'", [.blob(bytes), .text(Canonical.hash(bytes))]) }
            await rejected { _ = try await self.prepare(x) }; try await x.store.close()
        }

        // S03: inject actual SQLite BLOB and malformed UTF-8 TEXT ids, not Swift DTO failures.
        for variant in ["future", "unknown-kind", "blob-id", "bad-utf8", "orphan-result", "extra-field", "hash-key", "duplicate-ordinal"] {
            let x = try await fixture(); _ = try await prepare(x)
            if variant == "extra-field" {
                try update(x, key: "initial-delete-auth-v1:head") { $0["future"] = true }
            } else if variant == "hash-key" {
                try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET id=? WHERE id LIKE 'initial-delete-auth-v1:attempt:%'", [.text("initial-delete-auth-v1:attempt:" + String(repeating: "0", count: 64))]) }
            } else if variant == "duplicate-ordinal" {
                try await x.store.closePreparedInitialDeletionAttemptV4(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0)
                _ = try await prepare(x, auth: "second-auth", challenge: "second-challenge")
                try update(x, key: "initial-delete-auth-v1:attempt:" + AuthorityWire.hash(Data("second-auth".utf8))) { $0["ordinal"] = 0 }
            } else {
                let key: SQLValue
                var expression = "?"
                switch variant {
                case "blob-id": key = .blob(Data("initial-delete-auth-v1:blob".utf8))
                case "bad-utf8": key = .blob(Data("initial-delete-auth".utf8) + Data([0xff])); expression = "CAST(? AS TEXT)"
                case "future": key = .text("initial-delete-auth-v2:head")
                case "orphan-result": key = .text("initial-delete-auth-v1:result:" + String(repeating: "c", count: 64))
                default: key = .text("initial-delete-auth-v1:future")
                }
                try insert(x, key: key, payload: Data("{}".utf8), keyExpression: expression)
            }
            let before = try rawRows(x)
            await rejected { _ = try await x.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }
            XCTAssertEqual(try rawRows(x), before); try await x.store.close()
        }

        // S04: attempts cannot evade the fixed allocation or reserve response storage after dispatch.
        let capacity = try await fixture()
        for index in 0..<16 {
            _ = try await prepare(capacity, auth: "auth-\(index)", challenge: "challenge-\(index)")
            try await capacity.store.closePreparedInitialDeletionAttemptV4(creationID: "delete", authRequestID: "auth-\(index)", expectedIdentityGeneration: 0)
        }
        let full = try rawRows(capacity)
        XCTAssertEqual(try sql(capacity) { try $0.scalar("SELECT max(length(CAST(id AS BLOB))) FROM lifecycle_steps_v4 WHERE id LIKE 'initial-delete-auth%'").number }, 98)
        await rejected({ _ = try await self.prepare(capacity, auth: "auth-16", challenge: "challenge-16") }, issue: .capacity)
        XCTAssertEqual(try rawRows(capacity), full); try await capacity.store.close()
        for size in [65_537, 2 * 1024 * 1024 + 1] {
            let x = try await fixture()
            try insert(x, key: .text("initial-delete-auth-v1:head"), payload: Data(repeating: 32, count: size))
            await rejected({ _ = try await x.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .capacity)
            try await x.store.close()
        }
        for variant in ["rows", "total"] {
            let x = try await fixture()
            for ordinal in 0..<(variant == "rows" ? 50 : 33) {
                let payload = variant == "rows" ? Data("{}".utf8) : Data(repeating: 32, count: ordinal == 32 ? 1 : 65_536)
                try insert(x, key: .text("initial-delete-auth-v1:budget-\(ordinal)"), payload: payload)
            }
            await rejected({ _ = try await x.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .capacity)
            try await x.store.close()
        }
        for kind in ["text", "blob"] {
            let x = try await fixture(), long = "initial-delete-auth-v1:" + String(repeating: "x", count: 65_536)
            try insert(x, key: kind == "text" ? .text(long) : .blob(Data(long.utf8)), payload: Data("{}".utf8))
            let before = try rawRows(x)
            await rejected({ _ = try await x.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .capacity)
            XCTAssertEqual(try rawRows(x), before); try await x.store.close()
        }
    }

    func testAttemptsAndBidirectionalIsolation() async throws {
        // S05: immutable request/source and CAS from prepared to sent or notDispatched.
        let f = try await fixture()
        _ = try await prepare(f); _ = try await prepare(f)
        let before = try rawRows(f)
        let changed = try InitialDeletionRequestV1(creationID: "delete", originalScope: f.request.originalScope,
            cloud: .keep, local: .delete, health: .keep, healthConfirmed: false, confirmedAt: f.request.confirmedAt + 1)
        await rejected { _ = try await f.store.prepareInitialDeletionAuthenticationV4(request: changed, expectedSource: f.source, authRequestID: "fresh-auth", challengeRequestID: "fresh-challenge") }
        await rejected { _ = try await self.prepare(f, auth: "another-auth", challenge: "another-challenge") }
        XCTAssertEqual(try rawRows(f), before)
        try await f.store.closePreparedInitialDeletionAttemptV4(creationID: "delete", authRequestID: "fresh-auth", expectedIdentityGeneration: 0)
        await rejected { try await f.store.saveInitialDeletionAttemptV4(creationID: "delete", authentication: self.attempt(f), expectedIdentityGeneration: 0) }
        let next = try await prepare(f, auth: "second-auth", challenge: "second-challenge")
        XCTAssertEqual(next.attempts.map(\.authRequestID), ["fresh-auth", "second-auth"])
        XCTAssertEqual(next.attempts[0].resolution, .notDispatched)

        // S06: a saved attempt remains unknown and cannot grant a second fresh request.
        let sent = try attempt(f, id: "second-auth")
        try await f.store.saveInitialDeletionAttemptV4(creationID: "delete", authentication: sent, expectedIdentityGeneration: 0)
        try await f.store.saveInitialDeletionAttemptV4(creationID: "delete", authentication: sent, expectedIdentityGeneration: 0)
        let unknown = try rawRows(f)
        await rejected({ _ = try await self.prepare(f, auth: "third-auth", challenge: "third-challenge") }, issue: .unresolved)
        await rejected { try await f.store.closePreparedInitialDeletionAttemptV4(creationID: "delete", authRequestID: sent.requestID, expectedIdentityGeneration: 0) }
        XCTAssertEqual(try rawRows(f), unknown)
        try await f.store.resolveInitialDeletionAttemptV4(creationID: "delete", authRequestID: sent.requestID, resolution: .knownAbandoned, expectedIdentityGeneration: 0)
        _ = try await prepare(f, auth: "third-auth", challenge: "third-challenge")
        try await f.store.close()

        // S07: all four original mutations reject before even their idempotent or generation branches.
        for action in ["save", "accept", "resolve", "terminal"] {
            let x = try await fixture(); _ = try await prepare(x)
            let normal = try rawRows(x, excludingPurpose: true), binding = try rawRows(x, table: "account_binding_v4")
            let pending = try await x.store.pendingAuthAttemptsV4(); XCTAssertTrue(pending.isEmpty)
            await rejected {
                switch action {
                case "save": try await x.store.saveAuthAttemptV4(x.source.attempt, expectedIdentityGeneration: 0)
                case "accept": try await x.store.acceptAuthenticationV4(attempt: x.source.attempt, binding: x.source.binding, receipt: x.source.receipt, expectedIdentityGeneration: 0)
                case "resolve": try await x.store.resolveAuthAttemptV4(requestID: x.source.currentAuthRequestID, resolution: .knownAbandoned)
                default: _ = try await x.store.resolveTerminalAuthenticationV4(requestID: x.source.currentAuthRequestID, resolution: .knownExpired, expectedIdentityGeneration: 0)
                }
            }
            XCTAssertEqual(try rawRows(x, excludingPurpose: true), normal)
            XCTAssertEqual(try rawRows(x, table: "account_binding_v4"), binding)
            try await x.store.close()
        }
        // S08: original control and Watch request/challenge claims cannot adopt purpose ids.
        for id in ["delete", "fresh-auth", "fresh-challenge"] {
            let x = try await fixture(); _ = try await prepare(x)
            let before = try rawRows(x)
            await rejected { _ = try await x.store.prepareControlV4(self.saga(x, id: id).intent) }
            XCTAssertEqual(try rawRows(x), before); try await x.store.close()
        }
        for field in ["request", "challenge"] {
            let x = try await fixture(); _ = try await prepare(x)
            let value = try watch(x, requestID: field == "request" ? "fresh-auth" : "watch-request",
                challengeID: field == "challenge" ? "fresh-challenge" : "watch-challenge")
            let before = try rawRows(x)
            await rejected { try await x.store.saveWatchRegistrationAttemptV4(value, expectedIdentityGeneration: 0) }
            XCTAssertEqual(try rawRows(x), before); try await x.store.close()
        }
        for field in ["request", "challenge"] {
            let x = try await fixture(), value = try watch(x, requestID: "watch-request", challengeID: "watch-challenge")
            try await x.store.saveWatchRegistrationAttemptV4(value, expectedIdentityGeneration: 0)
            let closed = try h.receipt(x.context, requestID: value.requestID, digest: value.requestDigest, operation: .registerWatch,
                result: .knownAbandoned, extra: ["registration": ["watchID": value.payload.watchID, "watchPublicKey": value.payload.watchPublicKey]])
            try await x.store.closeWatchRegistrationV4(value, receipt: closed, expectedIdentityGeneration: 0)
            await rejected { _ = try await self.prepare(x, auth: field == "request" ? "watch-request" : "fresh-auth", challenge: field == "challenge" ? "watch-challenge" : "fresh-challenge") }
            try await x.store.close()
        }
    }

    func testAssociationAndReservation() async throws {
        // S09: signed results and their opaque handle are immutable; real nil is preserved.
        for opaque: String? in [nil, "fresh-reauth"] {
            let f = try await fixture(), normal = try rawRows(f), binding = try rawRows(f, table: "account_binding_v4")
            _ = try await prepare(f); let fresh = try attempt(f)
            try await f.store.saveInitialDeletionAttemptV4(creationID: "delete", authentication: fresh, expectedIdentityGeneration: 0)
            let receipt = try h.receipt(f.context, requestID: fresh.requestID, digest: fresh.requestDigest, operation: .authApple, result: .registered)
            for _ in 0..<2 { try await f.store.acceptInitialDeletionAuthenticationV4(creationID: "delete", authRequestID: fresh.requestID,
                receipt: receipt, opaqueReauthenticationID: opaque, expectedIdentityGeneration: 0) }
            let context = try await f.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            XCTAssertEqual(context?.association?.receipt.raw, receipt.raw); XCTAssertEqual(context?.association?.opaqueReauthenticationID, opaque)
            XCTAssertNil(context?.reservation)
            let before = try rawRows(f)
            await rejected { try await f.store.acceptInitialDeletionAuthenticationV4(creationID: "delete", authRequestID: fresh.requestID,
                receipt: receipt, opaqueReauthenticationID: "other-reauth", expectedIdentityGeneration: 0) }
            XCTAssertEqual(try rawRows(f), before)
            XCTAssertEqual(try rawRows(f, excludingPurpose: true), normal); XCTAssertEqual(try rawRows(f, table: "account_binding_v4"), binding)
            if opaque == nil {
                await rejected({ _ = try await f.store.reserveInitialDeletionV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .missingReauthentication)
                await rejected { _ = try await self.prepare(f, auth: "another", challenge: "another-challenge") }
            } else {
                // S10: the reservation carries original provenance and separate fresh linkage.
                let first = try await f.store.reserveInitialDeletionV4(creationID: "delete", expectedIdentityGeneration: 0)
                let second = try await f.store.reserveInitialDeletionV4(creationID: "delete", expectedIdentityGeneration: 0)
                XCTAssertEqual(first.request, f.request); XCTAssertEqual(second.request, first.request)
                XCTAssertEqual(first.originalAuthRequestID, f.source.currentAuthRequestID)
                XCTAssertEqual(first.originalAuthReceiptDigest, AuthorityWire.hash(f.source.receipt.raw))
                XCTAssertEqual(first.initialAuthRequestID, fresh.requestID); XCTAssertEqual(first.initialAuthReceiptDigest, AuthorityWire.hash(receipt.raw))
                XCTAssertEqual(first.opaqueReauthenticationID, opaque)
                let beforeRead = try LocalBusinessErasureValidationTests().controls(f.context.url)
                let changes = try await f.store.initialDeletionTestChanges()
                for _ in 0..<2 {
                    let read = try await f.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
                    let reservation = try XCTUnwrap(read?.reservation)
                    XCTAssertEqual(try reservationBytes(reservation), try reservationBytes(first))
                }
                let afterChanges = try await f.store.initialDeletionTestChanges(); XCTAssertEqual(afterChanges, changes)
                XCTAssertEqual(try LocalBusinessErasureValidationTests().controls(f.context.url), beforeRead)
                await rejected({ _ = try await self.prepare(f, auth: "another", challenge: "another-challenge") }, issue: .alreadyReserved)
            }
            try await f.store.close()
        }
        for fault in [StoreFault.beforeCommit, .afterCommit] {
            let f = try await fixture(); let supplied = try await associated(f); let descriptor = try XCTUnwrap(supplied)
            let rows = try rawRows(f); try await f.store.close()
            let original = try h.store(f.context, fault: fault), changes = try await original.initialDeletionTestChanges()
            let read = try await original.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0)
            XCTAssertEqual(try reservationBytes(XCTUnwrap(read?.reservation)), try reservationBytes(descriptor))
            let after = try await original.initialDeletionTestChanges(); XCTAssertEqual(after, changes)
            XCTAssertEqual(try rawRows(f), rows); try await original.close()
        }
        for variant in ["source", "selected", "saga"] {
            let f = try await fixture(); _ = try await associated(f)
            if variant == "source" {
                let raw = try Canonical.data(Int64(1))
                try sql(f) { try $0.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-admission:original-auth'", [.blob(raw), .text(Canonical.hash(raw))]) }
            } else if variant == "selected" {
                try update(f, key: "initial-delete-auth-v1:head") { $0["selectedAuthRequestID"] = "absent-selected" }
            } else { try await f.store.createDeletionSagaV4(saga(f)) }
            await rejected { _ = try await f.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }
            try await f.store.close()
        }
    }

    func testAtomicSagaConsumptionAndOldGuards() async throws {
        // S11: original control, one capability, Saga and purpose consumption share one COMMIT.
        let f = try await fixture(); _ = try await associated(f); let original = try saga(f)
        try await f.store.createDeletionSagaV4(original)
        let stored = try await f.store.deletionSagaV4(requestID: "delete")
        XCTAssertEqual(stored, original)
        let phase = try sql(f) { db -> String? in
            let raw = try XCTUnwrap(db.scalar("SELECT payload FROM lifecycle_steps_v4 WHERE id='initial-delete-auth-v1:head'").data)
            return (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["phase"] as? String
        }
        XCTAssertEqual(phase, "consumed")
        try await f.store.createDeletionSagaV4(original)
        let retained = try await f.store.deletionSagaV4(requestID: "delete"); XCTAssertEqual(retained?.recoveryCapability, original.recoveryCapability)
        await rejected({ _ = try await f.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .parentExists)

        // S08 (052 reverse): a real original parent cannot claim an initial auth/challenge id.
        for field in ["request", "challenge"] {
            let context = try await f.store.deletionControlContextV4(parentID: "delete", expectedIdentityGeneration: 0)
            let auth = try attempt(f, id: field == "request" ? "fresh-auth" : "control-auth")
            let control = try DeletionControlAttemptV1(context: context, challengeRequestID: field == "challenge" ? "fresh-challenge" : "control-challenge", authentication: auth)
            let before = try rawRows(f)
            await rejected { try await f.store.saveDeletionControlAttemptV4(control) }
            XCTAssertEqual(try rawRows(f), before)
        }
        try await f.store.close()

        // S12: original revision/scope/source guards reject before any control or Saga write.
        for variant in ["unreserved", "revision", "scope", "source", "source-key", "source-receipt", "migration", "held", "terminationPending"] {
            let x = try await fixture()
            if variant == "unreserved" { _ = try await prepare(x) } else { _ = try await associated(x) }
            var candidate = try saga(x)
            if variant == "revision" { candidate.revision = 1 }
            if variant == "scope" {
                candidate = try DeletionSagaV4(intent: candidate.intent, accountID: candidate.accountID, activationEpoch: 1,
                    recoveryCapability: candidate.recoveryCapability, cloudChoice: .keep, localChoice: .delete, healthChoice: .keep,
                    healthConfirmed: false, originalScope: CloudScopeV1(accountID: candidate.accountID, cloudSpaceID: "other-cloud", zoneID: "matches", activationEpoch: 1))
            }
            if variant == "source" {
                let raw = try Canonical.data(Int64(1))
                try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-admission:original-auth'", [.blob(raw), .text(Canonical.hash(raw))]) }
            }
            if variant == "source-key" {
                let original = x.source.attempt
                let changed = try AuthAttemptV4(requestID: original.requestID, deviceID: original.deviceID,
                    publicKey: AuthorityWire.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation), cloudSpaceID: original.cloudSpaceID,
                    challengeID: original.challengeID, requestDigest: original.requestDigest, environment: original.environment)
                let bytes = try Canonical.data(changed)
                try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-attempt:original-auth'", [.blob(bytes), .text(Canonical.hash(bytes))]) }
            }
            if variant == "source-receipt" {
                let changed = try h.receipt(x.context, requestID: x.source.attempt.requestID, digest: x.source.attempt.requestDigest,
                    operation: .authApple, result: .registered, extra: ["receiptID": "different-source-receipt"])
                let bytes = try Canonical.data(changed.raw)
                try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-receipt:original-auth'", [.blob(bytes), .text(Canonical.hash(bytes))]) }
            }
            if variant == "migration" {
                var fields = AuthorityFields(); fields.newPhoneID = "new-phone"; fields.activationEpoch = 1
                let intent = try ControlIntentV1(requestID: "migration-request", operation: .prepareMigration, fields: fields)
                _ = try await x.store.prepareControlV4(intent)
                let proof = try h.receipt(x.context, requestID: intent.requestID, digest: intent.digest, operation: .prepareMigration,
                    result: .waitingMigration, extra: ["migration": ["migrationID": "migration", "kind": "normal", "state": "oldPhonePrepared",
                        "oldPhoneID": x.source.binding.deviceID, "newPhoneID": "new-phone", "cloudSpaceID": x.source.binding.cloudSpaceID,
                        "checkpointID": "", "contentCommitment": "", "oldActivationEpoch": 1, "requestedAt": 10, "eligibleAt": 10]])
                try await x.store.acceptLifecycleResultV4(intent: intent, receipt: proof)
            }
            if variant == "held" || variant == "terminationPending" {
                let descriptor = h.h.descriptor()
                _ = try await x.store.commit(StoreCommit(commandID: "guard-match", expectedGeneration: 0, descriptor: descriptor, events: [], packets: []))
                var projection = StoredAuthorityProjection(); projection.status = variant == "held" ? .held : .terminationPending
                let bytes = try Canonical.data(projection)
                try sql(x) { try $0.execute("INSERT INTO authority_projection_v4 VALUES (?,?,?)", [.text(descriptor.matchID), .blob(bytes), .text(Canonical.hash(bytes))]) }
            }
            let before = try rawRows(x)
            await rejected { try await x.store.createDeletionSagaV4(candidate) }
            XCTAssertEqual(try rawRows(x), before)
            let saved = try await x.store.deletionSagaV4(requestID: "delete"); XCTAssertNil(saved)
            try await x.store.close()
        }

        // S13: original fault injection rolls back all three records; COMMIT loss reads back exact data.
        for fault in [StoreFault.afterReceipt, .beforeCommit, .afterCommit] {
            let x = try await fixture(); _ = try await associated(x); let candidate = try saga(x)
            let before = try rawRows(x); try await x.store.close()
            let failing = try h.store(x.context, fault: fault)
            await rejected { try await failing.createDeletionSagaV4(candidate) }; try await failing.close()
            let reopened = try h.store(x.context)
            if fault == .afterCommit {
                let saved = try await reopened.deletionSagaV4(requestID: "delete"); XCTAssertEqual(saved, candidate)
                try await reopened.createDeletionSagaV4(candidate)
            } else { XCTAssertEqual(try rawRows(x), before) }
            try await reopened.close()
        }
        // S14/S15: another parent and a second connection's source change cannot consume a reservation.
        let x = try await fixture(); _ = try await associated(x)
        await rejected { try await x.store.createDeletionSagaV4(self.saga(x, id: "different-creation")) }
        let bytes = try Canonical.data(Int64(1))
        try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='auth-admission:original-auth'", [.blob(bytes), .text(Canonical.hash(bytes))]) }
        await rejected { try await x.store.createDeletionSagaV4(self.saga(x)) }
        let absent = try await x.store.deletionSagaV4(requestID: "delete"); XCTAssertNil(absent)
        try await x.store.close()
        let existing = try await fixture(); try await existing.store.createDeletionSagaV4(saga(existing, id: "already-existing"))
        await rejected({ _ = try await self.prepare(existing) }, issue: .parentExists)
        try await existing.store.close()
    }
}
private extension MatchStore {
    func initialDeletionTestChanges() throws -> Int64 { try db.scalar("SELECT total_changes()").number ?? -1 }
}
