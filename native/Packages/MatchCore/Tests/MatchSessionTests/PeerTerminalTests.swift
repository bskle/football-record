import Foundation
import XCTest
import MatchCore
import MatchStore
@testable import MatchSession

private actor PeerSnapshotLog {
    var values: [SessionSnapshot] = []
    func append(_ value: SessionSnapshot) { values.append(value) }
}

final class PeerTerminalTests: XCTestCase, @unchecked Sendable {
    func peer(_ clock: TestClock) throws -> PeerAuthorization {
        try PeerAuthorization(localDeviceID: "watch", remoteDeviceID: "phone", accountSubject: "account", pairingID: "pair", trustEpoch: "epoch", environment: .development(databaseNamespace: "test-development"), issuedAt: clock.now().addingTimeInterval(-1), expiresAt: clock.now().addingTimeInterval(3600))
    }

    func terminal(_ h: Harness, match: String) async throws -> MatchPacketV2 {
        let s = try await h.repo.snapshotV2(matchID: match)
        let event = try PostMatchEditor.terminateAbnormally(terminationID: "peer-terminal", descriptor: s.business.descriptor, events: s.business.events, sourceDeviceID: "phone", now: h.clock.now())
        return try MatchPacketV2(packetID: "peer-packet", idempotencyKey: "peer-key", sequence: 1, sourceDeviceID: "phone", targetDeviceID: "watch", descriptor: s.business.descriptor, events: s.business.events + [event], captureRevisions: s.captureRevisions)
    }

    func waitForIdle(_ session: MatchSession, match: String) async throws {
        try await eventually("capture driver must retire after this attempt") {
            !(await session.captureDrivers).contains(match)
        }
    }

    func requestBytes(_ request: StoreCommitV2) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    func assertOriginalToken(_ snapshot: StoreSnapshotV2, token: String) {
        XCTAssertEqual(snapshot.captureOperations.filter { $0.operation.action == .start }.count, 1)
        XCTAssertEqual(Set(snapshot.captureOperations.map(\.operation.externalToken)), [token])
        XCTAssertTrue(snapshot.business.events.contains { $0.type == .matchTerminated })
        XCTAssertEqual(snapshot.business.descriptor.backendLockState, .held)
    }

    func testRemoteTerminalWhileGatewaySuspended() async throws {
        let h = try Harness()
        await h.gateway.configure(suspend: true)
        defer { Task { await h.gateway.release() } }
        let started = try await h.session.execute(h.session.prepareStart(starter: true))
        let match = started.receipt.matchID
        try await eventually("start must be suspended outside the match queue") { await h.gateway.performed.count == 1 }
        h.clock.advance(10)
        let packet = try await terminal(h, match: match)
        let received = try await h.session.receiveSyncPacket(packet.canonicalBytes(), peer: peer(h.clock), matchID: match)
        XCTAssertEqual(received.matchID, match)
        let saved = try await h.repo.snapshotV2(matchID: match)
        let start = try XCTUnwrap(saved.captureOperations.first { $0.operation.action == .start })
        let finish = try XCTUnwrap(saved.captureOperations.first { $0.operation.action == .finish })
        XCTAssertEqual(finish.operation.externalToken, start.operation.externalToken)
        XCTAssertEqual(finish.state, .pending)
        let waitingCalls = await h.gateway.performed
        XCTAssertEqual(waitingCalls.map(\.action), [.start], "receipt must return before the suspended SDK action")
        await h.gateway.release()
        try await h.waitCaptureSettled(match)
        try await waitForIdle(h.session, match: match)
        let final = try await h.session.snapshot(matchID: match)
        XCTAssertEqual(final.replay.state, .incomplete)
        assertOriginalToken(final.store, token: start.operation.externalToken)
    }

