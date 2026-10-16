import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class SyncDeliveryTests: XCTestCase, @unchecked Sendable {
    let h = SyncRoutingTests()
    func testFragmentReorderDuplicateAndRestart() async throws {
        let packet = try SyncReceiveV2Tests().packet(revisions: [])
        let bytes = try packet.canonicalBytes()
        let fragments = try SyncFragment.fragments(bytes: bytes, kind: .packet)
        let url = h.h.h.path(), s = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "phone-db"))
        let peer = try h.peer(local: "phone", remote: "watch", namespace: "phone-db")
        let first = try await s.acceptSyncFragmentV3(fragments[0].canonicalBytes(), peer: peer, now: h.t)
        guard case .complete(_, .packet, "match", let digest, let raw) = first else { return XCTFail("complete") }
        XCTAssertEqual(raw, bytes); XCTAssertEqual(digest, Canonical.hash(bytes)); try await s.close()
        let reopened = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "phone-db"))
        let repeated = try await reopened.acceptSyncFragmentV3(fragments[0].canonicalBytes(), peer: peer, now: h.t)
        XCTAssertEqual(first, repeated); try await reopened.close()
    }
    func testRestartRetriesOriginalBytes() async throws {
        let url = h.h.h.path(); _ = try await h.prepare(url)
        let s = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        _ = try await s.routeBusinessOutboxV3(outboxID: "delta", peer: h.peer(), now: h.t)
        try await s.ensureSyncDeliveriesV3(matchID: "match")
        let due = try await s.dueSyncDeliveriesV3(now: h.t, limit: 32)
        XCTAssertEqual(due.count, 1)
        try await s.recordSyncAttemptV3(deliveryID: due[0].deliveryID, nextAttemptAt: h.t.addingTimeInterval(1), issue: nil, now: h.t)
        try await s.close()
        let reopened = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        let later = try await reopened.dueSyncDeliveriesV3(now: h.t.addingTimeInterval(1), limit: 32)
        XCTAssertEqual(later[0].fragmentBytes, due[0].fragmentBytes); XCTAssertEqual(later[0].attemptCount, 1); try await reopened.close()
    }
}

