import Foundation
import XCTest
import MatchStore
import MatchSession
@testable import MatchPresentation

@MainActor final class LifecycleStatusTests: XCTestCase {
  func testFreshRealStoreDefaultsAnalyticsOffAndReadErrorIsUnknown() async throws {
    let repo = try accountRepository("lifecycle-read")
    let model = LifecycleStatusModel(repository: repo)
    await model.refresh()
    XCTAssertEqual(model.analyticsEnabled, false)
    XCTAssertTrue(model.deletions.isEmpty)
    try await repo.close(); await model.refresh()
    XCTAssertNil(model.analyticsEnabled)
    XCTAssertNotNil(model.issue)
    XCTAssertNil(model.cloudSaved)
  }
  func testFourDeletionGroupsAggregateBothLocalComponents() throws {
    var fields = AuthorityFields(); fields.reauthenticationID = "fresh-reauth"; fields.recoveryCapabilityDigest = AuthorityWire.hash(Data(AuthorityWire.base64URL(Data(repeating: 3, count: 32)).utf8))
    let intent = try ControlIntentV1(requestID: "delete-original", operation: .deleteAccount, fields: fields)
    var saga = try DeletionSagaV4(intent: intent, accountID: "account", activationEpoch: 1, recoveryCapability: AuthorityWire.base64URL(Data(repeating: 3, count: 32)), cloudChoice: .keep, localChoice: .delete, healthChoice: .keep, healthConfirmed: false, originalScope: CloudScopeV1(accountID: "account", cloudSpaceID: "cloud", zoneID: "matches", activationEpoch: 1))
    saga.backendDeleted = true; saga.localProgress = .completed; saga.localTransportProgress = .failed
    let rows = LifecycleStatusModel.deletionRows(saga)
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows[2].progress, .failed)
    XCTAssertFalse(saga.finished)
    saga.localTransportProgress = .completed
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[2].progress, .completed)
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[1].progress, .retained)
    XCTAssertEqual(LifecycleStatusModel.deletionRows(saga)[3].progress, .retained)
    XCTAssertTrue(saga.finished)
  }
}
