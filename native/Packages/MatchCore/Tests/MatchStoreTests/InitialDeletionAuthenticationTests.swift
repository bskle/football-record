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
        for variant in ["future", "unknown-kind", "blob-id", "bad-utf8", "orphan-result", "extra-field", "hash-key"] {
            let x = try await fixture(); _ = try await prepare(x)
            if variant == "extra-field" {
                try update(x, key: "initial-delete-auth-v1:head") { $0["future"] = true }
            } else if variant == "hash-key" {
                try sql(x) { try $0.execute("UPDATE lifecycle_steps_v4 SET id=? WHERE id LIKE 'initial-delete-auth-v1:attempt:%'", [.text("initial-delete-auth-v1:attempt:" + String(repeating: "0", count: 64))]) }
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
        await rejected({ _ = try await self.prepare(capacity, auth: "auth-16", challenge: "challenge-16") }, issue: .capacity)
        XCTAssertEqual(try rawRows(capacity), full); try await capacity.store.close()
        for size in [65_537, 2 * 1024 * 1024 + 1] {
            let x = try await fixture()
            try insert(x, key: .text("initial-delete-auth-v1:head"), payload: Data(repeating: 32, count: size))
            await rejected({ _ = try await x.store.initialDeletionContextV4(creationID: "delete", expectedIdentityGeneration: 0) }, issue: .capacity)
            try await x.store.close()
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
    }
}
