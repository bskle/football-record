import Foundation
import MatchCore
extension MatchStore {
    public func prepareNormalTerminationV4(matchID:String,requestID:String,now:Date)throws->ControlIntentV1 {
        let result=try db.transaction {
            let b=try activeBindingV4(),state=try authorityStateV4(matchID:matchID,now:now)
            if let prior=try controlV4(requestID) {
                guard prior.operation == .terminate,prior.matchID==matchID,prior.fields.mode=="normal" else {throw AuthorityError.conflict};return prior
            }
            guard let acquire=state.acquire,state.status == .held,acquire.body.recordingDeviceID==b.deviceID,
                  let cloud=try matchingCloudSaveV4(matchID:matchID) else {throw CloudImportError.proofUnavailable}
            var f=AuthorityFields();f.matchID=matchID;f.lockID=acquire.body.lockID;f.recordingDeviceID=acquire.body.recordingDeviceID;f.activationEpoch=b.activationEpoch;f.mode="normal";f.cloudConfirmationID=cloud.input.confirmationID;f.contentCommitment=cloud.input.factDigest
            let intent=try ControlIntentV1(requestID:requestID,operation:.terminate,fields:f)
            _=try prepareControlLockedV4(intent);return intent
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    public func prepareAbnormalTerminationV4(intent:ControlIntentV1,request:StoreCommitV2)throws->ControlIntentReceiptV4 {
        let result=try preservingDiagnostics(matchID:intent.matchID) {try db.transaction {
            let b=try activeBindingV4(),state=try authorityStateV4(matchID:intent.matchID,now:request.events.first?.createdAt ?? Date())
            guard b.role == .phone,intent.operation == .terminate,intent.fields.mode=="abnormal",intent.fields.activationEpoch==b.activationEpoch,
                  let acquire=state.acquire,intent.fields.matchID==acquire.body.matchID,intent.fields.lockID==acquire.body.lockID,intent.fields.recordingDeviceID==acquire.body.recordingDeviceID,
                  request.commandID==intent.requestID,request.descriptor.matchID==intent.matchID,request.descriptor.recordingDeviceID==acquire.body.recordingDeviceID,
                  request.events.count==1,request.events[0].type == .matchTerminated,request.events[0].authority == .abnormalTermination,request.events[0].terminationID==intent.requestID,request.events[0].sourceDeviceID==b.deviceID,
                  request.captureRevisions.isEmpty,request.newCaptureOperations.isEmpty,request.captureOperationUpdates.isEmpty else {throw AuthorityError.intentMismatch}
            let receipt=try prepareControlLockedV4(intent)
            _=try applyCommitV2(request)
            var p=try projectionV4(intent.matchID)
            if p.status == .held {p.status = .terminationPending;try writeV4(p,table:"authority_projection_v4",idColumn:"match_id",id:intent.matchID)}
            try fail(.beforeCommit);return receipt
        }};if fault == .afterCommit {throw StoreError.responseLost};return result
    }
}
