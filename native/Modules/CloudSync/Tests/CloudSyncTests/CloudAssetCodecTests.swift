import XCTest
import Foundation
import MatchCore
@testable import CloudSync

final class CloudAssetCodecTests:XCTestCase {
    func testManifestPartsReconstructExactOriginalCanonicalBytes() throws {
        let upload=try cloudUpload(),p=try CloudAssetCodec.package(upload,partByteLimit:128)
        XCTAssertGreaterThan(p.parts.count,1)
        XCTAssertEqual(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:p.manifestBytes,parts:p.parts.map(\.bytes)),upload.record)
        XCTAssertEqual(p.manifest.parts,p.parts.map(\.reference))
        XCTAssertEqual(p.parts.map(\.bytes).reduce(Data(),+),upload.record.canonicalBytes)
    }
    func testMissingReorderedCrossedOrCorruptPartsAndUnknownManifestReject() throws {
        let upload=try cloudUpload(),p=try CloudAssetCodec.package(upload,partByteLimit:128),parts=p.parts.map(\.bytes)
        XCTAssertThrowsError(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:p.manifestBytes,parts:Array(parts.dropLast())))
        XCTAssertThrowsError(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:p.manifestBytes,parts:Array(parts.reversed())))
        var bad=parts;bad[0]=Data(repeating:1,count:bad[0].count)
        XCTAssertThrowsError(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:p.manifestBytes,parts:bad))
        var object=try JSONSerialization.jsonObject(with:p.manifestBytes) as! [String:Any];object["extra"]=true
        XCTAssertThrowsError(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]),parts:parts))
        XCTAssertThrowsError(try CloudAssetCodec.package(upload,partByteLimit:0))
    }
    func testNearEightMiBUsesBoundedPartsAndRoundTrips() throws {
        let facts=try cloudFacts(),scope=try cloudScope()
        let goal=GoalPayload(scoreImpact:.forTeam,scoringTeamSnapshot:"team",note:String(repeating:"x",count:8*1024*1024-6000))
        let event=MatchEvent(eventID:"large",matchID:"match",sequence:3,occurredAt:cloudTime,matchElapsed:0,type:.scoreEvent,sourceDeviceID:"watch",createdAt:cloudTime,updatedAt:cloudTime,goal:goal)
        let full=try CloudMatchFacts(startIntent:facts.startIntent,starter:true,events:facts.events+[event],captureRevisions:[]),record=try CloudRecord(scope:scope,payload:.matchFacts(full)),upload=try CloudUpload(scope:scope,record:record)
        let p=try CloudAssetCodec.package(upload)
        XCTAssertGreaterThan(record.canonicalBytes.count,8*1024*1024-10000);XCTAssertLessThanOrEqual(p.parts.count,64)
        XCTAssertTrue(p.parts.allSatisfy {$0.bytes.count<=256*1024})
        XCTAssertEqual(try CloudAssetCodec.record(scope:scope,manifestBytes:p.manifestBytes,parts:p.parts.map(\.bytes)),record)
    }
    func testReadbackRequiresAllConditionalTagsAndOriginalBytes() throws {
        let upload=try cloudUpload();try CloudAssetCodec.validate(completeCloudSave(upload),upload:upload)
        XCTAssertThrowsError(try CloudAssetCodec.validate(completeCloudSave(upload,condition:.unconditional),upload:upload))
        XCTAssertThrowsError(try CloudAssetCodec.validate(completeCloudSave(upload,readBack:Data("wrong".utf8)),upload:upload))
    }
    func testManifestMetadataCannotUseCanonicallyEquivalentDifferentUTF8() throws {
        let upload=try cloudUpload(match:"é"),p=try CloudAssetCodec.package(upload)
        var object=try JSONSerialization.jsonObject(with:p.manifestBytes) as! [String:Any]
        object["matchID"]="e\u{301}"
        let changed=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertNotEqual(changed,p.manifestBytes)
        XCTAssertThrowsError(try CloudAssetCodec.record(scope:upload.scope,manifestBytes:changed,parts:p.parts.map(\.bytes)))
    }

}
