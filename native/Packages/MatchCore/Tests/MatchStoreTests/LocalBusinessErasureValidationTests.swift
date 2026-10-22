import Foundation
import XCTest
import MatchCore
import SQLite3
@testable import MatchStore
@testable import MatchSession

final class LocalBusinessErasureValidationTests: XCTestCase, @unchecked Sendable {
    let h = LifecycleStateTests()
    let tables = ["matches","events","commands","outbox","inbound","diagnostics","completion","capture_identities","capture_revisions","capture_operations","capture_operation_history","business_outbox","commands_v2","completion_confirmations","completion_v2","sync_delivery_v3","sync_fragments_v3","sync_context_v3","sync_registry_v3","sync_routes_v3","sync_sequences_v3","sync_inbox_v3","sync_acknowledgements_v3","sync_ack_controls_v3","sync_receive_progress_v3","cloud_applied_batches_v4","cloud_checkpoints_v4","cloud_records_v4","cloud_history_v4","cloud_cursors_v4","cloud_deletions_v4","peer_contexts_v4","peer_inbox_v4","peer_grants_v4"]
    func deleted(_ c: LifecycleStateTests.Context, local: ClientDeletionChoiceV4 = .delete, zone: String = "matches") async throws -> DeletionSagaV4 {
        let s = try h.store(c), original = try h.saga(c)
        let saga = try DeletionSagaV4(intent: original.intent, accountID: original.accountID, activationEpoch: original.activationEpoch, recoveryCapability: original.recoveryCapability, cloudChoice: .delete, localChoice: local, healthChoice: .delete, healthConfirmed: true, originalScope: CloudScopeV1(accountID: c.binding.accountID, cloudSpaceID: c.binding.cloudSpaceID, zoneID: zone, activationEpoch: 1))
        try await s.bindAccountV4(c.binding)
        try await s.createDeletionSagaV4(saga)
        let receipt = try h.receipt(c, requestID: "delete", digest: saga.intent.digest, operation: .deleteAccount, result: .deleted, extra: ["deletion": ["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        let backend = try await s.acceptDeletionV4(requestID: "delete", receipt: receipt, expectedRevision: 0)
        let result = local == .delete ? try await s.eraseLocalBusinessV4(requestID: "delete", expectedRevision: backend.revision) : backend
        try await s.close()
        return result
    }
    func witness(_ s: MatchStore, _ saga: DeletionSagaV4) async throws -> LocalBusinessErasureWitnessV4 {
        try await s.validateLocalBusinessErasedV4(requestID: saga.intent.requestID, requestDigest: saga.intent.digest, scope: XCTUnwrap(saga.originalScope))
    }
    func blocked(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("must reject without erasing or changing original controls", file: file, line: line) } catch {}
    }
    func sql(_ url: URL, _ action: (SQLite) throws -> Void) throws {
        let db = try SQLite(url: url, fault: nil); defer { try? db.close() }; try action(db)
    }
    func controls(_ url: URL) throws -> [[String]] {
        let db = try SQLite(url: url, fault: nil); defer { try? db.close() }
        return try ["account_binding_v4","control_intents_v4","authority_results_v4","authority_projection_v4","lifecycle_steps_v4"].flatMap { table -> [[String]] in
            let columns = try db.rows("PRAGMA table_info("+table+")").map { $0[1].string! }
            return try db.rows("SELECT "+columns.map { "quote("+$0+")" }.joined(separator: ",")+" FROM "+table+" ORDER BY rowid").map { [table]+$0.map { $0.string! } }
        }
    }
    func editSaga(_ c: LifecycleStateTests.Context, _ change: (inout [String:Any]) throws -> Void) throws {
        try sql(c.url) { db in
            let bytes = try XCTUnwrap(db.scalar("SELECT payload FROM lifecycle_steps_v4 WHERE id='deletion:delete'").data)
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any]); try change(&value)
            let edited = try JSONDecoder().decode(DeletionSagaV4.self, from: JSONSerialization.data(withJSONObject: value))
            let raw = try Canonical.data(edited)
            try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='deletion:delete'", [.blob(raw),.text(Canonical.hash(raw))])
        }
    }
    func testRealEraseReadbackRepeatsAndReopensWithoutChangingOriginalControls() async throws {
        let c = try h.context(), saga = try await deleted(c), before = try controls(c.url)
        let s = try h.store(c), first = try await witness(s,saga), second = try await witness(s,saga)
        XCTAssertEqual(first.requestID, saga.intent.requestID); XCTAssertEqual(first.requestDigest,saga.intent.digest)
        XCTAssertEqual(first.originalScope,saga.originalScope); XCTAssertEqual(first.currentSagaRevision,saga.revision)
        XCTAssertEqual(first.backendReceiptDigest,AuthorityWire.hash(try XCTUnwrap(saga.backendReceipt)))
        XCTAssertEqual(second.currentSagaRevision,first.currentSagaRevision); try await s.close()
        let r = try h.store(c); _ = try await witness(r,saga); try await r.close()
        XCTAssertEqual(try controls(c.url),before)
    }
    func testSameInodeRestoredRealBusinessBlocksHistoricalCompletedSaga() async throws {
        let c = try h.context(), seed = try h.store(c)
        try await seed.bindAccountV4(c.binding)
        _ = try await seed.commit(StoreCommit(commandID:"actual-original",expectedGeneration:0,descriptor:h.h.descriptor(),events:[],packets:[]))
        try await seed.close()
        var original: [SQLValue] = []
        try sql(c.url) { original = try XCTUnwrap($0.rows("SELECT * FROM matches").first) }
        let saga = try await deleted(c), inode = try FileManager.default.attributesOfItem(atPath:c.url.path)[.systemFileNumber] as? NSNumber
        try sql(c.url) { try $0.execute("INSERT INTO matches VALUES (?,?,?,?)",original) }
        let before = try controls(c.url), s = try h.store(c)
        await blocked { _ = try await self.witness(s,saga) }; try await s.close()
        XCTAssertEqual(try controls(c.url),before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:c.url.path)[.systemFileNumber] as? NSNumber,inode)
        try sql(c.url) { XCTAssertEqual(try $0.scalar("SELECT count(*) FROM matches").number,1) }
    }
    func testEveryCoveredTableIncludingMalformedPayloadBlocksAndRemainsUntouched() async throws {
        XCTAssertEqual(tables.count,34)
        let c = try h.context(), saga = try await deleted(c), s = try h.store(c)
        for table in tables {
            try sql(c.url) { db in
                let info = try db.rows("PRAGMA table_info("+table+")")
                let values: [SQLValue] = info.map { row in
                    switch row[2].string! { case "INTEGER": .integer(1); case "BLOB": .blob(Data([0xff,0])); default: .text("residual") }
                }
                try db.execute("INSERT INTO "+table+" VALUES ("+Array(repeating:"?",count:values.count).joined(separator:",")+")",values)
            }
            await blocked { _ = try await self.witness(s,saga) }
            try sql(c.url) { db in XCTAssertEqual(try db.scalar("SELECT count(*) FROM "+table).number,1,table); try db.execute("DELETE FROM "+table) }
        }
        _ = try await witness(s,saga); try await s.close()
    }
    func testNormalIntentAndMigrationCheckpointResidualsBlockWithoutDecoding() async throws {
        let c = try h.context(), saga = try await deleted(c), s = try h.store(c)
        for key in ["normal-intent:old", "migration-checkpoint:old", "NORMAL-INTENT:case-preserved"] {
            try sql(c.url) { try $0.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)",[.text(key),.blob(Data([0xff])),.text("bad")]) }
            await blocked { _ = try await self.witness(s,saga) }
            try sql(c.url) { db in XCTAssertEqual(try db.scalar("SELECT count(*) FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]).number,1);try db.execute("DELETE FROM lifecycle_steps_v4 WHERE id=?",[.text(key)]) }
        }
        _ = try await witness(s,saga); try await s.close()
    }
    func testOriginalParentDigestRawScopeAndProgressAreRequired() async throws {
        let c = try h.context(), saga = try await deleted(c), s = try h.store(c), scope = try XCTUnwrap(saga.originalScope)
        await blocked { _ = try await s.validateLocalBusinessErasedV4(requestID:"other",requestDigest:saga.intent.digest,scope:scope) }
        await blocked { _ = try await s.validateLocalBusinessErasedV4(requestID:"delete",requestDigest:String(repeating:"0",count:64),scope:scope) }
        for wrong in [try CloudScopeV1(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:"other",activationEpoch:1),try CloudScopeV1(accountID:scope.accountID,cloudSpaceID:scope.cloudSpaceID,zoneID:scope.zoneID,activationEpoch:2)] {
            await blocked { _ = try await s.validateLocalBusinessErasedV4(requestID:"delete",requestDigest:saga.intent.digest,scope:wrong) }
        }
        try await s.close()
        for change: (inout [String:Any]) throws -> Void in [{ $0["localProgress"]="pending" },{ $0["originalScope"]=nil },{ $0["recoveryCapability"]=AuthorityWire.base64URL(Data(repeating:42,count:32)) },{ $0["revision"] = -1 }] {
            let x = try h.context(), original = try await deleted(x); try editSaga(x,change)
            let before = try controls(x.url), r = try h.store(x); await blocked { _ = try await self.witness(r,original) };try await r.close();XCTAssertEqual(try controls(x.url),before)
        }
        let keep = try h.context(), retained = try await deleted(keep,local:.keep), r = try h.store(keep)
        await blocked { _ = try await self.witness(r,retained) };try await r.close()
    }
    func testStoredBackendReceiptAndOriginalControlAreReverifiedNotTrustedFromFlags() async throws {
        for variant in 0..<5 {
            let c = try h.context(), saga = try await deleted(c)
            if variant == 0 { try editSaga(c) { $0["backendReceipt"] = Data("unsigned".utf8).base64EncodedString() } }
            if variant == 1 {
                let bad = try h.receipt(c,requestID:"another",digest:saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
                try editSaga(c) { $0["backendReceipt"] = bad.raw.base64EncodedString() }
            }
            if variant == 2 { try sql(c.url) { try $0.execute("DELETE FROM control_intents_v4 WHERE id='delete'") } }
            if variant == 3 { try sql(c.url) { try $0.execute("UPDATE lifecycle_steps_v4 SET checksum='bad' WHERE id='deletion:delete'") } }
            if variant == 4 {
                let wrong = try h.receipt(c,requestID:"delete",digest:saga.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"pending","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
                try editSaga(c) { $0["backendReceipt"] = wrong.raw.base64EncodedString() }
            }
            let before = try controls(c.url), s = try h.store(c);await blocked { _ = try await self.witness(s,saga) };try await s.close();XCTAssertEqual(try controls(c.url),before)
        }
    }
    func testLiveUnknownFutureOrChangedLayoutFailsClosedWithoutRepair() async throws {
        for ddl in ["PRAGMA user_version=5", "CREATE TABLE unknown_business (raw BLOB)", "CREATE VIEW old_business AS SELECT * FROM matches", "CREATE TRIGGER hidden_business AFTER INSERT ON matches BEGIN SELECT 1; END", "ALTER TABLE matches ADD COLUMN restored BLOB", "DROP TABLE events"] {
            let c = try h.context(), saga = try await deleted(c), s = try h.store(c)
            try sql(c.url) { try $0.execute(ddl) }
            let beforeFile = try Data(contentsOf:c.url), beforeCatalog = try rawRows(c.url,"SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name"), beforeVersion = try rawRows(c.url,"PRAGMA user_version")
            await blocked { _ = try await self.witness(s,saga) }
            XCTAssertEqual(try Data(contentsOf:c.url),beforeFile)
            XCTAssertEqual(try rawRows(c.url,"SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name"),beforeCatalog)
            XCTAssertEqual(try rawRows(c.url,"PRAGMA user_version"),beforeVersion)
            try await s.close()
        }
    }
    func testOriginalEraseCommitResponseLossAllowsReadOnlyValidationWithoutNewProgress() async throws {
        let c = try h.context(), seed = try h.store(c), original = try h.saga(c)
        try await seed.bindAccountV4(c.binding);try await seed.createDeletionSagaV4(original)
        let signed = try h.receipt(c,requestID:"delete",digest:original.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        let backend = try await seed.acceptDeletionV4(requestID:"delete",receipt:signed,expectedRevision:0);try await seed.close()
        let failing = try h.store(c,fault:.afterCommit)
        await blocked { _ = try await failing.eraseLocalBusinessV4(requestID:"delete",expectedRevision:backend.revision) };try await failing.close()
        let before = try controls(c.url), s = try h.store(c)
        let savedValue = try await s.deletionSagaV4(requestID:"delete"), saved = try XCTUnwrap(savedValue)
        _ = try await witness(s,saved);try await s.close();XCTAssertEqual(try controls(c.url),before)
    }
    func testConcreteWrapperUsesOriginalFacadeAndDoesNotExpandGenericProtocol() async throws {
        let c = try h.context(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), repo = try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"erase-validation",authorityTrust:c.trust)
        let original = try h.saga(c)
        try await repo.store.bindAccountV4(c.binding);try await repo.store.createDeletionSagaV4(original)
        let signed = try h.receipt(c,requestID:"delete",digest:original.intent.digest,operation:.deleteAccount,result:.deleted,extra:["deletion":["backend":"backendDeleted","apple":"revoked","cloud":"clientManaged","local":"clientManaged","health":"separateConfirmation"]])
        let backend = try await repo.store.acceptDeletionV4(requestID:"delete",receipt:signed,expectedRevision:0), local = try await repo.store.eraseLocalBusinessV4(requestID:"delete",expectedRevision:backend.revision)
        let result = try await repo.validateLocalBusinessErasedV4(requestID:"delete",requestDigest:local.intent.digest,scope:XCTUnwrap(local.originalScope));XCTAssertEqual(result.currentSagaRevision,local.revision)
        try await repo.close()
    }
    func rawRows(_ url: URL, _ query: String) throws -> [[String]] {
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { throw StoreError.invalidRequest }
        defer { sqlite3_close(db) };var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,query,-1,&statement,nil) == SQLITE_OK else { throw StoreError.invalidRequest }
        defer { sqlite3_finalize(statement) };var result: [[String]] = []
        while true {
            let code = sqlite3_step(statement);if code == SQLITE_DONE { return result };guard code == SQLITE_ROW else { throw StoreError.invalidRequest }
            var row: [String] = []
            for i in 0..<sqlite3_column_count(statement) {
                let n = Int(sqlite3_column_bytes(statement,i)), kind = sqlite3_column_type(statement,i)
                row.append(String(kind)+":"+(sqlite3_column_blob(statement,i).map { Data(bytes:$0,count:n).base64EncodedString() } ?? "NULL"))
            }
            result.append(row)
        }
    }
    func testRawUnicodeZoneCannotAliasOriginalDeletionScope() async throws {
        let c = try h.context(), saga = try await deleted(c,zone:"caf\u{00e9}"), s = try h.store(c)
        let original = try XCTUnwrap(saga.originalScope), other = try CloudScopeV1(accountID:original.accountID,cloudSpaceID:original.cloudSpaceID,zoneID:"cafe\u{0301}",activationEpoch:1)
        XCTAssertEqual(original.zoneID,other.zoneID) // Swift String canonical equivalence is insufficient here.
        XCTAssertNotEqual(Data(original.zoneID.utf8),Data(other.zoneID.utf8))
        await blocked { _ = try await s.validateLocalBusinessErasedV4(requestID:"delete",requestDigest:saga.intent.digest,scope:other) }
        _ = try await witness(s,saga);try await s.close()
    }
    func testEachNewReadDetectsLaterRestorationAndDoesNotInvokeWriteFaults() async throws {
        let c = try h.context(), saga = try await deleted(c), a = try h.store(c,fault:.beforeCommit), b = try h.store(c,fault:.afterCommit)
        let before = try controls(c.url);_ = try await witness(a,saga);_ = try await witness(b,saga)
        try sql(c.url) { try $0.execute("INSERT INTO commands VALUES (?,?,?)",[.text("restored"),.text("original-hash"),.blob(Data([1]))]) }
        await blocked { _ = try await self.witness(a,saga) };await blocked { _ = try await self.witness(b,saga) }
        try await a.close();try await b.close();XCTAssertEqual(try controls(c.url),before)
        try sql(c.url) { XCTAssertEqual(try $0.scalar("SELECT count(*) FROM commands").number,1) }
    }
    func testMalformedOriginalSagaRejectsWithTypedErrorAndPreservesCanonicalRow() async throws {
        let c = try h.context(), saga = try await deleted(c)
        try sql(c.url) { db in let raw = Data("{\"unknown\":true}".utf8);try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id='deletion:delete'",[.blob(raw),.text(Canonical.hash(raw))]) }
        let before = try controls(c.url), s = try h.store(c)
        do { _ = try await witness(s,saga);XCTFail("corrupt original proof") }
        catch { XCTAssertTrue(error is StoreError || error is AuthorityError || error is LocalBusinessErasureErrorV4,"stable typed control error required, got \(error)") }
        try await s.close();XCTAssertEqual(try controls(c.url),before)
    }

    func testRetainedBindingAndOriginalControlCannotBeRebound() async throws {
        for bindingChange in [true,false] {
            let c = try h.context(), saga = try await deleted(c)
            try sql(c.url) { db in
                let raw: Data
                if bindingChange {
                    raw = try Canonical.data(AccountBindingV4(accountID:c.binding.accountID,cloudSpaceID:"other-cloud",deviceID:c.binding.deviceID,activationEpoch:1,role:.phone,environment:.development,suspended:true))
                    try db.execute("UPDATE account_binding_v4 SET payload=?,checksum=? WHERE id='current'",[.blob(raw),.text(Canonical.hash(raw))])
                } else {
                    var fields = saga.intent.fields;fields.reauthenticationID = "another-reauth"
                    raw = try Canonical.data(ControlIntentV1(requestID:"delete",operation:.deleteAccount,fields:fields))
                    try db.execute("UPDATE control_intents_v4 SET payload=?,checksum=? WHERE id='delete'",[.blob(raw),.text(Canonical.hash(raw))])
                }
            }
            let before = try controls(c.url), s = try h.store(c);await blocked { _ = try await self.witness(s,saga) };try await s.close();XCTAssertEqual(try controls(c.url),before)
        }
    }
    func testFrozenVersionOneMigrationUsesTheSameSupportedLayout() async throws {
        let original = try h.context(), c = LifecycleStateTests.Context(url:try LegacyCompatibilityTests().database(),key:original.key,trust:original.trust,binding:original.binding)
        let saga = try await deleted(c), s = try h.store(c)
        _ = try await witness(s,saga);try await s.close()
        XCTAssertEqual(try MigrationV2Tests().rawInt(c.url,"PRAGMA user_version"),4)
    }

}
