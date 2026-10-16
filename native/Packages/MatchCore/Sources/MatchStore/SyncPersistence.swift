import Foundation
import MatchCore

struct StoredSyncRoute: Codable, Equatable {
    let receipt: RouteReceiptV3
    let packetBytes: Data
    let peer: PeerAuthorization
}
struct StoredSyncInbox: Codable, Equatable {
    let packetBytes: Data
    let projection: MatchDescriptor
    let receipt: InboundReceiptV3
    let ackBytes: Data
    let peer: PeerAuthorization
}
struct StoredSyncACK: Codable, Equatable {
    let raw: Data
    let peer: PeerAuthorization
    let acceptedAt: Date
}
struct SyncReceiveProgress: Codable, Equatable {
    let highestObserved, highestContiguous: Int64
    let gaps: [SyncGap]
    init(sequences: [Int64]) throws {
        let ordered = sequences.sorted()
        var next: Int64 = 1, gaps: [SyncGap] = []
        for sequence in ordered {
            guard sequence >= next, sequence < Int64.max else { throw StoreError.syncConflict }
            if sequence > next { gaps.append(try SyncGap(lowerBound: next, upperBound: sequence - 1)) }
            next = sequence + 1
        }
        highestObserved = ordered.last ?? 0
        highestContiguous = gaps.first.map { $0.lowerBound - 1 } ?? highestObserved
        self.gaps = gaps
    }
}

