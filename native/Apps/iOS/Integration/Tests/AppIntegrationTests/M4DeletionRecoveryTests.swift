import Foundation
import CryptoKit
import SQLite3
import XCTest
import CloudSync
import DeviceSync
import MatchCore
import MatchStore
import MatchSession
import AccountKit
import HealthKitDeletion
import MatchPresentation
@testable import AppIntegration

@MainActor final class M4DeletionRecoveryTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4-local-erase-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func scope() throws -> CloudScope { try CloudScope(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 2) }
  private func seal(_ catalog: M4OwnedDataCatalog, capsules: [M4OwnershipCapsule]) throws -> M4FrozenDeletionPlan {
    for capsule in capsules { try catalog.record(capsule) }
    _ = try catalog.reserve(requestID: "original-parent", scope: scope(), choices: M4DeletionChoices(cloud: .keep, local: .delete, health: .keep, healthConfirmed: false), health: .empty)
    return try catalog.seal(requestID: "original-parent", parentIntentDigest: String(repeating: "d", count: 64))
  }
  private func staging(_ root: URL, id: String = "staging") throws -> (CloudOwnedStaging, M4OwnershipCapsule, URL) {
    let directory = root.appendingPathComponent(id), control = root.appendingPathComponent(id + "-control.sqlite")
    let store = try CloudOwnedStaging(rootURL: directory, controlURL: control)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: id, kind: .cloudStaging, scope: scope(), root: directory,
      retainedControls: [control, URL(fileURLWithPath: control.path + ".owner"), URL(fileURLWithPath: directory.path + ".owner")])
    return (store, capsule, control)
  }
  private func erase(_ leaves: M4LocalTransportLeaves, _ capsule: M4OwnershipCapsule, _ plan: M4FrozenDeletionPlan) async throws -> M4RetainedLeafReceipt {
    try await leaves.erase(componentID: capsule.componentID, parentID: plan.requestID, parentIntentDigest: XCTUnwrap(plan.parentIntentDigest))
  }
  func testStagingOriginalReceiptReopensButRestoredDirectoryBlocksCachedSuccess() async throws {
    let root = try root(), catalogURL = root.appendingPathComponent("catalog"), catalog = try M4OwnedDataCatalog(directory: catalogURL)
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let leaves = M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control])
    let first = try await erase(leaves, capsule, plan)
    XCTAssertEqual(first.kind, .cloudStaging); XCTAssertEqual(first.leafDigest, plan.parentIntentDigest)
    let saved = try catalog.receipts(requestID: plan.requestID)
    XCTAssertEqual(try M4CatalogIO.encode(saved), try M4CatalogIO.encode([first])); try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: catalogURL), retry = M4LocalTransportLeaves(catalog: reopened, stagingControls: [capsule.componentID: control])
    let second = try await erase(retry, capsule, plan); XCTAssertEqual(try M4CatalogIO.encode(second), try M4CatalogIO.encode(first))
    let restored = URL(fileURLWithPath: capsule.root.path).appendingPathComponent(try scope().stableZoneKey)
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
    let foreign = restored.appendingPathComponent("unknown-restored"); try Data("preserve".utf8).write(to: foreign)
    do { _ = try await erase(retry, capsule, plan); XCTFail("cached receipt cannot replace actual current-zero replay") } catch {}
    XCTAssertEqual(try Data(contentsOf: foreign), Data("preserve".utf8))
    XCTAssertEqual(try M4CatalogIO.encode(reopened.receipts(requestID: plan.requestID)), try M4CatalogIO.encode(saved)); try reopened.close()
  }
  func testDefaultDeviceDrainIsIncompleteAndControlledReceiptStillChecksCurrentInventory() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let directory = root.appendingPathComponent("DeviceSync"), context = try DeviceSyncStorageContext(root: directory)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "device", kind: .deviceSync, scope: scope(), root: directory,
      retainedControls: [directory.appendingPathComponent(".control/.owner"), directory.appendingPathComponent(".control/control.sqlite")])
    try context.bind(capsule.deviceBinding()); let plan = try seal(catalog, capsules: [capsule])
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog), capsule, plan); XCTFail("default driver cannot complete") }
    catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty)
    let controlled = M4LocalTransportLeaves(catalog: catalog, deviceDriver: LocalControlledDrain())
    let first = try await erase(controlled, capsule, plan)
    XCTAssertEqual(first.kind, .deviceSync); XCTAssertNotEqual(first.leafDigest, plan.parentIntentDigest)
    let inbox = directory.appendingPathComponent("inbox"); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
    let bytes = Data("restored-original-frame".utf8), restored = inbox.appendingPathComponent("frame-" + M4CatalogIO.hash(bytes) + ".frame")
    try bytes.write(to: restored)
    do { _ = try await erase(controlled, capsule, plan); XCTFail("receipt replay must inspect current files") } catch {}
    XCTAssertEqual(try Data(contentsOf: restored), bytes)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)), try M4CatalogIO.encode([first])); try catalog.close()
  }
  func testConcreteCloudLeafReopenReplaysOriginalReceiptAndRejectsRestoredOldEpoch() async throws {
    let root = try root(), directory = root.appendingPathComponent("catalog"), catalog = try M4OwnedDataCatalog(directory: directory)
    let url = root.appendingPathComponent("ledger.sqlite"), ledger = try SQLiteCloudLedger(url: url)
    let oldScope = try CloudScope(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 1)
    let foreign = try CloudScope(accountID: "other", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 2)
    for (scope, id) in [(oldScope, "old-epoch-upload"), (foreign, "foreign-upload")] {
      let record = try CloudRecord(scope: scope, payload: .deletion(CloudDeletion(matchID: id, deletionID: id, deletedAt: Date(timeIntervalSince1970: 10))))
      try await ledger.enqueue(CloudUpload(id: id, scope: scope, record: record))
    }
    let originalRow = try XCTUnwrap(sqlStrings(url, "SELECT quote(id)||','||quote(scope)||','||quote(digest)||','||quote(original)||','||quote(state)||','||quote(attempts)||','||quote(issue)||','||quote(retry_ms)||','||quote(attempted_ms) FROM cloud_uploads WHERE id='old-epoch-upload'").first)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "all-epoch-ledger", kind: .cloudLedger, scope: scope(), root: url, retainedControls: [])
    let plan = try seal(catalog, capsules: [capsule]); try await ledger.close()
    let first = try await erase(M4LocalTransportLeaves(catalog: catalog), capsule, plan)
    XCTAssertEqual(first.kind, .cloudLedger)
    XCTAssertEqual(try sqlStrings(url, "SELECT id FROM cloud_uploads ORDER BY id"), ["foreign-upload"])
    let saved = try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)); try catalog.close()
    let reopened = try M4OwnedDataCatalog(directory: directory), retry = M4LocalTransportLeaves(catalog: reopened)
    let second = try await erase(retry, capsule, plan)
    XCTAssertEqual(try M4CatalogIO.encode(first), try M4CatalogIO.encode(second))
    try executeSQL(url, "INSERT INTO cloud_uploads VALUES(" + originalRow + ")")
    let before = try sqlStrings(url, "SELECT hex(original) FROM cloud_uploads ORDER BY id")
    do { _ = try await erase(retry, capsule, plan); XCTFail("first receipt cannot bypass actual044 replay of a restored older epoch") }
    catch { XCTAssertEqual(error as? CloudError, CloudError(.invalidPayload)) }
    XCTAssertEqual(try sqlStrings(url, "SELECT hex(original) FROM cloud_uploads ORDER BY id"), before)
    XCTAssertEqual(try M4CatalogIO.encode(reopened.receipts(requestID: plan.requestID)), saved)
    try reopened.close()
  }
  func testCloudCachedReceiptMissingInternalProofMustNotEraseRestoredPayload() async throws {
    try await cloudLostProofFixture(legacyV3: false)
  }
  func testCloudCachedReceiptLegacyV3MustNotMigrateOrEraseRestoredPayload() async throws {
    try await cloudLostProofFixture(legacyV3: true)
  }
  private func cloudLostProofFixture(legacyV3: Bool) async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog")), url = root.appendingPathComponent("proof-ledger.sqlite")
    let scope = try scope(), ledger = try SQLiteCloudLedger(url: url)
    let record = try CloudRecord(scope: scope, payload: .deletion(CloudDeletion(matchID: "proof-match", deletionID: "proof-delete", deletedAt: Date(timeIntervalSince1970: 10))))
    try await ledger.enqueue(CloudUpload(id: "proof-upload", scope: scope, record: record))
    let row = try XCTUnwrap(sqlStrings(url, "SELECT quote(id)||','||quote(scope)||','||quote(digest)||','||quote(original)||','||quote(state)||','||quote(attempts)||','||quote(issue)||','||quote(retry_ms)||','||quote(attempted_ms) FROM cloud_uploads WHERE id='proof-upload'").first)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "proof-ledger", kind: .cloudLedger, scope: scope, root: url, retainedControls: [])
    let plan = try seal(catalog, capsules: [capsule]); try await ledger.close()
    let leaves = M4LocalTransportLeaves(catalog: catalog), first = try await erase(leaves, capsule, plan)
    let edits = legacyV3 ? "DROP TABLE cloud_local_erase_receipts; DROP TABLE cloud_local_erase_fences; PRAGMA user_version=3;" : "DELETE FROM cloud_local_erase_receipts; DELETE FROM cloud_local_erase_fences;"
    try executeSQL(url, edits + "INSERT INTO cloud_uploads VALUES(" + row + ")")
    let schema = try sqlStrings(url, "SELECT type||':'||name||':'||coalesce(sql,'') FROM sqlite_schema ORDER BY type,name"), version = try sqlStrings(url, "PRAGMA user_version")
    let original = try sqlStrings(url, "SELECT hex(original) FROM cloud_uploads WHERE id='proof-upload'"), identity = try M4CatalogIO.encode(M4CatalogIO.anchor(url))
    do { _ = try await erase(leaves, capsule, plan); XCTFail("external first receipt requires retained internal proof; it cannot authorize a fresh re-erase or constructor migration") } catch {}
    XCTAssertEqual(try sqlStrings(url, "SELECT hex(original) FROM cloud_uploads WHERE id='proof-upload'"), original)
    XCTAssertEqual(try sqlStrings(url, "SELECT type||':'||name||':'||coalesce(sql,'') FROM sqlite_schema ORDER BY type,name"), schema)
    XCTAssertEqual(try sqlStrings(url, "PRAGMA user_version"), version)
    XCTAssertEqual(try M4CatalogIO.encode(M4CatalogIO.anchor(url)), identity)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)), try M4CatalogIO.encode([first])); try catalog.close()
  }
  func testConcreteCloudLeafPreservesUnknownLiveLayoutAfterFirstReceipt() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog")), url = root.appendingPathComponent("ledger.sqlite")
    let ledger = try SQLiteCloudLedger(url: url); try await ledger.close()
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "layout-ledger", kind: .cloudLedger, scope: scope(), root: url, retainedControls: [])
    let plan = try seal(catalog, capsules: [capsule]), leaves = M4LocalTransportLeaves(catalog: catalog)
    let first = try await erase(leaves, capsule, plan)
    try executeSQL(url, "CREATE TABLE future_business(value BLOB) STRICT; INSERT INTO future_business VALUES(X'010203')")
    do { _ = try await erase(leaves, capsule, plan); XCTFail("unknown layout must reach concrete leaf validation even with a receipt") }
    catch { XCTAssertEqual(error as? CloudError, CloudError(.invalidPayload)) }
    XCTAssertEqual(try sqlStrings(url, "SELECT hex(value) FROM future_business"), ["010203"])
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)), try M4CatalogIO.encode([first])); try catalog.close()
  }
  func testConcreteStoreWitnessUsesOriginalFacadeAndStableFirstBytesAcrossSagaProgress() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil)
    try await f.composition.quiesceBusiness()
    let erased = try await f.composition.session.eraseLocalBusiness(requestID: f.saga.intent.requestID, expectedRevision: f.saga.revision)
    let plan = try XCTUnwrap(f.catalog.plan(requestID: f.saga.intent.requestID)), capsule = try XCTUnwrap(plan.entries.first(where: { $0.capsule.kind == .businessStore })).capsule
    let leaves = M4LocalTransportLeaves(catalog: f.catalog, storeRoutes: [capsule.componentID: f.composition])
    let first = try await erase(leaves, capsule, plan)
    XCTAssertEqual(first.kind, .businessStore)
    var advanced = erased; advanced.revision += 1; advanced.cloudProgress = .completed
    try await f.composition.session.updateDeletionSaga(advanced, expectedRevision: erased.revision)
    let again = try await erase(leaves, capsule, plan)
    XCTAssertEqual(try M4CatalogIO.encode(first), try M4CatalogIO.encode(again), "mutable Saga revision is not frozen into the first component receipt")
    do { _ = try await erase(M4LocalTransportLeaves(catalog: f.catalog), capsule, plan); XCTFail("an absent original Store route cannot borrow another proof") }
    catch { XCTAssertEqual(error as? M4LocalErasureError, .unsupportedComponent) }
    let wrong = try await deletionGuardFixture(healthIssue: nil)
    do { _ = try await erase(M4LocalTransportLeaves(catalog: f.catalog, storeRoutes: [capsule.componentID: wrong.composition]), capsule, plan); XCTFail("another facade cannot prove this capsule") }
    catch { XCTAssertEqual(error as? M4CatalogError, .identityChanged) }
    try await wrong.close()
    let seed = f.prepared.seed, material = f.prepared.material, trust = f.composition.client.trust
    try await f.close()
    let prepared = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    let composition = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: f.scope.cloudSpaceID)
    let catalog = try M4OwnedDataCatalog(directory: f.root.appendingPathComponent("catalog"))
    let reopened = M4LocalTransportLeaves(catalog: catalog, storeRoutes: [capsule.componentID: composition])
    let replay = try await erase(reopened, capsule, plan)
    XCTAssertEqual(try M4CatalogIO.encode(replay), try M4CatalogIO.encode(first))
    let raw = try M4CatalogIO.encode("restored-business"), hex = raw.map { String(format: "%02x", $0) }.joined()
    try executeSQL(f.database, "INSERT INTO lifecycle_steps_v4 VALUES('normal-intent:guard-witness',X'" + hex + "','" + M4CatalogIO.hash(raw) + "')")
    do { _ = try await erase(reopened, capsule, plan); XCTFail("original first bytes cannot replace the fresh045 current-zero query") }
    catch { XCTAssertEqual(error as? LocalBusinessErasureErrorV4, .residualBusiness(table: "lifecycle_steps_v4")) }
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: plan.requestID)), try M4CatalogIO.encode([first]))
    try catalog.close(); try await composition.close()
  }
  private func sqlStrings(_ url: URL, _ query: String) throws -> [String] {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }; defer { sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }; defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
    return rows
  }
  private func executeSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }; defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }
  }
  func testUnregisteredStagingControlCannotBeOpenedOrCreateAReplacementOwner() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, _) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let wrong = root.appendingPathComponent("foreign-control.sqlite")
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: wrong]), capsule, plan); XCTFail("explicit control must match original retained paths") }
    catch { XCTAssertEqual(error as? M4LocalErasureError, .intentMismatch) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path + ".owner"))
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
  func testRetiredStagingCapsuleRemainsAnActualRequiredLeaf() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root, id: "retired-staging")
    try catalog.record(capsule); try catalog.retire(componentID: capsule.componentID)
    let plan = try seal(catalog, capsules: [capsule]); try staging.close()
    XCTAssertTrue(try XCTUnwrap(plan.entries.first).retired)
    let receipt = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control]), capsule, plan)
    XCTAssertEqual(receipt.componentID, capsule.componentID)
    XCTAssertEqual(try catalog.receipts(requestID: plan.requestID).count, 1); try catalog.close()
  }
  func testReplacedRetainedOwnerBlocksBeforeLeafAndPreservesForeignBytes() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let owner = URL(fileURLWithPath: control.path + ".owner"), retained = root.appendingPathComponent("original-owner-preserved")
    try FileManager.default.moveItem(at: owner, to: retained); try Data("foreign-owner".utf8).write(to: owner)
    let before = try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json"))
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control]), capsule, plan); XCTFail("replaced control inode cannot enter leaf") }
    catch { XCTAssertEqual(error as? M4CatalogError, .identityChanged) }
    XCTAssertEqual(try Data(contentsOf: owner), Data("foreign-owner".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), before); try catalog.close()
  }
  func testUnknownDeviceInventoryIsPreservedWithoutCallingDrainOrSavingReceipt() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let directory = root.appendingPathComponent("DeviceSync"), context = try DeviceSyncStorageContext(root: directory)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "unknown-device", kind: .deviceSync, scope: scope(), root: directory,
      retainedControls: [directory.appendingPathComponent(".control/.owner"), directory.appendingPathComponent(".control/control.sqlite")])
    try context.bind(capsule.deviceBinding()); let plan = try seal(catalog, capsules: [capsule])
    let foreign = directory.appendingPathComponent("unclassified"), bytes = Data("preserve-unknown".utf8); try bytes.write(to: foreign)
    let drain = LocalCountingDrain()
    do { _ = try await erase(M4LocalTransportLeaves(catalog: catalog, deviceDriver: drain), capsule, plan); XCTFail("unknown inventory cannot drain") }
    catch { XCTAssertEqual(error as? DeviceSyncErasureError, .unknownInventory) }
    let calls = await drain.calls; XCTAssertEqual(calls, 0)
    XCTAssertEqual(try Data(contentsOf: foreign), bytes); XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
  func testRealRetainedHealthArtifactsAnd028ConfirmationPublishOnlyBoundedFullSealReferences() async throws {
    let root = try root(), namespace = "fullseal-fixture", business = root.appendingPathComponent(namespace)
    let key = Curve25519.Signing.PrivateKey(), trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["fullseal-fixture": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let repo = try SQLiteSessionRepository(rootDirectory: root, databaseNamespace: namespace, authorityTrust: trust)
    try await repo.bindAccountV4(AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: "phone", activationEpoch: 2, role: .phone, environment: .development))
    let raw = try rawHealthReservation(), catalogURL = root.appendingPathComponent("catalog"), catalog = try M4OwnedDataCatalog(directory: catalogURL)
    let capsule = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "original-store", kind: .businessStore, scope: scope(), root: business.appendingPathComponent("matches.sqlite"), retainedControls: [])
    try catalog.record(capsule)
    let artifactURL = root.appendingPathComponent("health-artifacts"), owner = M4HealthArtifactOwner(installationID: UUID().uuidString, namespace: namespace, scope: raw.scope)
    let artifacts = try M4RetainedHealthArtifactStore(directory: artifactURL, owner: owner, removableRoots: [business], fullSealProvider: { try catalog.healthFullSeal(parentID: $0) })
    let ledger = try SQLiteHealthDeletionLedger(url: root.appendingPathComponent("health-selection/selection.sqlite"), businessDataDirectory: business)
    let bridge = M4HealthDeletionBridge(mapping: artifacts, parents: repo, ledger: ledger, allowedSourceOrigin: .controlledFixture, clock: { 12 })
    try await bridge.reserve(raw)
    _ = try catalog.reserve(requestID: raw.parentID, scope: scope(), choices: M4DeletionChoices(cloud: raw.cloud, local: raw.local, health: raw.health, healthConfirmed: raw.healthConfirmed), health: M4HealthReservation(selections: [], issue: nil, rawArtifactDigest: raw.digest()))
    let saga = try healthSaga(raw); try await repo.createDeletionSagaV4(saga)
    let savedSaga = try await repo.deletionSagaV4(requestID: raw.parentID), persisted = try XCTUnwrap(savedSaga)
    _ = try catalog.seal(requestID: raw.parentID, parentIntentDigest: persisted.intent.digest)
    let absent = try await artifacts.readFullSeal(parentID: raw.parentID); XCTAssertNil(absent)
    let proposed = try M4HealthPreparedMapping(reservation: raw, parentDigest: persisted.intent.digest)
    let submitted = try await ledger.submit(proposed.request), unsealedBytes = try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json"))
    XCTAssertNil(submitted.confirmation)
    XCTAssertThrowsError(try catalog.sealFullControls(saga: persisted, raw: raw, prepared: proposed, entry: submitted)) { XCTAssertEqual($0 as? M4CatalogError, .intentMismatch) }
    XCTAssertEqual(try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json")), unsealedBytes)
    let prepared = try await bridge.prepare(parentID: raw.parentID), entry = try await ledger.entry(prepared.request.requestID)
    try catalog.sealFullControls(saga: persisted, raw: raw, prepared: prepared, entry: entry)
    let actual = try await artifacts.readFullSeal(parentID: raw.parentID), seal = try XCTUnwrap(actual)
    XCTAssertEqual(seal.reservationDigest, try raw.digest()); XCTAssertEqual(seal.preparedDigest, try M4CatalogIO.hash(prepared.canonicalBytes()))
    XCTAssertEqual(seal.parentDigest, persisted.intent.digest); XCTAssertEqual(seal.catalogDigest, try catalog.index().digest())
    let bytes = try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json"))
    XCTAssertLessThan(bytes.count, 1_048_576)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("raw-capture-token-kept-out-of-catalog"))
    try catalog.sealFullControls(saga: persisted, raw: raw, prepared: prepared, entry: entry)
    XCTAssertEqual(try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json")), bytes)
    let changedRaw = try rawHealthReservation(), changedPrepared = try M4HealthPreparedMapping(reservation: changedRaw, parentDigest: persisted.intent.digest)
    XCTAssertThrowsError(try catalog.sealFullControls(saga: persisted, raw: changedRaw, prepared: changedPrepared, entry: entry)) { XCTAssertEqual($0 as? M4CatalogError, .intentMismatch) }
    XCTAssertEqual(try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json")), bytes)
    try await artifacts.close(); try catalog.close(); try await ledger.close(); try await repo.close()
    let reopened = try M4OwnedDataCatalog(directory: catalogURL)
    let restoredArtifacts = try M4RetainedHealthArtifactStore(directory: artifactURL, owner: owner, removableRoots: [business], fullSealProvider: { try reopened.healthFullSeal(parentID: $0) })
    let restoredSeal = try await restoredArtifacts.readFullSeal(parentID: raw.parentID)
    XCTAssertEqual(try M4CatalogIO.encode(restoredSeal), try M4CatalogIO.encode(actual))
    XCTAssertEqual(try Data(contentsOf: catalogURL.appendingPathComponent("catalog.json")), bytes)
    try await restoredArtifacts.close(); try reopened.close()
  }
  func testUnmappedHealthSelectionCannotPublishFullSealOrInventArtifactReference() throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, _) = try staging(root); try staging.close(); try catalog.record(capsule)
    let raw = try rawHealthReservation(), saga = try healthSaga(raw)
    _ = try catalog.reserve(requestID: saga.intent.requestID, scope: scope(), choices: M4DeletionChoices(cloud: .keep, local: .delete, health: .delete, healthConfirmed: true), health: M4HealthReservation(selections: [], issue: .missingMapping))
    let original = try catalog.seal(requestID: saga.intent.requestID, parentIntentDigest: saga.intent.digest)
    let bytes = try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json"))
    XCTAssertThrowsError(try catalog.sealFullControls(saga: saga)) { XCTAssertEqual($0 as? M4CatalogError, .intentMismatch) }
    XCTAssertThrowsError(try catalog.sealFullControls(saga: saga, raw: raw, prepared: M4HealthPreparedMapping(reservation: raw, parentDigest: saga.intent.digest))) { XCTAssertEqual($0 as? M4CatalogError, .intentMismatch) }
    XCTAssertNil(try catalog.healthFullSeal(parentID: saga.intent.requestID))
    XCTAssertEqual(try catalog.plan(requestID: saga.intent.requestID)?.canonicalBytes(), try original.canonicalBytes())
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), bytes); try catalog.close()
  }
  func testMissingHealthMappingKeepsOriginalBusinessWhileCloudCompletesIndependently() async throws {
    for issue in [M4HealthSelectionIssue.missingMapping, .sourceUnavailable, .unsupportedSelection] {
      let f = try await deletionGuardFixture(healthIssue: issue)
      let cloud = GateControlledCloud(), admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger)
      let coordinator = M4GuardedLifecycleCoordinator(admission: admission)
      let service = LifecycleService(client: f.composition.client, repository: f.composition.repository, coordinator: coordinator, scope: f.scope, ledger: f.ledger, cloudDeletion: cloud, localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
      let result = try await service.resumeDeletion(requestID: f.saga.intent.requestID)
      let calls = await cloud.calls; XCTAssertEqual(calls, 1)
      XCTAssertEqual(result.cloudProgress, .completed)
      XCTAssertEqual(result.localProgress, .failed, "unretained Health selection must block Store erasure")
      XCTAssertEqual(result.localTransportProgress, .failed); XCTAssertEqual(result.healthProgress, .failed)
      XCTAssertFalse(result.finished)
      XCTAssertEqual(try businessWitnessCount(f.database), 1)
      XCTAssertNil(try f.catalog.healthFullSeal(parentID: f.saga.intent.requestID))
      let expected: M4HealthBridgeError
      switch issue { case .missingMapping: expected = .missingMapping; case .sourceUnavailable: expected = .sourceUnavailable; case .unsupportedSelection: expected = .unsupportedSelection }
      do { try await M4GuardedLocalTransportDeletion(admission: admission).purgeBusinessCopies(LocalTransportDeletionRequest(scope: f.scope, saga: result)); XCTFail("direct transport entrance must require the same real Health seal") }
      catch { XCTAssertEqual(error as? M4HealthBridgeError, expected) }
      let retained = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
      XCTAssertEqual(retained?.recoveryCapability, f.saga.recoveryCapability); XCTAssertEqual(retained?.intent, f.saga.intent)
      try await f.close()
    }
  }
  func testHealthKeepUsesGeneralParentSealWithoutInventingHealthArtifacts() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil), cloud = GateControlledCloud()
    let admission = controlledAggregateAdmission(f)
    let service = LifecycleService(client: f.composition.client, repository: f.composition.repository, coordinator: M4GuardedLifecycleCoordinator(admission: admission), scope: f.scope, ledger: f.ledger, cloudDeletion: cloud, localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
    let result = try await service.resumeDeletion(requestID: f.saga.intent.requestID)
    XCTAssertEqual(result.localProgress, .completed); XCTAssertEqual(result.healthProgress, .retained)
    XCTAssertEqual(try businessWitnessCount(f.database), 0)
    XCTAssertNil(try f.catalog.healthFullSeal(parentID: f.saga.intent.requestID))
    XCTAssertTrue(result.finished, "the explicit controlled copy drain and every concrete local leaf must complete")
    try await f.close()
  }
  func testUnsealedDirectServiceAndCoordinatorCannotBypassGeneralResumeGate() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, sealParent: false), cloud = GateControlledCloud()
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger), coordinator = M4GuardedLifecycleCoordinator(admission: admission)
    let service = LifecycleService(client: f.composition.client, repository: f.composition.repository, coordinator: coordinator, scope: f.scope, ledger: f.ledger, cloudDeletion: cloud, localTransportDeletion: M4GuardedLocalTransportDeletion(admission: admission))
    do { _ = try await service.resumeDeletion(requestID: f.saga.intent.requestID); XCTFail("raw service path must hit forwarding gate before Cloud/Store") } catch {}
    let calls = await cloud.calls; XCTAssertEqual(calls, 0)
    let original = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    do { _ = try await coordinator.eraseLocalBusiness(requestID: f.saga.intent.requestID, expectedRevision: XCTUnwrap(original).revision); XCTFail("direct coordinator path must remain gated") } catch {}
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    XCTAssertNil(try f.catalog.plan(requestID: f.saga.intent.requestID)?.parentIntentDigest)
    try await f.close()
  }
  func testGenericDeleteAccountReconcileCannotCreateAnUncatalogedParent() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil)
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger)
    let service = LifecycleService(client: f.composition.client, repository: f.composition.repository, coordinator: M4GuardedLifecycleCoordinator(admission: admission), scope: f.scope, ledger: f.ledger)
    let foreign = try ControlIntentV1(requestID: "foreign-parent", operation: .deleteAccount, fields: f.saga.intent.fields)
    do { _ = try await service.reconcileLifecycle(foreign); XCTFail("generic delete must require original saga/catalog seal") }
    catch { XCTAssertEqual(error as? LifecycleClientError, .unknownOriginal) }
    let created = try await f.composition.repository.lifecycleControlIntentV4(requestID: foreign.requestID)
    XCTAssertNil(created); XCTAssertEqual(try businessWitnessCount(f.database), 1)
    try await f.close()
  }
  func testReopenResumeRebuildsAnalyticsAndFenceWithoutNewParentOrCapability() async throws {
    let original = try await deletionGuardFixture(healthIssue: nil, acceptBackend: false)
    let seed = original.prepared.seed, material = original.prepared.material, trust = original.composition.client.trust
    try await original.close()
    let prepared = try await M4IdentityBootstrap.prepare(root: seed.root, namespace: seed.namespace, controlDirectory: seed.controlDirectory) { _ in material }
    let composition = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: original.scope.cloudSpaceID)
    let catalog = try M4OwnedDataCatalog(directory: original.root.appendingPathComponent("catalog")), ledger = try SQLiteCloudLedger(url: original.root.appendingPathComponent("cloud-ledger.sqlite"))
    let persisted = try await composition.repository.deletionSagaV4(requestID: original.saga.intent.requestID)
    let f = GateFixture(root: original.root, composition: composition, prepared: prepared, catalog: catalog, ledger: ledger, scope: original.scope, saga: try XCTUnwrap(persisted), database: seed.businessDatabaseURL)
    XCTAssertEqual(f.saga.intent, original.saga.intent); XCTAssertEqual(f.saga.recoveryCapability, original.saga.recoveryCapability)
    let before = try await f.composition.repository.analyticsEnabledV4(); XCTAssertTrue(before)
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger)
    let result = try await M4DeletionResumeController(admission: admission).resume(requestID: f.saga.intent.requestID)
    let enabled = try await f.composition.repository.analyticsEnabledV4(), state = try await f.ledger.scopeState(scope: f.scope)
    XCTAssertFalse(enabled); XCTAssertEqual(state.issue, .accountChanged)
    XCTAssertEqual(result.intent, f.saga.intent); XCTAssertEqual(result.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertFalse(result.backendDeleted); XCTAssertEqual(try businessWitnessCount(f.database), 1)
    try await f.close()
  }
  func testAutomaticRecoveryAndGenericControllerUseOriginalGuardedParent() async throws {
    let f = try await deletionGuardFixture(healthIssue: .missingMapping), cloud = GateControlledCloud()
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger), controller = M4DeletionResumeController(admission: admission, cloudDeletion: cloud)
    let recovered = try await controller.recover(), result = try XCTUnwrap(recovered.first)
    XCTAssertEqual(result.intent, f.saga.intent); XCTAssertEqual(result.cloudProgress, .completed); XCTAssertEqual(result.localProgress, .failed)
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    let foreign = try ControlIntentV1(requestID: "controller-foreign-parent", operation: .deleteAccount, fields: f.saga.intent.fields)
    do { _ = try await controller.reconcile(foreign); XCTFail("generic controller cannot replace the original request") }
    catch { XCTAssertEqual(error as? LifecycleClientError, .unknownOriginal) }
    try await f.close()
  }
  func testAutomaticRecoveryRejectsUnsealedOriginalParentBeforeAnyComponentCall() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, sealParent: false), cloud = GateControlledCloud()
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger)
    do { _ = try await M4DeletionResumeController(admission: admission, cloudDeletion: cloud).recover(); XCTFail("reopen must not bypass parent seal") }
    catch { XCTAssertEqual(error as? M4CatalogError, .intentMismatch) }
    let calls = await cloud.calls; XCTAssertEqual(calls, 0); XCTAssertEqual(try businessWitnessCount(f.database), 1)
    try await f.close()
  }
  private func aggregateLeaves(_ f: GateFixture, deviceDriver: any DeviceSyncErasureDriving = LocalControlledDrain()) -> M4LocalTransportLeaves {
    M4LocalTransportLeaves(catalog: f.catalog, stagingControls: ["retired-staging": f.root.appendingPathComponent("retired-staging-control.sqlite")], deviceDriver: deviceDriver, storeRoutes: ["guard-store": f.composition])
  }
  private func controlledAggregateAdmission(_ f: GateFixture, deviceDriver: any DeviceSyncErasureDriving = LocalControlledDrain()) -> M4DeletionAdmission {
    M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger,
      healthArtifacts: f.healthArtifacts, healthLedger: f.healthLedger, allowedHealthSourceOrigin: .controlledFixture,
      localLeaves: aggregateLeaves(f, deviceDriver: deviceDriver), copyDrain: GateControlledCopyDrain(scope: f.scope, parent: f.saga.intent.requestID, digest: f.saga.intent.digest))
  }
  func testAggregateDefaultCopyDrainPreservesStoreAndAllowsIndependentCloud() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil), cloud = GateControlledCloud()
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger, localLeaves: aggregateLeaves(f))
    let result = try await M4DeletionResumeController(admission: admission, cloudDeletion: cloud).resume(requestID: f.saga.intent.requestID)
    XCTAssertEqual(result.cloudProgress, .completed); XCTAssertEqual(result.localProgress, .failed); XCTAssertEqual(result.localTransportProgress, .failed)
    XCTAssertEqual(try businessWitnessCount(f.database), 1); XCTAssertFalse(result.finished)
    XCTAssertTrue(try f.catalog.receipts(requestID: result.intent.requestID).isEmpty); try await f.close()
  }
  func testAggregateUsesEveryCurrentAndRetiredLeafThenReplaysHistoricalCompleted() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, additionalTransport: true), admission = controlledAggregateAdmission(f), cloud = GateControlledCloud()
    let controller = M4DeletionResumeController(admission: admission, cloudDeletion: cloud)
    let result = try await controller.resume(requestID: f.saga.intent.requestID)
    XCTAssertTrue(result.finished); XCTAssertEqual(result.localTransportProgress, .completed); XCTAssertEqual(try businessWitnessCount(f.database), 0)
    let plan = try XCTUnwrap(f.catalog.plan(requestID: result.intent.requestID)), receipts = try f.catalog.receipts(requestID: result.intent.requestID)
    XCTAssertEqual(receipts.count, plan.entries.count); XCTAssertEqual(Set(receipts.map(\.kind)), Set([.businessStore, .cloudLedger, .cloudStaging, .deviceSync]))
    XCTAssertTrue(plan.entries.contains(where: { $0.retired && $0.capsule.kind == .cloudLedger }))
    let firstBytes = try M4CatalogIO.encode(receipts)
    let replay = try await controller.resume(requestID: result.intent.requestID)
    XCTAssertTrue(replay.finished); XCTAssertEqual(replay.intent, f.saga.intent); XCTAssertEqual(replay.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertEqual(try M4CatalogIO.encode(f.catalog.receipts(requestID: result.intent.requestID)), firstBytes)
    try executeSQL(f.root.appendingPathComponent("retired-ledger.sqlite"), "CREATE TABLE future_business(value BLOB) STRICT; INSERT INTO future_business VALUES(X'040506')")
    do { _ = try await controller.resume(requestID: result.intent.requestID); XCTFail("historical transport completed cannot bypass every actual leaf replay") }
    catch { XCTAssertEqual(error as? CloudError, CloudError(.invalidPayload)) }
    XCTAssertEqual(try sqlStrings(f.root.appendingPathComponent("retired-ledger.sqlite"), "SELECT hex(value) FROM future_business"), ["040506"])
    XCTAssertEqual(try M4CatalogIO.encode(f.catalog.receipts(requestID: result.intent.requestID)), firstBytes); try await f.close()
  }
  func testAggregateUnknownAdditionalStoreBlocksBeforeErasingOriginalStore() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, additionalStore: true), admission = controlledAggregateAdmission(f), cloud = GateControlledCloud()
    let before = try Data(contentsOf: f.root.appendingPathComponent("unproven-store.sqlite"))
    let result = try await M4DeletionResumeController(admission: admission, cloudDeletion: cloud).resume(requestID: f.saga.intent.requestID)
    XCTAssertEqual(result.cloudProgress, .completed); XCTAssertEqual(result.localProgress, .failed); XCTAssertEqual(result.localTransportProgress, .failed)
    XCTAssertEqual(try businessWitnessCount(f.database), 1); XCTAssertFalse(result.finished)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("unproven-store.sqlite")), before)
    XCTAssertTrue(try f.catalog.receipts(requestID: result.intent.requestID).isEmpty); try await f.close()
  }
  func testAggregatePendingDeviceNeverBecomesCompleteAndCanRetryOriginalParent() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, additionalTransport: true), cloud = GateControlledCloud()
    let blocked = controlledAggregateAdmission(f, deviceDriver: UnavailableDeviceSyncErasureDriver())
    let first = try await M4DeletionResumeController(admission: blocked, cloudDeletion: cloud).resume(requestID: f.saga.intent.requestID)
    XCTAssertEqual(first.localProgress, .completed); XCTAssertEqual(first.localTransportProgress, .failed); XCTAssertFalse(first.finished)
    let firstReceipts = try f.catalog.receipts(requestID: first.intent.requestID)
    XCTAssertTrue(firstReceipts.contains(where: { $0.kind == .businessStore })); XCTAssertFalse(firstReceipts.contains(where: { $0.kind == .deviceSync }))
    let retry = try await M4DeletionResumeController(admission: controlledAggregateAdmission(f), cloudDeletion: cloud).resume(requestID: first.intent.requestID)
    XCTAssertTrue(retry.finished); XCTAssertEqual(retry.intent, first.intent); XCTAssertEqual(retry.recoveryCapability, first.recoveryCapability)
    for original in firstReceipts { XCTAssertTrue(try f.catalog.receipts(requestID: first.intent.requestID).contains(where: { try M4CatalogIO.encode($0) == M4CatalogIO.encode(original) })) }
    try await f.close()
  }
  func testAggregateHistoricalStoreCompletedStillRunsFresh045BeforeReturn() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil), admission = controlledAggregateAdmission(f)
    let controller = M4DeletionResumeController(admission: admission, cloudDeletion: GateControlledCloud())
    let completed = try await controller.resume(requestID: f.saga.intent.requestID)
    XCTAssertTrue(completed.finished)
    let first = try M4CatalogIO.encode(f.catalog.receipts(requestID: completed.intent.requestID)), raw = try M4CatalogIO.encode("restored after completion"), hex = raw.map { String(format: "%02x", $0) }.joined()
    try executeSQL(f.database, "INSERT INTO lifecycle_steps_v4 VALUES('normal-intent:guard-witness',X'" + hex + "','" + M4CatalogIO.hash(raw) + "')")
    do { _ = try await controller.resume(requestID: completed.intent.requestID); XCTFail("historical Store completed is not a current-zero authority") }
    catch { XCTAssertEqual(error as? LocalBusinessErasureErrorV4, .residualBusiness(table: "lifecycle_steps_v4")) }
    XCTAssertEqual(try businessWitnessCount(f.database), 1); XCTAssertEqual(try M4CatalogIO.encode(f.catalog.receipts(requestID: completed.intent.requestID)), first)
    try await f.close()
  }
  func testAggregateRoutedAdditionalStoreWithoutOriginalSagaBlocksBeforeFirstErase() async throws {
    let other = try await deletionGuardFixture(healthIssue: nil, acceptBackend: false)
    try executeSQL(other.database, "DELETE FROM lifecycle_steps_v4 WHERE id='deletion:guard-parent'")
    let missing = try await other.composition.repository.deletionSagaV4(requestID: other.saga.intent.requestID); XCTAssertNil(missing)
    let f = try await deletionGuardFixture(healthIssue: nil, extraStore: other.composition), cloud = GateControlledCloud()
    let leaves = M4LocalTransportLeaves(catalog: f.catalog, storeRoutes: ["guard-store": f.composition, "routed-extra-store": other.composition])
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger, localLeaves: leaves,
      copyDrain: GateControlledCopyDrain(scope: f.scope, parent: f.saga.intent.requestID, digest: f.saga.intent.digest))
    do { _ = try await M4DeletionResumeController(admission: admission, cloudDeletion: cloud).resume(requestID: f.saga.intent.requestID) } catch {}
    let actual = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(actual?.cloudProgress, .completed, "independent Cloud can progress despite an unsupported multi-Store provenance")
    XCTAssertNotEqual(actual?.localProgress, .completed)
    XCTAssertEqual(try businessWitnessCount(f.database), 1, "valid extra route/inode alone is not same-parent Store provenance")
    XCTAssertEqual(try businessWitnessCount(other.database), 1)
    XCTAssertTrue(try f.catalog.receipts(requestID: f.saga.intent.requestID).isEmpty)
    try await f.close(); try await other.close()
  }
  func testControllerFinalStopJoinsHeldOriginalCloudTaskAndRetainsSagaFacade() async throws {
    let f = try await deletionGuardFixture(healthIssue: .missingMapping), cloud = GateHeldCloud(), admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger)
    let controller = M4DeletionResumeController(admission: admission, cloudDeletion: cloud)
    let running = Task { try await controller.resume(requestID: f.saga.intent.requestID) }
    await cloud.waitForEntry()
    var stopping = false, done = false
    let stop = Task { stopping = true; await controller.stopAndJoin(); done = true }
    while !stopping { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(done, "final stop must join the original cancellation-insensitive control task")
    let pending = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(pending?.intent, f.saga.intent); XCTAssertEqual(pending?.recoveryCapability, f.saga.recoveryCapability)
    do { _ = try await controller.resume(requestID: f.saga.intent.requestID); XCTFail("stopped controller cannot admit a later resume") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    await cloud.release(); _ = await running.result; await stop.value
    let actual = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(actual?.cloudProgress, .completed); XCTAssertEqual(actual?.localProgress, .failed)
    XCTAssertEqual(actual?.intent, f.saga.intent); XCTAssertEqual(actual?.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    do { _ = try await controller.recover(); XCTFail("stopped automatic recovery is closed") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    try await f.close()
  }
  func testControllerFinalStopJoinsGenericReconcileOnSameOriginalRelay() async throws {
    let relay = GateHeldAuthorityRelay(), f = try await deletionGuardFixture(healthIssue: .missingMapping, acceptBackend: false, authorityRelay: relay, hasCredential: true)
    let admission = M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger), controller = M4DeletionResumeController(admission: admission)
    let running = Task { try await controller.reconcile(f.saga.intent) }
    await relay.waitForEntry()
    var stopping = false, done = false
    let stop = Task { stopping = true; await controller.stopAndJoin(); done = true }
    while !stopping { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(done, "generic reconciliation owns its same original HTTP operation until it returns")
    let current = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(current?.intent, f.saga.intent); XCTAssertFalse(current?.backendDeleted ?? true)
    do { _ = try await controller.reconcile(f.saga.intent); XCTFail("final stop closes generic control admission") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    await relay.release(); _ = await running.result; await stop.value
    let actual = try await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID), calls = await relay.calls
    XCTAssertEqual(calls, 1); XCTAssertEqual(actual?.intent, f.saga.intent); XCTAssertEqual(actual?.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertFalse(actual?.backendDeleted ?? true); XCTAssertEqual(try businessWitnessCount(f.database), 1)
    try await f.close()
  }
  func testPublicContextLeaseCloseFailurePreservesOriginalSagaAndRetriesSameOwner() async throws {
    let f = try await deletionGuardFixture(healthIssue: .missingMapping)
    let owner = f.prepared.seed.controlDirectory.appendingPathComponent("identity.owner"), retained = f.root.appendingPathComponent("original-identity-owner")
    try FileManager.default.moveItem(at: owner, to: retained); try Data("foreign-owner-preserved".utf8).write(to: owner)
    await f.composition.context.shutdown()
    XCTAssertNotNil(f.composition.lastCloseFailure, "Void API records typed failure instead of pretending the original owner closed")
    let retainedSaga = try? await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(retainedSaga?.intent, f.saga.intent); XCTAssertEqual(retainedSaga?.recoveryCapability, f.saga.recoveryCapability)
    do { try await f.composition.close(); XCTFail("throwing owner close exposes the same real lease-preflight refusal") }
    catch { XCTAssertEqual(error as? M4BootstrapError, .identityUnavailable) }
    let foreign = f.root.appendingPathComponent("foreign-owner-preserved")
    try FileManager.default.moveItem(at: owner, to: foreign); try FileManager.default.moveItem(at: retained, to: owner)
    try await f.composition.close(); XCTAssertNil(f.composition.lastCloseFailure)
    let prepared = try await M4IdentityBootstrap.prepare(root: f.prepared.seed.root, namespace: f.prepared.seed.namespace, controlDirectory: f.prepared.seed.controlDirectory) { _ in f.prepared.material }
    let reopened = try prepared.openRepository(authorityTrust: f.composition.client.trust)
    let saga = try await reopened.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(saga?.intent, f.saga.intent); XCTAssertEqual(saga?.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign-owner-preserved".utf8))
    try f.catalog.close(); try await f.ledger.close(); try await prepared.close()
  }
  func testCompositionFinalCloseJoinsRegisteredControlBeforeClosingOriginalDB() async throws {
    let f = try await deletionGuardFixture(healthIssue: .missingMapping), cloud = GateHeldCloud()
    let controller = M4DeletionResumeController(admission: M4DeletionAdmission(composition: f.composition, catalog: f.catalog, scope: f.scope, ledger: f.ledger), cloudDeletion: cloud)
    let operation = Task { try await controller.resume(requestID: f.saga.intent.requestID) }; await cloud.waitForEntry()
    var began = false, done = false
    let closing = Task { began = true; try await f.composition.close(); done = true }
    while !began { await Task.yield() }; try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(done, "the original control HTTP/client lifetime ends after its Saga task joins")
    let retained = try? await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(retained?.intent, f.saga.intent)
    await cloud.release(); _ = await operation.result; try await closing.value
    do { _ = try await controller.resume(requestID: f.saga.intent.requestID); XCTFail("owner final close permanently stops control admission") } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    try f.catalog.close(); try await f.ledger.close()
  }
  private struct GateFixture {
    let root: URL
    let composition: M4AccountComposition
    let prepared: M4PreparedIdentity
    let catalog: M4OwnedDataCatalog
    let ledger: SQLiteCloudLedger
    let scope: CloudScope
    let saga: DeletionSagaV4
    let database: URL
    var healthRaw: M4HealthRawReservation? = nil
    var healthArtifacts: M4RetainedHealthArtifactStore? = nil
    var healthLedger: SQLiteHealthDeletionLedger? = nil
    var controlledAdapters: M4ControlledAdapters? = nil
    var protocolRoot: URL? = nil
    func close() async throws {
      try await composition.close(); try catalog.close(); try await ledger.close()
      try await healthArtifacts?.close(); try await healthLedger?.close()
    }
  }
  private func deletionGuardFixture(healthIssue: M4HealthSelectionIssue?, sealParent: Bool = true, acceptBackend: Bool = true, additionalTransport: Bool = false, additionalStore: Bool = false, authorityRelay: (any AuthorityHTTPRelay)? = nil, hasCredential: Bool = false, extraStore: M4AccountComposition? = nil, completeHealth: Bool = false, lateGateway: GateHeldLinkedCapture? = nil, controlledClients: Bool = false, generationReplyGate: (@Sendable () async -> Void)? = nil) async throws -> GateFixture {
    let root = try root(), namespace = controlledClients ? "m4-ui-integration-phone" : "guard-fixture", key = Curve25519.Signing.PrivateKey()
    let trust = try AuthorityTrustConfiguration(environment: .development, publicKeys: ["guard-key": AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
    let prepared = try await M4IdentityBootstrap.prepare(root: root.appendingPathComponent("business"), namespace: namespace, controlDirectory: root.appendingPathComponent("identity-control")) { seed in
      let signer = try DevelopmentDeviceSigner(namespace: namespace, rawRepresentation: Data(repeating: 21, count: 32))
      let credential = hasCredential ? DeviceCredential(token: AuthorityWire.base64URL(Data(repeating: 5, count: 32)), sessionID: "guard-control-session", accountID: "account", deviceID: seed.installationID, keyID: try AuthorityWire.deviceKeyID(publicKey: signer.publicKey), activationEpoch: 2, expiresAt: 9_007_199_254_740_990) : nil
      return M4IdentityMaterial(signer: signer, vault: MemoryDeviceCredentialVault(credential))
    }
    var controlled: M4ControlledAdapters?, protocolRoot: URL?
    if controlledClients {
      #if DEBUG
      let directory = root.appendingPathComponent("protocol-clients"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let configuration = DevelopmentAuthorityConfiguration(dataset: "integration", namespace: namespace, baseURL: "http://127.0.0.1:1", keyID: "guard-key", publicKey: AuthorityWire.base64URL(key.publicKey.rawRepresentation), cloudSpaceID: "cloud", subject: "controlled-fixture", role: "phone")
      controlled = try M4ControlledAdapters.make(configuration: configuration, rootDirectory: directory, generationReplyGate: generationReplyGate); protocolRoot = directory
      #else
      throw M4LocalErasureError.unavailable
      #endif
    }
    let c = try await M4AccountComposition.make(prepared: prepared, trust: trust, cloudSpaceID: "cloud", authorityRelay: authorityRelay, workout: lateGateway, controlledAdapters: controlled)
    var retainedRaw: M4HealthRawReservation?
    if completeHealth {
      try await seedHealthCanonicalMatch(c, device: prepared.seed.installationID, id: "facts-original", linked: true)
      if lateGateway == nil { try await c.quiesceBusiness() }
      let inventory = try await c.repository.captureInventoryV4()
      retainedRaw = try M4HealthRawReservation(parentID: "guard-parent", scope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 2), cloud: .delete, local: .delete, health: .delete, healthConfirmed: true, createdAt: 10, confirmedAt: 11,
        facts: inventory.map { M4HealthCaptureFacts(binding: $0.binding, revisions: $0.captureRevisions, operations: $0.captureOperations) },
        sources: [M4HealthSourceEvidence(recordingDeviceID: prepared.seed.installationID, bundleID: "app.fixture.phone", platform: .iOS, origin: .controlledFixture, evidenceID: "original-control-source")])
      if let lateGateway {
        // Intentional stale-artifact regression: freeze before another original
        // writer's linked observation. This is not the valid production order.
        try await seedHealthCanonicalMatch(c, device: prepared.seed.installationID, id: "facts-late", linked: false)
        await c.context.recording.load(); await lateGateway.waitForEntry()
        // Complete the original unbound-development writer before binding the
        // account. Binding mid-capture would invalidate this seed's authority
        // provenance rather than exercise the retained selection comparison.
        let retiring = Task { try await c.quiesceBusiness() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2)); var retired = false
        while ContinuousClock.now < deadline {
          do { _ = try await c.session.prepareStart(starter: false) } catch { if error as? SessionError == .retired { retired = true; break } }
          try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(retired, "the same original Session gates before joining its held gateway")
        await lateGateway.release(); try await retiring.value
      }
    }
    try await c.repository.bindAccountV4(AccountBindingV4(accountID: "account", cloudSpaceID: "cloud", deviceID: prepared.seed.installationID, activationEpoch: 2, role: .phone, environment: .development))
    let scope = try scope(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog")), ledgerURL = root.appendingPathComponent("cloud-ledger.sqlite"), ledger = try SQLiteCloudLedger(url: ledgerURL)
    let database = prepared.seed.businessDatabaseURL
    try catalog.record(M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "guard-store", kind: .businessStore, scope: scope, root: database, retainedControls: []))
    try catalog.record(M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "guard-ledger", kind: .cloudLedger, scope: scope, root: ledgerURL, retainedControls: []))
    if additionalTransport {
      let (staged, capsule, _) = try staging(root, id: "retired-staging"); try staged.close(); try catalog.record(capsule); try catalog.retire(componentID: capsule.componentID)
      let directory = root.appendingPathComponent("DeviceSync"), context = try DeviceSyncStorageContext(root: directory)
      let device = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "owned-device", kind: .deviceSync, scope: scope, root: directory,
        retainedControls: [directory.appendingPathComponent(".control/.owner"), directory.appendingPathComponent(".control/control.sqlite")])
      try context.bind(device.deviceBinding()); try catalog.record(device)
      let oldURL = root.appendingPathComponent("retired-ledger.sqlite"), old = try SQLiteCloudLedger(url: oldURL)
      let oldScope = try CloudScope(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: 1)
      let record = try CloudRecord(scope: oldScope, payload: .deletion(CloudDeletion(matchID: "retired", deletionID: "retired", deletedAt: Date(timeIntervalSince1970: 10))))
      try await old.enqueue(CloudUpload(id: "retired-payload", scope: oldScope, record: record)); try await old.close()
      let capsuleOld = try M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "retired-ledger", kind: .cloudLedger, scope: oldScope, root: oldURL, retainedControls: [])
      try catalog.record(capsuleOld); try catalog.retire(componentID: capsuleOld.componentID)
    }
    if additionalStore {
      let extra = root.appendingPathComponent("unproven-store.sqlite"); try Data("unproven original Store without same-parent Saga".utf8).write(to: extra)
      try catalog.record(M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "unproven-store", kind: .businessStore, scope: scope, root: extra, retainedControls: []))
    }
    if let extraStore {
      let database = await extraStore.repository.databaseURL
      try catalog.record(M4OwnershipCapsule.capture(namespaceID: UUID().uuidString, componentID: "routed-extra-store", kind: .businessStore, scope: scope, root: database, retainedControls: []))
    }
    let health: ClientDeletionChoiceV4 = completeHealth || healthIssue != nil ? .delete : .keep
    let choices = M4DeletionChoices(cloud: .delete, local: .delete, health: health, healthConfirmed: health == .delete)
    var artifacts: M4RetainedHealthArtifactStore?, healthLedger: SQLiteHealthDeletionLedger?, healthBridge: M4HealthDeletionBridge?
    if let raw = retainedRaw {
      let store = try M4RetainedHealthArtifactStore(directory: root.appendingPathComponent("health-artifacts"), owner: M4HealthArtifactOwner(installationID: prepared.seed.installationID, namespace: namespace, scope: raw.scope), removableRoots: [prepared.seed.namespaceDirectory], fullSealProvider: { try catalog.healthFullSeal(parentID: $0) })
      let selection = try SQLiteHealthDeletionLedger(url: root.appendingPathComponent("health-selection/selection.sqlite"), businessDataDirectory: prepared.seed.namespaceDirectory)
      let bridge = M4HealthDeletionBridge(mapping: store, parents: c.repository, ledger: selection, allowedSourceOrigin: .controlledFixture, clock: { 12 })
      try await bridge.reserve(raw); artifacts = store; healthLedger = selection; healthBridge = bridge
    }
    _ = try catalog.reserve(requestID: "guard-parent", scope: scope, choices: choices, health: M4HealthReservation(selections: [], issue: healthIssue, rawArtifactDigest: try retainedRaw.map { try $0.digest() }))
    let capability = AuthorityWire.base64URL(Data(repeating: 7, count: 32)); var fields = AuthorityFields(); fields.reauthenticationID = "guard-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
    let saga = try DeletionSagaV4(intent: ControlIntentV1(requestID: "guard-parent", operation: .deleteAccount, fields: fields), accountID: scope.accountID, activationEpoch: scope.activationEpoch, recoveryCapability: capability, cloudChoice: choices.cloud, localChoice: choices.local, healthChoice: choices.health, healthConfirmed: choices.healthConfirmed, originalScope: CloudScopeV1(accountID: scope.accountID, cloudSpaceID: scope.cloudSpaceID, zoneID: scope.zoneID, activationEpoch: scope.activationEpoch))
    try await c.session.setAnalyticsEnabled(true)
    try await c.session.createDeletionSaga(saga)
    if sealParent { _ = try catalog.seal(requestID: saga.intent.requestID, parentIntentDigest: saga.intent.digest) }
    if let raw = retainedRaw, let bridge = healthBridge, let selection = healthLedger {
      let prepared = try await bridge.prepare(parentID: raw.parentID), entry = try await selection.entry(prepared.request.requestID)
      try catalog.sealFullControls(saga: saga, raw: raw, prepared: prepared, entry: entry)
    }
    let body: [String: Any] = ["version": 1, "environment": "development", "keyID": "guard-key", "receiptID": "guard-receipt", "requestID": saga.intent.requestID, "requestDigest": saga.intent.digest, "operation": "deleteAccount", "accountID": scope.accountID, "activationEpoch": scope.activationEpoch, "matchID": "", "lockID": "", "recordingDeviceID": "", "result": "deleted", "issuedAt": Int64(Date().timeIntervalSince1970), "deletion": ["backend": "backendDeleted", "apple": "revoked", "cloud": "clientManaged", "local": "clientManaged", "health": "separateConfirmation"]]
    let bodyBytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    let raw = try JSONSerialization.data(withJSONObject: ["body": body, "signature": AuthorityWire.base64URL(key.signature(for: AuthorityWire.signedInput("football-record.authority.receipt.v1", body: bodyBytes)))], options: [.sortedKeys, .withoutEscapingSlashes])
    let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(saga.intent, accountID: scope.accountID, epoch: scope.activationEpoch), trust: trust)
    let accepted: DeletionSagaV4
    if acceptBackend { accepted = try await c.session.acceptDeletion(requestID: saga.intent.requestID, receipt: receipt, expectedRevision: 0) }
    else { accepted = saga }
    var sql: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &sql), SQLITE_OK); defer { sqlite3_close(sql) }
    let witness = try M4CatalogIO.encode("original-business-witness"), hex = witness.map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(sqlite3_exec(sql, "INSERT INTO lifecycle_steps_v4 VALUES('normal-intent:guard-witness',X'" + hex + "','" + M4CatalogIO.hash(witness) + "')", nil, nil, nil), SQLITE_OK)
    var result = GateFixture(root: root, composition: c, prepared: prepared, catalog: catalog, ledger: ledger, scope: scope, saga: accepted, database: database)
    result.healthRaw = retainedRaw; result.healthArtifacts = artifacts; result.healthLedger = healthLedger
    result.controlledAdapters = controlled; result.protocolRoot = protocolRoot
    return result
  }
  func testControlledQuiescenceJoinsOriginalAppleButKeepsParentCloudClientOpen() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, controlledClients: true), adapters = try XCTUnwrap(f.controlledAdapters), root = try XCTUnwrap(f.protocolRoot)
    let authorization = Task { try await adapters.authorize(nonceSHA256: AuthorityWire.hash(Data("original-nonce".utf8))) }
    let pending = try await protocolRequest(root, operation: "apple")
    try await f.composition.quiesceBusiness()
    var drained = false
    do { try await adapters.assertDrained(scope: f.scope, requestID: f.saga.intent.requestID, parentIntentDigest: f.saga.intent.digest); drained = true }
    catch { XCTFail("composition quiesce did not join original protocol operations: \(error)") }
    // Old unwired ownership is released by the fixture, preserving a runtime
    // RED rather than waiting a mailbox timeout. Green uses actual cancellation.
    if !drained { try protocolReply(pending, payload: JSONSerialization.data(withJSONObject: ["identityToken": "late-token", "authorizationCode": "late-code"])) }
    do { _ = try await authorization.value; XCTFail("a quiesced original Apple result cannot escape") } catch {}
    // This is the original client and exact parent, still open for Saga control.
    let driver = adapters.deletionDriver(parentID: f.saga.intent.requestID, parentIntentDigest: f.saga.intent.digest, scope: f.scope)
    let cloud = Task { try await driver.deletePrivateZone(scope: f.scope) }
    let deletion = try await protocolRequest(root, operation: "cloud-delete")
    XCTAssertEqual(try JSONDecoder().decode(CloudScope.self, from: deletion.payload), f.scope)
    try protocolReply(deletion, payload: Data()); try await cloud.value
    do { try await adapters.assertDrained(scope: f.scope, requestID: f.saga.intent.requestID, parentIntentDigest: f.saga.intent.digest) }
    catch { XCTFail("original control completion must leave a readable drain state: \(error)") }
    do { try await adapters.assertDrained(scope: f.scope, requestID: "foreign-parent", parentIntentDigest: f.saga.intent.digest); XCTFail("a foreign parent cannot borrow original mailbox zero") } catch { XCTAssertEqual(error as? M4LocalErasureError, .intentMismatch) }
    try await f.close()
  }
  func testCompletedAppleResultCannotCrossStoppedSecondGenerationReply() async throws { try await completedBusinessReply(cloud: false) }
  func testCompletedCloudResultCannotCrossStoppedSecondGenerationReply() async throws { try await completedBusinessReply(cloud: true) }
  private func completedBusinessReply(cloud: Bool) async throws {
    let gate = M4SecondGenerationReplyGate(), f = try await deletionGuardFixture(healthIssue: nil, controlledClients: true, generationReplyGate: { await gate.pause() })
    let adapters = try XCTUnwrap(f.controlledAdapters), root = try XCTUnwrap(f.protocolRoot)
    let originalIdentity = await f.composition.repository.syncRepositoryIdentity(), generation = try await f.composition.repository.identityGenerationV4()
    let call = Task {
      if cloud {
        let record = try CloudRecord(scope: f.scope, payload: .deletion(CloudDeletion(matchID: "original-match", deletionID: "original-delete", deletedAt: Date(timeIntervalSince1970: 10))))
        _ = try await adapters.save(CloudUpload(id: "original-upload", scope: f.scope, record: record))
      } else { _ = try await adapters.authorize(nonceSHA256: AuthorityWire.hash(Data("original-nonce".utf8))) }
    }
    let pending = try await protocolRequest(root, operation: cloud ? "cloud-save" : "apple")
    try protocolReply(pending, payload: cloud ? pending.payload : JSONSerialization.data(withJSONObject: ["identityToken": "completed-token", "authorizationCode": "completed-code"]))
    // Real work has completed. Hold only the reply from the original second
    // repository read; the fixture cannot manufacture its generation/identity.
    await gate.waitForReply()
    let quiesce = Task { try await f.composition.quiesceBusiness() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2)); var stopped = false
    while ContinuousClock.now < deadline {
      if await adapters.businessAdmissionClosed { stopped = true; break }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(stopped)
    await gate.release()
    do { try await call.value; XCTFail("completed original business result cannot escape a stop established during generation-read await") }
    catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
    try await quiesce.value
    let actualIdentity = await f.composition.repository.syncRepositoryIdentity(), actualGeneration = try await f.composition.repository.identityGenerationV4()
    XCTAssertEqual(actualIdentity, originalIdentity); XCTAssertEqual(actualGeneration, generation)
    try await f.close()
  }
  func testControlledFinalCloseUndrainedPreservesOriginalDBAndLeaseForRetry() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, controlledClients: true), root = try XCTUnwrap(f.protocolRoot), adapters = try XCTUnwrap(f.controlledAdapters)
    try await f.composition.quiesceBusiness()
    let file = root.appendingPathComponent("development/mailbox/incoming/fixture-foreign"), bytes = Data([0,255,7]); try bytes.write(to: file)
    do { try await adapters.assertDrained(scope: f.scope, requestID: f.saga.intent.requestID, parentIntentDigest: f.saga.intent.digest); XCTFail("unknown mailbox payload cannot authorize local erasure") } catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
    do { try await f.composition.close(); XCTFail("undrained client final close must preserve the original DB") } catch { XCTAssertEqual(error as? M4LocalErasureError, .pendingTransfer) }
    let retained = try? await f.composition.repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(retained?.intent, f.saga.intent); XCTAssertEqual(retained?.recoveryCapability, f.saga.recoveryCapability)
    XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertNotNil(f.composition.lastCloseFailure)
    do { _ = try await M4IdentityBootstrap.prepare(root: f.prepared.seed.root, namespace: f.prepared.seed.namespace, controlDirectory: f.prepared.seed.controlDirectory) { _ in f.prepared.material }; XCTFail("failed final close retains original identity lease") } catch { XCTAssertEqual(error as? M4BootstrapError, .leaseInUse) }
    // Only this fixture removes its own exact byte-matched test file.
    try FileManager.default.removeItem(at: file)
    try await f.composition.close(); XCTAssertNil(f.composition.lastCloseFailure)
    let prepared = try await M4IdentityBootstrap.prepare(root: f.prepared.seed.root, namespace: f.prepared.seed.namespace, controlDirectory: f.prepared.seed.controlDirectory) { _ in f.prepared.material }
    let repository = try prepared.openRepository(authorityTrust: f.composition.client.trust), original = try await repository.deletionSagaV4(requestID: f.saga.intent.requestID)
    XCTAssertEqual(original?.intent, f.saga.intent); XCTAssertEqual(original?.recoveryCapability, f.saga.recoveryCapability)
    try await prepared.close(); try f.catalog.close(); try await f.ledger.close()
  }
  private struct ProtocolRequest {
    let response: URL
    let payload: Data
  }
  private func protocolRequest(_ root: URL, operation: String) async throws -> ProtocolRequest {
    let directory = root.appendingPathComponent("development/mailbox/outgoing"), deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], value["operation"] as? String == operation,
              let id = value["id"] as? String, let base64 = value["payload"] as? String, let payload = Data(base64Encoded: base64) else { continue }
        return ProtocolRequest(response: root.appendingPathComponent("development/mailbox/responses/" + id + ".json"), payload: payload)
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw M4LocalErasureError.unavailable
  }
  private func protocolReply(_ request: ProtocolRequest, payload: Data) throws {
    try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString()], options: [.sortedKeys]).write(to: request.response, options: .atomic)
  }
  private func seedHealthCanonicalMatch(_ c: M4AccountComposition, device: String, id: String, linked: Bool) async throws {
    // Public canonical StoreCommit fixture on this one original M4 facade,
    // before account binding. It is not authenticated account capture or E2E.
    let date = Date(timeIntervalSince1970: 20), intent = StartIntent(id: id + "/intent", matchID: id, recordingDeviceID: device, requestedAt: date)
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: intent.id, expectedGeneration: 0, descriptor: MatchDescriptor(startIntent: intent, starter: true), events: [], captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [], businessOutbox: []))
    let descriptor = MatchDescriptor(startIntent: intent, starter: true, startPermit: DevelopmentStartFixture.permit(for: intent), backendLockState: .held)
    var recorder = LiveMatchRecorder(descriptor: descriptor); try recorder.start(eventID: id + "/event", sourceDeviceID: device, now: date)
    if linked { try recorder.transition(.matchEnded, eventID: id + "/end", sourceDeviceID: device, now: date.addingTimeInterval(1)) }
    let binding = try CaptureBinding(matchID: id, recordingDeviceID: device), command = id + "/start", token = id + "/capture/start"
    let operation = try CaptureOperation(id: token, binding: binding, associatedCommandID: command, action: .start, requestedAt: date, externalToken: token)
    let delta = try BusinessOutboxItem(id: id + "/delta", matchID: id, sourceDeviceID: device, payload: BusinessDeltaV2(descriptor: descriptor, events: recorder.events, captureRevisions: []))
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: command, expectedGeneration: 1, descriptor: descriptor, events: recorder.events, captureRevisions: [], newCaptureOperations: [operation], captureOperationUpdates: [], businessOutbox: [delta]))
    guard linked else { return }
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: id + "/dispatch", expectedGeneration: 2, descriptor: descriptor, events: [], captureRevisions: [], newCaptureOperations: [], captureOperationUpdates: [CaptureOperationUpdate(operationID: token, expectedState: .pending, state: .needsReconciliation, observation: nil)], businessOutbox: []))
    let window = try CaptureWindow(start: date, end: date.addingTimeInterval(1)), workout = UUID().uuidString
    let observation = try WorkoutObservation(operationID: token, binding: binding, externalToken: token, observedAt: date.addingTimeInterval(1), outcome: .linked(workoutID: workout), window: window)
    let segment = try CaptureSegment(id: token + "/segment", binding: binding, workoutID: workout, window: window)
    let revision = try CaptureRevision(id: id + "/revision", binding: binding, parentID: nil, revision: 1, observedAt: observation.observedAt, metadata: CaptureMetadata(binding: binding, segments: [segment], gaps: []))
    let revisionDelta = try BusinessOutboxItem(id: id + "/revision-delta", matchID: id, sourceDeviceID: device, payload: BusinessDeltaV2(descriptor: descriptor, events: [], captureRevisions: [revision]))
    _ = try await c.repository.commitV2(StoreCommitV2(commandID: id + "/observe", expectedGeneration: 3, descriptor: descriptor, events: [], captureRevisions: [revision], newCaptureOperations: [], captureOperationUpdates: [CaptureOperationUpdate(operationID: token, expectedState: .needsReconciliation, state: .settled, observation: observation)], businessOutbox: [revisionDelta]))
  }
  func testFullHealthInventoryAllowsFirstStoreEraseAndReplaysOriginalRawAfterErasure() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, completeHealth: true), admission = controlledAggregateAdmission(f), cloud = GateControlledCloud()
    let raw = try XCTUnwrap(f.healthRaw), originalBytes = try raw.canonicalBytes()
    let before = try await f.composition.repository.captureInventoryV4(); XCTAssertEqual(before.count, 1)
    let controller = M4DeletionResumeController(admission: admission, cloudDeletion: cloud)
    let result = try await controller.resume(requestID: f.saga.intent.requestID)
    XCTAssertEqual(result.cloudProgress, .completed); XCTAssertEqual(result.localProgress, .completed); XCTAssertEqual(result.localTransportProgress, .completed)
    XCTAssertEqual(try businessWitnessCount(f.database), 0)
    let after = try await f.composition.repository.captureInventoryV4(); XCTAssertTrue(after.isEmpty)
    let retry = try await controller.resume(requestID: f.saga.intent.requestID)
    XCTAssertEqual(retry.localProgress, .completed); XCTAssertEqual(retry.localTransportProgress, .completed)
    let actualRaw = try await f.healthArtifacts?.readReservation(parentID: raw.parentID)
    XCTAssertEqual(try actualRaw?.canonicalBytes(), originalBytes, "empty erased Store must never replace the retained original selection")
    let firstReceipts = try M4CatalogIO.encode(f.catalog.receipts(requestID: raw.parentID))
    try await f.close()
    // Real close/reopen of original controls and DB; never a parallel facade.
    let prepared = try await M4IdentityBootstrap.prepare(root: f.prepared.seed.root, namespace: f.prepared.seed.namespace, controlDirectory: f.prepared.seed.controlDirectory) { _ in f.prepared.material }
    let composition = try await M4AccountComposition.make(prepared: prepared, trust: f.composition.client.trust, cloudSpaceID: f.scope.cloudSpaceID)
    let catalog = try M4OwnedDataCatalog(directory: f.root.appendingPathComponent("catalog")), ledger = try SQLiteCloudLedger(url: f.root.appendingPathComponent("cloud-ledger.sqlite"))
    let artifacts = try M4RetainedHealthArtifactStore(directory: f.root.appendingPathComponent("health-artifacts"), owner: M4HealthArtifactOwner(installationID: prepared.seed.installationID, namespace: prepared.seed.namespace, scope: raw.scope), removableRoots: [prepared.seed.namespaceDirectory], fullSealProvider: { try catalog.healthFullSeal(parentID: $0) })
    let selection = try SQLiteHealthDeletionLedger(url: f.root.appendingPathComponent("health-selection/selection.sqlite"), businessDataDirectory: prepared.seed.namespaceDirectory)
    var reopened = GateFixture(root: f.root, composition: composition, prepared: prepared, catalog: catalog, ledger: ledger, scope: f.scope, saga: result, database: f.database)
    reopened.healthRaw = raw; reopened.healthArtifacts = artifacts; reopened.healthLedger = selection
    let resumed = try await M4DeletionResumeController(admission: controlledAggregateAdmission(reopened), cloudDeletion: cloud).resume(requestID: raw.parentID)
    XCTAssertEqual(resumed.intent, result.intent); XCTAssertEqual(resumed.localProgress, .completed); XCTAssertEqual(resumed.localTransportProgress, .completed)
    XCTAssertEqual(try M4CatalogIO.encode(catalog.receipts(requestID: raw.parentID)), firstReceipts)
    let reopenedRaw = try await artifacts.readReservation(parentID: raw.parentID); XCTAssertEqual(try reopenedRaw?.canonicalBytes(), originalBytes)
    try await reopened.close()
  }
  func testStaleHealthRawBeforeHeldLinkedObservationPreservesStoreAndIndependentCloud() async throws {
    let gateway = GateHeldLinkedCapture(), f = try await deletionGuardFixture(healthIssue: nil, completeHealth: true, lateGateway: gateway)
    let admission = controlledAggregateAdmission(f), raw = try XCTUnwrap(f.healthRaw), bytes = try raw.canonicalBytes(), cloud = GateControlledCloud()
    // The fixture froze raw, held the original gateway, established the real
    // original Session gate, then released/joined its linked observation before
    // binding the account and sealing this same parent. Selection is now stale.
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    let controller = M4DeletionResumeController(admission: admission, cloudDeletion: cloud)
    _ = try await controller.resume(requestID: f.saga.intent.requestID)
    let actual = try await f.composition.repository.deletionSagaV4(requestID: raw.parentID)
    XCTAssertEqual(actual?.cloudProgress, .completed); XCTAssertEqual(actual?.localProgress, .failed)
    XCTAssertNotEqual(actual?.localTransportProgress, .completed); XCTAssertEqual(try businessWitnessCount(f.database), 1)
    let inventory = try await f.composition.repository.captureInventoryV4(); XCTAssertEqual(inventory.count, 2)
    XCTAssertTrue(inventory.contains { $0.captureOperations.contains { if case .linked = $0.observation?.outcome { true } else { false } } && $0.binding.matchID == "facts-late" })
    do { _ = try await admission.localErase(requestID: raw.parentID); XCTFail("old immutable raw cannot omit the joined original linked fact") }
    catch { XCTAssertEqual(error as? M4HealthBridgeError, .identityConflict) }
    let actualRaw = try await f.healthArtifacts?.readReservation(parentID: raw.parentID); XCTAssertEqual(try actualRaw?.canonicalBytes(), bytes)
    XCTAssertTrue(try f.catalog.receipts(requestID: raw.parentID).isEmpty); try await f.close()
  }
  func testFullHealthInventoryRejectsCanonicalOrphanBeforeFirstErase() async throws {
    let f = try await deletionGuardFixture(healthIssue: nil, completeHealth: true), admission = controlledAggregateAdmission(f)
    try executeSQL(f.database, "DELETE FROM matches WHERE match_id='facts-original'")
    let oldIDs = try await f.composition.repository.matchIDs(); XCTAssertTrue(oldIDs.isEmpty)
    let rawBytes = try XCTUnwrap(f.healthRaw).canonicalBytes()
    do { _ = try await admission.localErase(requestID: f.saga.intent.requestID); XCTFail("an orphan invisible to matchIDs must block first Store erase") }
    catch { XCTAssertTrue(error is StoreError, "must surface the actual complete046 inventory failure, got \(error)") }
    XCTAssertEqual(try businessWitnessCount(f.database), 1)
    let retained = try await f.healthArtifacts?.readReservation(parentID: f.saga.intent.requestID); XCTAssertEqual(try retained?.canonicalBytes(), rawBytes)
    XCTAssertTrue(try f.catalog.receipts(requestID: f.saga.intent.requestID).isEmpty); try await f.close()
  }
  private func businessWitnessCount(_ database: URL) throws -> Int {
    var sql: OpaquePointer?, query: OpaquePointer?; guard sqlite3_open_v2(database.path, &sql, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }; defer { sqlite3_close(sql) }
    guard sqlite3_prepare_v2(sql, "SELECT count(*) FROM lifecycle_steps_v4 WHERE id='normal-intent:guard-witness'", -1, &query, nil) == SQLITE_OK else { throw M4CatalogError.storageBlocked }; defer { sqlite3_finalize(query) }
    guard sqlite3_step(query) == SQLITE_ROW else { throw M4CatalogError.storageBlocked }; return Int(sqlite3_column_int(query, 0))
  }
  private func healthSaga(_ raw: M4HealthRawReservation) throws -> DeletionSagaV4 {
    let capability = AuthorityWire.base64URL(Data(repeating: 7, count: 32)); var fields = AuthorityFields(); fields.reauthenticationID = "reauth-original"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(capability.utf8))
    return try DeletionSagaV4(intent: ControlIntentV1(requestID: raw.parentID, operation: .deleteAccount, fields: fields), accountID: raw.scope.accountID, activationEpoch: raw.scope.activationEpoch, recoveryCapability: capability, cloudChoice: raw.cloud, localChoice: raw.local, healthChoice: raw.health, healthConfirmed: raw.healthConfirmed, originalScope: raw.scope)
  }
  private func rawHealthReservation() throws -> M4HealthRawReservation {
    let binding = try CaptureBinding(matchID: "match-original", recordingDeviceID: "watch-original"), date = Date(timeIntervalSince1970: 10), token = "raw-capture-token-kept-out-of-catalog"
    let operation = try CaptureOperation(id: token, binding: binding, associatedCommandID: "command-original", action: .start, requestedAt: date, externalToken: token)
    let window = try CaptureWindow(start: date, end: date.addingTimeInterval(1)), workout = UUID().uuidString
    let observation = try WorkoutObservation(operationID: token, binding: binding, externalToken: token, observedAt: date, outcome: .linked(workoutID: workout), window: window)
    let segment = try CaptureSegment(id: "opaque-original-segment", binding: binding, workoutID: workout, window: window)
    let revision = try CaptureRevision(id: "revision-original", binding: binding, parentID: nil, revision: 1, observedAt: date, metadata: CaptureMetadata(binding: binding, segments: [segment], gaps: []))
    let facts = M4HealthCaptureFacts(binding: binding, revisions: [revision], operations: [try CaptureOperationRecord(operation: operation, state: .settled, observation: observation)])
    return try M4HealthRawReservation(parentID: "original-parent", scope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "zone", activationEpoch: 2), cloud: .keep, local: .delete, health: .delete, healthConfirmed: true, createdAt: 10, confirmedAt: 11, facts: [facts], sources: [M4HealthSourceEvidence(recordingDeviceID: "watch-original", bundleID: "app.fixture.watch", platform: .watchOS, origin: .controlledFixture, evidenceID: "controlled-source")])
  }
  func testWrongOriginalParentOrDigestPreservesJournalAndLeaf() async throws {
    let root = try root(), catalog = try M4OwnedDataCatalog(directory: root.appendingPathComponent("catalog"))
    let (staging, capsule, control) = try staging(root), plan = try seal(catalog, capsules: [capsule]); try staging.close()
    let before = try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), leaves = M4LocalTransportLeaves(catalog: catalog, stagingControls: [capsule.componentID: control])
    for (parent, digest) in [("foreign", try XCTUnwrap(plan.parentIntentDigest)), (plan.requestID, String(repeating: "f", count: 64))] {
      do { _ = try await leaves.erase(componentID: capsule.componentID, parentID: parent, parentIntentDigest: digest); XCTFail("original intent required") }
      catch { XCTAssertEqual(error as? M4LocalErasureError, .intentMismatch) }
    }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog/catalog.json")), before)
    XCTAssertTrue(try catalog.receipts(requestID: plan.requestID).isEmpty); try catalog.close()
  }
}
private struct LocalControlledDrain: DeviceSyncErasureDriving {
  func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { .drained }
}

