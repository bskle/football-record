import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class SyncCompatibilityTests: XCTestCase, @unchecked Sendable {
    let h = SyncRoutingTests()
    let receiver = SyncReceiveV2Tests()
    func testSnapshotDoesNotACKUnmappedOutbox() async throws {
        let url = h.h.h.path(); let (original, receipt) = try await h.prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        _ = try await store.commitV2(h.h.request("second", generation: 2, descriptor: h.descriptor(), revisions: [h.h.revision("r2", parent: "r1", number: 2)], outboxID: "second-delta"))
        let route = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: h.peer(), now: h.t)
        XCTAssertEqual(route.packet.body.captureRevisions.count, 2)
        try await store.acknowledgeV2(DurableACKV2(packet: route.packet).canonicalBytes(), peer: h.peer(), now: h.t)
        let state = try await store.syncStateV3(matchID: "match"); XCTAssertEqual(state.unroutedCount, 1); XCTAssertEqual(state.pendingACKCount, 0)
        let remaining = try await store.unroutedBusinessOutboxV3(matchID: "match"); XCTAssertEqual(remaining.map(\.id), ["second-delta"])
        let retry = try await store.commitV2(original); XCTAssertEqual(retry, receipt); try await store.close()
    }
    func testForeignPeerAndV1ACKCannotConfirmV2() async throws {
        let url = h.h.h.path(); _ = try await h.prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let route = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: h.peer(), now: h.t)
        let ack = try DurableACKV2(packet: route.packet)
        for (bytes, peer) in [(try ack.canonicalBytes(), try h.peer(remote: "foreign")), (try Canonical.data(DurableACK(packetID: route.packet.body.packetID, checksum: route.packet.checksum, receivingDeviceID: "phone")), try h.peer())] {
            do { try await store.acknowledgeV2(bytes, peer: peer, now: h.t); XCTFail("untrusted or v1 ACK") } catch {}
        }
        let pending = try await store.pendingPacketsV2(matchID: "match"); XCTAssertEqual(pending.count, 1)
        try await store.close()
    }
    func testMalformedACKPreservesRawAudit() async throws {
        let url = h.h.h.path(); _ = try await h.prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let raw = Data("{broken ACK".utf8)
        do { try await store.acknowledgeV2(raw, peer: h.peer(), now: h.t); XCTFail("malformed") } catch {}
        let global = try await store.diagnostics(matchID: "sync-wire"); XCTAssertTrue(global.contains { $0.rawBytes == raw && $0.severity == .audit })
        try await store.close()
    }
    func testUnknownMatchStateIsNotSynchronized() async throws {
        let store = try MatchStore(url: h.h.h.path())
        for id in ["", "missing"] {
            do { _ = try await store.syncStateV3(matchID: id); XCTFail("unknown cannot be synchronized") }
            catch let error as StoreError { XCTAssertEqual(error, id.isEmpty ? .invalidRequest : .notFound) }
        }
        try await store.close()
    }
    func testPeerReleaseOrCompletionClaimsDoNotPromoteState() async throws {
        for claim in ["releaseRequested", "releasedConfirmed", "network", "permitID", "proof"] {
            let s = try receiver.store(h.h.h.path()), good = try receiver.packet()
            let d = good.body.descriptor
            var descriptor = d
            if claim == "releaseRequested" || claim == "releasedConfirmed" { descriptor = MatchDescriptor(startIntent: d.startIntent, starter: d.starter, startPermit: d.startPermit, backendLockState: BackendLockState(rawValue: claim)!) }
            if claim == "network" { descriptor = MatchDescriptor(startIntent: d.startIntent, starter: d.starter, startPermit: .acceptedByTrustedNetworkBoundary(for: d.startIntent, permitID: "self-asserted"), backendLockState: .held) }
            var raw = try receiver.packet(descriptor: descriptor).canonicalBytes()
            if claim == "proof" {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any]); json["completionProof"] = ["confirmationID": "forged"]
                raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            }
            if claim == "permitID" {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any]); var body = try XCTUnwrap(json["body"] as? [String: Any]); var desc = try XCTUnwrap(body["descriptor"] as? [String: Any]); var permit = try XCTUnwrap(desc["startPermit"] as? [String: Any]); permit["permitID"] = "wrong-but-development-evidence"; desc["startPermit"] = permit; body["descriptor"] = desc; json["body"] = body
                let bodyBytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                json["checksum"] = Canonical.hash(Data("football-record.sync.packet.v2\0".utf8) + bodyBytes)
                raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            }
            do { _ = try await s.receiveV2(raw, peer: h.peer(local: "phone", remote: "watch", namespace: "phone-db"), expectedMatchID: "match", now: h.t); XCTFail(claim) } catch {}
            let matches = try await s.matchIDs(); XCTAssertTrue(matches.isEmpty, claim); try await s.close()
        }
    }
    func testOldHeldSnapshotPreservesExistingLocalCompletionProof() async throws {
        let url = h.h.h.path(); let s = try receiver.store(url)
        let d = h.descriptor(); var recorder = LiveMatchRecorder(descriptor: d)
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: h.t)
        try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: h.t.addingTimeInterval(10))
        let p = try receiver.packet(revisions: [], events: recorder.events)
        let first = try await receiver.receive(s, p)
        let evidence = try TrustedCompletionEvidence.acceptedByCompleteSaveBoundary(descriptor: d, events: recorder.events, confirmationID: "local-trusted-save", now: h.t.addingTimeInterval(10))
        try await s.saveCompletionEvidence(evidence, expectedGeneration: 1, now: h.t.addingTimeInterval(10))
        let repeated = try await receiver.receive(s, p); XCTAssertEqual(repeated, first)
        let snapshot = try await s.snapshot(matchID: "match"); XCTAssertEqual(try snapshot.replay(now: h.t.addingTimeInterval(10)).state, .completed)
        XCTAssertEqual(snapshot.completionEvidence, evidence); try await s.close()
    }
    func testRouteReceiveACKFaultsAreAtomicAndRetryable() async throws {
        for point in [StoreFault.afterRoute, .beforeCommit] {
            let url = h.h.h.path(); _ = try await h.prepare(url)
            let failing = try MatchStore(url: url, fault: point, syncEnvironment: .development(databaseNamespace: "sync-test"))
            do { _ = try await failing.routeBusinessOutboxV3(outboxID: "delta", peer: h.peer(), now: h.t); XCTFail("route fault") } catch {}; try await failing.close()
            let raw = try SQLite(url: url, fault: nil); XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_routes_v3").number, 0); XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_sequences_v3").number, 0); try raw.close()
        }
        for point in [StoreFault.afterInboundFacts, .afterInboundReceipt, .beforeCommit] {
            let url = h.h.h.path(), p = try receiver.packet(), failing = try receiver.store(url, fault: point)
            do { _ = try await receiver.receive(failing, p); XCTFail("receive fault") } catch {}; try await failing.close()
            let raw = try SQLite(url: url, fault: nil); XCTAssertEqual(try raw.scalar("SELECT count(*) FROM matches").number, 0); XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_inbox_v3").number, 0); XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_ack_controls_v3").number, 0); try raw.close()
            let reopened = try receiver.store(url); _ = try await receiver.receive(reopened, p)
            let recovered = try await reopened.syncStateV3(matchID: "match"); XCTAssertNil(recovered.issue, "transaction retry must clear transient failure")
            try await reopened.close()
        }
        for point in [StoreFault.afterACK, .beforeCommit, .afterCommit] {
            let url = h.h.h.path(); _ = try await h.prepare(url)
            let good = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test")); let route = try await good.routeBusinessOutboxV3(outboxID: "delta", peer: h.peer(), now: h.t); try await good.close()
            let failing = try MatchStore(url: url, fault: point, syncEnvironment: .development(databaseNamespace: "sync-test"))
            do { try await failing.acknowledgeV2(DurableACKV2(packet: route.packet).canonicalBytes(), peer: h.peer(), now: h.t); XCTFail("ACK fault") } catch {}; try await failing.close()
            let restored = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test")); let pending = try await restored.pendingPacketsV2(matchID: "match"); XCTAssertEqual(pending.count, point == .afterCommit ? 0 : 1)
            try await restored.acknowledgeV2(DurableACKV2(packet: route.packet).canonicalBytes(), peer: h.peer(), now: h.t); try await restored.close()
        }
    }
}