extension MatchStore {
    func syncCorrupt(_ table: String, _ key: String, _ raw: Data = Data()) -> Quarantined {
        quarantine(.corruptPayload(table: table, key: key), code: "corrupt-" + table, key: key, raw: raw)
    }
    func checkedSync<T: Codable>(_ type: T.Type, raw: SQLValue, checksum: SQLValue, table: String, key: String) throws -> T {
        guard let bytes = raw.data, checksum.string == Canonical.hash(bytes) else { throw syncCorrupt(table, key, raw.data ?? Data()) }
        let value = try decode(type, raw, table: table, key: key)
        guard try Canonical.data(value) == bytes else { throw syncCorrupt(table, key, bytes) }
        return value
    }
    func saveSyncRegistry(kind: String, id: String, matchID: String, raw: Data) throws {
        try db.execute("INSERT INTO sync_registry_v3 VALUES (?,?,?,?,?)", [.text(kind), .text(id), .text(matchID), .blob(raw), .text(Canonical.hash(raw))])
    }
    func verifySyncRegistry(kind: String, id: String, matchID: String, raw: Data) throws {
        guard let row = try db.rows("SELECT match_id,payload,checksum FROM sync_registry_v3 WHERE kind=? AND id=?", [.text(kind), .text(id)]).first,
              row[0].string == matchID, row[1].data == raw, row[2].string == Canonical.hash(raw) else { throw syncCorrupt("sync_registry_v3", id, raw) }
    }
    func verifySyncRegistrySet(kind: String, matchID: String, ids: [String], table: String) throws {
        let actual = Set(ids)
        for row in try db.rows("SELECT id,payload,checksum FROM sync_registry_v3 WHERE kind=? AND match_id=?", [.text(kind), .text(matchID)]) {
            let id = row[0].string ?? "invalid-id", raw = row[1].data ?? Data()
            guard actual.contains(id), row[2].string == Canonical.hash(raw) else { throw syncCorrupt(table, id, raw) }
        }
    }
    /// Persist the local context on first use; reopening the same DB cannot silently change namespace.
    func bindSyncPeer(_ peer: PeerAuthorization) throws {
        if let row = try db.rows("SELECT payload,checksum FROM sync_context_v3 WHERE singleton=1").first {
            let saved = try checkedSync(PeerAuthorization.self, raw: row[0], checksum: row[1], table: "sync_context_v3", key: "1")
            guard saved.sameBinding(as: peer) else { throw StoreError.invalidPeerAuthorization }
        } else {
            // Registry provides a second witness for a missing context row.
            guard try db.rows("SELECT id FROM sync_registry_v3").isEmpty else { throw syncCorrupt("sync_context_v3", "1") }
            let raw = try Canonical.data(peer)
            try db.execute("INSERT INTO sync_context_v3 VALUES (1,?,?)", [.blob(raw), .text(Canonical.hash(raw))])
        }
    }
    func verifySyncBusinessItem(_ item: BusinessOutboxItem) throws {
        let persisted = try verifyPersistedFacts(descriptor: item.payload.descriptor, events: item.payload.events)
        let revisions = try loadCaptureRevisions(descriptor: persisted.0)
        for revision in item.payload.captureRevisions {
            guard revisions.contains(revision) else { throw syncCorrupt("capture_revisions", revision.id, try Canonical.data(revision)) }
        }
    }
    func syncBusinessItems(_ matchID: String) throws -> [BusinessOutboxItem] {
        if let d = try descriptorAndGeneration(matchID)?.0 { try validateCaptureAbsenceIntegrity(descriptor: d) }
        let items = try db.rows("SELECT id FROM business_outbox WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map { row in
            let item = try loadBusinessOutbox(id: row[0].string ?? "invalid-id")
            guard item.matchID == matchID else { throw syncCorrupt("business_outbox", item.id) }
            try verifySyncBusinessItem(item)
            return item
        }
        try verifyCaptureRegistrySet(kind: "outbox", matchID: matchID, ids: items.map(\.id), table: "business_outbox")
        return items
    }
    func verifySyncFacts(_ packet: MatchPacketV2, projection: MatchDescriptor, now: Date) throws {
        let b = packet.body, snapshot = try loadSnapshot(matchID: b.descriptor.matchID)
        try verifySyncProjection(projection, current: snapshot, now: now)
        _ = try verifyPersistedFacts(descriptor: b.descriptor, events: b.events)
        let revisions = try loadCaptureRevisions(descriptor: snapshot.descriptor)
        for revision in b.captureRevisions {
            guard revisions.contains(revision) else { throw syncCorrupt("capture_revisions", revision.id, try Canonical.data(revision)) }
        }
    }
    func loadSyncRoutes(_ matchID: String) throws -> [StoredSyncRoute] {
        let rows = try db.rows("SELECT outbox_id,packet_id,idempotency_key,source,target,sequence,record,checksum FROM sync_routes_v3 WHERE match_id=? ORDER BY sequence", [.text(matchID)])
        var result: [StoredSyncRoute] = []
        for row in rows {
            let id = row[0].string ?? "invalid-id", raw = row[6].data ?? Data()
            let route = try checkedSync(StoredSyncRoute.self, raw: row[6], checksum: row[7], table: "sync_routes_v3", key: id)
            let r = route.receipt, b = r.packet.body
            guard r.outboxID == id, b.packetID == row[1].string, b.idempotencyKey == row[2].string,
                  b.sourceDeviceID == row[3].string, b.targetDeviceID == row[4].string, b.sequence == row[5].number,
                  b.descriptor.matchID == matchID, route.packetBytes == (try r.packet.canonicalBytes()),
                  b.sourceDeviceID == route.peer.localDeviceID, b.targetDeviceID == route.peer.remoteDeviceID else { throw syncCorrupt("sync_routes_v3", id, raw) }
            try verifySyncRegistry(kind: "route", id: id, matchID: matchID, raw: raw)
            let item = try loadBusinessOutbox(id: id)
            guard item.matchID == matchID, item.sourceDeviceID == b.sourceDeviceID,
                  r.sourcePayloadDigest == Canonical.hash(try Canonical.data(item)),
                  b.packetID == (try SyncWire.derive("packet-id", [id, b.sourceDeviceID, b.targetDeviceID])),
                  b.idempotencyKey == (try SyncWire.derive("idempotency-key", [id, b.sourceDeviceID, b.targetDeviceID])) else { throw syncCorrupt("sync_routes_v3", id, raw) }
            try verifySyncBusinessItem(item)
            guard item.payload.events.allSatisfy(b.events.contains), item.payload.captureRevisions.allSatisfy(b.captureRevisions.contains),
                  item.payload.descriptor.startIntent == b.descriptor.startIntent, item.payload.descriptor.starter == b.descriptor.starter,
                  item.payload.descriptor.startPermit == nil || item.payload.descriptor.startPermit == b.descriptor.startPermit else { throw syncCorrupt("sync_routes_v3", id, raw) }
            try validateSyncSnapshot(r.packet, peer: route.peer)
            try verifySyncFacts(r.packet, projection: b.descriptor, now: route.peer.issuedAt)
            result.append(route)
        }
        try verifySyncRegistrySet(kind: "route", matchID: matchID, ids: result.map { $0.receipt.outboxID }, table: "sync_routes_v3")
        for group in Dictionary(grouping: result, by: { $0.receipt.packet.body.sourceDeviceID + "\0" + $0.receipt.packet.body.targetDeviceID }).values {
            let b = group[0].receipt.packet.body, expected = (group.map { $0.receipt.packet.body.sequence }.max() ?? 0) + 1
            guard let row = try db.rows("SELECT next_sequence FROM sync_sequences_v3 WHERE source=? AND target=? AND match_id=?", [.text(b.sourceDeviceID), .text(b.targetDeviceID), .text(matchID)]).first,
                  row[0].number == expected else { throw syncCorrupt("sync_sequences_v3", matchID) }
            guard Int64(group.count) == expected - 1, group.map({ $0.receipt.packet.body.sequence }).sorted().enumerated().allSatisfy({ $0.element == Int64($0.offset) + 1 }) else { throw syncCorrupt("sync_routes_v3", matchID) }
        }
        return result
    }
    public func unroutedBusinessOutboxV3(matchID: String) throws -> [BusinessOutboxItem] {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                let items = try syncBusinessItems(matchID), routes = try loadSyncRoutes(matchID)
                let routed = Set(routes.map { $0.receipt.outboxID })
                return items.filter { !routed.contains($0.id) }
            }
        }
    }
    public func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) throws -> RouteReceiptV3 {
        try validateSyncPeer(peer, now: now)
        var matchID = outboxID
        let result: RouteReceiptV3
        do {
            result = try db.transaction {
                let item = try loadBusinessOutbox(id: outboxID); matchID = item.matchID
                try bindSyncPeer(peer)
                let routes = try loadSyncRoutes(matchID)
                if let route = routes.first(where: { $0.receipt.outboxID == outboxID }) {
                    guard route.peer.sameBinding(as: peer) else { throw StoreError.invalidPeerAuthorization }
                    return route.receipt
                }
                _ = try syncBusinessItems(matchID)
                guard item.sourceDeviceID == peer.localDeviceID else { throw StoreError.invalidPeerAuthorization }
                let snapshot = try loadSnapshot(matchID: matchID), revisions = try loadCaptureRevisions(descriptor: snapshot.descriptor)
                guard !snapshot.diagnostics.contains(where: { $0.severity == .blocking }) else { throw StoreError.unresolvedDiagnostics }
                let values: [SQLValue] = [.text(peer.localDeviceID), .text(peer.remoteDeviceID), .text(matchID)]
                let next = try db.rows("SELECT next_sequence FROM sync_sequences_v3 WHERE source=? AND target=? AND match_id=?", values).first?.first?.number ?? 1
                let domainCount = routes.filter { $0.receipt.packet.body.sourceDeviceID == peer.localDeviceID && $0.receipt.packet.body.targetDeviceID == peer.remoteDeviceID }.count
                guard next == Int64(domainCount) + 1 else { throw syncCorrupt("sync_sequences_v3", matchID) }
                guard next > 0, next < Int64.max - 1 else { throw StoreError.syncQuotaExceeded }
                // Validate closure before assigning a sequence or freezing immutable bytes.
                let packet = try MatchPacketV2(packetID: SyncWire.derive("packet-id", [outboxID, peer.localDeviceID, peer.remoteDeviceID]), idempotencyKey: SyncWire.derive("idempotency-key", [outboxID, peer.localDeviceID, peer.remoteDeviceID]), sequence: next, sourceDeviceID: peer.localDeviceID, targetDeviceID: peer.remoteDeviceID, descriptor: snapshot.descriptor, events: snapshot.events, captureRevisions: revisions)
                do { try validateSyncSnapshot(packet, peer: peer) }
                catch StoreError.ancestryIncomplete { throw quarantine(.ancestryIncomplete, code: "sync-ancestry-incomplete", key: outboxID, raw: try packet.canonicalBytes(), severity: .audit) }
                let bytes = try packet.canonicalBytes()
                guard bytes.count <= SyncWire.maximumBytes else { throw StoreError.syncQuotaExceeded }
                let receipt = try RouteReceiptV3(outboxID: outboxID, sourcePayloadDigest: Canonical.hash(Canonical.data(item)), packet: packet)
                let saved = StoredSyncRoute(receipt: receipt, packetBytes: bytes, peer: peer), raw = try Canonical.data(saved)
                try db.execute("INSERT INTO sync_routes_v3 VALUES (?,?,?,?,?,?,?,?,?)", [.text(outboxID), .text(packet.body.packetID), .text(packet.body.idempotencyKey)] + values + [.integer(next), .blob(raw), .text(Canonical.hash(raw))])
                try saveSyncRegistry(kind: "route", id: outboxID, matchID: matchID, raw: raw)
                try db.execute("INSERT INTO sync_sequences_v3 VALUES (?,?,?,?) ON CONFLICT(source,target,match_id) DO UPDATE SET next_sequence=excluded.next_sequence", values + [.integer(next + 1)])
                try fail(.afterRoute); try fail(.beforeCommit)
                return receipt
            }
        } catch { return try preservingDiagnostics(matchID: matchID) { throw error } }
        if fault == .afterCommit { throw StoreError.responseLost }; return result
    }
    func loadSyncACKs(_ matchID: String, routes: [StoredSyncRoute]) throws -> [StoredSyncACK] {
        var result: [StoredSyncACK] = []
        for row in try db.rows("SELECT packet_id,ack_id,record,checksum FROM sync_acknowledgements_v3 WHERE match_id=?", [.text(matchID)]) {
            let id = row[0].string ?? "invalid-id", raw = row[2].data ?? Data()
            let saved = try checkedSync(StoredSyncACK.self, raw: row[2], checksum: row[3], table: "sync_acknowledgements_v3", key: id)
            guard let route = routes.first(where: { $0.receipt.packet.body.packetID == id }),
                  route.peer.sameBinding(as: saved.peer), saved.acceptedAt.timeIntervalSinceReferenceDate.isFinite,
                  let ack = try? JSONDecoder().decode(DurableACKV2.self, from: saved.raw), ack == (try DurableACKV2(packet: route.receipt.packet)),
                  saved.raw == (try ack.canonicalBytes()), row[1].string == ack.body.ackID else { throw syncCorrupt("sync_acknowledgements_v3", id, raw) }
            try verifySyncRegistry(kind: "ack", id: id, matchID: matchID, raw: raw); result.append(saved)
        }
        let ids = try result.map { try JSONDecoder().decode(DurableACKV2.self, from: $0.raw).body.packetID }
        try verifySyncRegistrySet(kind: "ack", matchID: matchID, ids: ids, table: "sync_acknowledgements_v3")
        return result
    }
    public func pendingPacketsV2(matchID: String) throws -> [MatchPacketV2] {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                _ = try syncBusinessItems(matchID)
                let routes = try loadSyncRoutes(matchID), acknowledgements = try loadSyncACKs(matchID, routes: routes)
                let acked = Set(try acknowledgements.map { try JSONDecoder().decode(DurableACKV2.self, from: $0.raw).body.packetID })
                return routes.map { $0.receipt.packet }.filter { !acked.contains($0.body.packetID) }
            }
        }
    }
    public func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) throws {
        try validateSyncPeer(peer, now: now)
        guard bytes.count <= SyncWire.maximumBytes else { throw StoreError.syncQuotaExceeded }
        let ack: DurableACKV2
        do { ack = try JSONDecoder().decode(DurableACKV2.self, from: bytes); guard bytes == (try ack.canonicalBytes()) else { throw StoreError.invalidACK } }
        catch {
            var scope = "sync-wire"
            if let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let body = json["body"] as? [String: Any], let id = body["matchID"] as? String,
               !(try db.rows("SELECT match_id FROM matches WHERE match_id=?", [.text(id)])).isEmpty { scope = id }
            return try preservingDiagnostics(matchID: scope) {
                throw quarantine(.invalidACK, code: "invalid-sync-ack-wire", key: Canonical.hash(bytes), raw: bytes, severity: .audit)
            }
        }
        let b = ack.body
        try preservingDiagnostics(matchID: b.matchID) {
            do {
                try db.transaction {
                    try bindSyncPeer(peer)
                    guard b.sourceDeviceID == peer.remoteDeviceID, b.targetDeviceID == peer.localDeviceID else { throw StoreError.invalidACK }
                    let routes = try loadSyncRoutes(b.matchID), savedACKs = try loadSyncACKs(b.matchID, routes: routes)
                    guard let route = routes.first(where: { $0.receipt.packet.body.packetID == b.packetID }),
                          route.peer.sameBinding(as: peer), ack == (try DurableACKV2(packet: route.receipt.packet)) else { throw StoreError.invalidACK }
                    if let saved = try savedACKs.first(where: { try JSONDecoder().decode(DurableACKV2.self, from: $0.raw).body.packetID == b.packetID }) {
                        guard saved.raw == bytes else { throw StoreError.invalidACK }; return
                    }
                    let raw = try Canonical.data(StoredSyncACK(raw: bytes, peer: peer, acceptedAt: now))
                    try db.execute("INSERT INTO sync_acknowledgements_v3 VALUES (?,?,?,?,?)", [.text(b.packetID), .text(b.ackID), .text(b.matchID), .blob(raw), .text(Canonical.hash(raw))])
                    try saveSyncRegistry(kind: "ack", id: b.packetID, matchID: b.matchID, raw: raw)
                    try fail(.afterACK); try fail(.beforeCommit)
                }
            } catch let error as StoreError {
                throw quarantine(error, code: "invalid-sync-ack", key: b.ackID, raw: bytes, severity: .audit)
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }
    }
    func loadSyncInboxes(_ matchID: String) throws -> [StoredSyncInbox] {
        var result: [StoredSyncInbox] = []
        for row in try db.rows("SELECT packet_id,idempotency_key,source,target,sequence,record,checksum FROM sync_inbox_v3 WHERE match_id=? ORDER BY sequence", [.text(matchID)]) {
            let id = row[0].string ?? "invalid-id", raw = row[5].data ?? Data()
            let saved = try checkedSync(StoredSyncInbox.self, raw: row[5], checksum: row[6], table: "sync_inbox_v3", key: id)
            guard let packet = try? JSONDecoder().decode(MatchPacketV2.self, from: saved.packetBytes) else { throw syncCorrupt("sync_inbox_v3", id, raw) }
            let b = packet.body, receipt = saved.receipt
            guard b.packetID == id, b.idempotencyKey == row[1].string, b.sourceDeviceID == row[2].string,
                  b.targetDeviceID == row[3].string, b.sequence == row[4].number, b.descriptor.matchID == matchID,
                  b.sourceDeviceID == saved.peer.remoteDeviceID, b.targetDeviceID == saved.peer.localDeviceID,
                  saved.packetBytes == (try packet.canonicalBytes()), receipt.matchID == matchID,
                  receipt.ack == (try DurableACKV2(packet: packet)), saved.ackBytes == (try receipt.ack.canonicalBytes()),
                  Set(receipt.insertedEventIDs).isSubset(of: Set(b.events.map(\.eventID))),
                  Set(receipt.insertedCaptureRevisionIDs).isSubset(of: Set(b.captureRevisions.map(\.id))) else { throw syncCorrupt("sync_inbox_v3", id, raw) }
            try validateSyncSnapshot(packet, peer: saved.peer)
            try verifySyncRegistry(kind: "inbox", id: id, matchID: matchID, raw: raw)
            try verifySyncFacts(packet, projection: saved.projection, now: b.events.map(\.createdAt).max() ?? b.descriptor.startIntent.requestedAt)
            guard let current = try descriptorAndGeneration(matchID), current.1 >= receipt.generation else { throw syncCorrupt("sync_inbox_v3", id, raw) }
            let ackID = receipt.ack.body.ackID
            guard let control = try db.rows("SELECT packet_id,match_id,raw,checksum FROM sync_ack_controls_v3 WHERE ack_id=?", [.text(ackID)]).first,
                  control[0].string == id, control[1].string == matchID, control[2].data == saved.ackBytes,
                  control[3].string == Canonical.hash(saved.ackBytes) else { throw syncCorrupt("sync_ack_controls_v3", ackID, saved.ackBytes) }
            try verifySyncRegistry(kind: "control", id: ackID, matchID: matchID, raw: saved.ackBytes)
            result.append(saved)
        }
        try verifySyncRegistrySet(kind: "inbox", matchID: matchID, ids: result.map { $0.receipt.ack.body.packetID }, table: "sync_inbox_v3")
        try verifySyncRegistrySet(kind: "control", matchID: matchID, ids: result.map { $0.receipt.ack.body.ackID }, table: "sync_ack_controls_v3")
        let controls = try db.rows("SELECT ack_id FROM sync_ack_controls_v3 WHERE match_id=?", [.text(matchID)]).map { $0[0].string ?? "invalid-id" }
        guard Set(controls) == Set(result.map { $0.receipt.ack.body.ackID }) else { throw syncCorrupt("sync_ack_controls_v3", matchID) }
        return result
    }
    func syncProgressKey(source: String, target: String) -> String { source + "\0" + target }
    func verifySyncProgress(_ matchID: String, inboxes: [StoredSyncInbox]) throws -> [SyncReceiveProgress] {
        let grouped = Dictionary(grouping: inboxes, by: { syncProgressKey(source: $0.receipt.ack.body.targetDeviceID, target: $0.receipt.ack.body.sourceDeviceID) })
        let rows = try db.rows("SELECT source,target,record,checksum FROM sync_receive_progress_v3 WHERE match_id=?", [.text(matchID)])
        guard rows.count == grouped.count else { throw syncCorrupt("sync_receive_progress_v3", matchID) }
        return try rows.map { row in
            guard let source = row[0].string, let target = row[1].string, let group = grouped[syncProgressKey(source: source, target: target)] else { throw syncCorrupt("sync_receive_progress_v3", matchID) }
            let progress = try checkedSync(SyncReceiveProgress.self, raw: row[2], checksum: row[3], table: "sync_receive_progress_v3", key: matchID)
            guard progress == (try SyncReceiveProgress(sequences: group.map { $0.receipt.ack.body.sequence })) else { throw syncCorrupt("sync_receive_progress_v3", matchID, row[2].data ?? Data()) }
            return progress
        }
    }
    public func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) throws -> InboundReceiptV3 {
        try validateSyncPeer(peer, now: now)
        guard bytes.count <= SyncWire.maximumBytes else { throw StoreError.syncQuotaExceeded }
        let result: InboundReceiptV3 = try preservingDiagnostics(matchID: expectedMatchID) {
            let packet: MatchPacketV2
            do {
                packet = try JSONDecoder().decode(MatchPacketV2.self, from: bytes)
                guard bytes == (try packet.canonicalBytes()) else { throw StoreError.invalidPacket }
            } catch { throw quarantine(.invalidPacket, code: "invalid-sync-wire", key: Canonical.hash(bytes), raw: bytes, severity: .audit) }
            let b = packet.body
            guard b.sourceDeviceID == peer.remoteDeviceID, b.targetDeviceID == peer.localDeviceID,
                  b.descriptor.matchID == expectedMatchID else { throw quarantine(.invalidPacket, code: "invalid-sync-routing", key: b.packetID, raw: bytes, severity: .audit) }
            do { try validateSyncSnapshot(packet, peer: peer) }
            catch { throw quarantine(.invalidPacket, code: "invalid-sync-facts", key: b.packetID, raw: bytes) }
            do {
                return try db.transaction {
                    try bindSyncPeer(peer)
                    let inboxes = try loadSyncInboxes(expectedMatchID)
                    _ = try verifySyncProgress(expectedMatchID, inboxes: inboxes)
                    let collisions = inboxes.filter { saved in
                        let ack = saved.receipt.ack.body
                        return ack.packetID == b.packetID || ack.idempotencyKey == b.idempotencyKey || (ack.sourceDeviceID == b.targetDeviceID && ack.targetDeviceID == b.sourceDeviceID && ack.sequence == b.sequence)
                    }
                    if let saved = collisions.first {
                        guard collisions.count == 1, saved.packetBytes == bytes, saved.peer.sameBinding(as: peer) else { throw StoreError.packetConflict }
                        return saved.receipt
                    }
                    // Also reject globally reused packet or idempotency identities from another match.
                    guard try db.rows("SELECT packet_id FROM sync_inbox_v3 WHERE packet_id=? OR idempotency_key=?", [.text(b.packetID), .text(b.idempotencyKey)]).isEmpty else { throw StoreError.packetConflict }
                    let current = try descriptorAndGeneration(expectedMatchID).map { _ in try loadSnapshot(matchID: expectedMatchID) }
                    let projection = try acceptedSyncProjection(b.descriptor, current: current, now: now)
                    if let current { try rejectInboundCaptureAbsenceContradictions(descriptor: current.descriptor, revisions: b.captureRevisions, raw: bytes) }
                    let oldRevisions = try current.map { try loadCaptureRevisions(descriptor: $0.descriptor) } ?? []
                    for (old, incoming) in zip(oldRevisions, b.captureRevisions) { guard old == incoming else { throw StoreError.captureBranch } }
                    let eventIDs = Set(current?.events.map(\.eventID) ?? []), revisionIDs = Set(oldRevisions.map(\.id))
                    let insertedEvents = b.events.filter { !eventIDs.contains($0.eventID) }, insertedRevisions = b.captureRevisions.filter { !revisionIDs.contains($0.id) }
                    let changed = current == nil || current?.descriptor != projection || !insertedEvents.isEmpty || !insertedRevisions.isEmpty
                    let generation = current?.generation ?? 0
                    guard !changed || generation < Int64.max else { throw StoreError.invalidRequest }
                    let newGeneration = changed ? generation + 1 : generation
                    if changed { try writeDescriptor(projection, generation: newGeneration) }
                    try append(b.events, matchID: expectedMatchID)
                    for revision in insertedRevisions { try appendRevision(revision, descriptor: projection) }
                    let merged = try loadSnapshot(matchID: expectedMatchID), mergedRevisions = try loadCaptureRevisions(descriptor: projection)
                    let union = try MatchPacketV2(packetID: b.packetID, idempotencyKey: b.idempotencyKey, sequence: b.sequence, sourceDeviceID: b.sourceDeviceID, targetDeviceID: b.targetDeviceID, descriptor: b.descriptor, events: merged.events, captureRevisions: mergedRevisions)
                    try validateSyncSnapshot(union, peer: peer)
                    try validateCaptureAbsenceIntegrity(descriptor: projection)
                    try fail(.afterInboundFacts)
                    let ack = try DurableACKV2(packet: packet), ackBytes = try ack.canonicalBytes()
                    let receipt = try InboundReceiptV3(ack: ack, matchID: expectedMatchID, generation: newGeneration, insertedEventIDs: insertedEvents.map(\.eventID), insertedCaptureRevisionIDs: insertedRevisions.map(\.id))
                    let saved = StoredSyncInbox(packetBytes: bytes, projection: projection, receipt: receipt, ackBytes: ackBytes, peer: peer), raw = try Canonical.data(saved)
                    try db.execute("INSERT INTO sync_inbox_v3 VALUES (?,?,?,?,?,?,?,?)", [.text(b.packetID), .text(b.idempotencyKey), .text(b.sourceDeviceID), .text(b.targetDeviceID), .text(expectedMatchID), .integer(b.sequence), .blob(raw), .text(Canonical.hash(raw))])
                    try saveSyncRegistry(kind: "inbox", id: b.packetID, matchID: expectedMatchID, raw: raw)
                    try db.execute("INSERT INTO sync_ack_controls_v3 VALUES (?,?,?,?,?)", [.text(ack.body.ackID), .text(b.packetID), .text(expectedMatchID), .blob(ackBytes), .text(Canonical.hash(ackBytes))])
                    try saveSyncRegistry(kind: "control", id: ack.body.ackID, matchID: expectedMatchID, raw: ackBytes)
                    let sameDomain = inboxes.filter { $0.receipt.ack.body.sourceDeviceID == b.targetDeviceID && $0.receipt.ack.body.targetDeviceID == b.sourceDeviceID }
                    let progress = try SyncReceiveProgress(sequences: sameDomain.map { $0.receipt.ack.body.sequence } + [b.sequence]), progressRaw = try Canonical.data(progress)
                    try db.execute("INSERT INTO sync_receive_progress_v3 VALUES (?,?,?,?,?) ON CONFLICT(source,target,match_id) DO UPDATE SET record=excluded.record,checksum=excluded.checksum", [.text(b.sourceDeviceID), .text(b.targetDeviceID), .text(expectedMatchID), .blob(progressRaw), .text(Canonical.hash(progressRaw))])
                    try fail(.afterInboundReceipt); try fail(.beforeCommit)
                    return receipt
                }
            } catch let q as Quarantined {
                if q.diagnostic.code == "capture-absence-contradiction" { throw q }
                switch q.error {
                case .eventConflict, .captureConflict, .captureBranch, .invalidCaptureRevision, .missingCaptureParent:
                    throw quarantine(q.error, code: "sync-fact-conflict", key: b.packetID, raw: bytes)
                default: throw q
                }
            } catch let error as StoreError {
                // Transaction/connection failures are retryable; they are not evidence of bad facts.
                switch error {
                case .injectedFailure, .sqlite, .closed: throw error
                default: throw quarantine(error, code: "sync-receive-rejected", key: b.packetID, raw: bytes)
                }
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }; return result
    }
    public func syncStateV3(matchID: String) throws -> SyncState {
        try SyncWire.id(matchID)
        return try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                guard try descriptorAndGeneration(matchID) != nil else { throw StoreError.notFound }
                let items = try syncBusinessItems(matchID), routes = try loadSyncRoutes(matchID), acknowledgements = try loadSyncACKs(matchID, routes: routes)
                let inboxes = try loadSyncInboxes(matchID), progress = try verifySyncProgress(matchID, inboxes: inboxes)
                let routed = Set(routes.map { $0.receipt.outboxID }), unrouted = items.filter { !routed.contains($0.id) }
                let diagnostics = try diagnostics(matchID: matchID)
                let issue: SyncIssue? = diagnostics.contains { $0.severity == .blocking } ? .blockedIntegrity : diagnostics.contains { $0.code == "sync-ancestry-incomplete" && unrouted.map(\.id).contains($0.key) } ? .ancestryIncomplete : nil
                return try SyncState(matchID: matchID, unroutedCount: unrouted.count, pendingACKCount: routes.count - acknowledgements.count, receivedGapCount: progress.reduce(0) { $0 + $1.gaps.count }, lastPeerACKAt: acknowledgements.map(\.acceptedAt).max(), issue: issue)
            }
        }
    }
}