    func testRemoteTerminalWhileResumeSuspendedPersistsOriginalTokenFinish() async throws {
        let h = try Harness()
        defer { Task { await h.gateway.release() } }
        let request = try await h.session.prepareStart(starter: true)
        _ = try await h.session.execute(request)
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        h.clock.advance(2)
        _ = try await h.session.execute(h.session.prepare(.pause, matchID: request.matchID))
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        await h.gateway.configure(suspend: true)
        h.clock.advance(2)
        _ = try await h.session.execute(h.session.prepare(.resume, matchID: request.matchID))
        try await eventually("resume must reach the suspended gateway") { await h.gateway.performed.count == 3 }
        h.clock.advance(2)
        let packet = try await terminal(h, match: request.matchID)
        _ = try await h.session.receiveSyncPacket(packet.canonicalBytes(), peer: peer(h.clock), matchID: request.matchID)
        let before = try await h.repo.snapshotV2(matchID: request.matchID)
        let finish = try XCTUnwrap(before.captureOperations.first { $0.operation.action == .finish })
        XCTAssertEqual(finish.operation.externalToken, request.captureOperationID)
        XCTAssertEqual(finish.state, .pending)
        let waitingCalls = await h.gateway.performed
        XCTAssertEqual(waitingCalls.map(\.action), [.start, .pause, .resume])
        await h.gateway.release()
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let calls = await h.gateway.performed
        XCTAssertEqual(calls.map(\.action), [.start, .pause, .resume, .finish])
        let final = try await h.repo.snapshotV2(matchID: request.matchID)
        assertOriginalToken(final, token: try XCTUnwrap(request.captureOperationID))
    }

    func testRemoteTerminalWhileReconcileSuspendedDoesNotCreateRecoveryStart() async throws {
        let h = try Harness()
        await h.gateway.configure(outcome: .unknown)
        defer { Task { await h.gateway.releaseReconciliation() } }
        let request = try await h.session.prepareStart(starter: true)
        _ = try await h.session.execute(request)
        await h.repo.waitForObservation()
        try await waitForIdle(h.session, match: request.matchID)
        await h.gateway.configure(outcome: .running)
        await h.gateway.suspendReconciliation()
        _ = try await h.session.recover()
        try await eventually("original uncertain start must enter reconciliation") { await h.gateway.reconciled.count == 1 }
        h.clock.advance(10)
        let packet = try await terminal(h, match: request.matchID)
        _ = try await h.session.receiveSyncPacket(packet.canonicalBytes(), peer: peer(h.clock), matchID: request.matchID)
        let before = try await h.repo.snapshotV2(matchID: request.matchID)
        let finish = try XCTUnwrap(before.captureOperations.first { $0.operation.action == .finish })
        XCTAssertEqual(finish.operation.externalToken, request.captureOperationID)
        XCTAssertEqual(finish.state, .pending)
        await h.gateway.releaseReconciliation()
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let calls = await h.gateway.performed
        XCTAssertEqual(calls.map(\.action), [.start, .finish])
        let final = try await h.repo.snapshotV2(matchID: request.matchID)
        assertOriginalToken(final, token: try XCTUnwrap(request.captureOperationID))
        XCTAssertFalse(final.captureOperations.contains { $0.operation.action == .recover })
    }

    func testDuplicatePacketPublishesAfterReceiveCommitLosesResponse() async throws {
        try await exerciseInboundFault("response")
    }

    func testDuplicatePacketPublishesAfterPostCommitReloadFails() async throws {
        try await exerciseInboundFault("reload")
    }

