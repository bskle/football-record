import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class SyncRoutingTests: XCTestCase, @unchecked Sendable {
    let h = CaptureTransactionTests()
    let t = TransactionTests().t
    func peer(local: String = "watch", remote: String = "phone", namespace: String = "sync-test") throws -> PeerAuthorization {
        try PeerAuthorization(localDeviceID: local, remoteDeviceID: remote, accountSubject: "account", pairingID: "pair", trustEpoch: "epoch", environment: .development(databaseNamespace: namespace), issuedAt: t.addingTimeInterval(-60), expiresAt: t.addingTimeInterval(3600))
    }
    func descriptor() -> MatchDescriptor {
        let intent = TransactionTests().descriptor().startIntent
        return MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
    }
    func prepare(_ url: URL) async throws -> (StoreCommitV2, CommitReceiptV2) {
        try await h.h.prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let d = descriptor(); var recorder = LiveMatchRecorder(descriptor: d)
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: t)
        let request = try h.request("command", generation: 1, descriptor: d, events: recorder.events, revisions: [h.revision()], outboxID: "delta")
        let receipt = try await store.commitV2(request); try await store.close()
        return (request, receipt)
    }
    func testRoutingKeepsOriginalCommandRetryValid() async throws {
        let url = h.h.path(); let (request, first) = try await prepare(url)
        let raw = try SQLite(url: url, fault: nil)
        let before = try raw.rows("SELECT payload,checksum,routing_state FROM business_outbox"); try raw.close()
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let route = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        XCTAssertEqual(route.packet.body.sequence, 1)
        let retry = try await store.commitV2(request); XCTAssertEqual(retry, first)
        let legacy = try await store.pendingBusinessOutbox(matchID: "match"); XCTAssertEqual(legacy.map(\.id), ["delta"])
        let unrouted = try await store.unroutedBusinessOutboxV3(matchID: "match"); XCTAssertTrue(unrouted.isEmpty)
        let ack = try DurableACKV2(packet: route.packet)
        try await store.acknowledgeV2(Canonical.data(ack), peer: peer(), now: t)
        let afterACK = try await store.committedCommandV2(commandID: request.commandID); XCTAssertEqual(afterACK?.receipt, first)
        try await store.close()
        let inspect = try SQLite(url: url, fault: nil)
        let after = try inspect.rows("SELECT payload,checksum,routing_state FROM business_outbox")
        XCTAssertEqual(after[0][0].data, before[0][0].data); XCTAssertEqual(after[0][1].string, before[0][1].string); XCTAssertEqual(after[0][2].string, "unrouted")
        try inspect.close()
    }
    func testRouteResponseLostReturnsOriginalPacket() async throws {
        let url = h.h.path(); _ = try await prepare(url)
        let lost = try MatchStore(url: url, fault: .afterCommit, syncEnvironment: .development(databaseNamespace: "sync-test"))
        do { _ = try await lost.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t); XCTFail("lost response") } catch let e as StoreError { XCTAssertEqual(e, .responseLost) }
        try await lost.close()
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let first = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        let retry = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t.addingTimeInterval(1))
        XCTAssertEqual(first, retry); XCTAssertEqual(first.packet.body.sequence, 1)
        try await store.close()
    }
}