extension SyncDeliveryTests {
    func largePacket() throws -> MatchPacketV2 {
        let base = try SyncReceiveV2Tests().packet(revisions: [])
        let goal = MatchEvent(eventID: "large-goal", matchID: "match", sequence: 1, occurredAt: h.t.addingTimeInterval(1), matchElapsed: 1, type: .scoreEvent, sourceDeviceID: "watch", createdAt: h.t.addingTimeInterval(1), updatedAt: h.t.addingTimeInterval(1), goal: GoalPayload(scoreImpact: .forTeam, scoringTeamSnapshot: "team", note: String(repeating: "x", count: 600_000)))
        return try SyncReceiveV2Tests().packet(revisions: [], events: base.body.events + [goal])
    }
    func receiver(_ url: URL) throws -> MatchStore { try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "phone-db")) }
    func longPeer() throws -> PeerAuthorization {
        try PeerAuthorization(localDeviceID: "phone", remoteDeviceID: "watch", accountSubject: "account", pairingID: "pair", trustEpoch: "epoch", environment: .development(databaseNamespace: "phone-db"), issuedAt: h.t.addingTimeInterval(-100), expiresAt: h.t.addingTimeInterval(1_000_000))
    }
    func testLargeReorderRestartConsumeAndDuplicateRetainFirstACK() async throws {
        let p = try largePacket(), fragments = try SyncFragment.fragments(bytes: p.canonicalBytes(), kind: .packet)
        XCTAssertEqual(fragments.count, 3)
        let url = h.h.h.path(), s = try receiver(url), peer = try longPeer()
        let last = try fragments[2].canonicalBytes()
        let partial = try await s.acceptSyncFragmentV3(last, peer: peer, now: h.t); XCTAssertEqual(partial, .incomplete)
        let duplicate = try await s.acceptSyncFragmentV3(last, peer: peer, now: h.t); XCTAssertEqual(duplicate, .incomplete)
        try await s.close(); let reopened = try receiver(url)
        _ = try await reopened.acceptSyncFragmentV3(fragments[0].canonicalBytes(), peer: peer, now: h.t)
        let result = try await reopened.acceptSyncFragmentV3(fragments[1].canonicalBytes(), peer: peer, now: h.t)
        guard case .complete(let id, _, _, let digest, let raw) = result else { return XCTFail("complete") }
        let pending = try await reopened.pendingSyncAssembliesV3(peer: peer, now: h.t); XCTAssertEqual(pending, [result])
        do { try await reopened.consumeSyncAssemblyV3(messageID: id, wholeChecksum: digest); XCTFail("no durable business receipt") } catch {}
        let receipt = try await reopened.receiveV2(raw, peer: peer, expectedMatchID: "match", now: h.t)
        try await reopened.consumeSyncAssemblyV3(messageID: id, wholeChecksum: digest)
        try await reopened.consumeSyncAssemblyV3(messageID: id, wholeChecksum: digest)
        let empty = try await reopened.pendingSyncAssembliesV3(peer: peer, now: h.t); XCTAssertTrue(empty.isEmpty)
        for f in fragments { _ = try await reopened.acceptSyncFragmentV3(f.canonicalBytes(), peer: peer, now: h.t) }
        let repeated = try await reopened.receiveV2(raw, peer: peer, expectedMatchID: "match", now: h.t); XCTAssertEqual(repeated, receipt)
        try await reopened.close()
    }
    func testWholeCanonicalHeaderMismatchQuarantinesOriginalFrame() async throws {
        let p = try SyncReceiveV2Tests().packet(revisions: []), bytes = try p.canonicalBytes()
        for mode in ["kind", "message", "match", "whole"] {
            let s = try receiver(h.h.h.path())
            let f = try SyncFragment(body: SyncFragment.Body(kind: mode == "kind" ? .ack : .packet, messageID: mode == "message" ? "wrong" : p.body.packetID, sourceDeviceID: "watch", targetDeviceID: "phone", matchID: mode == "match" ? "wrong" : "match", wholeChecksum: mode == "whole" ? String(repeating: "0", count: 64) : Canonical.hash(bytes), totalBytes: bytes.count, index: 0, count: 1, payload: bytes))
            let raw = try f.canonicalBytes()
            do { _ = try await s.acceptSyncFragmentV3(raw, peer: longPeer(), now: h.t); XCTFail(mode) } catch {}
            let diagnostics = try await s.diagnostics(matchID: f.body.matchID); XCTAssertTrue(diagnostics.contains { $0.rawBytes == raw }, mode)
            let ids = try await s.matchIDs(); XCTAssertTrue(ids.isEmpty); try await s.close()
        }
    }
    func testSameFragmentIdentityConflictAndTimeoutNeverACKPartial() async throws {
        let fragments = try SyncFragment.fragments(bytes: largePacket().canonicalBytes(), kind: .packet), first = fragments[0], b = first.body
        let url = h.h.h.path(), s = try receiver(url), peer = try longPeer()
        _ = try await s.acceptSyncFragmentV3(first.canonicalBytes(), peer: peer, now: h.t)
        let conflict = try SyncFragment(body: SyncFragment.Body(kind: .ack, messageID: b.messageID, sourceDeviceID: b.sourceDeviceID, targetDeviceID: b.targetDeviceID, matchID: b.matchID, wholeChecksum: b.wholeChecksum, totalBytes: b.totalBytes, index: b.index, count: b.count, payload: b.payload))
        XCTAssertEqual(try conflict.fragmentID, try first.fragmentID)
        do { _ = try await s.acceptSyncFragmentV3(conflict.canonicalBytes(), peer: peer, now: h.t); XCTFail("same ID different bytes") } catch let error as StoreError { XCTAssertEqual(error, .syncConflict) }
        try await s.expireSyncAssembliesV3(now: h.t.addingTimeInterval(-1))
        try await s.expireSyncAssembliesV3(now: h.t.addingTimeInterval(86_400))
        let diagnostics = try await s.diagnostics(matchID: "match"); XCTAssertTrue(diagnostics.contains { $0.code == "sync-fragment-timeout" })
        let restarted = try await s.acceptSyncFragmentV3(first.canonicalBytes(), peer: peer, now: h.t.addingTimeInterval(86_400)); XCTAssertEqual(restarted, .incomplete)
        let matches = try await s.matchIDs(); XCTAssertTrue(matches.isEmpty); try await s.close()
    }
    func testACKSleepsAfterEightAttemptsAndExplicitWakeKeepsTotalAudit() async throws {
        let url = h.h.h.path(), s = try receiver(url), p = try SyncReceiveV2Tests().packet(revisions: []), peer = try longPeer()
        _ = try await s.receiveV2(p.canonicalBytes(), peer: peer, expectedMatchID: "match", now: h.t)
        try await s.ensureSyncDeliveriesV3(matchID: "match")
        var firstID: String?
        for attempt in 0..<8 {
            let now = h.t.addingTimeInterval(Double(attempt)), due = try await s.dueSyncDeliveriesV3(now: now, limit: 32)
            XCTAssertEqual(due.count, 1); XCTAssertEqual(due[0].attemptCount, attempt); firstID = due[0].deliveryID
            try await s.recordSyncAttemptV3(deliveryID: due[0].deliveryID, nextAttemptAt: now.addingTimeInterval(1), issue: nil, now: now)
            try await s.ensureSyncDeliveriesV3(matchID: "match")
        }
        let sleeping = try await s.dueSyncDeliveriesV3(now: h.t.addingTimeInterval(1000), limit: 32); XCTAssertTrue(sleeping.isEmpty)
        try await s.reactivateSyncACKsV3()
        let woken = try await s.dueSyncDeliveriesV3(now: h.t, limit: 32); XCTAssertEqual(woken[0].attemptCount, 8); XCTAssertEqual(woken[0].deliveryID, firstID)
        try await s.recordSyncAttemptV3(deliveryID: woken[0].deliveryID, nextAttemptAt: h.t.addingTimeInterval(1), issue: nil, now: h.t)
        _ = try await s.receiveV2(p.canonicalBytes(), peer: peer, expectedMatchID: "match", now: h.t)
        let replay = try await s.dueSyncDeliveriesV3(now: h.t, limit: 32); XCTAssertEqual(replay[0].attemptCount, 9); try await s.close()
    }
    func testUnfinishedMessageQuota256RejectsNewFrameWithoutACK() async throws {
        let s = try receiver(h.h.h.path()), peer = try longPeer()
        for n in 0...256 {
            let f = try SyncFragment(body: SyncFragment.Body(kind: .packet, messageID: "quota-\(n)", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: SyncFragment.chunkBytes + 1, index: 1, count: 2, payload: Data([125])))
            if n == 256 {
                do { _ = try await s.acceptSyncFragmentV3(f.canonicalBytes(), peer: peer, now: h.t); XCTFail("quota") } catch let error as StoreError { XCTAssertEqual(error, .syncQuotaExceeded) }
            } else { let result = try await s.acceptSyncFragmentV3(f.canonicalBytes(), peer: peer, now: h.t); XCTAssertEqual(result, .incomplete) }
        }
        let ids = try await s.matchIDs(); XCTAssertTrue(ids.isEmpty); try await s.close()
    }
}