extension SyncCompatibilityTests {
    func testIncomingPositiveCaptureBlocksOriginalAbsenceCancellationAfterRollbackAndReopen() async throws {
        let absent = AbsentCaptureCleanupTests()
        let (url, initial, cancel) = try await absent.fixture()
        _ = try await initial.commitV2(cancel); try await initial.close()
        let binding = try h.h.binding()
        let segment = try CaptureSegment(id: "real-remote-segment", binding: binding, workoutID: "real-remote-workout", window: CaptureWindow(start: h.t, end: nil))
        let packet = try receiver.packet(revisions: [h.h.revision(segments: [segment])]), raw = try packet.canonicalBytes()
        let store = try receiver.store(url)
        do { _ = try await receiver.receive(store, packet); XCTFail("contradicts proven absence") } catch {}
        let diagnostics = try await store.diagnostics(matchID: "match")
        XCTAssertTrue(diagnostics.contains { $0.code == "capture-absence-contradiction" && $0.rawBytes == raw && $0.severity == .blocking })
        try await store.close(); let reopened = try receiver.store(url)
        do { _ = try await reopened.commitV2(cancel); XCTFail("contradictory original cancel retry") } catch {}
        do { _ = try await reopened.committedCommandV2(commandID: cancel.commandID); XCTFail("contradictory original cancel lookup") } catch {}
        try await reopened.close()
        let inspect = try SQLite(url: url, fault: nil)
        XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM capture_revisions").number, 0)
        XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM sync_inbox_v3").number, 0); try inspect.close()
    }
}

