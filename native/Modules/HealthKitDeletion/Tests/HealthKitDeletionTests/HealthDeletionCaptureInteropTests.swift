import Foundation
import XCTest
import MatchCore
import MatchSession
@testable import HealthKitDeletion

private struct InteropClock: SessionClock {
    func now() -> Date { Date(timeIntervalSince1970:Double(deletionTime)) }
}
private struct InteropIdentity: DeviceIdentityProvider {
    func localDeviceID() async throws -> String { "watch-q28" }
}
private final class InteropIDs: SessionIDFactory, @unchecked Sendable {
    private let lock=NSLock()
    private var value=0
    func nextID() -> String { lock.withLock { value += 1;return "q28-\(value)" } }
}
/// Pure observations drive the reviewed Session/CaptureCoordinator; no SDK is imported.
private actor InteropWorkoutGateway: WorkoutGateway {
    func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
        let recovering=operation.action == .recover
        return try! WorkoutObservation(operationID:operation.id,binding:operation.binding,externalToken:operation.externalToken,
            observedAt:operation.requestedAt.addingTimeInterval(0.1),
            outcome:recovering ? .linked(workoutID:"10000000-0000-0000-0000-000000000001") : .running,
            window:CaptureWindow(start:nil,end:nil),failure:recovering ? .recoveryUnavailable : nil)
    }
    func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
}

