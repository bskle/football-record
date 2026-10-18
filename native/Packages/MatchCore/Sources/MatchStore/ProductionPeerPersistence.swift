import Foundation
import MatchCore
struct StoredProductionGrantV4:Codable {let intent:ControlIntentV1;let raw:Data}
struct StoredProductionRouteV4:Codable {let receipt:RouteReceiptV3;let packetBytes:Data;let grantID,pairingID:String;let epoch:Int64;let accountID:String}
struct StoredProductionInboxV4:Codable {let packetBytes:Data;let rawEnvelope:Data;let grantID,pairingID:String;let epoch:Int64;let receipt:InboundReceiptV3}
struct StoredProductionACKV4:Codable {let bytes:Data;let receivedAt:Date}
extension MatchStore {
    func readPeerV4<T:Codable>(_ type:T.Type,_ id:String)throws->T? {guard let row=try db.rows("SELECT payload,checksum FROM peer_contexts_v4 WHERE id=?",[.text(id)]).first else {return nil};return try checkedV4(type,row:row,table:"peer_contexts_v4",key:id)}
    func productionBindingV4()throws->AccountBindingV4 {let b=try activeBindingV4();guard syncEnvironment == .production,b.environment == .production,authorityTrust?.environment == .production else {throw StoreError.trustUnavailable};try validateAccountBusinessWriteV4();return b}
    func checkProductionGrantV4(_ grant:VerifiedPeerGrantV1,now:Date)throws->VerifiedPeerGrantV1 {
        let b=try productionBindingV4();guard let trust=authorityTrust else {throw StoreError.trustUnavailable}
        return try VerifiedPeerGrantV1.verify(grant.receipt.raw,intent:grant.intent,trust:trust,binding:b,now:now)
    }
    func rememberProductionGrantV4(_ grant:VerifiedPeerGrantV1)throws {
        let g=grant.grant,key="latest:"+g.grantID
        if let row=try db.rows("SELECT payload,checksum FROM peer_grants_v4 WHERE id=?",[.text(key)]).first {
            let prior=try checkedV4(StoredProductionGrantV4.self,row:row,table:"peer_grants_v4",key:key)
            guard let trust=authorityTrust else {throw StoreError.trustUnavailable}
            let old=try VerifiedAuthorityReceiptV1.verify(prior.raw,expected:AuthorityExpectedIntent(prior.intent,accountID:grant.receipt.body.accountID,epoch:grant.receipt.body.activationEpoch),trust:trust)
            guard let p=old.body.peerGrant,p.grantID==g.grantID,p.pairingID==g.pairingID,p.localDeviceID==g.localDeviceID,p.remoteDeviceID==g.remoteDeviceID,p.localPublicKey==g.localPublicKey,p.remotePublicKey==g.remotePublicKey,p.localRole==g.localRole,p.remoteRole==g.remoteRole,p.activePhoneID==g.activePhoneID else {throw AuthorityError.conflict}
            if old.body.issuedAt>grant.receipt.body.issuedAt || p.expiresAt>g.expiresAt {return}
        }
        let value=StoredProductionGrantV4(intent:grant.intent,raw:grant.receipt.raw)
        try writeV4(value,table:"peer_grants_v4",id:key)
        let receiptKey="receipt:"+grant.receipt.body.receiptID
        if let row=try db.rows("SELECT payload,checksum FROM peer_grants_v4 WHERE id=?",[.text(receiptKey)]).first {let prior=try checkedV4(StoredProductionGrantV4.self,row:row,table:"peer_grants_v4",key:receiptKey);guard prior.raw==value.raw,prior.intent==value.intent else {throw AuthorityError.conflict}}
        else {try writeV4(value,table:"peer_grants_v4",id:receiptKey)}
    }
    public func authorizeProductionMatchV4(intent:ControlIntentV1,receipt:VerifiedAuthorityReceiptV1)throws {
        try db.transaction {
            let b=try productionBindingV4();guard let trust=authorityTrust,intent.operation == .acquire,intent.fields.activationEpoch==b.activationEpoch else {throw AuthorityError.intentMismatch}
            let r=try VerifiedAuthorityReceiptV1.verify(receipt.raw,expected:AuthorityExpectedIntent(intent,accountID:b.accountID,epoch:b.activationEpoch),trust:trust).body
            guard r.result == .held,r.matchID==intent.fields.matchID,r.recordingDeviceID==intent.fields.recordingDeviceID,!r.lockID.isEmpty else {throw AuthorityError.intentMismatch}
            let value=StoredProductionGrantV4(intent:intent,raw:receipt.raw),key="original-acquire:"+r.matchID
            if let prior=try readPeerV4(StoredProductionGrantV4.self,key) {guard prior.intent==intent,prior.raw==receipt.raw else {throw AuthorityError.conflict}}
            else {try writeV4(value,table:"peer_contexts_v4",id:key)}
            _=try prepareControlLockedV4(intent)
            if let first=try resultV4(intent.requestID) {guard first.raw==receipt.raw else {throw AuthorityError.conflict}}
            else {
                var projection=try projectionV4(r.matchID)
                if let original=projection.acquireRequestID {guard original==intent.requestID else {throw AuthorityError.conflict}}
                projection.acquireRequestID=intent.requestID
                if projection.status == .unknown {projection.status = .held}
                let output=AuthorityReceiptV4(requestID:r.requestID,receiptID:r.receiptID,rawDigest:AuthorityWire.hash(receipt.raw),status:projection.status),saved=StoredAuthorityResult(intent:intent,raw:receipt.raw,receipt:output),raw=try Canonical.data(saved)
                try db.execute("INSERT INTO authority_results_v4 VALUES (?,?,?,?,?)",[.text(r.receiptID),.text(r.requestID),.text(r.matchID),.blob(raw),.text(Canonical.hash(raw))])
                try writeV4(projection,table:"authority_projection_v4",idColumn:"match_id",id:r.matchID)
            }
            try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
    func validateProductionSnapshotV4(_ packet:MatchPacketV2,grant:VerifiedPeerGrantV1)throws {
        let d=packet.body.descriptor,b=try productionBindingV4(),pair=Set([grant.grant.localDeviceID,grant.grant.remoteDeviceID])
        guard d.backendLockState == .unknown || d.backendLockState == .held,pair.contains(d.recordingDeviceID),let stored=try readPeerV4(StoredProductionGrantV4.self,"original-acquire:"+d.matchID),let trust=authorityTrust,try ControlIntentV1.acquire(d.startIntent,epoch:b.activationEpoch)==stored.intent else {throw StoreError.trustUnavailable}
        let a=try VerifiedAuthorityReceiptV1.verify(stored.raw,expected:AuthorityExpectedIntent(stored.intent,accountID:b.accountID,epoch:b.activationEpoch),trust:trust)
        guard d.startPermit == .acceptedByTrustedNetworkBoundary(for:d.startIntent,permitID:a.body.receiptID),a.body.recordingDeviceID==d.recordingDeviceID else {throw StoreError.trustUnavailable}
        try validateDescriptor(d,prior:nil);try validatePeerSnapshotFactsV4(packet,pair:pair)
    }
    func productionRoutesV4(_ matchID:String)throws->[StoredProductionRouteV4] {
        try db.rows("SELECT id,payload,checksum FROM peer_contexts_v4 WHERE id LIKE 'route:%' ORDER BY rowid").compactMap {row in
            let r=try checkedV4(StoredProductionRouteV4.self,row:[row[1],row[2]],table:"peer_contexts_v4",key:row[0].string ?? "route")
            guard r.receipt.packet.body.descriptor.matchID==matchID else {return nil}
            let item=try loadBusinessOutbox(id:r.receipt.outboxID)
            guard row[0].string=="route:"+r.receipt.outboxID,r.packetBytes == (try r.receipt.packet.canonicalBytes()),r.receipt.sourcePayloadDigest==Canonical.hash(try Canonical.data(item)),r.receipt.packet.body.sourceDeviceID==item.sourceDeviceID else {throw StoreError.syncConflict}
            return r
        }
    }
    public func unroutedProductionOutboxV4(matchID:String)throws->[BusinessOutboxItem] {let routes=try productionRoutesV4(matchID),ids=Set(routes.map{$0.receipt.outboxID});return try syncBusinessItems(matchID).filter{!ids.contains($0.id)}}
    public func routeProductionOutboxV4(outboxID:String,grant:VerifiedPeerGrantV1,now:Date)throws->RouteReceiptV3 {
        let checked=try checkProductionGrantV4(grant,now:now),b=try productionBindingV4(),g=checked.grant
        let result=try db.transaction {
            try rememberProductionGrantV4(checked)
            let item=try loadBusinessOutbox(id:outboxID),routes=try productionRoutesV4(item.matchID)
            if let prior=routes.first(where:{$0.receipt.outboxID==outboxID}) {guard prior.grantID==g.grantID,prior.pairingID==g.pairingID,prior.epoch==b.activationEpoch,prior.accountID==b.accountID else {throw AuthorityError.conflict};return prior.receipt}
            guard item.sourceDeviceID==b.deviceID else {throw StoreError.invalidPeerAuthorization}
            _=try syncBusinessItems(item.matchID)
            let target=b.deviceID==g.localDeviceID ? g.remoteDeviceID:g.localDeviceID,snapshot=try loadSnapshot(matchID:item.matchID),revisions=try loadCaptureRevisions(descriptor:snapshot.descriptor)
            guard !snapshot.diagnostics.contains(where:{$0.severity == .blocking}) else {throw StoreError.unresolvedDiagnostics}
            let sequence=Int64(routes.filter {$0.grantID==g.grantID}.count)+1
            let packet=try MatchPacketV2(packetID:SyncWire.derive("packet-id",[outboxID,b.deviceID,target]),idempotencyKey:SyncWire.derive("idempotency-key",[outboxID,b.deviceID,target]),sequence:sequence,sourceDeviceID:b.deviceID,targetDeviceID:target,descriptor:snapshot.descriptor,events:snapshot.events,captureRevisions:revisions)
            try validateProductionSnapshotV4(packet,grant:checked)
            let receipt=try RouteReceiptV3(outboxID:outboxID,sourcePayloadDigest:Canonical.hash(Canonical.data(item)),packet:packet),value=StoredProductionRouteV4(receipt:receipt,packetBytes:try packet.canonicalBytes(),grantID:g.grantID,pairingID:g.pairingID,epoch:b.activationEpoch,accountID:b.accountID)
            try writeV4(value,table:"peer_contexts_v4",id:"route:"+outboxID);try fail(.afterRoute);try fail(.beforeCommit);return receipt
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    public func pendingProductionPacketsV4(matchID:String,grant:VerifiedPeerGrantV1,now:Date)throws->[MatchPacketV2] {
        let checked=try checkProductionGrantV4(grant,now:now),b=try productionBindingV4()
        return try db.transaction {try rememberProductionGrantV4(checked);return try productionRoutesV4(matchID).filter {$0.grantID==checked.grant.grantID && $0.pairingID==checked.grant.pairingID && $0.epoch==b.activationEpoch && $0.accountID==b.accountID}.compactMap {r in
            if let ack=try readPeerV4(StoredProductionACKV4.self,"ack:"+r.receipt.packet.body.packetID) {guard ack.bytes == (try DurableACKV2(packet:r.receipt.packet).canonicalBytes()) else {throw StoreError.invalidACK};return nil};return r.receipt.packet
        }}
    }
    public func receiveProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,matchID:String,now:Date)throws->InboundReceiptV3 {
        let b=try productionBindingV4();guard let trust=authorityTrust else {throw StoreError.trustUnavailable}
        let e=try VerifiedPeerEnvelopeV1.verify(envelope.raw,grant:envelope.grant,trust:trust,binding:b,now:now)
        guard e.envelope.body.kind == .packet else {throw StoreError.invalidPacket}
        let packet=try JSONDecoder().decode(MatchPacketV2.self,from:e.payload),body=packet.body,g=e.grant.grant
        guard body.descriptor.matchID==matchID else {throw StoreError.invalidPacket}
        let result=try preservingDiagnostics(matchID:matchID) {
            do {return try db.transaction {
                try validateProductionSnapshotV4(packet,grant:e.grant);try rememberProductionGrantV4(e.grant)
                let rows=try db.rows("SELECT id,digest,receipt FROM peer_inbox_v4")
                for row in rows {
                    guard let raw=row[2].data,row[1].string==Canonical.hash(raw) else {throw StoreError.syncConflict}
                    let saved=try JSONDecoder().decode(StoredProductionInboxV4.self,from:raw),a=saved.receipt.ack.body
                    guard try Canonical.data(saved)==raw else {throw StoreError.syncConflict}
                    if a.packetID==body.packetID || a.idempotencyKey==body.idempotencyKey || (a.sourceDeviceID==body.targetDeviceID && a.targetDeviceID==body.sourceDeviceID && a.matchID==matchID && saved.grantID==g.grantID && a.sequence==body.sequence) {
                        guard saved.packetBytes==e.payload,saved.grantID==g.grantID,saved.pairingID==g.pairingID,saved.epoch==b.activationEpoch else {throw StoreError.packetConflict};return saved.receipt
                    }
                }
                let current=try descriptorAndGeneration(matchID).map {_ in try loadSnapshot(matchID:matchID)},incoming=body.descriptor
                if let current {try validateDescriptor(incoming,prior:current.descriptor);try rejectInboundCaptureAbsenceContradictions(descriptor:current.descriptor,revisions:body.captureRevisions,raw:e.payload)}
                let oldRevisions=try current.map {try loadCaptureRevisions(descriptor:$0.descriptor)} ?? []
                for (old,new) in zip(oldRevisions,body.captureRevisions) {guard old==new else {throw StoreError.captureBranch}}
                let eventIDs=Set(current?.events.map(\.eventID) ?? []),revisionIDs=Set(oldRevisions.map(\.id)),events=body.events.filter{!eventIDs.contains($0.eventID)},revisions=body.captureRevisions.filter{!revisionIDs.contains($0.id)}
                let changed=current==nil || current?.descriptor != incoming || !events.isEmpty || !revisions.isEmpty,generation=current?.generation ?? 0
                guard !changed || generation<Int64.max else {throw StoreError.invalidRequest}
                let next=changed ? generation+1:generation
                if changed {try writeDescriptor(incoming,generation:next)}
                try append(body.events,matchID:matchID);for revision in revisions {try appendRevision(revision,descriptor:incoming)}
                let merged=try loadSnapshot(matchID:matchID),captures=try loadCaptureRevisions(descriptor:incoming),union=try MatchPacketV2(packetID:body.packetID,idempotencyKey:body.idempotencyKey,sequence:body.sequence,sourceDeviceID:body.sourceDeviceID,targetDeviceID:body.targetDeviceID,descriptor:incoming,events:merged.events,captureRevisions:captures)
                try validateProductionSnapshotV4(union,grant:e.grant);try validateCaptureAbsenceIntegrity(descriptor:incoming);try fail(.afterInboundFacts)
                let ack=try DurableACKV2(packet:packet),receipt=try InboundReceiptV3(ack:ack,matchID:matchID,generation:next,insertedEventIDs:events.map(\.eventID),insertedCaptureRevisionIDs:revisions.map(\.id)),saved=StoredProductionInboxV4(packetBytes:e.payload,rawEnvelope:e.raw,grantID:g.grantID,pairingID:g.pairingID,epoch:b.activationEpoch,receipt:receipt),raw=try Canonical.data(saved)
                try db.execute("INSERT INTO peer_inbox_v4 VALUES (?,?,?)",[.text(body.packetID),.text(Canonical.hash(raw)),.blob(raw)])
                try fail(.afterInboundReceipt);try fail(.beforeCommit);return receipt
            }} catch let error as StoreError {switch error {case .injectedFailure,.sqlite,.closed:throw error;default:throw quarantine(error,code:"production-peer-rejected",key:body.packetID,raw:e.payload)}}
        };if fault == .afterCommit {throw StoreError.responseLost};return result
    }
    public func acknowledgeProductionEnvelopeV4(_ envelope:VerifiedPeerEnvelopeV1,now:Date)throws {
        let b=try productionBindingV4();guard let trust=authorityTrust else {throw StoreError.trustUnavailable}
        let e=try VerifiedPeerEnvelopeV1.verify(envelope.raw,grant:envelope.grant,trust:trust,binding:b,now:now)
        guard e.envelope.body.kind == .ack else {throw StoreError.invalidACK}
        let ack=try JSONDecoder().decode(DurableACKV2.self,from:e.payload)
        try db.transaction {
            try rememberProductionGrantV4(e.grant)
            guard let route=try productionRoutesV4(ack.body.matchID).first(where:{$0.receipt.packet.body.packetID==ack.body.packetID}),route.grantID==e.grant.grant.grantID,route.pairingID==e.grant.grant.pairingID,route.epoch==b.activationEpoch,route.accountID==b.accountID,e.payload == (try DurableACKV2(packet:route.receipt.packet).canonicalBytes()) else {throw StoreError.invalidACK}
            let key="ack:"+ack.body.packetID
            if let prior=try readPeerV4(StoredProductionACKV4.self,key) {guard prior.bytes==e.payload else {throw StoreError.invalidACK};return}
            try writeV4(StoredProductionACKV4(bytes:e.payload,receivedAt:now),table:"peer_contexts_v4",id:key);try fail(.afterACK);try fail(.beforeCommit)
        };if fault == .afterCommit {throw StoreError.responseLost}
    }
}
