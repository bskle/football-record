import Foundation
import MatchCore
import MatchStore
import MatchSession
public actor AuthorityStartPermitProvider: StartPermitProvider {
    let client:AuthorityClient
    let repository:any AuthorityRepository
    let now:@Sendable ()->Date
    var coordinator:(any AuthorityInboundCoordinator)?
    public init(client:AuthorityClient,repository:any AuthorityRepository,now:@escaping @Sendable ()->Date={Date()}) { self.client=client;self.repository=repository;self.now=now }
    public func attach(_ coordinator:any AuthorityInboundCoordinator) async throws {
        guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity() else { throw AuthorityError.identityChanged };self.coordinator=coordinator
    }
    public func acquire(for intent:StartIntent) async throws -> TrustedStartPermit {
        guard let coordinator,let binding=try await repository.accountBindingV4(),!binding.suspended,binding.deviceID==intent.recordingDeviceID,binding.environment==client.trust.environment else { throw AuthorityError.identityChanged }
        let control=try ControlIntentV1.acquire(intent,epoch:binding.activationEpoch)
        _ = try await coordinator.prepareAuthorityControl(control)
        try await ControlQueueSupport.begin(control,coordinator:coordinator,at:now())
        let raw:Data
        do {
            do {raw=try await client.query(requestID:control.requestID)}
            catch let failure as AuthorityHTTPFailure where failure.code=="notFound" {raw=try await client.send(control)}
        } catch {try await ControlQueueSupport.failed(control,error:error,coordinator:coordinator,at:now());throw error}
        let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(control,accountID:binding.accountID,epoch:binding.activationEpoch),trust:client.trust)
        _ = try await coordinator.acceptAuthorityResult(receipt)
        guard receipt.body.result == .held,receipt.body.matchID==intent.matchID,receipt.body.recordingDeviceID==intent.recordingDeviceID else { throw AuthorityError.terminalLock }
        let query=try LiveLockQueryV1(requestID:UUID().uuidString,acquireRequestID:control.requestID,matchID:intent.matchID,lockID:receipt.body.lockID,recordingDeviceID:intent.recordingDeviceID,activationEpoch:binding.activationEpoch,nonce:UUID().uuidString)
        let live=try await client.liveStatus(query,accountID:binding.accountID)
        try await coordinator.acceptLiveLock(live)
        guard live.body.status == .held else { throw AuthorityError.terminalLock }
        try await repository.validateAuthorityStartV4(intent,now:now())
        switch binding.environment {
        case .development:return DevelopmentStartFixture.permit(for:intent)
        case .production:return TrustedStartPermit.acceptedByTrustedNetworkBoundary(for:intent,permitID:receipt.body.receiptID)
        }
    }
}
