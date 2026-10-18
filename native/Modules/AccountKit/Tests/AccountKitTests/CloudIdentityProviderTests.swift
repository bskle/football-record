import XCTest
import Foundation
import MatchStore
import CloudSync
@testable import AccountKit

final class ManualCloudIdentity: CloudIdentityTransport, @unchecked Sendable {
    var onStart: (@Sendable () -> Void)?
    let lock=NSLock()
    private var callback: (@Sendable (Result<String,CloudIdentityError>) -> Void)?
    func currentUser(_ completion: @escaping @Sendable (Result<String,CloudIdentityError>) -> Void) { lock.withLock {callback=completion};onStart?() }
    func reply(_ value: Result<String,CloudIdentityError>) { let c=lock.withLock {callback};c?(value) }
}
final class CloudIdentityProviderTests: XCTestCase, @unchecked Sendable {
    func identity(container: String="iCloud.fixture", user: String="user", environment: AuthorityEnvironment = .production) async throws -> CloudIdentitySnapshot {
        let d=ManualCloudIdentity(), p=try CloudIdentityProvider(containerIdentifier:container,environment:environment,transport:d),started=expectation(description:"identity")
        d.onStart={started.fulfill()};let task=Task {try await p.currentIdentity()}
        await fulfillment(of:[started],timeout:1);d.reply(.success(user));return try await task.value
    }
    func testStableOpaqueIdentityIsBoundToContainerEnvironmentAndOriginalUserBytes() async throws {
        let a=try await identity(), b=try await identity(), c=try await identity(container:"iCloud.other"), d=try await identity(environment:.development), e=try await identity(user:"other")
        XCTAssertEqual(a,b);XCTAssertNotEqual(a,c);XCTAssertNotEqual(a,d);XCTAssertNotEqual(a,e)
        XCTAssertFalse(a.cloudSpaceID.contains("user"));XCTAssertNotEqual(try a.zoneID(accountID:"account"),try a.zoneID(accountID:"other"))
    }
    func testIdentityChangeFencesCallbackBeforeItCanAdmitNewSpace() async throws {
        let d=ManualCloudIdentity(), p=try CloudIdentityProvider(containerIdentifier:"iCloud.fixture",environment:.production,transport:d),started=expectation(description:"identity")
        d.onStart={started.fulfill()};let task=Task {try await p.currentIdentity()}
        await fulfillment(of:[started],timeout:1);try p.advanceIdentityFence(to:1);d.reply(.success("late"))
        do {_=try await task.value;XCTFail()}catch{}
        XCTAssertThrowsError(try p.advanceIdentityFence(to:0))
    }
    func testUnavailableEmptyOrDisabledIdentityIsNeverAnEmptyCloud() async throws {
        let p=try CloudIdentityProvider(containerIdentifier:"iCloud.fixture",environment:.production)
        do {_=try await p.currentIdentity();XCTFail()}catch{}
        do {_=try await identity(user:"");XCTFail()}catch{}
    }
    func testPublicCloudKitZoneConfigurationMatchesIdentityProvider() async throws {
        let snapshot=try await identity(),configuration=try CloudKitDriverConfiguration(containerIdentifier:"iCloud.fixture",environment:.production)
        XCTAssertEqual(try snapshot.zoneID(accountID:"account"),try configuration.zoneID(accountID:"account",cloudSpaceID:snapshot.cloudSpaceID))
    }

}
