import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class TransportTests: XCTestCase, @unchecked Sendable {
    let helper = TransactionTests()
    func packet(_ id: String = "wire", events: [MatchEvent]? = nil) throws -> MatchPacket {
        let (d, e) = try helper.facts()
        return try MatchPacket(packetID: id, idempotencyKey: "key-" + id, revision: 1,
            sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: d, events: events ?? e)
    }
    func altered(_ packet: MatchPacket, field: String, value: Any) throws -> MatchPacket {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(packet)) as? [String: Any])
        if field == "checksum" { json[field] = value }
        else { var body = try XCTUnwrap(json["body"] as? [String: Any]); body[field] = value; json["body"] = body }
        if field != "checksum" {
            let changed = try JSONDecoder().decode(MatchPacket.self, from: JSONSerialization.data(withJSONObject: json))
            json["checksum"] = Canonical.hash(try Canonical.data(changed.body))
        }
        return try JSONDecoder().decode(MatchPacket.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func receive(_ store: MatchStore, _ packet: MatchPacket) async throws -> DurableACK {
        try await store.receive(packet, expectedPeerDeviceID: "watch", localDeviceID: "phone", expectedMatchID: "match")
    }
    func testReceiveCommitBeforeLostACKAndDuplicateReopenReturnsSameACK() async throws {
        let url = helper.path(); let first = try MatchStore(url: url)
        let p = try packet(); let ack = try await receive(first, p)
        try await first.close()
        let reopened = try MatchStore(url: url)
        let retry = try await receive(reopened, p)
        XCTAssertEqual(ack, retry)
        let s = try await reopened.snapshot(matchID: "match")
        XCTAssertEqual(s.events.count, 2); XCTAssertEqual(s.generation, 1)
        XCTAssertEqual(try s.replay(now: helper.t.addingTimeInterval(10)).score.forTeam, 1)
        try await reopened.close()
    }
    func testDuplicateReceiptCannotACKMissingOrCorruptCommittedFacts() async throws {
        for damage in ["missing", "corrupt", "missing-match", "corrupt-match"] {
            let url = helper.path(); let receiver = try MatchStore(url: url); let p = try packet()
            _ = try await receive(receiver, p); try await receiver.close()
            let sql = try SQLite(url: url, fault: nil)
            if damage == "missing" { try sql.execute("DELETE FROM events WHERE event_id='goal'") }
            else if damage == "corrupt" { try sql.execute("UPDATE events SET checksum='corrupt' WHERE event_id='goal'") }
            else if damage == "missing-match" { try sql.execute("DELETE FROM matches") }
            else { try sql.execute("UPDATE matches SET descriptor=?", [.blob(Data("broken-match".utf8))]) }
            try sql.close()
            let reopened = try MatchStore(url: url)
            do { _ = try await receive(reopened, p); XCTFail("receipt alone must not ACK lost facts") } catch {}
            let diagnostics = try await reopened.diagnostics(matchID: "match")
            XCTAssertTrue(diagnostics.contains { $0.key == (damage.contains("match") ? "match" : "goal") && $0.severity == .blocking })
            try await reopened.close()
        }
    }
    func testReceiveFailureBeforeCommitProducesNoACKAndRetryPersistsOnce() async throws {
        let url = helper.path(); let failing = try MatchStore(url: url, fault: .beforeCommit)
        let p = try packet()
        do { _ = try await receive(failing, p); XCTFail("no durable ACK") } catch {}
        do { _ = try await failing.snapshot(matchID: "match"); XCTFail("rolled back") } catch {}
        try await failing.close()
        let restored = try MatchStore(url: url)
        let ack = try await receive(restored, p)
        XCTAssertEqual(ack.packetID, p.body.packetID)
        let restoredSnapshot = try await awaitSnapshot(restored)
        XCTAssertEqual(restoredSnapshot.generation, 1)
        try await restored.close()
    }
    func awaitSnapshot(_ store: MatchStore) async throws -> StoreSnapshot { try await store.snapshot(matchID: "match") }
    func testWrongChecksumPeerVersionAndMalformedBytesAreRejectedAndDiagnosed() async throws {
        let store = try MatchStore(url: helper.path()); let p = try packet()
        for bad in [try altered(p, field: "checksum", value: "bad"), try altered(p, field: "version", value: 99)] {
            do { _ = try await receive(store, bad); XCTFail("invalid wire packet") } catch {}
        }
        do { _ = try await store.receive(p, expectedPeerDeviceID: "other", localDeviceID: "phone", expectedMatchID: "match"); XCTFail("wrong peer") } catch {}
        let bytes = Data("{broken".utf8)
        do { _ = try await store.receive(bytes, expectedPeerDeviceID: "watch", localDeviceID: "phone", expectedMatchID: "match"); XCTFail("bad JSON") } catch {}
        let diagnostics = try await store.diagnostics(matchID: "match")
        XCTAssertTrue(diagnostics.contains { $0.rawBytes == bytes })
        XCTAssertGreaterThanOrEqual(diagnostics.count, 4)
        try await store.close()
    }
    func testRejectedWireAuditsDoNotPoisonValidFactsOrCorrectRetry() async throws {
        let store = try MatchStore(url: helper.path()); let p = try packet()
        _ = try await receive(store, p)
        for bad in [try altered(p, field: "checksum", value: "bad"), try altered(p, field: "version", value: 99)] {
            do { _ = try await receive(store, bad); XCTFail("reject wire") } catch {}
        }
        do { _ = try await store.receive(p, expectedPeerDeviceID: "other", localDeviceID: "phone", expectedMatchID: "match"); XCTFail("reject peer") } catch {}
        do { _ = try await store.receive(Data("broken-json".utf8), expectedPeerDeviceID: "watch", localDeviceID: "phone", expectedMatchID: "match"); XCTFail("reject JSON") } catch {}
        _ = try await receive(store, p)
        let s = try await store.snapshot(matchID: "match")
        XCTAssertEqual(s.diagnostics.count, 4)
        XCTAssertTrue(s.diagnostics.allSatisfy { $0.severity == .audit })
        XCTAssertEqual(try s.replay(now: helper.t.addingTimeInterval(10)).score.forTeam, 1)
        try await store.close()
    }
    func testSameEventIDDifferentPayloadIsQuarantinedWithoutACKOrOverwrite() async throws {
        let url = helper.path(); let store = try MatchStore(url: url); let p = try packet()
        _ = try await receive(store, p)
        let original = p.body.events[1]
        let conflict = MatchEvent(eventID: original.eventID, matchID: original.matchID, sequence: original.sequence,
            occurredAt: original.occurredAt, matchElapsed: original.matchElapsed, type: original.type,
            sourceDeviceID: original.sourceDeviceID, createdAt: original.createdAt, updatedAt: original.updatedAt,
            goal: GoalPayload(scoreImpact: .against, scoringTeamSnapshot: "wrong"))
        do { _ = try await receive(store, packet("collision", events: [conflict])); XCTFail("must not ACK") }
        catch let error as StoreError { XCTAssertEqual(error, .eventConflict) }
        try await store.close()
        let reopened = try MatchStore(url: url); let s = try await reopened.snapshot(matchID: "match")
        XCTAssertEqual(s.events, p.body.events); XCTAssertEqual(s.generation, 1)
        XCTAssertTrue(s.diagnostics.contains { $0.code == "event-conflict" })
        XCTAssertThrowsError(try s.replay(now: helper.t.addingTimeInterval(10)))
        try await reopened.close()
    }
    func testEventIDsAreGlobalAndCrossMatchCollisionIsNotACKed() async throws {
        let store = try MatchStore(url: helper.path()); let p = try packet()
        _ = try await receive(store, p)
        let intent = StartIntent(id: "intent-B", matchID: "match-B", recordingDeviceID: "watch", requestedAt: helper.t)
        let descriptor = MatchDescriptor(startIntent: intent, starter: true,
            startPermit: .acceptedByTrustedNetworkBoundary(for: intent, permitID: "permit-B"), backendLockState: .held)
        var recorder = LiveMatchRecorder(descriptor: descriptor)
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: helper.t)
        let collision = try MatchPacket(packetID: "packet-B", idempotencyKey: "key-B", revision: 1,
            sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: descriptor, events: recorder.events)
        do {
            _ = try await store.receive(collision, expectedPeerDeviceID: "watch", localDeviceID: "phone", expectedMatchID: "match-B")
            XCTFail("global event ID collision must not ACK")
        } catch let error as StoreError { XCTAssertEqual(error, .eventConflict) }
        let original = try await store.snapshot(matchID: "match")
        XCTAssertEqual(original.events, p.body.events)
        let diagnostics = try await store.diagnostics(matchID: "match-B")
        XCTAssertTrue(diagnostics.contains { $0.code == "event-conflict" && $0.key == "start" })
        try await store.close()
    }
    func testRevisionBeforeOriginalAndCrossWriterSequenceAreRetained() async throws {
        let store = try MatchStore(url: helper.path()); let (d, events) = try helper.facts()
        let undo = try PostMatchEditor.terminateAbnormally(terminationID: "terminate", descriptor: d,
            events: [events[0]], sourceDeviceID: "phone", now: helper.t.addingTimeInterval(10))
        XCTAssertEqual(undo.sequence, events[1].sequence)
        _ = try await receive(store, packet("phone-late", events: [undo]))
        var recorder = LiveMatchRecorder(descriptor: d, events: events)
        let tombstone = try recorder.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: helper.t.addingTimeInterval(5))
        _ = try await receive(store, packet("revision-first", events: [tombstone]))
        _ = try await receive(store, packet("original-last", events: events.reversed()))
        let s = try await store.snapshot(matchID: "match")
        XCTAssertEqual(s.events.count, 4); XCTAssertTrue(s.diagnostics.isEmpty)
        let replay = try s.replay(now: helper.t.addingTimeInterval(20))
        XCTAssertEqual(replay.state, .incomplete); XCTAssertEqual(replay.score.forTeam, 0)
        XCTAssertEqual(replay.backendLockState, .held)
        try await store.close()
    }
    func testOnlyExactDurableACKClearsSpecificPendingPacketAndDuplicateIsIdempotent() async throws {
        let url = helper.path(); try await helper.prepare(url)
        let store = try MatchStore(url: url); let (d, events) = try helper.facts()
        _ = try await store.commit(helper.request("one", descriptor: d, events: events))
        _ = try await store.commit(helper.request("two", generation: 2, descriptor: d, events: []))
        let packets = try await store.pendingPackets(matchID: "match")
        let p = packets[0]
        for ack in [DurableACK(packetID: "wrong", checksum: p.checksum, receivingDeviceID: "phone"),
                    DurableACK(packetID: p.body.packetID, checksum: "bad", receivingDeviceID: "phone"),
                    DurableACK(packetID: p.body.packetID, checksum: p.checksum, receivingDeviceID: "other")] {
            do { try await store.acknowledge(ack); XCTFail("wrong ACK") } catch {}
        }
        let pending = try await store.pendingPackets(matchID: "match")
        XCTAssertEqual(pending.count, 2)
        let ack = DurableACK(packetID: p.body.packetID, checksum: p.checksum, receivingDeviceID: "phone")
        try await store.acknowledge(ack); try await store.acknowledge(ack)
        try await store.close()
        let restored = try MatchStore(url: url)
        let rest = try await restored.pendingPackets(matchID: "match")
        XCTAssertEqual(rest.count, 1); XCTAssertEqual(rest[0].body.packetID, "packet-two")
        try await restored.close()
    }
    func testReusedPacketIdentityWithDifferentValidPayloadIsNotACKed() async throws {
        let store = try MatchStore(url: helper.path()); let p = try packet()
        _ = try await receive(store, p)
        let changed = try packet(events: [p.body.events[0]])
        do { _ = try await receive(store, changed); XCTFail("reused packet ID") }
        catch let error as StoreError { XCTAssertEqual(error, .packetConflict) }
        let s = try await store.snapshot(matchID: "match")
        XCTAssertEqual(s.events.count, 2); XCTAssertEqual(s.generation, 1)
        XCTAssertTrue(s.diagnostics.contains { $0.code == "packet-conflict" })
        try await store.close()
    }
    func testMissingStartAbnormalTerminationThenLateNormalEndRemainsIncomplete() async throws {
        let store = try MatchStore(url: helper.path()); let (d, events) = try helper.facts()
        let terminal = try PostMatchEditor.terminateAbnormally(terminationID: "empty-phone-log", descriptor: d,
            events: [], sourceDeviceID: "phone", now: helper.t.addingTimeInterval(10))
        _ = try await receive(store, packet("abnormal-first", events: [terminal]))
        let partial = try await store.snapshot(matchID: "match")
        XCTAssertNil(try partial.replay(now: helper.t.addingTimeInterval(20)).matchDuration)
        var recorder = LiveMatchRecorder(descriptor: d, events: events)
        try recorder.transition(.matchEnded, eventID: "normal-end", sourceDeviceID: "watch", now: helper.t.addingTimeInterval(12))
        _ = try await receive(store, packet("late-normal", events: recorder.events))
        let restored = try await store.snapshot(matchID: "match")
        let replay = try restored.replay(now: helper.t.addingTimeInterval(20))
        XCTAssertEqual(replay.state, .incomplete); XCTAssertEqual(replay.backendLockState, .held)
        XCTAssertEqual(replay.recordingDeviceID, "watch"); XCTAssertEqual(replay.score.forTeam, 1)
        XCTAssertFalse(replay.career.includeRecordedMatch)
        try await store.close()
    }
}
