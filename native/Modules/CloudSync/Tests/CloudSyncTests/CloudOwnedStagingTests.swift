import XCTest
import Foundation
@testable import CloudSync

final class CloudOwnedStagingTests:XCTestCase,@unchecked Sendable {
    func locations() throws->(root:URL,control:URL,source:URL) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("024-staging-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return (directory.appendingPathComponent("assets"),directory.appendingPathComponent("control.sqlite"),directory.appendingPathComponent("SDK-temp"))
    }
    func ref(_ bytes:Data,id:String="part/原值") throws->CloudAssetReference {try CloudAssetReference(partID:id,index:0,byteCount:bytes.count,digest:CloudCodec.hash(bytes))}
    func testCallbackCopiesAndHashesBeforeSDKFileExpires() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data("original".utf8)
        try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0);try bytes.write(to:l.source)
        let owned=try s.copyAsset(from:l.source,recordID:"record/原值",reference:ref(bytes),operation:op)
        try FileManager.default.removeItem(at:l.source)
        XCTAssertEqual(try Data(contentsOf:owned),bytes);XCTAssertTrue(owned.path.hasPrefix(l.root.path+"/"));try s.close()
    }
    func testCancellationAndIdentityChangeCannotCreateOwnedFiles() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data([1,2,3])
        try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0);try bytes.write(to:l.source);s.cancel(op)
        XCTAssertThrowsError(try s.copyAsset(from:l.source,recordID:"record",reference:ref(bytes),operation:op))
        let next=try s.begin(scope:scope,identityGeneration:0);try s.advanceIdentityFence(to:1)
        XCTAssertThrowsError(try s.copyAsset(from:l.source,recordID:"record",reference:ref(bytes),operation:next));try s.close()
        let reopened=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control)
        XCTAssertThrowsError(try reopened.admit(scope:scope,identityGeneration:0));try reopened.close()
    }
    func testPermanentEraseReplaysOriginalScopeAndRejectsOldEpochAfterReopen() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data([1,2,3])
        try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0)
        let owned=try s.store(bytes,recordID:"record",reference:ref(bytes),operation:op)
        let request=try CloudStagingEraseRequest(requestID:"saga-file",requestDigest:String(repeating:"a",count:64),scope:scope),receipt=try s.erase(request)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path));XCTAssertEqual(try s.erase(request),receipt)
        XCTAssertThrowsError(try s.store(bytes,recordID:"record",reference:ref(bytes),operation:op));try s.close()
        let reopened=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control)
        XCTAssertEqual(try reopened.erase(request),receipt)
        XCTAssertThrowsError(try reopened.admit(scope:cloudScope(epoch:2),identityGeneration:1))
        XCTAssertThrowsError(try reopened.erase(CloudStagingEraseRequest(requestID:"saga-file",requestDigest:request.requestDigest,scope:cloudScope(epoch:2))))
        try reopened.close()
    }
    func testCopyInFlightAndEraseShareTheActualFilesystemGate() async throws {
        let l=try locations(),entered=expectation(description:"copy gate"),release=DispatchSemaphore(value:0)
        let s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control,beforeCopy:{entered.fulfill();_=release.wait(timeout:.now()+5)}),scope=try cloudScope(),bytes=Data([1,2,3])
        try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0);try bytes.write(to:l.source)
        let otherHandle=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control)
        let reference=try ref(bytes),copy=Task.detached {try s.copyAsset(from:l.source,recordID:"record",reference:reference,operation:op)}
        await fulfillment(of:[entered],timeout:2)
        let request=try CloudStagingEraseRequest(requestID:"erase-race",requestDigest:String(repeating:"b",count:64),scope:scope),erase=Task.detached {try otherHandle.erase(request)}
        release.signal();let owned=try await copy.value;_=try await erase.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path));XCTAssertThrowsError(try s.copyAsset(from:l.source,recordID:"record",reference:reference,operation:op));try s.close()
    }
    func testFaultAfterDurableFenceOrBeforeReceiptReopensForSameScopeRetry() throws {
        for fault in [CloudStagingFault.afterFence,.beforeReceipt,.afterReceiptResponseLost] {
            let l=try locations(),scope=try cloudScope(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control,fault:fault),bytes=Data([3])
            try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0)
            _=try s.store(bytes,recordID:"record",reference:ref(bytes),operation:op)
            let request=try CloudStagingEraseRequest(requestID:"retry",requestDigest:String(repeating:"a",count:64),scope:scope)
            XCTAssertThrowsError(try s.erase(request));try s.close()
            let reopened=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control)
            XCTAssertThrowsError(try reopened.admit(scope:scope,identityGeneration:1));_=try reopened.erase(request)
            XCTAssertFalse(FileManager.default.fileExists(atPath:l.root.appendingPathComponent(scope.stableZoneKey).path));try reopened.close()
        }
    }
    func testBadHashOversizeAndSymlinkCannotInstallOrEscapeOwnedRoot() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data([1,2])
        try s.admit(scope:scope,identityGeneration:0);let op=try s.begin(scope:scope,identityGeneration:0);try Data([1,2,3]).write(to:l.source)
        XCTAssertThrowsError(try s.copyAsset(from:l.source,recordID:"record",reference:ref(bytes),operation:op))
        try s.close()
        let other=try locations(),s2=try CloudOwnedStaging(rootURL:other.root,controlURL:other.control)
        try s2.admit(scope:scope,identityGeneration:0);let op2=try s2.begin(scope:scope,identityGeneration:0)
        let outside=other.source.deletingLastPathComponent().appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:other.root.appendingPathComponent(scope.stableZoneKey),withDestinationURL:outside)
        XCTAssertThrowsError(try s2.store(bytes,recordID:"../record",reference:ref(bytes),operation:op2));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty);try s2.close()
    }
    func testFutureVersionPreservesDatabaseAndControlMustBeOutsideAssets() throws {
        let l=try locations(),sql=try CloudSQL(url:l.control);try sql.execute("PRAGMA user_version=99");try sql.close()
        let before=try Data(contentsOf:l.control)
        XCTAssertThrowsError(try CloudOwnedStaging(rootURL:l.root,controlURL:l.control));XCTAssertEqual(try Data(contentsOf:l.control),before)
        XCTAssertThrowsError(try CloudOwnedStaging(rootURL:l.root,controlURL:l.root.appendingPathComponent("control.sqlite")))
    }
    func testErasingOneStableZonePreservesOtherAccountFilesAndAdmission() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data([9])
        try s.admit(scope:scope,identityGeneration:0);let old=try s.begin(scope:scope,identityGeneration:0),original=try s.store(bytes,recordID:"record",reference:ref(bytes),operation:old)
        let other=try CloudScope(accountID:"other",cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:1)
        try s.admit(scope:other,identityGeneration:1);let current=try s.begin(scope:other,identityGeneration:1),retained=try s.store(bytes,recordID:"record",reference:ref(bytes),operation:current)
        _=try s.erase(CloudStagingEraseRequest(requestID:"old-saga",requestDigest:String(repeating:"a",count:64),scope:scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path));XCTAssertEqual(try Data(contentsOf:retained),bytes);try s.check(current);try s.close()
    }
    func testOldOperationCannotBeReusedAfterCloseEvenWithExplicitSameScopeAdmission() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control),scope=try cloudScope(),bytes=Data([7])
        try s.admit(scope:scope,identityGeneration:0);let old=try s.begin(scope:scope,identityGeneration:0);try s.close()
        let reopened=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control);try reopened.admit(scope:scope,identityGeneration:0)
        XCTAssertThrowsError(try reopened.store(bytes,recordID:"record",reference:ref(bytes),operation:old));try reopened.close()
    }

    func testSameAssetRootCannotAcquireAnotherIndependentControlOwner() throws {
        let l=try locations(),s=try CloudOwnedStaging(rootURL:l.root,controlURL:l.control)
        XCTAssertThrowsError(try CloudOwnedStaging(rootURL:l.root,controlURL:l.control.appendingPathExtension("other")))
        try s.close()
        XCTAssertThrowsError(try CloudOwnedStaging(rootURL:l.root.appendingPathExtension("changed"),controlURL:l.control))
    }

}