    private func exerciseInboundFault(_ mode: String) async throws {
        let h = try Harness()
        await h.gateway.configure(suspend: true)
        defer { Task { await h.gateway.release() } }
        let request = try await h.session.prepareStart(starter: true)
        _ = try await h.session.execute(request)
        try await eventually("start must reach the gateway") { await h.gateway.performed.count == 1 }
        let observed = PeerSnapshotLog()
        let stream = await h.session.updates(matchID: request.matchID)
        let collector = Task { for await value in stream { await observed.append(value) } }
        defer { collector.cancel() }
        try await eventually("subscription must deliver its persisted initial snapshot") { !(await observed.values).isEmpty }
        h.clock.advance(10)
        let packet = try await terminal(h, match: request.matchID)
        let bytes = try packet.canonicalBytes()
        await h.repo.failNextInbound(mode)
        do {
            _ = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
            XCTFail("inbound response/reload fault must escape")
        } catch let error as StoreError { XCTAssertEqual(error, .responseLost) }
        let recordedReceipt = await h.repo.lastInboundReceipt
        let committed = try XCTUnwrap(recordedReceipt)
        let persisted = try await h.repo.snapshotV2(matchID: request.matchID)
        XCTAssertTrue(persisted.business.events.contains { $0.type == .matchTerminated })
        let beforeDuplicate = await observed.values
        XCTAssertFalse(beforeDuplicate.contains { $0.store.business.events.contains { $0.type == .matchTerminated } })
        h.clock.advance(20)
        let repeated = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
        XCTAssertEqual(repeated, committed, "duplicate returns the first durable receipt")
        try await eventually("duplicate must republish the committed terminal state") {
            (await observed.values).contains { $0.store.business.events.contains { $0.type == .matchTerminated } }
        }
        let waiting = try await h.repo.snapshotV2(matchID: request.matchID)
        XCTAssertEqual(waiting.captureOperations.filter { $0.operation.action == .finish }.count, 1)
        await h.gateway.release()
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let final = try await h.repo.snapshotV2(matchID: request.matchID)
        assertOriginalToken(final, token: try XCTUnwrap(request.captureOperationID))
    }

    func testCleanupBeforeCommitFailureRetriesIdenticalRequestBytes() async throws {
        try await exerciseCleanupFault("before")
    }

    func testCleanupResponseLostKeepsOriginalCommittedRequestBytes() async throws {
        try await exerciseCleanupFault("after")
    }

    private func exerciseCleanupFault(_ mode: String) async throws {
        let h = try Harness()
        await h.gateway.configure(suspend: true)
        defer { Task { await h.gateway.release() } }
        let request = try await h.session.prepareStart(starter: true)
        _ = try await h.session.execute(request)
        try await eventually("start must remain suspended while cleanup is saved") { await h.gateway.performed.count == 1 }
        h.clock.advance(10)
        let packet = try await terminal(h, match: request.matchID)
        let bytes = try packet.canonicalBytes()
        await h.repo.failNextTerminalCleanup(mode)
        do {
            _ = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
            XCTFail("cleanup COMMIT fault must escape")
        } catch let error as StoreError {
            XCTAssertEqual(error, mode == "before" ? .injectedFailure : .responseLost)
        }
        let attemptsBefore = await h.repo.cleanupRequests
        let original = try XCTUnwrap(attemptsBefore.first)
        XCTAssertEqual(attemptsBefore.count, 1)
        let recordedReceipt = await h.repo.lastInboundReceipt
        let firstReceipt = try XCTUnwrap(recordedReceipt)
        let savedBefore = try await h.repo.committedCommandV2(commandID: original.commandID)
        XCTAssertEqual(savedBefore != nil, mode == "after")
        h.clock.advance(50)
        let duplicate = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
        XCTAssertEqual(duplicate, firstReceipt)
        let attempts = await h.repo.cleanupRequests
        XCTAssertEqual(attempts.count, mode == "before" ? 2 : 1)
        for attempted in attempts { XCTAssertEqual(try requestBytes(attempted), try requestBytes(original)) }
        let recordedCommand = try await h.repo.committedCommandV2(commandID: original.commandID)
        let saved = try XCTUnwrap(recordedCommand)
        XCTAssertEqual(saved.request.commandID, original.commandID)
        XCTAssertEqual(try requestBytes(saved.request), try requestBytes(original))
        let waiting = try await h.repo.snapshotV2(matchID: request.matchID)
        XCTAssertEqual(waiting.captureOperations.filter { $0.operation.action == .finish }.count, 1)
        await h.gateway.release()
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let final = try await h.repo.snapshotV2(matchID: request.matchID)
        assertOriginalToken(final, token: try XCTUnwrap(request.captureOperationID))
    }

