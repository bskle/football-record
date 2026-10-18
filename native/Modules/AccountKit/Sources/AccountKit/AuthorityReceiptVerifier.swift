import Foundation
import MatchStore
public struct AuthorityReceiptVerifier: Sendable {
 public let trust:AuthorityTrustConfiguration
 public init(trust:AuthorityTrustConfiguration) { self.trust=trust }
 public func verify(_ bytes:Data,expected:AuthorityExpectedIntent) throws -> VerifiedAuthorityReceiptV1 { try VerifiedAuthorityReceiptV1.verify(bytes,expected:expected,trust:trust) }
}
