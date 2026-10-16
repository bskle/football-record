import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class SyncReceiveV2Tests: XCTestCase, @unchecked Sendable {
    let h = SyncRoutingTests()
    func store(_ url: URL, fault: StoreFault? = nil) throws -> MatchStore {
        if let fault { return try MatchStore(url: url, fault: fault, syncEnvironment: .development(databaseNamespace: "phone-db")) }
        return try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "phone-db"))
    }
    func receive(_ store: MatchStore, _ packet: MatchPacketV2) async throws -> InboundReceiptV3 {
        try await store.receiveV2(packet.canonicalBytes(), peer: h.peer(local: "phone", remote: "watch", namespace: "phone-db"), expectedMatchID: "match", now: h.t)
    }
    func packet(_ id: String = "packet", sequence: Int64 = 1, revisions: [CaptureRevision]? = nil, events: [MatchEvent]? = nil, descriptor: MatchDescriptor? = nil) throws -> MatchPacketV2 {
        let d = descriptor ?? h.descriptor(); var recorder = LiveMatchRecorder(descriptor: h.descriptor())
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: h.t)
        return try MatchPacketV2(packetID: id, idempotencyKey: "key-" + id, sequence: sequence, sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: d, events: events ?? recorder.events, captureRevisions: revisions ?? [h.h.revision()])
    }
    func testR2SnapshotThenR1ThenDuplicateR2() async throws {
        let url = h.h.h.path(); let s = try store(url)
        let r1 = try h.h.revision(); let r2 = try h.h.revision("r2", parent: "r1", number: 2)
        let high = try packet("p2", sequence: 2, revisions: [r1, r2]); let low = try packet("p1", revisions: [r1])
        let first = try await receive(s, high)
        let gap = try await s.syncStateV3(matchID: "match"); XCTAssertEqual(gap.receivedGapCount, 1)
        let old = try await receive(s, low); XCTAssertTrue(old.insertedCaptureRevisionIDs.isEmpty)
        XCTAssertEqual(old.generation, first.generation)
        let complete = try await s.syncStateV3(matchID: "match"); XCTAssertEqual(complete.receivedGapCount, 0)
        try await s.close(); let reopened = try store(url)
        let repeated = try await receive(reopened, high); XCTAssertEqual(repeated, first)
        let snapshot = try await reopened.snapshotV2(matchID: "match")
        XCTAssertEqual(snapshot.captureRevisions.map(\.id), ["r1", "r2"]); XCTAssertEqual(snapshot.business.generation, 1)
        try await reopened.close()
    }
    func testForkQuarantinesWithoutACK() async throws {
        let s = try store(h.h.h.path()); _ = try await receive(s, packet(revisions: [h.h.revision(), h.h.revision("r2", parent: "r1", number: 2)]))
        do { _ = try await receive(s, packet("fork", sequence: 2, revisions: [h.h.revision(), h.h.revision("fork", parent: "r1", number: 2)])); XCTFail("fork") } catch {}
        let snapshot = try await s.snapshotV2(matchID: "match"); XCTAssertEqual(snapshot.captureRevisions.map(\.id), ["r1", "r2"])
        XCTAssertTrue(snapshot.business.diagnostics.contains { $0.severity == .blocking }); try await s.close()
    }
    func testMissingCaptureParentRejectsWholePacket() async throws {
        let s = try store(h.h.h.path())
        do { _ = try await receive(s, packet(revisions: [h.h.revision("r2", parent: "r1", number: 2)])); XCTFail("missing root") } catch {}
        let ids = try await s.matchIDs(); XCTAssertTrue(ids.isEmpty)
        let diagnostics = try await s.diagnostics(matchID: "match"); XCTAssertTrue(diagnostics.contains { $0.severity == .blocking }); try await s.close()
    }
    func testACKLossRevalidatesPersistedFacts() async throws {
        for damage in ["event", "revision", "registry", "inbox", "control"] {
            let url = h.h.h.path(); let p = try packet(); let lost = try store(url, fault: .afterCommit)
            do { _ = try await receive(lost, p); XCTFail("lost") } catch let e as StoreError { XCTAssertEqual(e, .responseLost) }
            try await lost.close(); let raw = try SQLite(url: url, fault: nil)
            switch damage {
            case "event": try raw.execute("DELETE FROM events")
            case "revision": try raw.execute("DELETE FROM capture_revisions"); try raw.execute("DELETE FROM capture_identities WHERE kind='revision'")
            case "registry": try raw.execute("DELETE FROM capture_identities")
            case "inbox": try raw.execute("DELETE FROM sync_inbox_v3")
            default: try raw.execute("DELETE FROM sync_ack_controls_v3")
            }
            try raw.close(); let reopened = try store(url)
            do { _ = try await receive(reopened, p); XCTFail("damaged " + damage) } catch {}
            let diagnostics = try await reopened.diagnostics(matchID: "match"); XCTAssertTrue(diagnostics.contains { $0.severity == .blocking }, damage); try await reopened.close()
        }
    }
}

