import Foundation
import MatchCore
public protocol AuthorityTerminationRepository:Sendable {
    func syncRepositoryIdentity() async->SyncRepositoryIdentity
    func prepareNormalTerminationV4(matchID:String,requestID:String,now:Date) async throws->ControlIntentV1
    func prepareAbnormalTerminationV4(intent:ControlIntentV1,request:StoreCommitV2) async throws->ControlIntentReceiptV4
}
