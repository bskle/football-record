import Foundation
import MatchStore
public protocol WatchRegistrationCoordinator:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func admitWatchRegistrationContext(_ context:WatchRegistrationContextV4,deviceID:String,publicKey:String) async throws->Int64
    func saveWatchRegistrationAttempt(_ attempt:WatchRegistrationAttemptV4,expectedIdentityGeneration:Int64) async throws
    func acceptWatchRegistration(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,watchBinding:AccountBindingV4?,expectedIdentityGeneration:Int64) async throws
}
extension MatchSession:WatchRegistrationCoordinator {
    public func admitWatchRegistrationContext(_ context:WatchRegistrationContextV4,deviceID:String,publicKey:String) async throws->Int64 {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any WatchRegistrationRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};return try await repository.admitWatchRegistrationContextV4(context,deviceID:deviceID,publicKey:publicKey)
    }
    public func saveWatchRegistrationAttempt(_ attempt:WatchRegistrationAttemptV4,expectedIdentityGeneration:Int64) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any WatchRegistrationRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};try await repository.saveWatchRegistrationAttemptV4(attempt,expectedIdentityGeneration:expectedIdentityGeneration)
    }
    public func acceptWatchRegistration(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,watchBinding:AccountBindingV4?,expectedIdentityGeneration:Int64) async throws {
        try await validateEnvironment(allowSuspendedRead:true);guard let repository=store as? any WatchRegistrationRepository else {throw AuthorityError.unavailable}
        await acquire("_authority-account");defer {release("_authority-account")};try await repository.acceptWatchRegistrationV4(attempt,receipt:receipt,watchBinding:watchBinding,expectedIdentityGeneration:expectedIdentityGeneration)
    }
}
extension SQLiteSessionRepository:WatchRegistrationRepository {
    public func admitWatchRegistrationContextV4(_ context:WatchRegistrationContextV4,deviceID:String,publicKey:String) async throws->Int64 {try await store.admitWatchRegistrationContextV4(context,deviceID:deviceID,publicKey:publicKey)}
    public func watchRegistrationAttemptV4(requestID:String) async throws->WatchRegistrationAttemptV4? {try await store.watchRegistrationAttemptV4(requestID:requestID)}
    public func pendingWatchRegistrationAttemptsV4() async throws->[WatchRegistrationAttemptV4] {try await store.pendingWatchRegistrationAttemptsV4()}
    public func watchRegistrationReceiptV4(requestID:String) async throws->Data? {try await store.watchRegistrationReceiptV4(requestID:requestID)}
    public func saveWatchRegistrationAttemptV4(_ attempt:WatchRegistrationAttemptV4,expectedIdentityGeneration:Int64) async throws {try await store.saveWatchRegistrationAttemptV4(attempt,expectedIdentityGeneration:expectedIdentityGeneration)}
    public func acceptWatchRegistrationV4(_ attempt:WatchRegistrationAttemptV4,receipt:VerifiedAuthorityReceiptV1,watchBinding:AccountBindingV4?,expectedIdentityGeneration:Int64) async throws {try await store.acceptWatchRegistrationV4(attempt,receipt:receipt,watchBinding:watchBinding,expectedIdentityGeneration:expectedIdentityGeneration)}
}