extension SyncRoutingTests {
    func testFirstRouteRevalidatesOriginalOutboxFacts() async throws {
        for kind in ["event", "revision"] {
            let url = h.h.path(); _ = try await prepare(url)
            let raw = try SQLite(url: url, fault: nil)
            if kind == "event" { try raw.execute("DELETE FROM events") }
            else { try raw.execute("DELETE FROM capture_revisions"); try raw.execute("DELETE FROM capture_identities WHERE kind='revision'") }
            try raw.close()
            let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
            do { _ = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t); XCTFail("lost " + kind) } catch {}
            try await store.close(); let inspect = try SQLite(url: url, fault: nil)
            XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM sync_routes_v3").number, 0, kind)
            XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM sync_sequences_v3").number, 0, kind)
            XCTAssertEqual(try inspect.scalar("SELECT count(*) FROM diagnostics WHERE severity='blocking'").number, 1, kind); try inspect.close()
        }
    }
    func testMissingEventAncestorRemainsUnroutedWithoutSequence() async throws {
        let url = h.h.path(); try await h.h.prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let d = descriptor(); var recorder = LiveMatchRecorder(descriptor: d)
        try recorder.start(eventID: "start", sourceDeviceID: "watch", now: t)
        try recorder.recordQuick(.myGoal, eventID: "goal", sourceDeviceID: "watch", now: t.addingTimeInterval(2))
        let original = recorder.events
        let undo = try recorder.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: t.addingTimeInterval(3))
        _ = try await store.commitV2(h.request("undo-first", generation: 1, descriptor: d, events: [undo], outboxID: "delta"))
        do { _ = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t); XCTFail("missing ancestor") } catch let error as StoreError { XCTAssertEqual(error, .ancestryIncomplete) }
        let state = try await store.syncStateV3(matchID: "match"); XCTAssertEqual(state.issue, .ancestryIncomplete); XCTAssertEqual(state.unroutedCount, 1)
        _ = try await store.commitV2(h.request("parent", generation: 2, descriptor: d, events: original, outboxID: "parent-delta"))
        let route = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        XCTAssertEqual(route.packet.body.sequence, 1); XCTAssertEqual(route.packet.body.events.count, 3)
        try await store.close()
    }
    func testRoutesFreezeSnapshotAndUseIndependentSequences() async throws {
        let url = h.h.path(); _ = try await prepare(url)
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        _ = try await store.commitV2(h.request("local-only", generation: 2, descriptor: descriptor()))
        let first = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        XCTAssertEqual(first.packet.body.sequence, 1)
        let r2 = try h.revision("r2", parent: "r1", number: 2)
        _ = try await store.commitV2(h.request("later", generation: 3, descriptor: descriptor(), revisions: [r2], outboxID: "later"))
        let second = try await store.routeBusinessOutboxV3(outboxID: "later", peer: peer(), now: t)
        let retry = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        XCTAssertEqual(retry, first); XCTAssertEqual(second.packet.body.sequence, 2)
        XCTAssertEqual(first.packet.body.captureRevisions.count, 1); XCTAssertEqual(second.packet.body.captureRevisions.count, 2)
        try await store.close()
    }
    func testPeerBindingCannotChangeAndProductionIsUnavailable() async throws {
        let url = h.h.path(); _ = try await prepare(url)
        let production = try MatchStore(url: url)
        let productionPeer = try PeerAuthorization(localDeviceID: "watch", remoteDeviceID: "phone", accountSubject: "account", pairingID: "pair", trustEpoch: "epoch", environment: .production, issuedAt: t.addingTimeInterval(-1), expiresAt: t.addingTimeInterval(1))
        do { _ = try await production.routeBusinessOutboxV3(outboxID: "delta", peer: productionPeer, now: t); XCTFail("production") } catch let e as StoreError { XCTAssertEqual(e, .trustUnavailable) }; try await production.close()
        let store = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let route = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t)
        for field in ["remote", "account", "epoch", "namespace", "expired", "future"] {
            let bad = try PeerAuthorization(localDeviceID: "watch", remoteDeviceID: field == "remote" ? "other" : "phone", accountSubject: field == "account" ? "other" : "account", pairingID: "pair", trustEpoch: field == "epoch" ? "other" : "epoch", environment: .development(databaseNamespace: field == "namespace" ? "other" : "sync-test"), issuedAt: field == "future" ? t.addingTimeInterval(1) : t.addingTimeInterval(-60), expiresAt: field == "expired" ? t.addingTimeInterval(-1) : t.addingTimeInterval(3600))
            do { _ = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: bad, now: t); XCTFail(field) } catch {}
        }
        let retry = try await store.routeBusinessOutboxV3(outboxID: "delta", peer: peer(), now: t); XCTAssertEqual(retry, route); try await store.close()
        let otherEnvironment = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "other"))
        do { _ = try await otherEnvironment.routeBusinessOutboxV3(outboxID: "delta", peer: peer(namespace: "other"), now: t); XCTFail("reopen namespace") } catch {}; try await otherEnvironment.close()
    }
}
