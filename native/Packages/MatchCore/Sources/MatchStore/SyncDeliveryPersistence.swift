import Foundation

struct StoredDelivery: Codable {
    var delivery: SyncDeliveryRecord
    var consecutiveAttempts: Int
    var sleeping: Bool
    var issue: SyncIssue?
}
struct AssemblyHeader: Codable, Equatable {
    let messageID, source, target, matchID, wholeChecksum: String
    let kind: SyncMessageKind
    let totalBytes, count: Int
    init(_ body: SyncFragment.Body) {
        messageID = body.messageID; source = body.sourceDeviceID; target = body.targetDeviceID
        matchID = body.matchID; wholeChecksum = body.wholeChecksum; kind = body.kind
        totalBytes = body.totalBytes; count = body.count
    }
    var id: String { get throws { try SyncWire.derive("assembly-id", [messageID, source, target]) } }
}
struct StoredAssembly: Codable {
    let header: AssemblyHeader
    let peer: PeerAuthorization
    var firstReceivedAt, expiresAt: Date
    var fragments: [Data]
    var consumed, expired: Bool
}

extension MatchStore {
    func loadSyncDeliveries(matchID: String? = nil) throws -> [StoredDelivery] {
        let rows = try db.rows("SELECT delivery_id,match_id,record,checksum FROM sync_delivery_v3" + (matchID == nil ? "" : " WHERE match_id=?"), matchID.map { [.text($0)] } ?? [])
        let values: [StoredDelivery] = try rows.map { row in
            let id = row[0].string ?? "invalid-id", saved = try checkedSync(StoredDelivery.self, raw: row[2], checksum: row[3], table: "sync_delivery_v3", key: id), d = saved.delivery
            guard d.deliveryID == id, d.matchID == row[1].string, saved.consecutiveAttempts >= 0,
                  saved.consecutiveAttempts <= d.attemptCount,
                  !saved.sleeping || (d.kind == .ack && saved.consecutiveAttempts >= 8) else { throw syncCorrupt("sync_delivery_v3", id, row[2].data ?? Data()) }
            try verifySyncRegistry(kind: "delivery", id: id, matchID: d.matchID, raw: d.fragmentBytes)
            return saved
        }
        let registered: [String]
        if let matchID { registered = [matchID] }
        else { registered = try db.rows("SELECT DISTINCT match_id FROM sync_registry_v3 WHERE kind='delivery'").compactMap { $0[0].string } }
        let matches = Set(values.map { $0.delivery.matchID }).union(registered)
        for match in matches {
            try verifySyncRegistrySet(kind: "delivery", matchID: match, ids: values.filter { $0.delivery.matchID == match }.map { $0.delivery.deliveryID }, table: "sync_delivery_v3")
        }
        return values
    }
    func writeDelivery(_ saved: StoredDelivery) throws {
        let raw = try Canonical.data(saved)
        try db.execute("UPDATE sync_delivery_v3 SET record=?,checksum=? WHERE delivery_id=?", [.blob(raw), .text(Canonical.hash(raw)), .text(saved.delivery.deliveryID)])
    }
    public func ensureSyncDeliveriesV3(matchID: String) throws {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                let routes = try loadSyncRoutes(matchID), inboxes = try loadSyncInboxes(matchID)
                _ = try loadSyncACKs(matchID, routes: routes)
                let saved = try loadSyncDeliveries(matchID: matchID), ids = Set(saved.map { $0.delivery.deliveryID })
                let messages: [(Data, SyncMessageKind)] = routes.map { ($0.packetBytes, .packet) } + inboxes.map { ($0.ackBytes, .ack) }
                for (bytes, kind) in messages {
                    for fragment in try SyncFragment.fragments(bytes: bytes, kind: kind) {
                        let id = try fragment.fragmentID
                        if ids.contains(id) { continue }
                        let b = fragment.body, rawFragment = try fragment.canonicalBytes()
                        let delivery = try SyncDeliveryRecord(deliveryID: id, messageID: b.messageID, matchID: b.matchID, sourceDeviceID: b.sourceDeviceID, targetDeviceID: b.targetDeviceID, kind: kind, fragmentBytes: rawFragment, attemptCount: 0, nextAttemptAt: .distantPast)
                        let raw = try Canonical.data(StoredDelivery(delivery: delivery, consecutiveAttempts: 0, sleeping: false, issue: nil))
                        try db.execute("INSERT INTO sync_delivery_v3 VALUES (?,?,?,?)", [.text(id), .text(matchID), .blob(raw), .text(Canonical.hash(raw))])
                        try saveSyncRegistry(kind: "delivery", id: id, matchID: matchID, raw: rawFragment)
                    }
                }
                try fail(.beforeCommit)
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }
    }
    func deliveryAuthorization(_ delivery: SyncDeliveryRecord) throws -> PeerAuthorization {
        if delivery.kind == .packet {
            guard let route = try loadSyncRoutes(delivery.matchID).first(where: { $0.receipt.packet.body.packetID == delivery.messageID }) else { throw syncCorrupt("sync_delivery_v3", delivery.deliveryID, delivery.fragmentBytes) }
            let fragments = try SyncFragment.fragments(bytes: route.packetBytes, kind: .packet)
            guard try fragments.contains(where: { try $0.canonicalBytes() == delivery.fragmentBytes }) else { throw syncCorrupt("sync_delivery_v3", delivery.deliveryID, delivery.fragmentBytes) }
            return route.peer
        }
        guard let inbox = try loadSyncInboxes(delivery.matchID).first(where: { $0.receipt.ack.body.ackID == delivery.messageID }),
              try SyncFragment.fragments(bytes: inbox.ackBytes, kind: .ack).contains(where: { try $0.canonicalBytes() == delivery.fragmentBytes }) else { throw syncCorrupt("sync_delivery_v3", delivery.deliveryID, delivery.fragmentBytes) }
        return inbox.peer
    }
    public func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) throws {
        try validateSyncPeer(peer, now: now)
        var match = "sync-wire"
        do {
            try db.transaction {
                guard let saved = try loadSyncDeliveries().first(where: { $0.delivery.deliveryID == deliveryID }) else { throw StoreError.notFound }
                match = saved.delivery.matchID
                guard try deliveryAuthorization(saved.delivery).sameBinding(as: peer) else { throw StoreError.invalidPeerAuthorization }
            }
        } catch { try preservingDiagnostics(matchID: match) { throw error } }
    }
    public func dueSyncDeliveriesV3(now: Date, limit: Int) throws -> [SyncDeliveryRecord] {
        guard now.timeIntervalSinceReferenceDate.isFinite, limit > 0, limit <= 32 else { throw StoreError.invalidRequest }
        return try preservingDiagnostics(matchID: "sync-wire") {
            try db.transaction {
                let rows = try loadSyncDeliveries()
                var acknowledged = Set<String>()
                for match in Set(rows.map { $0.delivery.matchID }) {
                    let routes = try loadSyncRoutes(match), acks = try loadSyncACKs(match, routes: routes)
                    for a in acks { acknowledged.insert(try JSONDecoder().decode(DurableACKV2.self, from: a.raw).body.packetID) }
                }
                let active = try rows.filter { saved in
                    _ = try deliveryAuthorization(saved.delivery)
                    return !saved.sleeping && saved.delivery.nextAttemptAt <= now && !(saved.delivery.kind == .packet && acknowledged.contains(saved.delivery.messageID))
                }
                return Array(active.sorted { ($0.delivery.nextAttemptAt, $0.delivery.deliveryID) < ($1.delivery.nextAttemptAt, $1.delivery.deliveryID) }.prefix(limit)).map(\.delivery)
            }
        }
    }
    public func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite, nextAttemptAt.timeIntervalSinceReferenceDate.isFinite, nextAttemptAt >= now else { throw StoreError.invalidRequest }
        try preservingDiagnostics(matchID: "sync-wire") {
            try db.transaction {
                guard var saved = try loadSyncDeliveries().first(where: { $0.delivery.deliveryID == deliveryID }) else { throw StoreError.notFound }
                let d = saved.delivery
                guard d.attemptCount < Int.max, saved.consecutiveAttempts < Int.max else { throw StoreError.syncQuotaExceeded }
                saved.delivery = try SyncDeliveryRecord(deliveryID: d.deliveryID, messageID: d.messageID, matchID: d.matchID, sourceDeviceID: d.sourceDeviceID, targetDeviceID: d.targetDeviceID, kind: d.kind, fragmentBytes: d.fragmentBytes, attemptCount: d.attemptCount + 1, nextAttemptAt: nextAttemptAt)
                saved.consecutiveAttempts += 1; saved.sleeping = d.kind == .ack && saved.consecutiveAttempts >= 8; saved.issue = issue
                try writeDelivery(saved); try fail(.beforeCommit)
            }
        }
    }
    func reactivateSyncACKsLocked(messageID: String? = nil) throws {
        for var saved in try loadSyncDeliveries() where saved.delivery.kind == .ack && (messageID == nil || saved.delivery.messageID == messageID) {
            let d = saved.delivery
            saved.delivery = try SyncDeliveryRecord(deliveryID: d.deliveryID, messageID: d.messageID, matchID: d.matchID, sourceDeviceID: d.sourceDeviceID, targetDeviceID: d.targetDeviceID, kind: d.kind, fragmentBytes: d.fragmentBytes, attemptCount: d.attemptCount, nextAttemptAt: .distantPast)
            saved.consecutiveAttempts = 0; saved.sleeping = false; saved.issue = nil; try writeDelivery(saved)
        }
    }
    public func reactivateSyncACKsV3() throws {
        try preservingDiagnostics(matchID: "sync-wire") { try db.transaction { try reactivateSyncACKsLocked() } }
    }
    func loadSyncAssemblies() throws -> [StoredAssembly] {
        try db.rows("SELECT fragment_id,match_id,record,checksum FROM sync_fragments_v3").map { row in
            let id = row[0].string ?? "invalid-id", saved = try checkedSync(StoredAssembly.self, raw: row[2], checksum: row[3], table: "sync_fragments_v3", key: id), h = saved.header
            guard try h.id == id, h.matchID == row[1].string, saved.firstReceivedAt.timeIntervalSinceReferenceDate.isFinite,
                  saved.expiresAt.timeIntervalSinceReferenceDate.isFinite, saved.expiresAt == saved.firstReceivedAt.addingTimeInterval(86_400),
                  saved.expired ? saved.fragments.isEmpty : !saved.fragments.isEmpty else { throw syncCorrupt("sync_fragments_v3", id, row[2].data ?? Data()) }
            var indexes = Set<Int>()
            for bytes in saved.fragments {
                let f = try JSONDecoder().decode(SyncFragment.self, from: bytes)
                guard bytes == (try f.canonicalBytes()), AssemblyHeader(f.body) == h, indexes.insert(f.body.index).inserted else { throw syncCorrupt("sync_fragments_v3", id, bytes) }
            }
            return saved
        }
    }
    func writeAssembly(_ saved: StoredAssembly) throws {
        let raw = try Canonical.data(saved)
        try db.execute("INSERT INTO sync_fragments_v3 VALUES (?,?,?,?) ON CONFLICT(fragment_id) DO UPDATE SET record=excluded.record,checksum=excluded.checksum", [.text(try saved.header.id), .text(saved.header.matchID), .blob(raw), .text(Canonical.hash(raw))])
    }
    func assembled(_ saved: StoredAssembly) throws -> FragmentAssemblyResult {
        guard !saved.expired, saved.fragments.count == saved.header.count else { return .incomplete }
        let fragments = try saved.fragments.map { try JSONDecoder().decode(SyncFragment.self, from: $0) }.sorted { $0.body.index < $1.body.index }
        let bytes = fragments.reduce(into: Data()) { $0.append($1.body.payload) }, h = saved.header
        guard bytes.count == h.totalBytes, Canonical.hash(bytes) == h.wholeChecksum else { throw StoreError.invalidPacket }
        do {
            guard try SyncMessageHeader(bytes: bytes, kind: h.kind).matches(fragments[0].body) else { throw StoreError.invalidPacket }
        } catch { throw StoreError.invalidPacket }
        return .complete(messageID: h.messageID, kind: h.kind, matchID: h.matchID, wholeChecksum: h.wholeChecksum, bytes: bytes)
    }
    public func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) throws -> FragmentAssemblyResult {
        try validateSyncPeer(peer, now: now)
        guard bytes.count <= SyncFragment.maximumEncodedBytes else { throw StoreError.syncQuotaExceeded }
        let fragment: SyncFragment
        do { fragment = try JSONDecoder().decode(SyncFragment.self, from: bytes); guard bytes == (try fragment.canonicalBytes()) else { throw StoreError.invalidPacket } }
        catch { return try preservingDiagnostics(matchID: "sync-wire") { throw quarantine(.invalidPacket, code: "invalid-sync-fragment", key: Canonical.hash(bytes), raw: bytes, severity: .audit) } }
        let b = fragment.body
        guard b.sourceDeviceID == peer.remoteDeviceID, b.targetDeviceID == peer.localDeviceID else { throw StoreError.invalidPeerAuthorization }
        let result: FragmentAssemblyResult = try preservingDiagnostics(matchID: b.matchID) {
            do {
                return try db.transaction {
                    try bindSyncPeer(peer)
                    let all = try loadSyncAssemblies(), header = AssemblyHeader(b), id = try header.id
                    var saved = try all.first { try $0.header.id == id } ?? StoredAssembly(header: header, peer: peer, firstReceivedAt: now, expiresAt: now.addingTimeInterval(86_400), fragments: [], consumed: false, expired: false)
                    guard saved.header == header, saved.peer.sameBinding(as: peer) else { throw StoreError.syncConflict }
                    if saved.expired {
                        saved = StoredAssembly(header: header, peer: peer, firstReceivedAt: now, expiresAt: now.addingTimeInterval(86_400), fragments: [], consumed: false, expired: false)
                    } else if now >= saved.expiresAt, saved.fragments.count < saved.header.count { throw StoreError.syncAssemblyExpired }
                    if let existing = try saved.fragments.first(where: { try JSONDecoder().decode(SyncFragment.self, from: $0).body.index == b.index }) {
                        guard existing == bytes else { throw StoreError.syncConflict }
                        return try assembled(saved)
                    }
                    let active = all.filter { !$0.expired && !$0.consumed && $0.peer.localDeviceID == peer.localDeviceID && $0.peer.remoteDeviceID == peer.remoteDeviceID }
                    let newMessage = !active.contains { (try? $0.header.id) == id }
                    let storedBytes = active.reduce(0) { $0 + $1.fragments.reduce(0) { $0 + $1.count } }
                    guard (!newMessage || active.count < 256), storedBytes <= 64 * 1024 * 1024 - bytes.count else { throw StoreError.syncQuotaExceeded }
                    saved.fragments.append(bytes)
                    saved.fragments = try saved.fragments.sorted { try JSONDecoder().decode(SyncFragment.self, from: $0).body.index < JSONDecoder().decode(SyncFragment.self, from: $1).body.index }
                    let result = try assembled(saved)
                    try writeAssembly(saved); try fail(.afterFragment); try fail(.beforeCommit)
                    return result
                }
            } catch let error as StoreError {
                switch error {
                case .injectedFailure, .sqlite, .closed: throw error
                case .syncQuotaExceeded, .syncAssemblyExpired: throw quarantine(error, code: "sync-fragment-quota-timeout", key: b.messageID, raw: bytes, severity: .audit)
                default: throw quarantine(error, code: "sync-fragment-conflict", key: b.messageID, raw: bytes)
                }
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }; return result
    }
    public func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) throws -> [FragmentAssemblyResult] {
        try validateSyncPeer(peer, now: now)
        return try preservingDiagnostics(matchID: "sync-wire") {
            try db.transaction {
                try bindSyncPeer(peer)
                return try loadSyncAssemblies().filter { !$0.expired && $0.fragments.count == $0.header.count }.compactMap { saved in
                    guard saved.peer.sameBinding(as: peer) else { throw StoreError.invalidPeerAuthorization }
                    let result = try assembled(saved)
                    if case .complete = result { return result }; return nil
                }
            }
        }
    }
    func hasDurableSyncReceipt(messageID: String, wholeChecksum: String) throws -> Bool {
        if let match = try db.rows("SELECT match_id FROM sync_inbox_v3 WHERE packet_id=?", [.text(messageID)]).first?[0].string {
            return try loadSyncInboxes(match).contains { $0.receipt.ack.body.packetID == messageID && Canonical.hash($0.packetBytes) == wholeChecksum }
        }
        if let match = try db.rows("SELECT match_id FROM sync_acknowledgements_v3 WHERE ack_id=?", [.text(messageID)]).first?[0].string {
            let routes = try loadSyncRoutes(match)
            return try loadSyncACKs(match, routes: routes).contains { Canonical.hash($0.raw) == wholeChecksum }
        }
        return false
    }
    public func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) throws {
        try preservingDiagnostics(matchID: "sync-wire") {
            try db.transaction {
                guard try hasDurableSyncReceipt(messageID: messageID, wholeChecksum: wholeChecksum) else { throw StoreError.notFound }
                if let saved = try loadSyncAssemblies().first(where: { $0.header.messageID == messageID && $0.header.wholeChecksum == wholeChecksum }) {
                    guard case .complete = try assembled(saved) else { throw StoreError.invalidPacket }
                    // Packet/inbox and ACK receipts retain original bytes; temporary chunks do not.
                    try db.execute("DELETE FROM sync_fragments_v3 WHERE fragment_id=?", [.text(try saved.header.id)])
                }
            }
        }
    }
    public func expireSyncAssembliesV3(now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidRequest }
        try preservingDiagnostics(matchID: "sync-wire") {
            try db.transaction {
                for var saved in try loadSyncAssemblies() where !saved.consumed && !saved.expired && saved.fragments.count < saved.header.count && now >= saved.expiresAt {
                    let h = saved.header
                    try db.execute("INSERT OR IGNORE INTO diagnostics VALUES (?,?,?,?,?)", [.text(h.matchID), .text("sync-fragment-timeout"), .text(h.messageID), .blob(try Canonical.data(h)), .text("audit")])
                    saved.fragments = []; saved.expired = true; try writeAssembly(saved)
                }
            }
        }
    }
}

extension MatchStore {
    /// Delivery failures remain authoritative during backoff and after reopening.
    /// A real matching business ACK removes packet delivery failures from active state.
    func syncDeliveryIssue(_ matchID: String, acknowledgedPacketIDs: Set<String>) throws -> SyncIssue? {
        let active = try loadSyncDeliveries(matchID: matchID).filter {
            !($0.delivery.kind == .packet && acknowledgedPacketIDs.contains($0.delivery.messageID))
        }
        for saved in active { _ = try deliveryAuthorization(saved.delivery) }
        return active.sorted { $0.delivery.deliveryID < $1.delivery.deliveryID }.compactMap(\.issue).first
    }
}