final class HealthDeletionCaptureInteropTests: XCTestCase, @unchecked Sendable {
    private func realCaptureOperations() async throws -> [CaptureOperation] {
        let paths=try deletionPaths(),namespace="q28-interop"
        let repository=try SQLiteSessionRepository(rootDirectory:paths.business,databaseNamespace:namespace)
        let ids=InteropIDs(),clock=InteropClock(),gateway=InteropWorkoutGateway()
        let session=MatchSession(store:repository,deviceIdentity:InteropIdentity(),clock:clock,ids:ids,
            permits:DevelopmentStartPermitProvider(),workout:gateway,environment:.development(databaseNamespace:namespace))
        let start=try await session.prepareStart(starter:true)
        XCTAssertEqual(start,try SessionRequest.start(intent:XCTUnwrap(start.startIntent),starter:true))
        _=try await session.execute(start)
        try await eventually { try await repository.snapshotV2(matchID:start.matchID).captureOperations.contains { $0.operation.action == .start && $0.state == .settled } }
        let restored=MatchSession(store:repository,deviceIdentity:InteropIdentity(),clock:clock,ids:ids,
            permits:DevelopmentStartPermitProvider(),workout:gateway,environment:.development(databaseNamespace:namespace))
        _=try await restored.recover()
        try await eventually {
            let records=try await repository.snapshotV2(matchID:start.matchID).captureOperations
            return records.filter { $0.operation.action == .start && $0.state == .settled }.count == 2
                && records.contains { $0.operation.action == .recover && $0.state == .settled }
        }
        let records=try await repository.snapshotV2(matchID:start.matchID).captureOperations.map(\.operation)
        let starts=records.filter { $0.action == .start },recovery=try XCTUnwrap(records.first { $0.action == .recover })
        XCTAssertEqual(starts.first?.externalToken,start.captureOperationID)
        XCTAssertEqual(recovery.externalToken,start.captureOperationID)
        XCTAssertTrue(recovery.id.contains("/recover/operation"))
        XCTAssertEqual(starts.last?.externalToken,recovery.id+"/restart/start")
        // Session capture tasks retain the repository until their final empty scan, as in Core tests.
        // Do not close their shared connection while the background driver is retiring.
        return [try XCTUnwrap(starts.first),recovery,try XCTUnwrap(starts.last)]
    }
    private func deletionTarget(_ operation: CaptureOperation) throws -> WorkoutDeletionTargetV1 {
        try WorkoutDeletionTargetV1(workoutUUID:UUID(),matchID:operation.binding.matchID,
            recordingDeviceID:operation.binding.recordingDeviceID,segmentToken:operation.externalToken,
            expectedSourceBundleID:"test.football.watch")
    }
    private func assertRoundTrip(_ selection: WorkoutDeletionTargetV1) async throws {
        let r=try request(targets:[selection]),raw=try r.canonicalBytes(),paths=try deletionPaths()
        let ledger=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
        _=try await ledger.submit(r);let c=try confirmation(r);_=try await ledger.confirm(c,now:deletionTime);try await ledger.close()
        let reopened=try SQLiteHealthDeletionLedger(url:paths.control,businessDataDirectory:paths.business)
        let entry=try await reopened.entry(r.requestID),restored=try XCTUnwrap(entry.request.targets.first)
        XCTAssertEqual(try entry.request.canonicalBytes(),raw);XCTAssertEqual(entry.selectionDigest,try r.selectionDigest());XCTAssertEqual(entry.confirmation,c)
        XCTAssertEqual(Data(restored.matchID.utf8),Data(selection.matchID.utf8))
        XCTAssertEqual(Data(restored.recordingDeviceID.utf8),Data(selection.recordingDeviceID.utf8))
        XCTAssertEqual(Data(restored.segmentToken.utf8),Data(selection.segmentToken.utf8))
        let plan=try HealthDeletionPredicatePlan(request:entry.request,currentSourceBundleID:selection.expectedSourceBundleID)
        XCTAssertTrue(plan.matches(selection))
        let altered=try WorkoutDeletionTargetV1(workoutUUID:selection.workoutUUID,matchID:selection.matchID,
            recordingDeviceID:selection.recordingDeviceID,segmentToken:selection.segmentToken+"/other",expectedSourceBundleID:selection.expectedSourceBundleID)
        XCTAssertFalse(plan.matches(altered));try await reopened.close()
    }
    func testActualSessionStartRecoverRestartTokensRoundTripWithoutRewriting() async throws {
        let operations=try await realCaptureOperations()
        XCTAssertEqual(operations.map(\.action),[.start,.recover,.start])
        for operation in operations {
            XCTAssertTrue(operation.externalToken.contains("/"))
            try await assertRoundTrip(deletionTarget(operation))
        }
    }
    func testExistingCoreOpaqueMetadataRetainsOriginalUTF8() async throws {
        let binding=try CaptureBinding(matchID:" match/球历 e\u{301} #1 ",recordingDeviceID:" device/手表 A\n")
        let intent=StartIntent(id:"intent/raw #1",matchID:binding.matchID,recordingDeviceID:binding.recordingDeviceID,requestedAt:InteropClock().now())
        let start=try SessionRequest.start(intent:intent,starter:true),token=try XCTUnwrap(start.captureOperationID)
        let operation=try CaptureOperation(id:token,binding:binding,associatedCommandID:start.commandID,action:.start,requestedAt:start.requestedAt,externalToken:token)
        let selected=try deletionTarget(operation);try await assertRoundTrip(selected)
        let r=try request(targets:[selected]),raw=try r.canonicalBytes()
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
        let items=try XCTUnwrap(json["targets"] as? [[String:Any]])
        XCTAssertEqual(Data(try XCTUnwrap(items.first?["segmentToken"] as? String).utf8),Data(token.utf8))
        XCTAssertTrue(String(decoding:raw,as:UTF8.self).contains("intent/raw #1/capture/start"))
        let composed=try WorkoutDeletionTargetV1(workoutUUID:selected.workoutUUID,matchID:" match/球历 é #1 ",recordingDeviceID:selected.recordingDeviceID,segmentToken:selected.segmentToken,expectedSourceBundleID:selected.expectedSourceBundleID)
        XCTAssertNotEqual(Data(composed.matchID.utf8),Data(selected.matchID.utf8))
        XCTAssertNotEqual(try r.selectionDigest(),try request(r.requestID,targets:[composed]).selectionDigest())
        let plan=try HealthDeletionPredicatePlan(request:r,currentSourceBundleID:selected.expectedSourceBundleID)
        XCTAssertFalse(plan.matches(composed))
    }
    func testMetadataIsBoundedNonemptyNoNULRatherThanHTTPIdentifierGrammar() throws {
        for index in 0..<3 {
            for invalid in ["","has\0nul",String(repeating:"x",count:4097)] {
                var values=["match","watch","segment"];values[index]=invalid
                XCTAssertThrowsError(try WorkoutDeletionTargetV1(workoutUUID:UUID(),matchID:values[0],recordingDeviceID:values[1],segmentToken:values[2],expectedSourceBundleID:"test.football.watch"))
            }
            for valid in ["/"," original / 元数据 #1 \n",String(repeating:"é",count:2048)] {
                var values=["match","watch","segment"];values[index]=valid
                let item=try WorkoutDeletionTargetV1(workoutUUID:UUID(),matchID:values[0],recordingDeviceID:values[1],segmentToken:values[2],expectedSourceBundleID:"test.football.watch")
                XCTAssertEqual(Data([item.matchID,item.recordingDeviceID,item.segmentToken][index].utf8),Data(valid.utf8))
            }
        }
    }
}
