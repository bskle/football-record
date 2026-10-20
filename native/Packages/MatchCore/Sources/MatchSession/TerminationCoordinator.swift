import Foundation
import MatchCore
import MatchStore
public protocol AuthorityControlCoordinator:AuthorityInboundCoordinator {
    func prepareNormalTermination(matchID:String,requestID:String) async throws->ControlIntentV1
    func prepareAbnormalTermination(_ intent:ControlIntentV1) async throws->ControlIntentReceiptV4
}
extension MatchSession:AuthorityControlCoordinator {
    public func prepareNormalTermination(matchID:String,requestID:String) async throws->ControlIntentV1 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();guard let repository=store as? any AuthorityTerminationRepository else {throw AuthorityError.unavailable}
        await acquire(matchID);defer {release(matchID)}
        try requireBusinessActive()
        return try await repository.prepareNormalTerminationV4(matchID:matchID,requestID:requestID,now:clock.now())
    }
    public func prepareAbnormalTermination(_ intent:ControlIntentV1) async throws->ControlIntentReceiptV4 {
        try beginBusiness(); defer { endBusiness() }
        try await validateEnvironment();guard let repository=store as? any AuthorityTerminationRepository else {throw AuthorityError.unavailable}
        await acquire(intent.matchID);defer {release(intent.matchID)}
        let authority=try authorityRepository()
        guard let b=try await authority.accountBindingV4(),b.role == .phone,b.deviceID == (try await identity()) else {throw AuthorityError.identityChanged}
        let commit:StoreCommitV2
        if let prior=try await store.committedCommandV2(commandID:intent.requestID) {commit=prior.request}
        else {
            let s=try await store.snapshotV2(matchID:intent.matchID)
            let event=try PostMatchEditor.terminateAbnormally(terminationID:intent.requestID,descriptor:s.business.descriptor,events:s.business.events,sourceDeviceID:b.deviceID,now:clock.now())
            commit=try makeCommit(command:intent.requestID,generation:s.business.generation,descriptor:s.business.descriptor,events:[event],operations:[],outboxID:intent.requestID+"/outbox")
        }
        try requireBusinessActive()
        let result=try await repository.prepareAbnormalTerminationV4(intent:intent,request:commit)
        authorityTerminalMatches.insert(intent.matchID)
        publish(try projected(await store.snapshotV2(matchID:intent.matchID)));scheduleCapture(intent.matchID)
        return result
    }
}
extension SQLiteSessionRepository:AuthorityTerminationRepository {
    public func prepareNormalTerminationV4(matchID:String,requestID:String,now:Date) async throws->ControlIntentV1 {try await store.prepareNormalTerminationV4(matchID:matchID,requestID:requestID,now:now)}
    public func prepareAbnormalTerminationV4(intent:ControlIntentV1,request:StoreCommitV2) async throws->ControlIntentReceiptV4 {try await store.prepareAbnormalTerminationV4(intent:intent,request:request)}
}
