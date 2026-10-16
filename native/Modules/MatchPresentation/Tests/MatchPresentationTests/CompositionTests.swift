import Foundation
import XCTest
import MatchCore
import MatchStore
import MatchSession
import MatchSync
import MatchPresentation

@MainActor final class CompositionTests: XCTestCase {
  func testPublicCompositionKeepsOneFacadeAndUnavailableProductionPermit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let composition = try AppBootstrap.composition(rootDirectory: root)
    let repositoryID = await composition.repository.syncRepositoryIdentity()
    let sessionID = await composition.session.syncRepositoryIdentity()
    XCTAssertEqual(repositoryID, sessionID)
    try await composition.sync.start()
    await composition.model.load(); await composition.model.start(starter: true)
    XCTAssertNotNil(composition.model.pendingRequest)
    XCTAssertEqual(composition.model.feedbackCount, 0)
    let ids = try await composition.repository.matchIDs()
    XCTAssertEqual(ids, [try XCTUnwrap(composition.model.pendingRequest?.matchID)])
    await composition.model.shutdown()
  }
  func testPublicDevelopmentCompositionUsesCommittedFacadeWithoutSecondSession() async throws {
    let composition = try AppBootstrap.composition(databaseNamespace: "composition-test", development: true, rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    await composition.model.load(); await composition.model.start(starter: false)
    let snapshot = try XCTUnwrap(composition.model.snapshot)
    let same = try await composition.session.snapshot(matchID: snapshot.replay.matchID)
    let stored = try await composition.repository.snapshotV2(matchID: snapshot.replay.matchID)
    XCTAssertEqual(same.replay.matchID, snapshot.replay.matchID)
    XCTAssertEqual(stored.business.events, snapshot.store.business.events)
    let repositoryID = await composition.repository.syncRepositoryIdentity(), sessionID = await composition.session.syncRepositoryIdentity()
    XCTAssertEqual(repositoryID, sessionID)
    await composition.model.shutdown()
  }
}
