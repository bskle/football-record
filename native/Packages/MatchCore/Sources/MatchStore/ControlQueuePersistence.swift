import Foundation
extension MatchStore {
    func controlHasResultV4(_ intent:ControlIntentV1)throws->Bool {
        if let first=try resultV4(intent.requestID) {
            struct Envelope:Codable {let body:AuthorityReceiptBodyV1;let signature:String}
            let body=try AuthorityWire.decode(Envelope.self,first.raw).body
            guard first.intent==intent,let trust=authorityTrust else {throw AuthorityError.conflict}
            _=try VerifiedAuthorityReceiptV1.verify(first.raw,expected:AuthorityExpectedIntent(intent,accountID:body.accountID,epoch:body.activationEpoch),trust:trust);return true
        }
        if try lifecycleReceiptV4(requestID:intent.requestID) != nil {return true}
        if let deletion=try deletionSagaV4(requestID:intent.requestID),deletion.backendDeleted,let raw=deletion.backendReceipt,let trust=authorityTrust {
            _=try VerifiedAuthorityReceiptV1.verify(raw,expected:AuthorityExpectedIntent(intent,accountID:deletion.accountID,epoch:deletion.activationEpoch),trust:trust);return true
        }
        return false
    }
    func controlEntryV4(_ intent:ControlIntentV1)throws->ControlQueueEntryV4 {
        var entry=try readLifecycleV4(ControlQueueEntryV4.self,"control-queue:"+intent.requestID) ?? ControlQueueEntryV4(intent:intent,state:.ready,attemptCount:0,lastAttemptAt:nil,nextAttemptAt:nil,lastIssue:nil)
        guard entry.intent==intent,entry.attemptCount>=0,entry.attemptCount<=9_007_199_254_740_991 else {throw AuthorityError.conflict}
        for date in [entry.lastAttemptAt,entry.nextAttemptAt].compactMap({$0}) {try CloudCanonicalV1.date(date)}
        if try controlHasResultV4(intent) {entry.state = .confirmed;entry.nextAttemptAt=nil;entry.lastIssue=nil}
        else {guard entry.state != .confirmed else {throw AuthorityError.conflict}}
        return entry
    }
    func readyControlLockedV4(_ intent:ControlIntentV1)throws {try writeV4(controlEntryV4(intent),table:"lifecycle_steps_v4",id:"control-queue:"+intent.requestID)}
    func confirmControlLockedV4(_ intent:ControlIntentV1)throws {var entry=try controlEntryV4(intent);entry.state = .confirmed;entry.nextAttemptAt=nil;entry.lastIssue=nil;try writeV4(entry,table:"lifecycle_steps_v4",id:"control-queue:"+intent.requestID)}
    public func controlQueueV4()throws->[ControlQueueEntryV4] {
        try db.rows("SELECT payload,checksum FROM control_intents_v4 ORDER BY rowid").map {try controlEntryV4(checkedV4(ControlIntentV1.self,row:$0,table:"control_intents_v4",key:"queue"))}
    }
    public func beginControlAttemptV4(intent:ControlIntentV1,at:Date)throws {
        try CloudCanonicalV1.date(at)
        try db.transaction {
            guard try controlV4(intent.requestID)==intent else {throw AuthorityError.intentMismatch}
            var entry=try controlEntryV4(intent);if entry.state == .confirmed {return}
            if intent.operation == .terminate {
                let binding=try activeBindingV4(),state=try authorityStateV4(matchID:intent.matchID,now:at)
                guard let acquired=state.acquire,acquired.body.lockID==intent.fields.lockID,acquired.body.recordingDeviceID==intent.fields.recordingDeviceID else {throw AuthorityError.intentMismatch}
                if intent.fields.mode=="normal" {
                    guard binding.deviceID==acquired.body.recordingDeviceID,let input=try readLifecycleV4(CloudSaveInputV1.self,"normal-intent:"+intent.requestID),input.confirmationID==intent.fields.cloudConfirmationID,input.factDigest==intent.fields.contentCommitment else {throw AuthorityError.intentMismatch}
                    _=try VerifiedCloudSaveV1.verifyReadback(input,policy:cloudSavePolicy)
                } else {
                    guard binding.role == .phone,state.status == .terminationPending,let row=try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?",[.text(intent.requestID)]).first else {throw AuthorityError.intentMismatch}
                    let committed=try verifiedCommandV2(commandID:intent.requestID,row:row).request
                    guard committed.commandID==intent.requestID,committed.events.count==1,committed.events[0].type == .matchTerminated,committed.events[0].authority == .abnormalTermination,committed.events[0].terminationID==intent.requestID else {throw AuthorityError.intentMismatch}
                }
            }
            guard entry.attemptCount<9_007_199_254_740_991 else {throw AuthorityError.unavailable}
            entry.attemptCount += 1;entry.state = .inFlight;entry.lastAttemptAt=at;entry.nextAttemptAt=nil;entry.lastIssue=nil
            try writeV4(entry,table:"lifecycle_steps_v4",id:"control-queue:"+intent.requestID);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    public func failControlAttemptV4(intent:ControlIntentV1,issue:LifecycleIssueV4,retryable:Bool,at:Date)throws {
        try CloudCanonicalV1.date(at)
        try db.transaction {
            guard try controlV4(intent.requestID)==intent else {throw AuthorityError.intentMismatch}
            var entry=try controlEntryV4(intent);if entry.state == .confirmed {return}
            entry.state=retryable ? .retryScheduled:.blocked;entry.lastIssue=issue
            entry.nextAttemptAt=retryable ? at.addingTimeInterval(pow(2,Double(min(entry.attemptCount,10)))):nil
            if let next=entry.nextAttemptAt {try CloudCanonicalV1.date(next)}
            try writeV4(entry,table:"lifecycle_steps_v4",id:"control-queue:"+intent.requestID);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
