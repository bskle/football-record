import CryptoKit
import Foundation
import MatchStore
#if canImport(CloudKit)
import CloudKit
#endif

public enum CloudIdentityError: Error, Sendable, Equatable { case disabled, unavailable, invalidResponse, identityChanged, cancelled }
public struct CloudIdentitySnapshot: Sendable, Equatable {
    public let cloudSpaceID:String
    public func zoneID(accountID:String) throws->String {
        try AuthorityWire.identifier(accountID)
        return "football-record-" + Self.hash("zone.v1",[accountID,cloudSpaceID])
    }
    static func hash(_ domain:String,_ fields:[String])->String {
        SHA256.hash(data:Data(("football-record.cloud-identity."+domain+"\0"+fields.joined(separator:"\0")).utf8)).map {String(format:"%02x",$0)}.joined()
    }
}
protocol CloudIdentityTransport:Sendable {func currentUser(_ completion:@escaping @Sendable (Result<String,CloudIdentityError>)->Void)}
private struct DisabledCloudIdentity:CloudIdentityTransport {func currentUser(_ completion:@escaping @Sendable (Result<String,CloudIdentityError>)->Void) {completion(.failure(.disabled))}}
/// Does not admit AccountService or persist Apple/CloudKit user identity.
public final class CloudIdentityProvider:@unchecked Sendable {
    private let containerIdentifier:String
    private let environment:AuthorityEnvironment
    private let transport:any CloudIdentityTransport
    private let gate=SDKResultGate<CloudIdentitySnapshot>()
    public convenience init(containerIdentifier:String,environment:AuthorityEnvironment,executionEnabled:Bool=false) throws {
        #if canImport(CloudKit)
        try self.init(containerIdentifier:containerIdentifier,environment:environment,transport:executionEnabled ? CloudKitIdentityTransport(containerIdentifier:containerIdentifier) : DisabledCloudIdentity())
        #else
        try self.init(containerIdentifier:containerIdentifier,environment:environment,transport:DisabledCloudIdentity())
        #endif
    }
    init(containerIdentifier:String,environment:AuthorityEnvironment,transport:any CloudIdentityTransport) throws {
        guard !containerIdentifier.isEmpty,containerIdentifier.utf8.count<=255,!containerIdentifier.utf8.contains(0) else {throw CloudIdentityError.invalidResponse}
        self.containerIdentifier=containerIdentifier;self.environment=environment;self.transport=transport
    }
    public func advanceIdentityFence(to generation:Int64) throws {_ = try gate.advance(to:generation,error:CloudIdentityError.identityChanged)}
    public func currentIdentity() async throws->CloudIdentitySnapshot {
        let ticket=try gate.begin()
        return try await withTaskCancellationHandler {
            if Task.isCancelled {gate.cancel(ticket,error:CloudIdentityError.cancelled)}
            if gate.current(ticket) {transport.currentUser {[gate,containerIdentifier,environment] result in
                do {
                    let user=try result.get()
                    guard !user.isEmpty,user.utf8.count<=1024,!user.utf8.contains(0) else {throw CloudIdentityError.invalidResponse}
                    let snapshot=CloudIdentitySnapshot(cloudSpaceID:"ck-"+CloudIdentitySnapshot.hash("space.v1",[containerIdentifier,environment.rawValue,user]))
                    gate.finish(ticket,.success(snapshot))
                } catch {gate.finish(ticket,.failure(error))}
            }}
            return try await ticket.latch.value()
        } onCancel: {[gate] in gate.cancel(ticket,error:CloudIdentityError.cancelled)}
    }
}
#if canImport(CloudKit)
private struct CloudKitIdentityTransport:CloudIdentityTransport {
    let containerIdentifier:String
    func currentUser(_ completion:@escaping @Sendable (Result<String,CloudIdentityError>)->Void) {
        let container=CKContainer(identifier:containerIdentifier)
        container.accountStatus {status,error in
            guard error==nil,status == .available else {completion(.failure(.unavailable));return}
            container.fetchUserRecordID {id,error in
                guard error==nil,let id else {completion(.failure(.unavailable));return};completion(.success(id.recordName))
            }
        }
    }
}
#endif
