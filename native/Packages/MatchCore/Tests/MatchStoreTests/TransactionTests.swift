import Foundation
import XCTest
import MatchCore
@testable import MatchStore

final class TransactionTests: XCTestCase, @unchecked Sendable {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("match-store-" + UUID().uuidString + ".sqlite") }
    func descriptor(permit: Bool = false) -> MatchDescriptor {
        let intent = StartIntent(id: "intent", matchID: "match", recordingDeviceID: "watch", requestedAt: t)
        return MatchDescriptor(startIntent: intent, starter: true,
            startPermit: permit ? .acceptedByTrustedNetworkBoundary(for: intent, permitID: "permit") : nil,
            backendLockState: permit ? .held : .unknown)
    }
    func facts() throws -> (MatchDescriptor, [MatchEvent]) {
        let d = descriptor(permit: true)
        var r = LiveMatchRecorder(descriptor: d)
        try r.start(eventID: "start", sourceDeviceID: "watch", now: t)
        try r.recordQuick(.myGoal, eventID: "goal", sourceDeviceID: "watch", now: t.addingTimeInterval(3))
        return (d, r.events)
    }
    func request(_ command: String = "command", generation: Int64 = 1,
                 descriptor: MatchDescriptor, events: [MatchEvent]) throws -> StoreCommit {
        let packet = try MatchPacket(packetID: "packet-" + command, idempotencyKey: "key-" + command,
            revision: generation, sourceDeviceID: "watch", targetDeviceID: "phone", descriptor: descriptor, events: events)
        return StoreCommit(commandID: command, expectedGeneration: generation, descriptor: descriptor, events: events, packets: [packet])
    }
    func prepare(_ url: URL) async throws {
        let store = try MatchStore(url: url)
        _ = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: descriptor(), events: [], packets: []))
        try await store.close()
    }
    func testIntentRestoresBeforePermitWithNoStart() async throws {
        let url = path(); let store = try MatchStore(url: url)
        _ = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: descriptor(), events: [], packets: []))
        try await store.close()
        let reopened = try MatchStore(url: url)
        let snapshot = try await reopened.snapshot(matchID: "match")
        XCTAssertEqual(snapshot.descriptor.startIntent, descriptor().startIntent)
        XCTAssertNil(snapshot.descriptor.startPermit)
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.generation, 1)
        try await reopened.close()
    }
    func testTransactionalFailuresDoNotCommitFactsOutboxOrReceipt() async throws {
        for point in [StoreFault.afterEvents, .afterOutbox, .beforeCommit] {
            let url = path(); let first = try MatchStore(url: url)
            _ = try await first.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: descriptor(), events: [], packets: []))
            try await first.close()
            let failing = try MatchStore(url: url, fault: point)
            let (d, e) = try facts(); let c = try request(descriptor: d, events: e)
            do { _ = try await failing.commit(c); XCTFail("expected failure at \(point)") } catch {}
            try await failing.close()
            let restored = try MatchStore(url: url)
            let s = try await restored.snapshot(matchID: "match")
            XCTAssertEqual(s.generation, 1); XCTAssertTrue(s.events.isEmpty)
            let pending = try await restored.pendingPackets(matchID: "match")
            XCTAssertTrue(pending.isEmpty)
            let receipt = try await restored.commit(c)
            XCTAssertEqual(receipt.generation, 2)
            try await restored.close()
        }
    }
    func testLostResponseReturnsFirstReceiptAfterReopenAndRejectsChangedCommand() async throws {
        let url = path(); try await prepare(url)
        let store = try MatchStore(url: url, fault: .afterCommit)
        let (d, e) = try facts(); let c = try request(descriptor: d, events: e)
        do { _ = try await store.commit(c); XCTFail("lost response") } catch {}
        try await store.close()
        let restored = try MatchStore(url: url)
        let a = try await restored.commit(c); let b = try await restored.commit(c)
        XCTAssertEqual(a, b); XCTAssertEqual(a.generation, 2)
        let changed = StoreCommit(commandID: c.commandID, expectedGeneration: 0, descriptor: d, events: [], packets: [])
        do { _ = try await restored.commit(changed); XCTFail("command collision") } catch let error as StoreError { XCTAssertEqual(error, .commandConflict) }
        let s = try await restored.snapshot(matchID: "match")
        XCTAssertEqual(s.events, e)
        try await restored.close()
    }
    func testTwoConnectionsCASPreventsStaleWriter() async throws {
        let url = path(); try await prepare(url)
        let a = try MatchStore(url: url); let b = try MatchStore(url: url)
        let (d, e) = try facts()
        _ = try await a.commit(request("one", descriptor: d, events: e))
        do { _ = try await b.commit(request("two", descriptor: d, events: e)); XCTFail("stale writer") }
        catch let error as StoreError { XCTAssertEqual(error, .staleGeneration) }
        let snapshot = try await b.snapshot(matchID: "match")
        XCTAssertEqual(snapshot.generation, 2)
        try await a.close(); try await b.close()
    }
    func testConcurrentConnectionsHaveOneCASWinner() async throws {
        let url = path(); try await prepare(url)
        let a = try MatchStore(url: url); let b = try MatchStore(url: url)
        let (d, e) = try facts()
        let one = try request("race-one", descriptor: d, events: e)
        let two = try request("race-two", descriptor: d, events: e)
        async let resultOne = accepted(a, one)
        async let resultTwo = accepted(b, two)
        let results = await [resultOne, resultTwo]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let s = try await a.snapshot(matchID: "match")
        XCTAssertEqual(s.generation, 2); XCTAssertEqual(s.events.count, 2)
        try await a.close(); try await b.close()
    }
    func accepted(_ store: MatchStore, _ request: StoreCommit) async -> Bool {
        do { _ = try await store.commit(request); return true } catch { return false }
    }
    func testUndoSurvivesReopenAndOldOriginalRetransmission() async throws {
        let url = path(); try await prepare(url)
        let store = try MatchStore(url: url); let (d, e) = try facts()
        _ = try await store.commit(request("initial", descriptor: d, events: e))
        var staging = LiveMatchRecorder(descriptor: d, events: e)
        let undo = try staging.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: t.addingTimeInterval(5))
        _ = try await store.commit(request("undo", generation: 2, descriptor: d, events: [undo]))
        try await store.close()
        let restored = try MatchStore(url: url)
        _ = try await restored.commit(request("retry-original", generation: 3, descriptor: d, events: e.reversed()))
        let s = try await restored.snapshot(matchID: "match")
        XCTAssertEqual(s.events.count, 3)
        XCTAssertEqual(try s.replay(now: t.addingTimeInterval(6)).score.forTeam, 0)
        var r = LiveMatchRecorder(descriptor: s.descriptor, events: s.events)
        XCTAssertThrowsError(try r.undoLastQuick(eventID: "again", sourceDeviceID: "watch", now: t.addingTimeInterval(7)))
        try await restored.close()
    }
    func testCommandReceiptCannotConfirmMissingOrCorruptFactsOrOutbox() async throws {
        for damage in ["missing-event", "corrupt-event", "missing-packet", "corrupt-packet", "missing-match", "corrupt-match"] {
            let url = path(); try await prepare(url)
            let store = try MatchStore(url: url); let (d, e) = try facts()
            let command = try request(descriptor: d, events: e)
            _ = try await store.commit(command); try await store.close()
            let sql = try SQLite(url: url, fault: nil)
            switch damage {
            case "missing-event": try sql.execute("DELETE FROM events WHERE event_id='goal'")
            case "corrupt-event": try sql.execute("UPDATE events SET checksum='wrong' WHERE event_id='goal'")
            case "missing-packet": try sql.execute("DELETE FROM outbox")
            case "missing-match": try sql.execute("DELETE FROM matches")
            case "corrupt-match": try sql.execute("UPDATE matches SET descriptor=?", [.blob(Data("broken-match".utf8))])
            default: try sql.execute("UPDATE outbox SET packet=?", [.blob(Data("broken-packet".utf8))])
            }
            try sql.close()
            let reopened = try MatchStore(url: url)
            do { _ = try await reopened.commit(command); XCTFail("receipt cannot confirm \(damage)") } catch {}
            let diagnostics = try await reopened.diagnostics(matchID: "match")
            XCTAssertFalse(diagnostics.isEmpty)
            XCTAssertTrue(diagnostics.allSatisfy { $0.severity == .blocking })
            try await reopened.close()
        }
    }
    func testOriginalIntentReceiptRemainsValidAfterPermitAndLaterRevision() async throws {
        let url = path(); try await prepare(url)
        let store = try MatchStore(url: url); let (d, e) = try facts()
        let command = try request(descriptor: d, events: e)
        let receipt = try await store.commit(command)
        var recorder = LiveMatchRecorder(descriptor: d, events: e)
        let undo = try recorder.undoLastQuick(eventID: "undo", sourceDeviceID: "watch", now: t.addingTimeInterval(5))
        _ = try await store.commit(request("undo", generation: 2, descriptor: d, events: [undo]))
        let repeated = try await store.commit(command)
        XCTAssertEqual(repeated, receipt)
        let intentReceipt = try await store.commit(StoreCommit(commandID: "intent", expectedGeneration: 0, descriptor: descriptor(), events: [], packets: []))
        XCTAssertEqual(intentReceipt.generation, 1)
        let s = try await store.snapshot(matchID: "match")
        XCTAssertEqual(s.generation, 3); XCTAssertEqual(s.descriptor.startPermit, d.startPermit)
        XCTAssertEqual(try s.replay(now: t.addingTimeInterval(6)).score.forTeam, 0)
        try await store.close()
    }
}