    func testDuplicatePacketRetriesFailedFinishOnlyOnOriginalToken() async throws {
        let h = try Harness()
        let request = try await h.session.prepareStart(starter: true)
        _ = try await h.session.execute(request)
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        await h.gateway.script(.finish, [.running])
        await h.gateway.configure(failure: .captureFailed)
        h.clock.advance(10)
        let packet = try await terminal(h, match: request.matchID)
        let bytes = try packet.canonicalBytes()
        let first = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let failedSnapshot = try await h.repo.snapshotV2(matchID: request.matchID)
        let failed = try XCTUnwrap(failedSnapshot.captureOperations.first { $0.operation.action == .finish && $0.state == .failed })
        await h.gateway.configure()
        h.clock.advance(20)
        let repeated = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
        XCTAssertEqual(repeated, first)
        try await h.waitCaptureSettled(request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let final = try await h.repo.snapshotV2(matchID: request.matchID)
        let finishes = final.captureOperations.filter { $0.operation.action == .finish }
        XCTAssertEqual(finishes.count, 2)
        XCTAssertEqual(finishes.last?.operation.associatedCommandID, failed.operation.id + "/terminal-retry")
        assertOriginalToken(final, token: try XCTUnwrap(request.captureOperationID))
        let calls = await h.gateway.performed
        XCTAssertEqual(calls.map(\.action), [.start, .finish, .finish])
        _ = try await h.session.receiveSyncPacket(bytes, peer: peer(h.clock), matchID: request.matchID)
        try await waitForIdle(h.session, match: request.matchID)
        let afterSavedReplay = try await h.repo.snapshotV2(matchID: request.matchID)
        XCTAssertEqual(afterSavedReplay.captureOperations.filter { $0.operation.action == .finish }.count, 2)
    }

    func testRemoteRecorderTerminalIsObservedWithoutLocalCaptureOrCandidate() async throws {
        let h = try Harness()
        let intent = StartIntent(id: "remote-intent", matchID: "remote-match", recordingDeviceID: "phone", requestedAt: h.clock.now())
        let descriptor = MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
        var recorder = LiveMatchRecorder(descriptor: descriptor)
        try recorder.start(eventID: "remote-start", sourceDeviceID: "phone", now: h.clock.now())
        h.clock.advance(10)
        let ended = try PostMatchEditor.terminateAbnormally(terminationID: "remote-terminal", descriptor: descriptor, events: recorder.events, sourceDeviceID: "phone", now: h.clock.now())
        let packet = try MatchPacketV2(packetID: "remote-packet", idempotencyKey: "remote-key", sequence: 1, sourceDeviceID: "phone", targetDeviceID: "watch", descriptor: descriptor, events: recorder.events + [ended], captureRevisions: [])
        let first = try await h.session.receiveSyncPacket(packet.canonicalBytes(), peer: peer(h.clock), matchID: intent.matchID)
        let repeated = try await h.session.receiveSyncPacket(packet.canonicalBytes(), peer: peer(h.clock), matchID: intent.matchID)
        XCTAssertEqual(repeated, first)
        guard case .none = try await h.session.recover() else { return XCTFail("remote terminal must never become a writable candidate") }
        let snapshot = try await h.session.snapshot(matchID: intent.matchID)
        XCTAssertEqual(snapshot.replay.state, .incomplete)
        XCTAssertEqual(snapshot.store.business.descriptor.recordingDeviceID, "phone")
        XCTAssertTrue(snapshot.store.captureOperations.isEmpty)
        let performed = await h.gateway.performed
        let reconciled = await h.gateway.reconciled
        XCTAssertTrue(performed.isEmpty)
        XCTAssertTrue(reconciled.isEmpty)
    }

    func testCoordinatorUsesSameFacadeIdentity() async throws {
        let h = try Harness()
        let repository = await h.repo.syncRepositoryIdentity()
        let coordinator = await h.session.syncRepositoryIdentity()
        XCTAssertEqual(repository, coordinator)
        let other = try SQLiteSessionRepository(rootDirectory: h.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString), databaseNamespace: "test-development")
        let otherID = await other.syncRepositoryIdentity()
        XCTAssertNotEqual(otherID, repository)
        try await other.close()
    }
}