extension SyncReceiveV2Tests {
    func testWireIntegrityPairAndCompleteEventClosureFailClosed() async throws {
        let good = try packet(revisions: [])
        for mode in ["checksum", "version", "source", "parent", "canonical"] {
            let store = try store(h.h.h.path())
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: good.canonicalBytes()) as? [String: Any]), body = try XCTUnwrap(json["body"] as? [String: Any])
            if mode == "checksum" { json["checksum"] = String(repeating: "0", count: 64) }
            if mode == "version" { body["version"] = 99 }
            if mode == "source" { var events = try XCTUnwrap(body["events"] as? [[String: Any]]); events[0]["sourceDeviceID"] = "foreign"; body["events"] = events }
            if mode == "parent" { var events = try XCTUnwrap(body["events"] as? [[String: Any]]); events[0]["correctionOfEventID"] = "missing"; events[0]["revision"] = 1; body["events"] = events }
            json["body"] = body
            if mode != "checksum" { json["checksum"] = Canonical.hash(Data("football-record.sync.packet.v2\0".utf8) + (try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))) }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: mode == "canonical" ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
            do { _ = try await store.receiveV2(bytes, peer: h.peer(local: "phone", remote: "watch", namespace: "phone-db"), expectedMatchID: "match", now: h.t); XCTFail(mode) } catch {}
            let ids = try await store.matchIDs(); XCTAssertTrue(ids.isEmpty)
            let diagnostics = try await store.diagnostics(matchID: "match"); XCTAssertTrue(diagnostics.contains { $0.rawBytes == bytes }); try await store.close()
        }
    }
    func testGlobalFactIdentitiesAndPacketSequenceCannotBeRebound() async throws {
        for mode in ["event", "capture", "packet", "sequence", "idempotency"] {
            let store = try store(h.h.h.path()), first = try packet(); _ = try await receive(store, first)
            var changed: MatchPacketV2
            if mode == "event" || mode == "capture" {
                let intent = StartIntent(id: "other-intent", matchID: "other", recordingDeviceID: "watch", requestedAt: h.t)
                let descriptor = MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
                var recorder = LiveMatchRecorder(descriptor: descriptor)
                try recorder.start(eventID: mode == "event" ? "start" : "other-start", sourceDeviceID: "watch", now: h.t)
                let binding = try CaptureBinding(matchID: "other", recordingDeviceID: "watch")
                let revision = try CaptureRevision(id: mode == "capture" ? "r1" : "other-r1", binding: binding, parentID: nil, revision: 1, observedAt: h.t, metadata: CaptureMetadata(binding: binding, segments: [], gaps: []))
                changed = try MatchPacketV2(packetID: "other", idempotencyKey: "key-other", sequence: 1, sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: descriptor, events: recorder.events, captureRevisions: [revision])
            } else {
                changed = try MatchPacketV2(packetID: mode == "packet" ? first.body.packetID : "changed", idempotencyKey: mode == "idempotency" ? first.body.idempotencyKey : "changed-key", sequence: mode == "sequence" ? 1 : 2, sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: h.descriptor(), events: first.body.events, captureRevisions: first.body.captureRevisions)
            }
            do { _ = try await store.receiveV2(changed.canonicalBytes(), peer: h.peer(local: "phone", remote: "watch", namespace: "phone-db"), expectedMatchID: changed.body.descriptor.matchID, now: h.t); XCTFail(mode) } catch {}
            let original = try await store.snapshotV2(matchID: "match"); XCTAssertEqual(original.business.generation, 1); XCTAssertEqual(original.captureRevisions.map(\.id), ["r1"]); try await store.close()
        }
    }
    func testFirstReceiptStaysFixedAcrossLaterLocalCASGeneration() async throws {
        let store = try store(h.h.h.path()), p = try packet(revisions: [])
        let first = try await receive(store, p)
        _ = try await store.commitV2(h.h.request("local-CAS", generation: 1, descriptor: h.descriptor()))
        let repeated = try await receive(store, p); XCTAssertEqual(repeated, first)
        let snapshot = try await store.snapshot(matchID: "match"); XCTAssertEqual(snapshot.generation, 2); try await store.close()
    }
}