extension SyncCompatibilityTests {
    func testNormalAndAbnormalTerminalSnapshotsRouteReceiveAndACK() async throws {
        for abnormal in [false, true] {
            let url = h.h.h.path(); _ = try await h.prepare(url)
            let source = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
            let snapshot = try await source.snapshot(matchID: "match"); var recorder = LiveMatchRecorder(descriptor: snapshot.descriptor, events: snapshot.events)
            let end: MatchEvent
            if abnormal { end = try PostMatchEditor.terminateAbnormally(terminationID: "abnormal", descriptor: snapshot.descriptor, events: snapshot.events, sourceDeviceID: "phone", now: h.t.addingTimeInterval(10)) }
            else { end = try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: h.t.addingTimeInterval(10)) }
            _ = try await source.commitV2(h.h.request("end", generation: 2, descriptor: snapshot.descriptor, events: [end], outboxID: "end-delta"))
            let route = try await source.routeBusinessOutboxV3(outboxID: "end-delta", peer: h.peer(), now: h.t)
            let destination = try receiver.store(h.h.h.path()); let receipt = try await receiver.receive(destination, route.packet)
            let received = try await destination.snapshot(matchID: "match")
            XCTAssertEqual(try received.replay(now: h.t.addingTimeInterval(20)).state, abnormal ? .incomplete : .endedPendingSync)
            XCTAssertEqual(received.descriptor.backendLockState, .held); XCTAssertNil(received.completionEvidence)
            try await source.acknowledgeV2(receipt.ack.canonicalBytes(), peer: h.peer(), now: h.t)
            let pending = try await source.pendingPacketsV2(matchID: "match"); XCTAssertTrue(pending.isEmpty)
            try await source.close(); try await destination.close()
        }
    }
    func testUnsupportedLocalReleaseFailsClosedAndPreservesAuthorityBytes() async throws {
        let url = h.h.h.path(); let initial = try receiver.store(url); let p = try receiver.packet(revisions: [])
        _ = try await receiver.receive(initial, p); try await initial.close()
        let d = h.descriptor(), released = MatchDescriptor(startIntent: d.startIntent, starter: d.starter, startPermit: d.startPermit, backendLockState: .releasedConfirmed)
        let original = try releasedBytes(released, at: url)
        let store = try receiver.store(url)
        do { _ = try await receiver.receive(store, p); XCTFail("no M4 authority proof verifier") } catch let error as StoreError { XCTAssertEqual(error, .trustUnavailable) }
        try await store.close()
        let raw = try SQLite(url: url, fault: nil)
        XCTAssertEqual(try raw.scalar("SELECT descriptor FROM matches WHERE match_id='match'").data, original)
        XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_inbox_v3").number, 1)
        XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sync_ack_controls_v3").number, 1); try raw.close()
    }
    // Simulates an unsupported persisted authority projection; it grants no trusted release API.
    func releasedBytes(_ descriptor: MatchDescriptor, at url: URL) throws -> Data {
        let bytes = try Canonical.data(descriptor), raw = try SQLite(url: url, fault: nil)
        try raw.execute("UPDATE matches SET descriptor=? WHERE match_id='match'", [.blob(bytes)]); try raw.close(); return bytes
    }
    func testValidPhonePostMatchFactsAndTombstonesKeepTheirAuthority() async throws {
        let d = h.descriptor(); var recorder = LiveMatchRecorder(descriptor: d)
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: h.t)
        try recorder.recordQuick(.myGoal, eventID: "goal", sourceDeviceID: "watch", now: h.t.addingTimeInterval(2))
        let old = recorder.events
        _ = try recorder.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: h.t.addingTimeInterval(3))
        try recorder.transition(.matchEnded, eventID: "end", sourceDeviceID: "watch", now: h.t.addingTimeInterval(10))
        let edit = try PostMatchEditor.insertScore(eventID: "phone-edit", descriptor: d, events: recorder.events, occurredAt: h.t.addingTimeInterval(4), goal: GoalPayload(scoreImpact: .against, scoringTeamSnapshot: "other"), sourceDeviceID: "phone", now: h.t.addingTimeInterval(11))
        let s = try receiver.store(h.h.h.path())
        let full = try receiver.packet("new", sequence: 2, revisions: [], events: recorder.events + [edit])
        _ = try await receiver.receive(s, full)
        _ = try await receiver.receive(s, receiver.packet("old", revisions: [], events: old))
        let snapshot = try await s.snapshot(matchID: "match"), replay = try snapshot.replay(now: h.t.addingTimeInterval(20))
        XCTAssertEqual(replay.score.forTeam, 0); XCTAssertEqual(replay.score.against, 1)
        XCTAssertTrue(snapshot.events.contains(edit)); XCTAssertTrue(snapshot.events.contains { $0.eventID == "undo" && $0.status == .deleted }); try await s.close()
    }
    func testStandaloneWireBodyDecodersRejectInvalidValues() throws {
        let p = try receiver.packet(revisions: [])
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(p.body)) as? [String: Any]); body["sequence"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(MatchPacketV2.Body.self, from: JSONSerialization.data(withJSONObject: body)))
        var ackBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Canonical.data(DurableACKV2(packet: p).body)) as? [String: Any]); ackBody["matchID"] = "  "
        XCTAssertThrowsError(try JSONDecoder().decode(DurableACKV2.Body.self, from: JSONSerialization.data(withJSONObject: ackBody)))
    }
}