extension SyncDeliveryTests {
    func testDueBatchIsBoundedAndAuthorizationCannotRebindSavedDelivery() async throws {
        let url = h.h.h.path(); _ = try await h.prepare(url)
        let s = try MatchStore(url: url, syncEnvironment: .development(databaseNamespace: "sync-test"))
        for index in 0..<33 {
            let id = "delivery-\(index)"
            _ = try await s.commitV2(h.h.request(id, generation: Int64(index + 2), descriptor: h.descriptor(), outboxID: id))
            _ = try await s.routeBusinessOutboxV3(outboxID: id, peer: h.peer(), now: h.t)
        }
        try await s.ensureSyncDeliveriesV3(matchID: "match")
        let batch = try await s.dueSyncDeliveriesV3(now: h.t, limit: 32); XCTAssertEqual(batch.count, 32)
        do { _ = try await s.dueSyncDeliveriesV3(now: h.t, limit: 33); XCTFail("bounded batch") } catch let error as StoreError { XCTAssertEqual(error, .invalidRequest) }
        let d = try XCTUnwrap(batch.first)
        for field in ["epoch", "account", "peer"] {
            let changed = try PeerAuthorization(localDeviceID: "watch", remoteDeviceID: field == "peer" ? "other-phone" : "phone", accountSubject: field == "account" ? "other-account" : "account", pairingID: "pair", trustEpoch: field == "epoch" ? "new-epoch" : "epoch", environment: .development(databaseNamespace: "sync-test"), issuedAt: h.t, expiresAt: h.t.addingTimeInterval(3600))
            do { try await s.validateSyncDeliveryV3(deliveryID: d.deliveryID, peer: changed, now: h.t); XCTFail(field) } catch let error as StoreError { XCTAssertEqual(error, .invalidPeerAuthorization) }
        }
        try await s.validateSyncDeliveryV3(deliveryID: d.deliveryID, peer: h.peer(), now: h.t)
        for delivery in batch { try await s.recordSyncAttemptV3(deliveryID: delivery.deliveryID, nextAttemptAt: h.t.addingTimeInterval(1), issue: nil, now: h.t) }
        let rest = try await s.dueSyncDeliveriesV3(now: h.t, limit: 32); XCTAssertEqual(rest.count, 1)
        try await s.close()
    }
    func testFragmentTransactionFaultRollsBackAndLostResponseKeepsExactBytes() async throws {
        let f = try XCTUnwrap(SyncFragment.fragments(bytes: largePacket().canonicalBytes(), kind: .packet).first), bytes = try f.canonicalBytes()
        for fault in [StoreFault.afterFragment, .beforeCommit, .afterCommit] {
            let url = h.h.h.path(), s = try MatchStore(url: url, fault: fault, syncEnvironment: .development(databaseNamespace: "phone-db"))
            do { _ = try await s.acceptSyncFragmentV3(bytes, peer: longPeer(), now: h.t); XCTFail("injected") } catch let error as StoreError { XCTAssertEqual(error, fault == .afterCommit ? .responseLost : .injectedFailure) }
            try await s.close(); let inspect = try SQLite(url: url, fault: nil)
            let before = try inspect.rows("SELECT record,checksum FROM sync_fragments_v3")
            XCTAssertEqual(before.count, fault == .afterCommit ? 1 : 0); try inspect.close()
            let reopened = try receiver(url)
            let result = try await reopened.acceptSyncFragmentV3(bytes, peer: longPeer(), now: h.t); XCTAssertEqual(result, .incomplete)
            try await reopened.close(); let after = try SQLite(url: url, fault: nil)
            let rows = try after.rows("SELECT record,checksum FROM sync_fragments_v3")
            if !before.isEmpty { XCTAssertEqual(rows[0][0].data, before[0][0].data); XCTAssertEqual(rows[0][1].string, before[0][1].string) }
            try after.close()
        }
    }
    func testFragmentSizeAndCountLimitsRejectBeforeAssembly() throws {
        let payload = Data(repeating: 1, count: SyncFragment.chunkBytes)
        XCTAssertThrowsError(try SyncFragment.Body(kind: .packet, messageID: "m", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: 8 * 1024 * 1024 + 1, index: 0, count: 33, payload: payload))
        XCTAssertThrowsError(try SyncFragment.Body(kind: .packet, messageID: "m", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: SyncFragment.chunkBytes + 1, index: 0, count: 2, payload: payload + Data([1])))
        let maximum = try SyncFragment.Body(kind: .packet, messageID: "m", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: 8 * 1024 * 1024, index: 0, count: 32, payload: payload)
        XCTAssertEqual(maximum.count, 32)
    }
    func testPersistedFragmentByteQuota64MiBRejectsAnotherChunk() async throws {
        let url = h.h.h.path(), s = try receiver(url), peer = try longPeer()
        try await s.close()
        let inspect = try SQLite(url: url, fault: nil), limit = 64 * 1024 * 1024
        var used = 0, group = 0
        // Seed the valid, bounded partial groups produced by earlier accepted frames.
        // This keeps the quota test focused on the crossing rather than 190 repeated scans.
        while true {
            var bytes: [Data] = [], header: AssemblyHeader?
            for index in 0..<31 {
                let f = try SyncFragment(body: SyncFragment.Body(kind: .packet, messageID: "bytes-\(group)", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: 8 * 1024 * 1024, index: index, count: 32, payload: Data(repeating: 1, count: SyncFragment.chunkBytes)))
                let raw = try f.canonicalBytes()
                if used + raw.count > limit { break }
                bytes.append(raw); header = AssemblyHeader(f.body); used += raw.count
            }
            guard let header, !bytes.isEmpty else { break }
            let saved = StoredAssembly(header: header, peer: peer, firstReceivedAt: h.t, expiresAt: h.t.addingTimeInterval(86_400), fragments: bytes, consumed: false, expired: false), raw = try Canonical.data(saved)
            try inspect.execute("INSERT INTO sync_fragments_v3 VALUES (?,?,?,?)", [.text(try header.id), .text("match"), .blob(raw), .text(Canonical.hash(raw))])
            group += 1
            if bytes.count < 31 { break }
        }
        XCTAssertGreaterThan(used, limit - 400_000); XCTAssertLessThanOrEqual(used, limit); try inspect.close()
        let reopened = try receiver(url)
        let next = try SyncFragment(body: SyncFragment.Body(kind: .packet, messageID: "bytes-next", sourceDeviceID: "watch", targetDeviceID: "phone", matchID: "match", wholeChecksum: String(repeating: "0", count: 64), totalBytes: 8 * 1024 * 1024, index: 0, count: 32, payload: Data(repeating: 1, count: SyncFragment.chunkBytes)))
        do { _ = try await reopened.acceptSyncFragmentV3(next.canonicalBytes(), peer: peer, now: h.t); XCTFail("64MiB quota") } catch let error as StoreError { XCTAssertEqual(error, .syncQuotaExceeded) }
        let ids = try await reopened.matchIDs(); XCTAssertTrue(ids.isEmpty); try await reopened.close()
    }
}
