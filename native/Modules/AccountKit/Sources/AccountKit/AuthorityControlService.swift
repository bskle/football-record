import Foundation
import MatchCore
import MatchStore
import MatchSession

public actor AuthorityControlService {
    let client:AuthorityClient
    let repository:any AuthorityRepository & CloudImportRepository
    let coordinator:any AuthorityInboundCoordinator
    public init(client:AuthorityClient,repository:any AuthorityRepository & CloudImportRepository,coordinator:any AuthorityInboundCoordinator){self.client=client;self.repository=repository;self.coordinator=coordinator}

    func checkedBinding() async throws->AccountBindingV4 {
        guard await coordinator.syncRepositoryIdentity()==repository.syncRepositoryIdentity(),let b=try await repository.accountBindingV4(),!b.suspended,b.environment==client.trust.environment else {throw AuthorityError.identityChanged};return b
    }
    public func normal(matchID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        _=try await checkedBinding()
        let state=try await repository.authorityStateV4(matchID:matchID,now:client.now())
        if let release=state.verifiedNormalRelease {return release}
        guard let coordinator=coordinator as? any AuthorityControlCoordinator else {throw AuthorityError.unavailable}
        let intent=try await coordinator.prepareNormalTermination(matchID:matchID,requestID:requestID)
        return try await reconcile(intent)
    }
    public func abnormal(matchID:String,requestID:String) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await checkedBinding();guard b.role == .phone,let coordinator=coordinator as? any AuthorityControlCoordinator else {throw AuthorityError.identityChanged}
        let state=try await repository.authorityStateV4(matchID:matchID,now:client.now())
        guard let acquire=state.acquire else {throw AuthorityError.intentMismatch}
        var f=AuthorityFields();f.matchID=matchID;f.lockID=acquire.body.lockID;f.recordingDeviceID=acquire.body.recordingDeviceID;f.activationEpoch=b.activationEpoch;f.mode="abnormal"
        let intent=try ControlIntentV1(requestID:requestID,operation:.terminate,fields:f)
        _=try await coordinator.prepareAbnormalTermination(intent)
        return try await reconcile(intent)
    }
    public func reconcile(_ intent:ControlIntentV1) async throws->VerifiedAuthorityReceiptV1 {
        let b=try await checkedBinding()
        try await ControlQueueSupport.begin(intent,coordinator:coordinator,at:client.now())
        do {
            let raw:Data
            do {raw=try await client.query(requestID:intent.requestID)}
            catch let error as AuthorityHTTPFailure where error.code=="notFound" {raw=try await client.send(intent)}
            let receipt=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:b.activationEpoch),trust:client.trust)
            _=try await coordinator.acceptAuthorityResult(receipt);return receipt
        } catch {try await ControlQueueSupport.failed(intent,error:error,coordinator:coordinator,at:client.now());throw error}
    }

    public func reconcilePending() async throws->[VerifiedAuthorityReceiptV1] {
        guard let queue=repository as? any ControlQueueRepository else {throw AuthorityError.unavailable}
        var results:[VerifiedAuthorityReceiptV1]=[]
        for entry in try await queue.controlQueueV4() where entry.intent.operation == .terminate && [.ready,.inFlight,.retryScheduled].contains(entry.state) && (entry.nextAttemptAt.map{$0<=client.now()} ?? true) {results.append(try await reconcile(entry.intent))};return results
    }
}
