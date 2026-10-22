import Foundation
import MatchStore
public protocol AccountLifecycleCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func resolveTerminalAuthentication(requestID:String,resolution:AuthResolutionV4,expectedIdentityGeneration:Int64) async throws->Int64?
    func resolveAuthAttempt(requestID:String,resolution:AuthResolutionV4) async throws
    func saveAuthAttempt(_ attempt:AuthAttemptV4,expectedIdentityGeneration:Int64) async throws
    func acceptAuthentication(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64) async throws
}
extension MatchSession:AccountLifecycleCoordinator {
    public func resolveTerminalAuthentication(requestID:String,resolution:AuthResolutionV4,expectedIdentityGeneration:Int64) async throws->Int64? {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any AccountLifecycleRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")}
        return try await repository.resolveTerminalAuthenticationV4(requestID:requestID,resolution:resolution,expectedIdentityGeneration:expectedIdentityGeneration)
    }
    public func resolveAuthAttempt(requestID:String,resolution:AuthResolutionV4) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any AccountLifecycleRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};try await repository.resolveAuthAttemptV4(requestID:requestID,resolution:resolution)
    }
    public func saveAuthAttempt(_ attempt:AuthAttemptV4,expectedIdentityGeneration:Int64) async throws {
        try beginBusiness();defer {endBusiness()}
        try await validateEnvironment(allowSuspendedRead:true);try requireBusinessActive();guard let repository=store as? any AccountLifecycleRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};try requireBusinessActive();try await repository.saveAuthAttemptV4(attempt,expectedIdentityGeneration:expectedIdentityGeneration)
    }
    public func acceptAuthentication(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64) async throws {
        try beginBusiness();defer {endBusiness()}
        try await validateEnvironment(allowSuspendedRead:true);try requireBusinessActive();guard let repository=store as? any AccountLifecycleRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};try requireBusinessActive();try await repository.acceptAuthenticationV4(attempt:attempt,binding:binding,receipt:receipt,expectedIdentityGeneration:expectedIdentityGeneration)
    }
}
extension SQLiteSessionRepository:AccountLifecycleRepository {
    public func resolveTerminalAuthenticationV4(requestID:String,resolution:AuthResolutionV4,expectedIdentityGeneration:Int64) async throws->Int64? {try await store.resolveTerminalAuthenticationV4(requestID:requestID,resolution:resolution,expectedIdentityGeneration:expectedIdentityGeneration)}
    public func identityGenerationV4() async throws->Int64 {try await store.identityGenerationV4()}
    public func currentAuthRequestIDV4() async throws->String? {try await store.currentAuthRequestIDV4()}
    public func authAttemptsV4() async throws->[AuthAttemptV4] {try await store.authAttemptsV4()}
    public func authResolutionV4(requestID:String) async throws->AuthResolutionV4? {try await store.authResolutionV4(requestID:requestID)}
    public func pendingAuthAttemptsV4() async throws->[AuthAttemptV4] {try await store.pendingAuthAttemptsV4()}
    public func resolveAuthAttemptV4(requestID:String,resolution:AuthResolutionV4) async throws {try await store.resolveAuthAttemptV4(requestID:requestID,resolution:resolution)}
    public func authAttemptV4(requestID:String) async throws->AuthAttemptV4? {try await store.authAttemptV4(requestID:requestID)}
    public func saveAuthAttemptV4(_ attempt:AuthAttemptV4,expectedIdentityGeneration:Int64=0) async throws {try await store.saveAuthAttemptV4(attempt,expectedIdentityGeneration:expectedIdentityGeneration)}
    public func acceptAuthenticationV4(attempt:AuthAttemptV4,binding:AccountBindingV4,receipt:VerifiedAuthorityReceiptV1,expectedIdentityGeneration:Int64=0) async throws {try await store.acceptAuthenticationV4(attempt:attempt,binding:binding,receipt:receipt,expectedIdentityGeneration:expectedIdentityGeneration)}
}
