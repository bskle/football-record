import Foundation
import XCTest
import MatchCore
import SQLite3
@testable import MatchStore

final class RecoveryTests: XCTestCase, @unchecked Sendable {
    let helper = TransactionTests()
    func seedWithoutKeepingMatchIDs(_ url: URL) async throws {
        let store = try MatchStore(url: url)
        for started in [false, true] {
            let intent = StartIntent(id: UUID().uuidString, matchID: UUID().uuidString,
                recordingDeviceID: "watch", requestedAt: helper.t)
            let pending = MatchDescriptor(startIntent: intent, starter: true)
            _ = try await store.commit(StoreCommit(commandID: UUID().uuidString, expectedGeneration: 0,
                descriptor: pending, events: [], packets: []))
            if started {
                let descriptor = MatchDescriptor(startIntent: intent, starter: true,
                    startPermit: .acceptedByTrustedNetworkBoundary(for: intent, permitID: "permit"), backendLockState: .held)
                var recorder = LiveMatchRecorder(descriptor: descriptor)
                try recorder.start(eventID: UUID().uuidString, sourceDeviceID: "watch", now: helper.t)
                let packet = try MatchPacket(packetID: UUID().uuidString, idempotencyKey: UUID().uuidString,
                    revision: 1, sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: descriptor, events: recorder.events)
                _ = try await store.commit(StoreCommit(commandID: UUID().uuidString, expectedGeneration: 1,
                    descriptor: descriptor, events: recorder.events, packets: [packet]))
            }
        }
        try await store.close()
    }
    func testRecoveryDiscoversIntentAndOutboxUsingOnlyDatabaseURL() async throws {
        let url = helper.path(); try await seedWithoutKeepingMatchIDs(url)
        let reopened = try MatchStore(url: url)
        let ids = try await reopened.matchIDs()
        XCTAssertEqual(ids.count, 2)
        var pending: StoreSnapshot?
        var packetCount = 0
        for id in ids {
            let snapshot = try await reopened.snapshot(matchID: id)
            if snapshot.descriptor.startPermit == nil { pending = snapshot }
            packetCount += try await reopened.pendingPackets(matchID: id).count
        }
        XCTAssertEqual(packetCount, 1)
        let saved = try XCTUnwrap(pending)
        let resumed = MatchDescriptor(startIntent: saved.descriptor.startIntent, starter: saved.descriptor.starter,
            startPermit: .acceptedByTrustedNetworkBoundary(for: saved.descriptor.startIntent, permitID: "recovered-permit"), backendLockState: .held)
        var recorder = LiveMatchRecorder(descriptor: resumed)
        try recorder.start(eventID: "recovered-start", sourceDeviceID: "watch", now: helper.t)
        let packet = try MatchPacket(packetID: "recovered-packet", idempotencyKey: "recovered-key", revision: saved.generation,
            sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: resumed, events: recorder.events)
        _ = try await reopened.commit(StoreCommit(commandID: "recovered-command", expectedGeneration: saved.generation,
            descriptor: resumed, events: recorder.events, packets: [packet]))
        let after = try await reopened.snapshot(matchID: saved.descriptor.matchID)
        XCTAssertEqual(after.descriptor.startIntent, saved.descriptor.startIntent)
        XCTAssertEqual(after.events.count, 1)
        try await reopened.close()
    }
    func testMigrationInterruptionRollsBackVersionAndSchemaThenReopens() async throws {
        let url = helper.path()
        XCTAssertThrowsError(try MatchStore(url: url, fault: .migrationAfterSchema))
        // Raw SQLite inspect is confined to tests; production API has no arbitrary SQL escape.
        XCTAssertEqual(try inspectInt(url, "PRAGMA user_version"), 0)
        XCTAssertEqual(try inspectInt(url, "SELECT count(*) FROM sqlite_master WHERE type='table'"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let store = try MatchStore(url: url)
        _ = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: helper.descriptor(), events: [], packets: []))
        try await store.close()
        XCTAssertEqual(try inspectInt(url, "PRAGMA user_version"), 4)
    }
    func inspectInt(_ url: URL, _ sql: String) throws -> Int64 {
        var handle: OpaquePointer?; var statement: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StoreError.invalidRequest }
        defer { sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.invalidRequest }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRequest }
        return sqlite3_column_int64(statement, 0)
    }
    func testFutureSchemaFailsWithoutRebuildingOriginalFile() async throws {
        let url = helper.path(); let sql = try SQLite(url: url, fault: nil)
        try sql.execute("PRAGMA user_version=99"); try sql.close()
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try MatchStore(url: url)) { XCTAssertEqual($0 as? StoreError, .unsupportedSchema(99)) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testFutureSchemaPreservesDatabaseWALAndSHMFiles() throws {
        let url = helper.path(); var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { throw StoreError.invalidRequest }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL;CREATE TABLE future_data(value TEXT);INSERT INTO future_data VALUES ('keep');PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        var persist: Int32 = 1
        XCTAssertEqual(sqlite3_file_control(handle, nil, SQLITE_FCNTL_PERSIST_WAL, &persist), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        let paths = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let originals = try paths.map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try MatchStore(url: url))
        for (path, bytes) in zip(paths.prefix(2), originals.prefix(2)) { XCTAssertEqual(try Data(contentsOf: path), bytes) }
        // SHM is SQLite's live lock/read-mark index, not an immutable fact log. Merely reading
        // user_version can alter read marks; preserve the file, without asserting byte identity.
        XCTAssertEqual(try Data(contentsOf: paths[2]).count, originals[2].count)
    }
    func testPhysicalCorruptionPreservesFileAndDoesNotReplaceIt() throws {
        let url = helper.path(); let bytes = Data("not a sqlite database\0preserve".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try MatchStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testPartialVersionOneSchemaFailsOnOpen() throws {
        let url = helper.path(); let sql = try SQLite(url: url, fault: nil)
        try sql.execute("ALTER TABLE matches RENAME COLUMN descriptor TO bogus")
        try sql.close()
        XCTAssertThrowsError(try MatchStore(url: url))
    }
    func testCorruptJSONAndChecksumRemainInDatabaseAndDiagnostics() async throws {
        for damage in ["json", "checksum"] {
            let url = helper.path(); try await helper.prepare(url)
            let writer = try MatchStore(url: url); let (d, e) = try helper.facts()
            _ = try await writer.commit(helper.request(descriptor: d, events: e)); try await writer.close()
            let sql = try SQLite(url: url, fault: nil)
            let bad = Data("{broken-event".utf8)
            if damage == "json" {
                try sql.execute("UPDATE events SET payload=?,checksum=? WHERE event_id='goal'", [.blob(bad), .text(Canonical.hash(bad))])
            } else { try sql.execute("UPDATE events SET checksum='wrong' WHERE event_id='goal'") }
            let original = try sql.rows("SELECT payload FROM events WHERE event_id='goal'")[0][0].data
            try sql.close()
            let restored = try MatchStore(url: url)
            do { _ = try await restored.snapshot(matchID: "match"); XCTFail("corrupt snapshot") } catch {}
            let diagnostics = try await restored.diagnostics(matchID: "match")
            XCTAssertTrue(diagnostics.contains { $0.rawBytes == original })
            try await restored.close()
            let inspect = try SQLite(url: url, fault: nil)
            XCTAssertEqual(try inspect.rows("SELECT payload FROM events WHERE event_id='goal'")[0][0].data, original)
            try inspect.close()
        }
    }
    func testStartRequiresPersistedIntentAndPacketsMustMatchSubmittedFacts() async throws {
        let store = try MatchStore(url: helper.path()); let (d, e) = try helper.facts()
        do { _ = try await store.commit(helper.request(generation: 0, descriptor: d, events: e)); XCTFail("intent first") } catch {}
        _ = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: helper.descriptor(), events: [], packets: []))
        let request = try helper.request(descriptor: d, events: e)
        let mismatch = StoreCommit(commandID: "mismatch", expectedGeneration: 1, descriptor: d, events: [e[0]], packets: request.packets)
        do { _ = try await store.commit(mismatch); XCTFail("packet facts mismatch") } catch {}
        let snapshot = try await store.snapshot(matchID: "match")
        XCTAssertTrue(snapshot.events.isEmpty); XCTAssertEqual(snapshot.generation, 1)
        try await store.close()
    }
    func testStableIntentIDCannotBeReboundToAnotherMatch() async throws {
        let store = try MatchStore(url: helper.path()); let d = helper.descriptor()
        _ = try await store.commit(StoreCommit(commandID: "original", expectedGeneration: 0, descriptor: d, events: [], packets: []))
        let rebound = MatchDescriptor(startIntent: StartIntent(id: d.startIntent.id, matchID: "other-match",
            recordingDeviceID: "watch", requestedAt: helper.t), starter: true)
        do {
            _ = try await store.commit(StoreCommit(commandID: "rebind", expectedGeneration: 0, descriptor: rebound, events: [], packets: []))
            XCTFail("stable intent must keep original match")
        } catch let error as StoreError { XCTAssertEqual(error, .descriptorConflict) }
        try await store.close()
    }
    func testLocalEndPartialACKAndStaleCompletionNeverReleaseLock() async throws {
        let url = helper.path(); try await helper.prepare(url)
        let store = try MatchStore(url: url); let (d, events) = try helper.facts()
        var recorder = LiveMatchRecorder(descriptor: d, events: events)
        try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: helper.t.addingTimeInterval(10))
        _ = try await store.commit(helper.request("ended", descriptor: d, events: recorder.events))
        _ = try await store.commit(helper.request("second-packet", generation: 2, descriptor: d, events: []))
        let allPackets = try await store.pendingPackets(matchID: "match")
        let p = try XCTUnwrap(allPackets.first)
        try await store.acknowledge(DurableACK(packetID: p.body.packetID, checksum: p.checksum, receivingDeviceID: "phone"))
        let pending = try await store.snapshot(matchID: "match")
        XCTAssertEqual(try pending.replay(now: helper.t.addingTimeInterval(20)).state, .endedPendingSync)
        let proof = try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: d, events: recorder.events,
            confirmationID: "trusted-adapter-confirmation", now: helper.t.addingTimeInterval(20))
        try await store.saveCompletionEvidence(proof, expectedGeneration: 3, now: helper.t.addingTimeInterval(20))
        let completed = try await store.snapshot(matchID: "match")
        XCTAssertEqual(try completed.replay(now: helper.t.addingTimeInterval(20)).state, .completed)
        let correction = try PostMatchEditor.revise(eventID: "goal", newEventID: "goal-delete", descriptor: d,
            events: recorder.events, delete: true, sourceDeviceID: "phone", now: helper.t.addingTimeInterval(20))
        _ = try await store.commit(helper.request("correction", generation: 3, descriptor: d, events: [correction]))
        do { try await store.saveCompletionEvidence(proof, expectedGeneration: 4, now: helper.t.addingTimeInterval(20)); XCTFail("old evidence") }
        catch let error as StoreError { XCTAssertEqual(error, .staleCompletionEvidence) }
        try await store.close()
        let restored = try MatchStore(url: url); let snapshot = try await restored.snapshot(matchID: "match")
        let replay = try snapshot.replay(now: helper.t.addingTimeInterval(20))
        XCTAssertEqual(replay.state, .endedPendingSync); XCTAssertEqual(replay.backendLockState, .held)
        try await restored.close()
    }
}
