import Foundation
import XCTest
import CryptoKit
import MatchCore
import MatchStore
@testable import MatchSession
final class AuthoritySessionTests: XCTestCase, @unchecked Sendable {
    func testBoundSessionCannotStartFromDevelopmentPermitWithoutFreshAuthority() async throws {
        let key=Curve25519.Signing.PrivateKey(),trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:["test":AuthorityWire.base64URL(key.publicKey.rawRepresentation)])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo=try SQLiteSessionRepository(rootDirectory:root,databaseNamespace:"authority-session",authorityTrust:trust)
        try await repo.bindAccountV4(AccountBindingV4(accountID:"account",cloudSpaceID:"cloud",deviceID:"watch",activationEpoch:1,role:.watch,environment:.development))
        let gateway=FakeGateway(),session=MatchSession(store:repo,deviceIdentity:Identity(value:"watch"),clock:TestClock(),ids:TestIDs(),permits:DevelopmentStartPermitProvider(),workout:gateway,environment:.development(databaseNamespace:"authority-session"))
        let request=try await session.prepareStart(starter:true)
        do { _ = try await session.execute(request); XCTFail("a fixture must not bypass a bound authority") } catch {}
        let s=try await repo.snapshotV2(matchID:request.matchID);XCTAssertTrue(s.business.events.isEmpty)
        try await repo.close()
    }
}
