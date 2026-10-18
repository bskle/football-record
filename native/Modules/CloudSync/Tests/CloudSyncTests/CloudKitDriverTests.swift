import XCTest
import Foundation
@testable import CloudSync

actor SDKTransportFixture:CloudKitTransport {
    var identity:String
    var batch:CloudFetchBatch
    var saveResult:CloudSaveResult?
    var failure:CloudIssue?
    var cursors:[CloudCursor]=[]
    var deletes=0
    var pause=false
    var entered=false
    var resume:CheckedContinuation<Void,Never>?
    var source:URL?
    init(identity:String,batch:CloudFetchBatch) {self.identity=identity;self.batch=batch}
    func currentCloudSpaceID() throws->String {identity}
    func fetch(scope:CloudScope,cursor:CloudCursor,context:CloudKitIOContext) async throws->CloudFetchBatch {
        cursors.append(cursor);entered=true
        if pause {await withCheckedContinuation {resume=$0}}
        if let source {
            let bytes=Data([1,2,3]),ref=try CloudAssetReference(partID:"late-part",index:0,byteCount:3,digest:CloudCodec.hash(bytes))
            _=try context.staging.copyAsset(from:source,recordID:"late",reference:ref,operation:context.operation)
        }
        if let failure {throw CloudError(failure)};return batch
    }
    func save(_ upload:CloudUpload,package:CloudAssetPackage,context:CloudKitIOContext) throws->CloudSaveResult {if let failure {throw CloudError(failure)};return try saveResult ?? .complete(completeCloudSave(upload))}
    func deleteZone(scope:CloudScope) {deletes += 1}
    nonisolated func cancel(_ id:UUID) {}
    func setup(identity:String?=nil,result:CloudSaveResult?=nil,failure:CloudIssue?=nil,pause:Bool=false,source:URL?=nil) {if let identity {self.identity=identity};saveResult=result;self.failure=failure;self.pause=pause;self.source=source}
    func release() {resume?.resume();resume=nil}
    func hasEntered()->Bool {entered}
    func requests()->[CloudCursor] {cursors}
    func deletionCount()->Int {deletes}
}
final class CloudKitDriverTests:XCTestCase,@unchecked Sendable {
    struct Harness {let config:CloudKitDriverConfiguration;let staging:CloudOwnedStaging;let scope:CloudScope;let driver:CloudKitDriver;let transport:SDKTransportFixture;let upload:CloudUpload;let root:URL}
    func harness() throws->Harness {
        let config=try CloudKitDriverConfiguration(containerIdentifier:"iCloud.fixture",environment:.production),space="ck-space"
        let scope=try CloudScope(accountID:"account",cloudSpaceID:space,zoneID:config.zoneID(accountID:"account",cloudSpaceID:space),activationEpoch:1)
        let upload=try CloudUpload(scope:scope,record:CloudRecord(scope:scope,payload:.matchFacts(cloudFacts())))
        let batch=try CloudFetchBatch(scope:scope,batchID:"batch",records:[upload.record],expectedAppliedToken:Data([0,255]),nextToken:Data([2]),fetchGeneration:4,moreComing:true)
        let root=try tempCloudURL("024-driver").deletingLastPathComponent(),staging=try CloudOwnedStaging(rootURL:root.appendingPathComponent("assets"),controlURL:root.appendingPathComponent("control.sqlite"))
        try staging.admit(scope:scope,identityGeneration:0)
        let transport=SDKTransportFixture(identity:space,batch:batch),driver=CloudKitDriver(configuration:config,staging:staging,identityGeneration:0,transport:transport)
        return Harness(config:config,staging:staging,scope:scope,driver:driver,transport:transport,upload:upload,root:root)
    }
    func testFetchUsesExactOpaqueAppliedCursorAndReturnsCompleteBoundBatch() async throws {
        let h=try harness(),cursor=try CloudCursor(appliedToken:Data([0,255]),fetchGeneration:4)
        let batch=try await h.driver.fetch(scope:h.scope,cursor:cursor),requests=await h.transport.requests()
        XCTAssertEqual(requests,[cursor]);XCTAssertEqual(batch.expectedAppliedToken,cursor.appliedToken);XCTAssertEqual(batch.fetchGeneration,4);XCTAssertTrue(batch.moreComing);try h.staging.close()
    }
    func testSaveOnlyCompletesAfterConditionalOriginalReadback() async throws {
        let h=try harness()
        guard case .complete=try await h.driver.save(h.upload) else {return XCTFail()}
        await h.transport.setup(result:.complete(try completeCloudSave(h.upload,readBack:Data("corrupt".utf8))))
        do {_=try await h.driver.save(h.upload);XCTFail()}catch{}
        await h.transport.setup(result:.partial([]))
        guard case .partial=try await h.driver.save(h.upload) else {return XCTFail()};try h.staging.close()
    }
    func testQuotaAndAccountIdentityMismatchNeverLookLikeEmptyCloud() async throws {
        let h=try harness();await h.transport.setup(failure:.quotaExceeded)
        await expectCloudError(.quotaExceeded) {_=try await h.driver.save(h.upload)}
        await h.transport.setup(identity:"other")
        await expectCloudError(.accountChanged) {_=try await h.driver.fetch(scope:h.scope,cursor:CloudCursor(appliedToken:nil,fetchGeneration:0))}
        let requests=await h.transport.requests();XCTAssertTrue(requests.isEmpty);try h.staging.close()
    }
    func testLateSDKAssetCallbackAfterLocalEraseCannotCopyOrReturnBatch() async throws {
        let h=try harness(),source=h.root.appendingPathComponent("SDK-temp");try Data([1,2,3]).write(to:source)
        await h.transport.setup(pause:true,source:source)
        let task=Task {try await h.driver.fetch(scope:h.scope,cursor:CloudCursor(appliedToken:Data([0,255]),fetchGeneration:4))}
        let deadline=Date().addingTimeInterval(1)
        while !(await h.transport.hasEntered()),Date()<deadline {await Task.yield()}
        let entered=await h.transport.hasEntered();XCTAssertTrue(entered)
        _=try h.staging.erase(CloudStagingEraseRequest(requestID:"saga-staging",requestDigest:String(repeating:"a",count:64),scope:h.scope))
        await h.transport.release();do {_=try await task.value;XCTFail()}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:h.root.appendingPathComponent("assets").appendingPathComponent(h.scope.stableZoneKey).path));XCTAssertTrue(FileManager.default.fileExists(atPath:source.path));try h.staging.close()
    }
    func testPrivateZoneDeletionRequiresFixedOriginalScopeAndCurrentCloudIdentityEvenAfterLocalErase() async throws {
        let h=try harness(),deletion=CloudPrivateZoneDeletion(driver:h.driver,originalScope:h.scope)
        let wrong=try CloudScope(accountID:h.scope.accountID,cloudSpaceID:h.scope.cloudSpaceID,zoneID:h.scope.zoneID,activationEpoch:2)
        do {try await deletion.deletePrivateZone(scope:wrong);XCTFail()}catch{}
        _=try h.staging.erase(CloudStagingEraseRequest(requestID:"first-local",requestDigest:String(repeating:"b",count:64),scope:h.scope))
        try await deletion.deletePrivateZone(scope:h.scope)
        let count=await h.transport.deletionCount();XCTAssertEqual(count,1)
        await h.transport.setup(identity:"other");do {try await deletion.deletePrivateZone(scope:h.scope);XCTFail()}catch{}
        let finalCount=await h.transport.deletionCount();XCTAssertEqual(finalCount,1);try h.staging.close()
    }
    func testOpaqueArchiveEnvelopeIsScopedAndCannotInferOrder() throws {
        let config=try CloudKitDriverConfiguration(containerIdentifier:"iCloud.fixture",environment:.production),scope=try cloudScope(),raw=Data([0,255,0,3])
        let wrapped=try CloudChangeTokenEnvelope.wrap(raw,scope:scope,configuration:config)
        XCTAssertEqual(try CloudChangeTokenEnvelope.unwrap(wrapped,scope:scope,configuration:config),raw)
        let other=try CloudScope(accountID:"other",cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:1)
        XCTAssertThrowsError(try CloudChangeTokenEnvelope.unwrap(wrapped,scope:other,configuration:config))
        XCTAssertThrowsError(try CloudChangeTokenEnvelope.wrap(Data(repeating:0,count:512*1024+1),scope:scope,configuration:config))
    }
    func testDefaultExecutionDoesNotCallSDKOrProduceSaveProof() async throws {
        let h=try harness(),driver=CloudKitDriver(configuration:h.config,staging:h.staging,identityGeneration:0)
        do {_=try await driver.fetch(scope:h.scope,cursor:CloudCursor(appliedToken:nil,fetchGeneration:0));XCTFail()}catch{}
        do {_=try await driver.save(h.upload);XCTFail()}catch{}
        try h.staging.close()
    }
    func testConflictRetainsBothOriginalFactsInRealTransportLedger() async throws {
        let h=try harness(),remote=try CloudRecord(scope:h.scope,payload:.matchFacts(cloudFacts(match:"remote")))
        await h.transport.setup(result:.conflict(recordID:h.upload.record.recordID,remote:remote,changeTag:"remote-tag"))
        let ledger=try SQLiteCloudLedger(url:tempCloudURL("024-conflict"));try await ledger.enqueue(h.upload)
        let service=CloudSyncService(scope:h.scope,ledger:ledger,driver:h.driver),outcome=try await service.synchronize()
        XCTAssertEqual(outcome.issue,.conflict)
        let conflicts=try await ledger.conflicts(scope:h.scope),evidence=try await ledger.saveEvidence(scope:h.scope)
        XCTAssertEqual(conflicts.count,1);XCTAssertEqual(conflicts.first?.localBytes,h.upload.record.canonicalBytes);XCTAssertEqual(conflicts.first?.remoteBytes,remote.canonicalBytes);XCTAssertTrue(evidence.isEmpty)
        try await ledger.close();try h.staging.close()
    }
    func testCloudDeletionPermanentlyFencesOldWritersWhileKeepingLocalFiles() async throws {
        let h=try harness(),op=try h.staging.begin(scope:h.scope,identityGeneration:0),bytes=Data([4])
        let ref=try CloudAssetReference(partID:"cached",index:0,byteCount:1,digest:CloudCodec.hash(bytes)),owned=try h.staging.store(bytes,recordID:"cached-record",reference:ref,operation:op)
        try await CloudPrivateZoneDeletion(driver:h.driver,originalScope:h.scope).deletePrivateZone(scope:h.scope)
        XCTAssertEqual(try Data(contentsOf:owned),bytes);XCTAssertThrowsError(try h.staging.check(op))
        await expectCloudError(.accountChanged) {_=try await h.driver.save(h.upload)};try h.staging.close()
    }
    func testCancellationInvalidatesLateAssetCallbackWithoutErasingExistingScope() async throws {
        let h=try harness(),source=h.root.appendingPathComponent("SDK-temp");try Data([1,2,3]).write(to:source)
        await h.transport.setup(pause:true,source:source)
        let task=Task {try await h.driver.fetch(scope:h.scope,cursor:CloudCursor(appliedToken:Data([0,255]),fetchGeneration:4))}
        let deadline=Date().addingTimeInterval(1)
        while !(await h.transport.hasEntered()),Date()<deadline {await Task.yield()}
        let entered=await h.transport.hasEntered();XCTAssertTrue(entered);task.cancel();await h.transport.release()
        do {_=try await task.value;XCTFail()}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:h.root.appendingPathComponent("assets").appendingPathComponent(h.scope.stableZoneKey).path))
        let next=try h.staging.begin(scope:h.scope,identityGeneration:0);try h.staging.check(next);try h.staging.close()
    }

}
