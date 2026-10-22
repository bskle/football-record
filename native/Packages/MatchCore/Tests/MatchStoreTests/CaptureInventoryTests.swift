import Foundation
import XCTest
import MatchCore
@testable import MatchSession
@testable import MatchStore

final class CaptureInventoryTests: XCTestCase, @unchecked Sendable {
    let h = CaptureTransactionTests()
    struct Clock: SessionClock { func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) } }
    struct Identity: DeviceIdentityProvider { func localDeviceID() async throws -> String { "watch" } }
    struct LinkedGateway: WorkoutGateway {
        func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
            try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
                observedAt: Clock().now(), outcome: .linked(workoutID: "real-software-workout"), window: CaptureWindow(start: nil, end: nil))
        }
        func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
    }
    func sql(_ url: URL, _ body: (SQLite) throws -> Void) throws {
        let db = try SQLite(url: url, fault: nil); defer { try? db.close() }; try body(db)
    }
    func dump(_ url: URL) throws -> [[String]] {
        let db = try SQLite(url: url, fault: nil); defer { try? db.close() }
        var result: [[String]] = []
        for table in try db.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").map({ $0[0].string! }) {
            let columns = try db.rows("PRAGMA table_info("+table+")").map { $0[1].string! }
            let projection = columns.flatMap { ["typeof("+$0+")", "hex(CAST("+$0+" AS BLOB))"] }.joined(separator: ",")
            result += try db.rows("SELECT "+projection+" FROM "+table+" ORDER BY rowid").map { [table]+$0.map { $0.string! } }
        }
        return result
    }
    func assertBlocked(_ store: MatchStore, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await store.captureInventoryV4(); XCTFail("complete inventory must reject, never skip/repair", file: file, line: line) }
        catch { XCTAssertTrue(error is StoreError, "public typed StoreError required: \(error)", file: file, line: line) }
    }
    func emptyMatch(_ store: MatchStore, id: String, device: String = "watch") async throws {
        let d = MatchDescriptor(startIntent: StartIntent(id: "intent-"+id, matchID: id, recordingDeviceID: device, requestedAt: h.h.t), starter: true)
        _ = try await store.commit(StoreCommit(commandID: "initial-"+id, expectedGeneration: 0, descriptor: d, events: [], packets: []))
    }
    func fixture() async throws -> URL {
        let url = h.h.path(); try await h.h.prepare(url)
        let s = try MatchStore(url: url), d = h.h.descriptor()
        let segment = try CaptureSegment(id: "segment", binding: h.binding(), workoutID: "workout", window: CaptureWindow(start: nil, end: nil))
        let gap = try CaptureGap(id: "gap", binding: h.binding(), window: CaptureWindow(start: nil, end: nil))
        let metadata = try CaptureMetadata(binding: h.binding(), segments: [segment], gaps: [gap])
        let revision = try CaptureRevision(id: "r1", binding: h.binding(), parentID: nil, revision: 1, observedAt: h.h.t, metadata: metadata)
        _ = try await s.commitV2(h.request("c0", generation: 1, descriptor: d, revisions: [revision], operations: [h.operation()], outboxID: "delta"))
        try await s.close(); return url
    }
    func testRealSessionLinkedCanonicalOrphanParentIsNotHiddenByOldPublicEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "inventory")
        let session = MatchSession(store: repo, deviceIdentity: Identity(), clock: Clock(), ids: UUIDSessionIDFactory(),
            permits: DevelopmentStartPermitProvider(), workout: LinkedGateway(), environment: .development(databaseNamespace: "inventory"))
        let request = try await session.prepareStart(starter: true); _ = try await session.execute(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var snapshot = try await repo.snapshotV2(matchID: request.matchID)
        while snapshot.captureRevisions.isEmpty && ContinuousClock.now < deadline {
            await Task.yield(); snapshot = try await repo.snapshotV2(matchID: request.matchID)
        }
        XCTAssertEqual(snapshot.captureRevisions.count, 1)
        XCTAssertEqual(snapshot.captureOperations.first?.state, .settled)
        try await emptyMatch(repo.store, id: "still-valid")
        let url = await repo.databaseURL; try await repo.close()
        try sql(url) { try $0.execute("DELETE FROM matches WHERE match_id=?", [.text(request.matchID)]) }
        let before = try dump(url), reopened = try MatchStore(url: url)
        let oldIDs = try await reopened.matchIDs(); XCTAssertEqual(oldIDs, ["still-valid"])
        _ = try await reopened.snapshotV2(matchID: "still-valid")
        do { _ = try await reopened.snapshotV2(matchID: request.matchID); XCTFail("explicit orphan lookup") }
        catch let error as StoreError { XCTAssertEqual(error, .notFound) }
        await assertBlocked(reopened); try await reopened.close(); XCTAssertEqual(try dump(url), before)
    }
    func testIncludesAllOperationStatesAncestryAndIdenticalReusedMetadata() async throws {
        let url = try await fixture(), s = try MatchStore(url: url), d = h.h.descriptor()
        let ids = ["cancelled", "failed", "needs", "settled"]
        _ = try await s.commitV2(h.request("all", generation: 2, descriptor: d, operations: try ids.map { try h.operation($0, command: "all") }))
        let pending = try ids.map { try CaptureOperationUpdate(operationID: $0, expectedState: .pending,
            state: $0 == "cancelled" ? .cancelled : .needsReconciliation, observation: nil) }
        _ = try await s.commitV2(h.request("dispatch", generation: 3, descriptor: d, updates: pending))
        let updates = try ["failed", "needs", "settled"].map { id -> CaptureOperationUpdate in
            let outcome: WorkoutOutcome = id == "failed" ? .notCreated(.writeDenied) : id == "needs" ? .unknown : .running
            let observation = try WorkoutObservation(operationID: id, binding: h.binding(), externalToken: id, observedAt: h.h.t, outcome: outcome, window: CaptureWindow(start: nil, end: nil))
            return try CaptureOperationUpdate(operationID: id, expectedState: .needsReconciliation,
                state: id == "failed" ? .failed : id == "needs" ? .needsReconciliation : .settled, observation: observation)
        }
        let previous = try await s.snapshotV2(matchID: "match").captureRevisions[0]
        let second = try CaptureRevision(id: "r2", binding: previous.binding, parentID: previous.id, revision: 2, observedAt: h.h.t, metadata: previous.metadata)
        _ = try await s.commitV2(h.request("observe", generation: 4, descriptor: d, revisions: [second], updates: updates, outboxID: "delta2"))
        try await emptyMatch(s, id: "another-intent")
        let before = try dump(url), inventory = try await s.captureInventoryV4()
        XCTAssertEqual(inventory.map(\.binding.matchID), ["another-intent", "match"])
        XCTAssertTrue(inventory[0].captureOperations.isEmpty); XCTAssertTrue(inventory[0].captureRevisions.isEmpty)
        XCTAssertEqual(inventory[1].captureRevisions.map(\.id), ["r1", "r2"])
        XCTAssertEqual(Set(inventory[1].captureOperations.map { $0.state.rawValue }), Set(["pending", "cancelled", "failed", "needsReconciliation", "settled"]))
        try await s.close(); XCTAssertEqual(try dump(url), before)
        let reopened = try MatchStore(url: url); let again = try await reopened.captureInventoryV4()
        XCTAssertEqual(again[1].captureOperations.map { $0.operation.id }, inventory[1].captureOperations.map { $0.operation.id }); try await reopened.close()
    }
    func testTerminalAndAbnormalMatchesRemainIncluded() async throws {
        for abnormal in [false, true] {
            let url = h.h.path(); try await h.h.prepare(url); let s = try MatchStore(url: url), (d, events) = try h.h.facts()
            var recorder = LiveMatchRecorder(descriptor: d, events: events)
            let finalEvents: [MatchEvent]
            if abnormal {
                finalEvents = events + [try PostMatchEditor.terminateAbnormally(terminationID: "termination", descriptor: d, events: events, sourceDeviceID: "phone", now: h.h.t.addingTimeInterval(10))]
            } else {
                try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: h.h.t.addingTimeInterval(10)); finalEvents = recorder.events
            }
            _ = try await s.commitV2(h.request("terminal", generation: 1, descriptor: d, events: finalEvents, outboxID: "terminal-delta"))
            let inventory = try await s.captureInventoryV4(); XCTAssertEqual(inventory.map(\.binding.matchID), ["match"]); try await s.close()
        }
    }
    func testOrphanHistoryAndUnvisitedCanonicalRowsBlock() async throws {
        for mode in ["history", "operation", "revision", "registry"] {
            let url = try await fixture()
            try sql(url) { db in
                switch mode {
                case "history": try db.execute("INSERT INTO capture_operation_history SELECT 'orphan',ordinal,command_id,record,checksum FROM capture_operation_history")
                case "operation": try db.execute("UPDATE capture_operations SET match_id='orphan'")
                case "revision": try db.execute("UPDATE capture_revisions SET match_id='orphan'")
                default: try db.execute("UPDATE capture_identities SET match_id='orphan'")
                }
            }
            let before = try dump(url), s = try MatchStore(url: url); await assertBlocked(s); try await s.close(); XCTAssertEqual(try dump(url), before, mode)
        }
    }
    func testUnknownKindAndExtraMetadataIdentitiesBlock() async throws {
        for kind in ["future-kind", "segment", "gap", "operation", "revision", "outbox"] {
            let url = try await fixture()
            try sql(url) { try $0.execute("INSERT INTO capture_identities VALUES (?,?,?,?,?)", [.text("extra"),.text(kind),.text("match"),.blob(Data("{}".utf8)),.text(Canonical.hash(Data("{}".utf8)))]) }
            let before = try dump(url), s = try MatchStore(url: url); await assertBlocked(s); try await s.close(); XCTAssertEqual(try dump(url), before, kind)
        }
    }
    func testOriginalCommandAndOutboxStillRequireDeletedCaptureFacts() async throws {
        for mode in ["revision", "operation", "outbox"] {
            let url = try await fixture()
            try sql(url) { db in
                if mode == "revision" { try db.execute("DELETE FROM capture_revisions"); try db.execute("DELETE FROM capture_identities WHERE kind IN ('revision','segment','gap')") }
                if mode == "operation" { try db.execute("DELETE FROM capture_operations"); try db.execute("DELETE FROM capture_operation_history"); try db.execute("DELETE FROM capture_identities WHERE kind='operation'") }
                if mode == "outbox" { try db.execute("DELETE FROM business_outbox"); try db.execute("DELETE FROM capture_identities WHERE kind='outbox'") }
            }
            let before = try dump(url), s = try MatchStore(url: url); await assertBlocked(s); try await s.close(); XCTAssertEqual(try dump(url), before, mode)
        }
    }
    func testBlockingAndInvalidDiagnosticCannotBeHiddenByMissingMatch() async throws {
        for match in ["match", "unknown-match"] {
            for severity in ["blocking", "unknown-severity"] {
                let url = try await fixture()
                try sql(url) { try $0.execute("INSERT INTO diagnostics VALUES (?,?,?,?,?)", [.text(match),.text("positive-conflict"),.text("old-token"),.blob(Data([0xff,0,1])),.text(severity)]) }
                let before = try dump(url), s = try MatchStore(url: url); await assertBlocked(s); try await s.close(); XCTAssertEqual(try dump(url), before)
            }
        }
    }
    func testBadCanonicalHistoryAndRegistryNeverWriteDiagnosticOrRepair() async throws {
        for edit in ["UPDATE capture_operations SET record_checksum='bad'", "UPDATE capture_operation_history SET checksum='bad'", "UPDATE capture_identities SET checksum='bad' WHERE kind='segment'", "UPDATE commands_v2 SET request_hash='bad'", "DELETE FROM capture_identities WHERE kind='gap'"] {
            let url = try await fixture(); try sql(url) { try $0.execute(edit) }
            let before = try dump(url), s = try MatchStore(url: url); await assertBlocked(s); try await s.close(); XCTAssertEqual(try dump(url), before, edit)
        }
    }
    func testLiveUnknownAndFutureLayoutPreserved() async throws {
        for edit in ["CREATE TABLE future_business (value BLOB)", "ALTER TABLE capture_operations ADD COLUMN future BLOB", "PRAGMA user_version=5"] {
            let url = try await fixture(), s = try MatchStore(url: url)
            // Use raw sqlite so a future-version failure is tested at the already-open public API.
            try sql(url) { try $0.execute(edit) }
            let bytes = try Data(contentsOf: url); await assertBlocked(s); XCTAssertEqual(try Data(contentsOf: url), bytes); try await s.close()
        }
    }
    func testRawUnicodeMembershipIsDistinctAndAlteredIndexDoesNotAlias() async throws {
        let nfc = "caf\u{00e9}", nfd = "cafe\u{0301}", url = h.h.path(), s = try MatchStore(url: url)
        try await emptyMatch(s, id: nfc); try await emptyMatch(s, id: nfd)
        let inventory = try await s.captureInventoryV4()
        XCTAssertEqual(inventory.count, 2); XCTAssertEqual(Set(inventory.map { Data($0.binding.matchID.utf8) }).count, 2)
        try await s.close()
        let other = h.h.path(), live = try MatchStore(url: other); try await emptyMatch(live, id: nfc); try await live.close()
        try sql(other) { try $0.execute("UPDATE matches SET match_id=?", [.text(nfd)]) }
        let before = try dump(other), reopened = try MatchStore(url: other); await assertBlocked(reopened); try await reopened.close(); XCTAssertEqual(try dump(other), before)
    }
    func testInvalidUTF8SQLTextIsNotSilentlyReplacementDecoded() async throws {
        let url = h.h.path(), s = try MatchStore(url: url); try await emptyMatch(s, id: "\u{fffd}"); try await s.close()
        try sql(url) { try $0.execute("UPDATE matches SET match_id=CAST(x'ff' AS TEXT)") }
        let before = try dump(url), reopened = try MatchStore(url: url); await assertBlocked(reopened); try await reopened.close(); XCTAssertEqual(try dump(url), before)
    }
    func testConcreteFacadeAndReadFaultsUseSameOriginalStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: "inventory")
        try await emptyMatch(repo.store, id: "original")
        let values = try await repo.captureInventoryV4(); XCTAssertEqual(values.map(\.binding.matchID), ["original"])
        let url = await repo.databaseURL; try await repo.close(); let before = try dump(url)
        for fault in [StoreFault.beforeCommit, .afterCommit] {
            let s = try MatchStore(url: url, fault: fault); let values = try await s.captureInventoryV4(); XCTAssertEqual(values.count, 1); try await s.close()
        }
        XCTAssertEqual(try dump(url), before)
    }
    func testMalformedOriginalBindingFailsWithTypedErrorAndPreservesBytes() async throws {
        let url = h.h.path(), s = try MatchStore(url: url); try await emptyMatch(s, id: "match"); try await s.close()
        try sql(url) { db in
            let raw = try XCTUnwrap(db.scalar("SELECT descriptor FROM matches").data)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String:Any])
            var intent = try XCTUnwrap(object["startIntent"] as? [String:Any]); intent["recordingDeviceID"] = ""
            object["startIntent"] = intent
            try db.execute("UPDATE matches SET descriptor=?", [.blob(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))])
        }
        let before = try dump(url), r = try MatchStore(url: url); await assertBlocked(r); try await r.close(); XCTAssertEqual(try dump(url), before)
    }
    func testOriginalImmutableIntentAndAssociatedCommandUseRawUTF8() async throws {
        let nfc = "caf\u{00e9}", nfd = "cafe\u{0301}"
        for mode in ["intent", "associated-command"] {
            let url = h.h.path(); let s = try MatchStore(url: url)
            if mode == "intent" {
                let descriptor = MatchDescriptor(startIntent: StartIntent(id: "intent", matchID: "match", recordingDeviceID: nfc, requestedAt: h.h.t), starter: true)
                _ = try await s.commitV2(h.request("intent", generation: 0, descriptor: descriptor))
                try await s.close()
                try sql(url) { db in
                    let different = MatchDescriptor(startIntent: StartIntent(id: "intent", matchID: "match", recordingDeviceID: nfd, requestedAt: h.h.t), starter: true)
                    let changed = try Canonical.data(h.request("intent", generation: 0, descriptor: different))
                    try db.execute("UPDATE commands_v2 SET request=?,request_hash=?", [.blob(changed),.text(Canonical.hash(changed))])
                }
            } else {
                try await s.close(); try await h.h.prepare(url); let active = try MatchStore(url: url)
                _ = try await active.commitV2(h.request(nfc, generation: 1, descriptor: h.h.descriptor(), operations: [h.operation(command: nfc)]))
                try await active.close()
                try sql(url) { db in
                    let op = try h.operation(command: nfd), raw = try Canonical.data(op)
                    let record = try Canonical.data(CaptureOperationRecord(operation: op, state: .pending, observation: nil))
                    let request = try Canonical.data(h.request(nfc, generation: 1, descriptor: h.h.descriptor(), operations: [op]))
                    try db.execute("UPDATE capture_operations SET operation=?,checksum=?,record=?,record_checksum=?", [.blob(raw),.text(Canonical.hash(raw)),.blob(record),.text(Canonical.hash(record))])
                    try db.execute("UPDATE capture_operation_history SET record=?,checksum=?", [.blob(record),.text(Canonical.hash(record))])
                    try db.execute("UPDATE capture_identities SET payload=?,checksum=? WHERE kind='operation'", [.blob(raw),.text(Canonical.hash(raw))])
                    try db.execute("UPDATE commands_v2 SET request=?,request_hash=?", [.blob(request),.text(Canonical.hash(request))])
                }
            }
            let before = try dump(url), r = try MatchStore(url: url); await assertBlocked(r); try await r.close(); XCTAssertEqual(try dump(url), before, mode)
        }
    }
    func testFrozenVersionOneMigrationStillHasAnInventory() async throws {
        let url = try LegacyCompatibilityTests().database(), s = try MatchStore(url: url)
        let ids = try await s.matchIDs(), inventory = try await s.captureInventoryV4()
        XCTAssertEqual(Set(inventory.map { Data($0.binding.matchID.utf8) }), Set(ids.map { Data($0.utf8) })); try await s.close()
    }

}