private actor LocalCountingDrain: DeviceSyncErasureDriving {
  private(set) var calls = 0
  func quiesceForErasure(_ request: DeviceSyncLocalEraseRequest, expected: [DeviceSyncTransferIdentity]) async throws -> DeviceSyncDrainStatus { calls += 1; return .drained }
}

private actor GateControlledCloud: CloudAccountDeletionDriver {
  private(set) var calls = 0
  func deletePrivateZone(scope: CloudScope) async throws { calls += 1 }
}

private struct GateControlledCopyDrain: M4LocalCopyDrainChecking {
  let scope: CloudScope
  let parent, digest: String
  func assertDrained(scope: CloudScope, requestID: String, parentIntentDigest: String) async throws {
    guard scope == self.scope, requestID.utf8.elementsEqual(parent.utf8), parentIntentDigest == digest else { throw M4LocalErasureError.intentMismatch }
  }
}

private actor GateHeldCloud: CloudAccountDeletionDriver {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
  func deletePrivateZone(scope: CloudScope) async throws {
    entered = true
    await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
  }
  func release() { held?.resume(); held = nil }
}
private actor GateHeldAuthorityRelay: AuthorityHTTPRelay {
  private(set) var calls = 0
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
  func send(_ request: AuthorityHTTPRequest) async throws -> AuthorityHTTPResponse {
    calls += 1; entered = true
    await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
    throw URLError(.networkConnectionLost)
  }
  func release() { held?.resume(); held = nil }
}

private actor GateHeldLinkedCapture: WorkoutGateway {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func waitForEntry() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    entered = true
    await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
    return try! WorkoutObservation(operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken, observedAt: operation.requestedAt.addingTimeInterval(2), outcome: .linked(workoutID: UUID().uuidString), window: CaptureWindow(start: operation.requestedAt, end: operation.requestedAt.addingTimeInterval(2)))
  }
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation { await perform(operation) }
  func release() { held?.resume(); held = nil }
}

private actor M4SecondGenerationReplyGate {
  private var reads = 0, entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var held: CheckedContinuation<Void, Never>?
  func pause() async {
    reads += 1
    guard reads == 2 else { return }
    await withCheckedContinuation { held = $0; entered = true; waiter?.resume(); waiter = nil }
  }
  func waitForReply() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
  func release() { held?.resume(); held = nil }
}