extension SyncCompatibilityTests {
    func testFrozenV2PacketAndACKBytesRemainCanonical() async throws {
        let bytes = try LegacyCompatibilityTests().fixture("sync-v2-ended-capture-packet")
        let ackBytes = try LegacyCompatibilityTests().fixture("sync-v2-ended-capture-ack")
        let packet = try JSONDecoder().decode(MatchPacketV2.self, from: bytes)
        let ack = try JSONDecoder().decode(DurableACKV2.self, from: ackBytes)
        XCTAssertEqual(try packet.canonicalBytes(), bytes); XCTAssertEqual(try ack.canonicalBytes(), ackBytes)
        XCTAssertEqual(try DurableACKV2(packet: packet), ack)
        let store = try receiver.store(h.h.h.path())
        let first = try await receiver.receive(store, packet), duplicate = try await receiver.receive(store, packet)
        XCTAssertEqual(first, duplicate); XCTAssertEqual(try first.ack.canonicalBytes(), ackBytes)
        let snapshot = try await store.snapshotV2(matchID: "match")
        XCTAssertEqual(snapshot.captureRevisions.map(\.id), ["fixture-r1", "fixture-r2"])
        XCTAssertEqual(try snapshot.business.replay(now: h.t.addingTimeInterval(20)).state, .endedPendingSync)
        XCTAssertNil(snapshot.business.completionEvidence); try await store.close()
    }
}
