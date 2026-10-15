import Foundation
import MatchCore

/// All database operations execute synchronously inside this actor; there is no await in a SQL transaction.
public actor MatchStore {
    private let db: SQLite
    private let fault: StoreFault?
    public init(url: URL) throws { db = try SQLite(url: url, fault: nil); fault = nil }
    init(url: URL, fault: StoreFault) throws { db = try SQLite(url: url, fault: fault); self.fault = fault }
    public func close() throws { try db.close() }
    /// Discover persisted intents and matches after process restart using only the database URL.
    /// Includes terminal matches; snapshots and pendingPackets derive the recovery work to perform.
    public func matchIDs() throws -> [String] {
        try db.rows("SELECT match_id FROM matches ORDER BY rowid").map {
            guard let id = $0[0].string, !id.isEmpty else { throw StoreError.corruptPayload(table: "matches", key: "invalid-id") }
            return id
        }
    }
    public func saveCompletionEvidence(_ evidence: TrustedCompletionEvidence, expectedGeneration: Int64, now: Date) throws {
        try preservingDiagnostics(matchID: evidence.matchID) {
            try db.transaction {
                let snapshot = try loadSnapshot(matchID: evidence.matchID)
                guard snapshot.generation == expectedGeneration else { throw StoreError.staleGeneration }
                guard !snapshot.diagnostics.contains(where: { $0.severity == .blocking }) else { throw StoreError.unresolvedDiagnostics }
                guard MatchReplay.replay(descriptor: snapshot.descriptor, events: snapshot.events, now: now,
                    completionEvidence: evidence).state == .completed else { throw StoreError.staleCompletionEvidence }
                try db.execute("INSERT INTO completion VALUES (?,?) ON CONFLICT(match_id) DO UPDATE SET evidence=excluded.evidence",
                    [.text(evidence.matchID), .blob(try Canonical.data(evidence))])
                try fail(.beforeCommit)
            }
        }
    }
    /// The calling adapter vouches for peer identity/account/permissions. This method verifies
    /// integrity and routing, and returns an ACK only after the receiver's SQL COMMIT succeeds.
    public func receive(_ packet: MatchPacket, expectedPeerDeviceID: String, localDeviceID: String,
                        expectedMatchID: String) throws -> DurableACK {
        try receive(Canonical.data(packet), expectedPeerDeviceID: expectedPeerDeviceID,
            localDeviceID: localDeviceID, expectedMatchID: expectedMatchID)
    }
    public func receive(_ bytes: Data, expectedPeerDeviceID: String, localDeviceID: String,
                        expectedMatchID: String) throws -> DurableACK {
        let ack: DurableACK = try preservingDiagnostics(matchID: expectedMatchID) {
            let packet: MatchPacket
            do { packet = try JSONDecoder().decode(MatchPacket.self, from: bytes) }
            catch { throw quarantine(.invalidPacket, code: "invalid-wire-json", key: Canonical.hash(bytes), raw: bytes, severity: .audit) }
            let b = packet.body
            do { try packet.validate() } catch {
                throw quarantine(.invalidPacket, code: "invalid-wire-checksum-version", key: b.packetID, raw: bytes, severity: .audit)
            }
            guard b.sourceDeviceID == expectedPeerDeviceID, b.targetDeviceID == localDeviceID,
                  b.descriptor.matchID == expectedMatchID else {
                throw quarantine(.invalidPacket, code: "invalid-wire-routing", key: b.packetID, raw: bytes, severity: .audit)
            }
            return try db.transaction {
                let ack = DurableACK(packetID: b.packetID, checksum: packet.checksum, receivingDeviceID: localDeviceID)
                if let row = try db.rows("SELECT checksum,peer,ack FROM inbound WHERE packet_id=? OR idempotency_key=?", [.text(b.packetID), .text(b.idempotencyKey)]).first {
                    let saved = try decode(DurableACK.self, row[2], table: "inbound", key: b.packetID)
                    guard row[0].string == packet.checksum, row[1].string == expectedPeerDeviceID, saved == ack else {
                        throw quarantine(.packetConflict, code: "packet-conflict", key: b.packetID, raw: bytes)
                    }
                    _ = try verifyPersistedFacts(descriptor: b.descriptor, events: b.events)
                    return saved
                }
                let existing = try descriptorAndGeneration(expectedMatchID)
                var descriptor = b.descriptor
                if let prior = existing?.0 {
                    // An old intent packet cannot downgrade an already persisted permit/held lock.
                    descriptor = MatchDescriptor(startIntent: b.descriptor.startIntent, starter: b.descriptor.starter,
                        startPermit: b.descriptor.startPermit ?? prior.startPermit,
                        backendLockState: b.descriptor.backendLockState == .unknown ? prior.backendLockState : b.descriptor.backendLockState)
                }
                try validateDescriptor(descriptor, prior: existing?.0)
                try validateFacts(b.events, descriptor: descriptor)
                guard (existing?.1 ?? 0) < Int64.max else { throw StoreError.invalidRequest }
                try writeDescriptor(descriptor, generation: (existing?.1 ?? 0) + 1)
                try append(b.events, matchID: expectedMatchID)
                try fail(.afterEvents)
                try db.execute("INSERT INTO inbound VALUES (?,?,?,?,?)", [.text(b.packetID), .text(b.idempotencyKey),
                    .text(packet.checksum), .text(expectedPeerDeviceID), .blob(try Canonical.data(ack))])
                try fail(.beforeCommit)
                return ack
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }
        return ack
    }
    /// Transport completion has no API here: only a trusted, authenticated durable receiver ACK
    /// marks one exact packet acknowledged. Retain the packet and ACK as an audit receipt.
    public func acknowledge(_ ack: DurableACK) throws {
        try db.transaction {
            guard let row = try db.rows("SELECT checksum,target,ack FROM outbox WHERE packet_id=?", [.text(ack.packetID)]).first,
                  row[0].string == ack.checksum, row[1].string == ack.receivingDeviceID else { throw StoreError.invalidACK }
            if let raw = row[2].data {
                guard raw == (try Canonical.data(ack)) else { throw StoreError.invalidACK }; return
            }
            try db.execute("UPDATE outbox SET ack=? WHERE packet_id=?", [.blob(try Canonical.data(ack)), .text(ack.packetID)])
            try fail(.beforeCommit)
        }
    }

    /// Retry the identical complete request, including its original expectedGeneration. A matching
    /// committed command is looked up before CAS, so a lost UI response cannot create new facts.
    public func commit(_ request: StoreCommit) throws -> CommitReceipt {
        let bytes = try Canonical.data(request), hash = Canonical.hash(bytes)
        let receipt: CommitReceipt = try preservingDiagnostics(matchID: request.descriptor.matchID) {
            try db.transaction {
                if let saved = try db.rows("SELECT request_hash,receipt FROM commands WHERE command_id=?", [.text(request.commandID)]).first {
                    guard saved[0].string == hash else { throw StoreError.commandConflict }
                    let receipt = try decode(CommitReceipt.self, saved[1], table: "commands", key: request.commandID)
                    let persisted = try verifyPersistedFacts(descriptor: request.descriptor, events: request.events)
                    guard request.expectedGeneration < Int64.max,
                          receipt == CommitReceipt(commandID: request.commandID, matchID: request.descriptor.matchID,
                            generation: request.expectedGeneration + 1, eventIDs: request.events.map(\.eventID), packetIDs: request.packets.map(\.body.packetID)),
                          persisted.1 >= receipt.generation else {
                        throw quarantine(.corruptPayload(table: "commands", key: request.commandID), code: "corrupt-commands", key: request.commandID, raw: saved[1].data ?? Data())
                    }
                    for packet in request.packets { try verifyPersistedPacket(packet) }
                    return receipt
                }
                guard !request.commandID.isEmpty, request.expectedGeneration >= 0,
                      request.expectedGeneration < Int64.max else { throw StoreError.invalidRequest }
                try validateFacts(request.events, descriptor: request.descriptor)
                for packet in request.packets {
                    try packet.validate()
                    guard packet.body.descriptor == request.descriptor,
                          packet.body.events == request.events else { throw StoreError.invalidPacket }
                }
                guard request.events.isEmpty || !request.packets.isEmpty else { throw StoreError.invalidRequest }
                let existing = try descriptorAndGeneration(request.descriptor.matchID)
                guard (existing?.1 ?? 0) == request.expectedGeneration else { throw StoreError.staleGeneration }
                // Originating writer must persist its stable intent before asking the network for a
                // permit. receive is deliberately a separate path for first-arrival peer snapshots.
                if existing == nil {
                    guard request.descriptor.startPermit == nil, request.events.isEmpty,
                          request.descriptor.backendLockState == .unknown else { throw StoreError.invalidRequest }
                }
                try validateDescriptor(request.descriptor, prior: existing?.0)
                let generation = request.expectedGeneration + 1
                try writeDescriptor(request.descriptor, generation: generation)
                try append(request.events, matchID: request.descriptor.matchID)
                try fail(.afterEvents)
                for packet in request.packets { try insertPacket(packet) }
                try fail(.afterOutbox)
                let receipt = CommitReceipt(commandID: request.commandID, matchID: request.descriptor.matchID,
                    generation: generation, eventIDs: request.events.map(\.eventID), packetIDs: request.packets.map(\.body.packetID))
                try db.execute("INSERT INTO commands VALUES (?,?,?)", [.text(request.commandID), .text(hash), .blob(try Canonical.data(receipt))])
                try fail(.beforeCommit)
                return receipt
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }
        return receipt
    }

    public func snapshot(matchID: String) throws -> StoreSnapshot {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction { try loadSnapshot(matchID: matchID) }
        }
    }

    private func loadSnapshot(matchID: String) throws -> StoreSnapshot {
        guard let (descriptor, generation) = try descriptorAndGeneration(matchID) else { throw StoreError.notFound }
        var events: [MatchEvent] = []
        for row in try db.rows("SELECT event_id,payload,checksum FROM events WHERE match_id=? ORDER BY rowid", [.text(matchID)]) {
            let key = row[0].string ?? "invalid-id"
            guard let raw = row[1].data, row[2].string == Canonical.hash(raw) else {
                throw quarantine(.corruptPayload(table: "events", key: key), code: "corrupt-events", key: key, raw: row[1].data ?? Data())
            }
            let event = try decode(MatchEvent.self, row[1], table: "events", key: key)
            guard event.eventID == key, event.matchID == matchID else {
                throw quarantine(.corruptPayload(table: "events", key: key), code: "corrupt-events", key: key, raw: raw)
            }
            events.append(event)
        }
        let evidence = try db.rows("SELECT evidence FROM completion WHERE match_id=?", [.text(matchID)]).first.map {
            try decode(TrustedCompletionEvidence.self, $0[0], table: "completion", key: matchID)
        }
        return StoreSnapshot(descriptor: descriptor, generation: generation, events: events,
            diagnostics: try diagnostics(matchID: matchID), completionEvidence: evidence)
    }

    public func diagnostics(matchID: String) throws -> [StoreDiagnostic] {
        try db.rows("SELECT code,key,raw,severity FROM diagnostics WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map {
            guard let code = $0[0].string, let key = $0[1].string, let raw = $0[2].data,
                  let severityName = $0[3].string, let severity = StoreDiagnosticSeverity(rawValue: severityName) else {
                throw StoreError.corruptPayload(table: "diagnostics", key: matchID)
            }
            return StoreDiagnostic(code: code, key: key, rawBytes: raw, severity: severity)
        }
    }

    public func pendingPackets(matchID: String) throws -> [MatchPacket] {
        try preservingDiagnostics(matchID: matchID) {
            try db.rows("SELECT packet_id,packet,checksum,target FROM outbox WHERE match_id=? AND ack IS NULL ORDER BY rowid", [.text(matchID)]).map {
                let key = $0[0].string ?? "invalid-id"
                let packet = try decode(MatchPacket.self, $0[1], table: "outbox", key: key)
                do { try packet.validate() } catch {
                    throw quarantine(.corruptPayload(table: "outbox", key: key), code: "corrupt-outbox", key: key, raw: $0[1].data ?? Data())
                }
                guard packet.body.packetID == key, packet.body.descriptor.matchID == matchID,
                      packet.checksum == $0[2].string, packet.body.targetDeviceID == $0[3].string else {
                    throw quarantine(.corruptPayload(table: "outbox", key: key), code: "corrupt-outbox", key: key, raw: $0[1].data ?? Data())
                }
                return packet
            }
        }
    }

    private func descriptorAndGeneration(_ matchID: String) throws -> (MatchDescriptor, Int64)? {
        guard let row = try db.rows("SELECT descriptor,generation,intent_id FROM matches WHERE match_id=?", [.text(matchID)]).first else { return nil }
        let descriptor = try decode(MatchDescriptor.self, row[0], table: "matches", key: matchID)
        guard descriptor.matchID == matchID, row[2].string == descriptor.startIntent.id,
              let generation = row[1].number, generation > 0 else {
            throw quarantine(.corruptPayload(table: "matches", key: matchID), code: "corrupt-matches", key: matchID, raw: row[0].data ?? Data())
        }
        return (descriptor, generation)
    }
    private func writeDescriptor(_ descriptor: MatchDescriptor, generation: Int64) throws {
        if let row = try db.rows("SELECT match_id FROM matches WHERE intent_id=?", [.text(descriptor.startIntent.id)]).first {
            guard row[0].string == descriptor.matchID else { throw StoreError.descriptorConflict }
        }
        try db.execute("INSERT INTO matches VALUES (?,?,?,?) ON CONFLICT(match_id) DO UPDATE SET descriptor=excluded.descriptor,generation=excluded.generation",
            [.text(descriptor.matchID), .blob(try Canonical.data(descriptor)), .integer(generation), .text(descriptor.startIntent.id)])
    }
    private func validateDescriptor(_ descriptor: MatchDescriptor, prior: MatchDescriptor?) throws {
        let intent = descriptor.startIntent
        guard !intent.id.isEmpty, !intent.matchID.isEmpty, !intent.recordingDeviceID.isEmpty,
              intent.requestedAt.timeIntervalSince1970.isFinite,
              descriptor.backendLockState == .unknown || descriptor.backendLockState == .held else { throw StoreError.invalidRequest }
        if let permit = descriptor.startPermit {
            guard permit.intentID == intent.id, permit.matchID == intent.matchID,
                  permit.recordingDeviceID == intent.recordingDeviceID, !permit.permitID.isEmpty else { throw StoreError.invalidRequest }
        }
        if let prior {
            guard prior.startIntent == intent, prior.starter == descriptor.starter,
                  prior.startPermit == nil || prior.startPermit == descriptor.startPermit,
                  prior.backendLockState == descriptor.backendLockState ||
                    (prior.backendLockState == .unknown && descriptor.backendLockState == .held && descriptor.startPermit != nil)
            else { throw StoreError.descriptorConflict }
        }
    }
    private func validateFacts(_ events: [MatchEvent], descriptor: MatchDescriptor) throws {
        guard events.allSatisfy({ $0.matchID == descriptor.matchID && !$0.eventID.isEmpty }) else { throw StoreError.invalidRequest }
        if events.contains(where: { $0.type == .matchStarted }) {
            guard descriptor.startPermit != nil else { throw StoreError.invalidRequest }
        }
    }
    /// Receipts are assertions about persisted bytes, not substitutes for the bytes. Both command
    /// retries and duplicate receive ACKs use this check. Later permits/revisions may add facts but
    /// cannot change identity or remove the raw facts acknowledged by the original receipt.
    private func verifyPersistedFacts(descriptor: MatchDescriptor, events: [MatchEvent]) throws -> (MatchDescriptor, Int64) {
        let rawDescriptor = try Canonical.data(descriptor)
        guard let stored = try descriptorAndGeneration(descriptor.matchID),
              stored.0.startIntent == descriptor.startIntent, stored.0.starter == descriptor.starter,
              descriptor.startPermit == nil || stored.0.startPermit == descriptor.startPermit else {
            throw quarantine(.corruptPayload(table: "matches", key: descriptor.matchID), code: "receipt-match-mismatch", key: descriptor.matchID, raw: rawDescriptor)
        }
        for event in events {
            let expected = try Canonical.data(event)
            guard let row = try db.rows("SELECT match_id,payload,checksum FROM events WHERE event_id=?", [.text(event.eventID)]).first else {
                throw quarantine(.corruptPayload(table: "events", key: event.eventID), code: "receipt-event-missing", key: event.eventID, raw: expected)
            }
            guard let actual = row[1].data, row[0].string == descriptor.matchID,
                  row[2].string == Canonical.hash(actual), actual == expected else {
                throw quarantine(.corruptPayload(table: "events", key: event.eventID), code: "receipt-event-mismatch", key: event.eventID, raw: row[1].data ?? Data())
            }
        }
        return stored
    }
    private func verifyPersistedPacket(_ packet: MatchPacket) throws {
        let body = packet.body, expected = try Canonical.data(packet)
        guard let row = try db.rows("SELECT packet,checksum,target,idempotency_key,match_id,ack FROM outbox WHERE packet_id=?", [.text(body.packetID)]).first else {
            throw quarantine(.corruptPayload(table: "outbox", key: body.packetID), code: "receipt-outbox-missing", key: body.packetID, raw: expected)
        }
        guard row[0].data == expected, row[1].string == packet.checksum, row[2].string == body.targetDeviceID,
              row[3].string == body.idempotencyKey, row[4].string == body.descriptor.matchID else {
            throw quarantine(.corruptPayload(table: "outbox", key: body.packetID), code: "receipt-outbox-mismatch", key: body.packetID, raw: row[0].data ?? Data())
        }
        if case .null = row[5] { return }
        let ack = try decode(DurableACK.self, row[5], table: "outbox", key: body.packetID)
        guard ack == DurableACK(packetID: body.packetID, checksum: packet.checksum, receivingDeviceID: body.targetDeviceID) else {
            throw quarantine(.corruptPayload(table: "outbox", key: body.packetID), code: "corrupt-outbox-ack", key: body.packetID, raw: row[5].data ?? Data())
        }
    }
    private func append(_ events: [MatchEvent], matchID: String) throws {
        for event in events {
            let bytes = try Canonical.data(event)
            if let row = try db.rows("SELECT payload,checksum,match_id FROM events WHERE event_id=?", [.text(event.eventID)]).first {
                guard let old = row[0].data, row[1].string == Canonical.hash(old) else {
                    throw quarantine(.corruptPayload(table: "events", key: event.eventID), code: "corrupt-events", key: event.eventID, raw: row[0].data ?? Data())
                }
                guard row[2].string == matchID, old == bytes else {
                    throw quarantine(.eventConflict, code: "event-conflict", key: event.eventID, raw: bytes)
                }
            } else {
                try db.execute("INSERT INTO events VALUES (?,?,?,?)", [.text(matchID), .text(event.eventID), .blob(bytes), .text(Canonical.hash(bytes))])
            }
        }
    }
    private func insertPacket(_ packet: MatchPacket) throws {
        let raw = try Canonical.data(packet), body = packet.body
        if let row = try db.rows("SELECT packet FROM outbox WHERE packet_id=? OR idempotency_key=?", [.text(body.packetID), .text(body.idempotencyKey)]).first {
            guard row[0].data == raw else { throw StoreError.packetConflict }; return
        }
        try db.execute("INSERT INTO outbox VALUES (?,?,?,?,?,?,NULL)", [.text(body.packetID), .text(body.idempotencyKey),
            .text(body.descriptor.matchID), .blob(raw), .text(packet.checksum), .text(body.targetDeviceID)])
    }
    private func fail(_ point: StoreFault) throws { if fault == point { throw StoreError.injectedFailure } }
    private struct Quarantined: Error {
        let error: StoreError
        let diagnostic: StoreDiagnostic
    }
    private func quarantine(_ error: StoreError, code: String, key: String, raw: Data,
                            severity: StoreDiagnosticSeverity = .blocking) -> Quarantined {
        Quarantined(error: error, diagnostic: StoreDiagnostic(code: code, key: key, rawBytes: raw, severity: severity))
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: SQLValue, table: String, key: String) throws -> T {
        let raw = value.data ?? Data()
        do { return try JSONDecoder().decode(type, from: raw) }
        catch { throw quarantine(.corruptPayload(table: table, key: key), code: "corrupt-" + table, key: key, raw: raw) }
    }
    private func preservingDiagnostics<T>(matchID: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let quarantined as Quarantined {
            try db.transaction {
                let d = quarantined.diagnostic
                try db.execute("INSERT OR IGNORE INTO diagnostics VALUES (?,?,?,?,?)", [.text(matchID), .text(d.code), .text(d.key), .blob(d.rawBytes), .text(d.severity.rawValue)])
            }
            throw quarantined.error
        }
    }
}
