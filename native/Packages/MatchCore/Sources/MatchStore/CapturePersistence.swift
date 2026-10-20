import Foundation
import MatchCore

/// Point-in-time capture projection, not a persisted deletion authorization.
public struct CaptureInventoryMatchV4: Sendable {
    public let binding: CaptureBinding
    public let captureRevisions: [CaptureRevision]
    public let captureOperations: [CaptureOperationRecord]
}

extension MatchStore {
    /// All original capture facts in one SQL snapshot. Caller must first drain every owned writer.
    /// No diagnostic, receipt or canonical row is written when validation fails.
    public func captureInventoryV4() throws -> [CaptureInventoryMatchV4] {
        do { return try db.transaction { try captureInventoryLockedV4() } }
        catch let failure as Quarantined { throw failure.error }
    }
    private struct InventoryIdentity {
        let kind: String
        let match: Data
        let raw: Data
    }
    private struct InventoryHistoryKey: Hashable { let operation: Data; let ordinal: Int64 }
    private struct InventoryHistory { let command: Data; let raw: Data }
    private func inventoryTextV4(_ text: SQLValue, raw: SQLValue, table: String) throws -> String {
        guard let value = text.string, let bytes = raw.data, bytes == Data(value.utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.corruptPayload(table: table, key: "inventory-text")
        }
        return value
    }
    private func inventoryBindingV4(_ value: CaptureBinding, _ parent: CaptureBinding) throws {
        guard Data(value.matchID.utf8) == Data(parent.matchID.utf8),
              Data(value.recordingDeviceID.utf8) == Data(parent.recordingDeviceID.utf8) else {
            throw StoreError.corruptPayload(table: "capture_identities", key: value.matchID)
        }
    }
    private func inventoryDescriptorV4(_ value: MatchDescriptor, parent: MatchDescriptor) throws {
        let permit = try Canonical.data(value.startPermit), currentPermit = try Canonical.data(parent.startPermit)
        guard try Canonical.data(value.startIntent) == Canonical.data(parent.startIntent), value.starter == parent.starter,
              value.startPermit == nil || permit == currentPermit else {
            throw StoreError.corruptPayload(table: "matches", key: value.matchID)
        }
    }
    private func captureInventoryLockedV4() throws -> [CaptureInventoryMatchV4] {
        try db.validateLocalErasureLayoutV4()
        // A rejected positive observation may live only in a diagnostic under an unknown parent.
        for row in try db.rows("SELECT match_id,code,key,raw,severity,CAST(match_id AS BLOB),CAST(code AS BLOB),CAST(key AS BLOB),CAST(severity AS BLOB) FROM diagnostics") {
            for (index, raw) in [(0,5),(1,6),(2,7),(4,8)] { _ = try inventoryTextV4(row[index], raw: row[raw], table: "diagnostics") }
            guard row[3].data != nil, let severity = StoreDiagnosticSeverity(rawValue: row[4].string!) else {
                throw StoreError.corruptPayload(table: "diagnostics", key: "inventory")
            }
            guard severity != .blocking else { throw StoreError.unresolvedDiagnostics }
        }
        var descriptors: [Data: MatchDescriptor] = [:]
        var matches = Set<Data>(), revisions: [Data: (match: Data, raw: Data)] = [:]
        var operations: [Data: SavedOperation] = [:], identities: [Data: InventoryIdentity] = [:]
        var histories: [InventoryHistoryKey: InventoryHistory] = [:], result: [CaptureInventoryMatchV4] = []
        func identity(_ id: String, kind: String, match: Data, raw: Data) throws {
            let key = Data(id.utf8), item = InventoryIdentity(kind: kind, match: match, raw: raw)
            if let prior = identities[key] {
                guard prior.kind == kind, prior.match == match, prior.raw == raw else {
                    throw StoreError.corruptPayload(table: "capture_identities", key: id)
                }
            } else { identities[key] = item }
        }
        for row in try db.rows("SELECT match_id,CAST(match_id AS BLOB),descriptor,intent_id,CAST(intent_id AS BLOB) FROM matches") {
            let id = try inventoryTextV4(row[0], raw: row[1], table: "matches"), key = Data(id.utf8)
            let intentID = try inventoryTextV4(row[3], raw: row[4], table: "matches")
            let snapshot = try loadSnapshot(matchID: id), descriptor = snapshot.descriptor
            guard matches.insert(key).inserted, Data(descriptor.matchID.utf8) == key,
                  Data(descriptor.startIntent.id.utf8) == Data(intentID.utf8),
                  row[2].data == (try Canonical.data(descriptor)),
                  !descriptor.recordingDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !snapshot.diagnostics.contains(where: { $0.severity == .blocking }) else {
                throw StoreError.corruptPayload(table: "matches", key: id)
            }
            descriptors[key] = descriptor
            let binding = try CaptureBinding(matchID: id, recordingDeviceID: descriptor.recordingDeviceID)
            let chain = try loadCaptureRevisions(descriptor: descriptor)
            var previous: Data?
            for revision in chain {
                try inventoryBindingV4(revision.binding, binding); try inventoryBindingV4(revision.metadata.binding, binding)
                let raw = try Canonical.data(revision), revisionKey = Data(revision.id.utf8)
                guard revision.parentID.map({ Data($0.utf8) }) == previous,
                      revisions.updateValue((key, raw), forKey: revisionKey) == nil else {
                    throw StoreError.corruptPayload(table: "capture_revisions", key: revision.id)
                }
                previous = revisionKey; try identity(revision.id, kind: "revision", match: key, raw: raw)
                for segment in revision.metadata.segments {
                    try inventoryBindingV4(segment.binding, binding)
                    try identity(segment.id, kind: "segment", match: key, raw: Canonical.data(segment))
                }
                for gap in revision.metadata.gaps {
                    try inventoryBindingV4(gap.binding, binding)
                    try identity(gap.id, kind: "gap", match: key, raw: Canonical.data(gap))
                }
            }
            let saved = try loadSavedOperations(matchID: id, descriptor: descriptor)
            try validateAbsentCancellations(saved, descriptor: descriptor)
            for item in saved {
                let operation = item.record.operation, opKey = Data(operation.id.utf8), raw = try Canonical.data(operation)
                try inventoryBindingV4(operation.binding, binding)
                guard operations.updateValue(item, forKey: opKey) == nil,
                      item.history.first.map({ Data($0.commandID.utf8) }) == Data(operation.associatedCommandID.utf8),
                      operation.action != .start || Data(operation.externalToken.utf8) == opKey else {
                    throw StoreError.corruptPayload(table: "capture_operations", key: operation.id)
                }
                try identity(operation.id, kind: "operation", match: key, raw: raw)
                for (ordinal, history) in item.history.enumerated() {
                    guard try Canonical.data(history.record.operation) == raw else {
                        throw StoreError.corruptPayload(table: "capture_operation_history", key: operation.id)
                    }
                    if let observed = history.record.observation {
                        try inventoryBindingV4(observed.binding, binding)
                        guard Data(observed.operationID.utf8) == opKey,
                              Data(observed.externalToken.utf8) == Data(operation.externalToken.utf8) else {
                            throw StoreError.corruptPayload(table: "capture_operation_history", key: operation.id)
                        }
                    }
                    histories[InventoryHistoryKey(operation: opKey, ordinal: Int64(ordinal))] =
                        InventoryHistory(command: Data(history.commandID.utf8), raw: try Canonical.data(history.record))
                }
            }
            result.append(CaptureInventoryMatchV4(binding: binding, captureRevisions: chain,
                captureOperations: saved.map(\.record).sorted { Data($0.operation.id.utf8).lexicographicallyPrecedes(Data($1.operation.id.utf8)) }))
        }
        // Reverse closure: rows whose parent was never discovered cannot disappear from inventory.
        for table in ["capture_revisions", "capture_operations"] {
            var seen = Set<Data>()
            for row in try db.rows("SELECT id,match_id,CAST(id AS BLOB),CAST(match_id AS BLOB) FROM "+table) {
                let id = try inventoryTextV4(row[0], raw: row[2], table: table)
                let match = try inventoryTextV4(row[1], raw: row[3], table: table), key = Data(id.utf8), parent = Data(match.utf8)
                let expected = table == "capture_revisions" ? revisions[key]?.match : operations[key].map { Data($0.record.operation.binding.matchID.utf8) }
                guard matches.contains(parent), expected == parent, seen.insert(key).inserted else { throw StoreError.corruptPayload(table: table, key: id) }
            }
            let expected = table == "capture_revisions" ? Set(revisions.keys) : Set(operations.keys)
            guard seen == expected else { throw StoreError.corruptPayload(table: table, key: "inventory-set") }
        }
        var seenHistory = Set<InventoryHistoryKey>()
        for row in try db.rows("SELECT operation_id,ordinal,command_id,record,checksum,CAST(operation_id AS BLOB),CAST(command_id AS BLOB) FROM capture_operation_history") {
            let op = try inventoryTextV4(row[0], raw: row[5], table: "capture_operation_history")
            let command = try inventoryTextV4(row[2], raw: row[6], table: "capture_operation_history")
            guard let ordinal = row[1].number else { throw StoreError.corruptPayload(table: "capture_operation_history", key: op) }
            let key = InventoryHistoryKey(operation: Data(op.utf8), ordinal: ordinal)
            guard let expected = histories[key], row[3].data == expected.raw, row[4].string == Canonical.hash(expected.raw),
                  Data(command.utf8) == expected.command, seenHistory.insert(key).inserted else {
                throw StoreError.corruptPayload(table: "capture_operation_history", key: op)
            }
        }
        guard seenHistory == Set(histories.keys) else { throw StoreError.corruptPayload(table: "capture_operation_history", key: "inventory-set") }
        for row in try db.rows("SELECT id,match_id,CAST(id AS BLOB),CAST(match_id AS BLOB) FROM business_outbox") {
            let id = try inventoryTextV4(row[0], raw: row[2], table: "business_outbox")
            let match = try inventoryTextV4(row[1], raw: row[3], table: "business_outbox"), parent = Data(match.utf8)
            let item = try loadBusinessOutbox(id: id)
            guard matches.contains(parent), Data(item.id.utf8) == Data(id.utf8), Data(item.matchID.utf8) == parent,
                  Data(item.payload.descriptor.matchID.utf8) == parent else { throw StoreError.corruptPayload(table: "business_outbox", key: id) }
            try inventoryDescriptorV4(item.payload.descriptor, parent: descriptors[parent]!)
            _ = try verifyPersistedFacts(descriptor: item.payload.descriptor, events: item.payload.events)
            for revision in item.payload.captureRevisions {
                guard revisions[Data(revision.id.utf8)]?.raw == (try Canonical.data(revision)) else { throw StoreError.corruptPayload(table: "capture_revisions", key: revision.id) }
            }
            try identity(id, kind: "outbox", match: parent, raw: Canonical.data(item))
        }
        var seenRegistry = Set<Data>()
        for row in try db.rows("SELECT id,kind,match_id,payload,checksum,CAST(id AS BLOB),CAST(kind AS BLOB),CAST(match_id AS BLOB) FROM capture_identities") {
            let id = try inventoryTextV4(row[0], raw: row[5], table: "capture_identities")
            let kind = try inventoryTextV4(row[1], raw: row[6], table: "capture_identities")
            let match = try inventoryTextV4(row[2], raw: row[7], table: "capture_identities"), key = Data(id.utf8)
            guard let expected = identities[key], expected.kind == kind, expected.match == Data(match.utf8),
                  row[3].data == expected.raw, row[4].string == Canonical.hash(expected.raw), seenRegistry.insert(key).inserted else {
                throw StoreError.corruptPayload(table: "capture_identities", key: id)
            }
        }
        guard seenRegistry == Set(identities.keys) else { throw StoreError.corruptPayload(table: "capture_identities", key: "inventory-set") }
        // Original immutable requests must still find their acknowledged capture facts, even if
        // a damaged file lost both a canonical row and its registry entry.
        for row in try db.rows("SELECT command_id,request,request_hash,receipt,match_id,CAST(command_id AS BLOB),CAST(match_id AS BLOB) FROM commands_v2") {
            let id = try inventoryTextV4(row[0], raw: row[5], table: "commands_v2")
            let match = try inventoryTextV4(row[4], raw: row[6], table: "commands_v2"), parent = Data(match.utf8)
            let original = try verifiedCommandV2(commandID: id, row: Array(row[1...4])).request
            guard matches.contains(parent), Data(original.commandID.utf8) == Data(id.utf8), Data(original.descriptor.matchID.utf8) == parent else {
                throw StoreError.corruptPayload(table: "commands_v2", key: id)
            }
            try inventoryDescriptorV4(original.descriptor, parent: descriptors[parent]!)
            for revision in original.captureRevisions {
                guard revisions[Data(revision.id.utf8)]?.raw == (try Canonical.data(revision)) else { throw StoreError.corruptPayload(table: "capture_revisions", key: revision.id) }
            }
            for operation in original.newCaptureOperations {
                guard let saved = operations[Data(operation.id.utf8)], let first = saved.history.first,
                      try Canonical.data(saved.record.operation) == Canonical.data(operation), Data(first.commandID.utf8) == Data(id.utf8) else { throw StoreError.corruptPayload(table: "capture_operations", key: operation.id) }
            }
            for update in original.captureOperationUpdates {
                guard let saved = operations[Data(update.operationID.utf8)],
                      let index = saved.history.firstIndex(where: { Data($0.commandID.utf8) == Data(id.utf8) }), index > 0,
                      saved.history[index-1].record.state == update.expectedState, saved.history[index].record.state == update.state,
                      try Canonical.data(saved.history[index].record.observation) == Canonical.data(update.observation) else {
                    throw StoreError.corruptPayload(table: "capture_operation_history", key: update.operationID)
                }
            }
        }
        return result.sorted { Data($0.binding.matchID.utf8).lexicographicallyPrecedes(Data($1.binding.matchID.utf8)) }
    }

    /// Lookup is read-only: a saved request is returned only after its complete receipt is verified.
    public func committedCommandV2(commandID: String) throws -> CommittedCommandV2? {
        var diagnosticMatchID = commandID
        do {
            return try db.transaction {
                guard let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(commandID)]).first else { return nil }
                diagnosticMatchID = row[3].string ?? commandID
                if let bytes = row[0].data, row[1].string == Canonical.hash(bytes),
                   let parsed = try? JSONDecoder().decode(StoreCommitV2.self, from: bytes),
                   (try? Canonical.data(parsed)) == bytes,
                   !parsed.descriptor.matchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diagnosticMatchID = parsed.descriptor.matchID
                }
                return try verifiedCommandV2(commandID: commandID, row: row)
            }
        } catch {
            return try preservingDiagnostics(matchID: diagnosticMatchID) { throw error }
        }
    }

    public func commitV2(_ request: StoreCommitV2) throws -> CommitReceiptV2 {
        let receipt = try preservingDiagnostics(matchID:request.descriptor.matchID) {
            try db.transaction {try applyCommitV2(request)}
        }
        if fault == .afterCommit {throw StoreError.responseLost};return receipt
    }
    /// Shared transaction body. Dedicated M4 control commits use the same business validation.
    func applyCommitV2(_ request:StoreCommitV2)throws->CommitReceiptV2 {
        let bytes=try Canonical.data(request),hash=Canonical.hash(bytes),matchID=request.descriptor.matchID
        if let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(request.commandID)]).first {
            if row[0].data == bytes, row[1].string != hash { throw corruptCapture("commands_v2", key: request.commandID, raw: row[0].data ?? Data()) }
            guard row[1].string == hash else { throw StoreError.commandConflict }
            return try verifiedCommandV2(commandID: request.commandID, row: row).receipt
        }
        guard try db.rows("SELECT command_id FROM commands WHERE command_id=?", [.text(request.commandID)]).isEmpty else { throw StoreError.commandConflict }
        try validateAccountBusinessWriteV4()
        try validateV2Coverage(request)
        let existing = try descriptorAndGeneration(matchID)
        guard (existing?.1 ?? 0) == request.expectedGeneration else { throw StoreError.staleGeneration }
        if existing == nil {
            guard request.descriptor.startPermit == nil, request.events.isEmpty, request.captureRevisions.isEmpty,
                  request.newCaptureOperations.isEmpty, request.captureOperationUpdates.isEmpty,
                  request.descriptor.backendLockState == .unknown else { throw StoreError.invalidRequest }
        }
        try validateDescriptor(request.descriptor, prior: existing?.0)
        try validateFacts(request.events, descriptor: request.descriptor)
        if let existing {
            let saved = try loadSavedOperations(matchID: matchID, descriptor: existing.0)
            try rejectAbsenceContradictions(request, saved: saved, descriptor: existing.0)
            try validateAbsentCancellations(saved, descriptor: existing.0)
        }
        let generation = request.expectedGeneration + 1
        try writeDescriptor(request.descriptor, generation: generation)
        try append(request.events, matchID: matchID); try fail(.afterEvents)
        for revision in request.captureRevisions { try appendRevision(revision, descriptor: request.descriptor) }
        try fail(.afterCaptureRevisions)
        for operation in request.newCaptureOperations { try insertOperation(operation, commandID: request.commandID, descriptor: request.descriptor) }
        for update in request.captureOperationUpdates { try updateOperation(update, commandID: request.commandID, descriptor: request.descriptor) }
        try fail(.afterCaptureOperations)
        for item in request.businessOutbox { try insertBusinessOutbox(item) }
        try fail(.afterOutbox)
        let receipt = try expectedReceipt(request)
        try db.execute("INSERT INTO commands_v2 VALUES (?,?,?,?,?)", [.text(request.commandID), .text(matchID), .blob(bytes), .text(hash), .blob(try Canonical.data(receipt))])
        _ = try loadOperations(matchID: matchID, descriptor: request.descriptor)
        try fail(.afterReceipt); try fail(.beforeCommit)
        return receipt
    }

    public func snapshotV2(matchID: String) throws -> StoreSnapshotV2 {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                let business = try loadSnapshot(matchID: matchID)
                let revisions = try loadCaptureRevisions(descriptor: business.descriptor)
                let operations = try loadOperations(matchID: matchID, descriptor: business.descriptor)
                return try StoreSnapshotV2(business: business, captureRevisions: revisions, captureOperations: operations)
            }
        }
    }
    public func pendingCaptureOperations(matchID: String) throws -> [CaptureOperationRecord] {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                guard let (descriptor, _) = try descriptorAndGeneration(matchID) else { throw StoreError.notFound }
                return try loadOperations(matchID: matchID, descriptor: descriptor).filter { $0.state == .pending || $0.state == .needsReconciliation }
            }
        }
    }
    public func pendingBusinessOutbox(matchID: String) throws -> [BusinessOutboxItem] {
        try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                if let descriptor = try descriptorAndGeneration(matchID)?.0 { try validateCaptureAbsenceIntegrity(descriptor: descriptor) }
                let items = try db.rows("SELECT id FROM business_outbox WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map {
                    let item = try loadBusinessOutbox(id: $0[0].string ?? "invalid-id")
                    guard item.matchID == matchID else { throw corruptCapture("business_outbox", key: item.id, raw: try Canonical.data(item)) }
                    return item
                }
                try verifyCaptureRegistrySet(kind: "outbox", matchID: matchID, ids: items.map(\.id), table: "business_outbox")
                return items
            }
        }
    }

    public func saveCompletionProofV2(evidence: TrustedCompletionEvidence, captureDigest: String,
                                      expectedGeneration: Int64, now: Date) throws {
        try preservingDiagnostics(matchID: evidence.matchID) {
            try db.transaction {
                guard try currentBindingV4() == nil else { throw StoreError.trustUnavailable }
                let snapshot = try loadSnapshot(matchID: evidence.matchID)
                guard snapshot.generation == expectedGeneration else { throw StoreError.staleGeneration }
                guard !snapshot.diagnostics.contains(where: { $0.severity == .blocking }) else { throw StoreError.unresolvedDiagnostics }
                let revisions = try loadCaptureRevisions(descriptor: snapshot.descriptor)
                guard captureDigest == (try CaptureRevision.digest(revisions)) else { throw StoreError.staleCaptureEvidence }
                guard now.timeIntervalSinceReferenceDate.isFinite,
                      MatchReplay.replay(descriptor: snapshot.descriptor, events: snapshot.events, now: now, completionEvidence: evidence).state == .completed else {
                    throw StoreError.staleCompletionEvidence
                }
                try rememberCaptureCompletionConfirmation(evidence: evidence, digest: captureDigest, hasCapture: !revisions.isEmpty)
                try db.execute("INSERT INTO completion_v2 VALUES (?,?,?) ON CONFLICT(match_id) DO UPDATE SET evidence=excluded.evidence,capture_digest=excluded.capture_digest",
                    [.text(evidence.matchID), .blob(try Canonical.data(evidence)), .text(captureDigest)])
                try fail(.beforeCommit)
            }
        }
    }

    /// Both snapshot APIs call this boundary, so old evidence cannot bypass capture invalidation.
    func filteredCompletionEvidence(descriptor: MatchDescriptor, events: [MatchEvent], legacy: TrustedCompletionEvidence?) throws -> TrustedCompletionEvidence? {
        try validateCaptureAbsenceIntegrity(descriptor: descriptor)
        let revisions = try loadCaptureRevisions(descriptor: descriptor)
        if try currentBindingV4() != nil {
            let state=try authorityStateV4(matchID:descriptor.matchID,now:descriptor.startIntent.requestedAt)
            guard state.status == .releasedNormal,state.verifiedNormalRelease != nil else {return nil}
            let current=try CloudFactSetV1(startIntent:descriptor.startIntent,starter:descriptor.starter,events:events,captureRevisions:revisions)
            var matched=false
            for row in try db.rows("SELECT payload,checksum FROM cloud_checkpoints_v4 WHERE match_id=?",[.text(descriptor.matchID)]) {
                let input=try checkedV4(CloudSaveInputV1.self,row:row,table:"cloud_checkpoints_v4",key:descriptor.matchID)
                _=try VerifiedCloudSaveV1.verifyReadback(input,policy:cloudSavePolicy)
                if case .matchFacts(let facts)=try input.record.payload,facts==current {matched=true;break}
            }
            guard matched else {return nil}
        }
        if let row = try db.rows("SELECT evidence,capture_digest FROM completion_v2 WHERE match_id=?", [.text(descriptor.matchID)]).first {
            let evidence = try decode(TrustedCompletionEvidence.self, row[0], table: "completion_v2", key: descriptor.matchID)
            guard evidence.matchID == descriptor.matchID else { throw corruptCapture("completion_v2", key: descriptor.matchID, raw: row[0].data ?? Data()) }
            let digest = row[1].string ?? ""
            let confirmation = try loadCaptureCompletionConfirmation(matchID: descriptor.matchID, confirmationID: evidence.confirmationID)
            guard confirmation.evidence == evidence, confirmation.captureDigest == digest else {
                throw corruptCapture("completion_v2", key: descriptor.matchID, raw: row[0].data ?? Data())
            }
            return digest == (try CaptureRevision.digest(revisions)) ? evidence : nil
        }
        guard revisions.isEmpty, let legacy else { return nil }
        let confirmation = try loadCaptureCompletionConfirmation(matchID: descriptor.matchID, confirmationID: legacy.confirmationID)
        guard confirmation.evidence == legacy, confirmation.captureDigest == (try CaptureRevision.digest([])) else {
            throw corruptCapture("completion", key: descriptor.matchID, raw: try Canonical.data(legacy))
        }
        return legacy
    }

    private func loadCaptureCompletionConfirmation(matchID: String, confirmationID: String) throws -> CaptureCompletionConfirmation {
        guard let row = try db.rows("SELECT proof,checksum FROM completion_confirmations WHERE match_id=? AND confirmation_id=?", [.text(matchID), .text(confirmationID)]).first else {
            throw corruptCapture("completion_confirmations", key: confirmationID, raw: Data())
        }
        let proof = try checkedCapture(CaptureCompletionConfirmation.self, raw: row[0], checksum: row[1], table: "completion_confirmations", key: confirmationID)
        guard proof.evidence.matchID == matchID, proof.evidence.confirmationID == confirmationID else {
            throw corruptCapture("completion_confirmations", key: confirmationID, raw: row[0].data ?? Data())
        }
        return proof
    }
    func rememberCaptureCompletionConfirmation(evidence: TrustedCompletionEvidence, digest: String, hasCapture: Bool) throws {
        let proof = CaptureCompletionConfirmation(evidence: evidence, captureDigest: digest)
        if !(try db.rows("SELECT confirmation_id FROM completion_confirmations WHERE match_id=? AND confirmation_id=?", [.text(evidence.matchID), .text(evidence.confirmationID)])).isEmpty {
            guard try loadCaptureCompletionConfirmation(matchID: evidence.matchID, confirmationID: evidence.confirmationID) == proof else { throw StoreError.staleCaptureEvidence }
            return
        }
        if hasCapture, let row = try db.rows("SELECT evidence FROM completion WHERE match_id=?", [.text(evidence.matchID)]).first {
            let legacy = try decode(TrustedCompletionEvidence.self, row[0], table: "completion", key: evidence.matchID)
            guard legacy.confirmationID != evidence.confirmationID else { throw StoreError.staleCaptureEvidence }
        }
        let bytes = try Canonical.data(proof)
        try db.execute("INSERT INTO completion_confirmations VALUES (?,?,?,?)", [.text(evidence.matchID), .text(evidence.confirmationID), .blob(bytes), .text(Canonical.hash(bytes))])
    }

    private func expectedReceipt(_ request: StoreCommitV2) throws -> CommitReceiptV2 {
        try CommitReceiptV2(commandID: request.commandID, matchID: request.descriptor.matchID, generation: request.expectedGeneration + 1,
            eventIDs: request.events.map(\.eventID), captureRevisionIDs: request.captureRevisions.map(\.id),
            operationIDs: request.newCaptureOperations.map(\.id) + request.captureOperationUpdates.map(\.operationID),
            businessOutboxIDs: request.businessOutbox.map(\.id))
    }
    func verifiedCommandV2(commandID: String, row: [SQLValue], validateAbsence: Bool = true) throws -> CommittedCommandV2 {
        let request = try checkedCapture(StoreCommitV2.self, raw: row[0], checksum: row[1], table: "commands_v2", key: commandID)
        let receipt = try decode(CommitReceiptV2.self, row[2], table: "commands_v2", key: commandID)
        guard request.commandID == commandID, request.descriptor.matchID == row[3].string, receipt == (try expectedReceipt(request)),
              try Canonical.data(receipt) == row[2].data else {
            throw corruptCapture("commands_v2", key: commandID, raw: row[2].data ?? Data())
        }
        let persisted = try verifyPersistedFacts(descriptor: request.descriptor, events: request.events)
        guard persisted.1 >= receipt.generation else { throw corruptCapture("commands_v2", key: commandID, raw: row[2].data ?? Data()) }
        let revisions = try loadCaptureRevisions(descriptor: persisted.0)
        for revision in request.captureRevisions {
            guard revisions.contains(revision) else { throw corruptCapture("capture_revisions", key: revision.id, raw: try Canonical.data(revision)) }
        }
        for operation in request.newCaptureOperations {
            let saved = try loadOperation(id: operation.id, descriptor: persisted.0)
            guard saved.record.operation == operation, saved.history.first?.commandID == commandID else {
                throw corruptCapture("capture_operations", key: operation.id, raw: try Canonical.data(operation))
            }
        }
        for update in request.captureOperationUpdates {
            let saved = try loadOperation(id: update.operationID, descriptor: persisted.0)
            guard let index = saved.history.firstIndex(where: { $0.commandID == commandID }), index > 0,
                  saved.history[index-1].record.state == update.expectedState,
                  saved.history[index].record.state == update.state,
                  saved.history[index].record.observation == update.observation else {
                throw corruptCapture("capture_operation_history", key: update.operationID, raw: try Canonical.data(update))
            }
        }
        for item in request.businessOutbox {
            guard try loadBusinessOutbox(id: item.id) == item else { throw corruptCapture("business_outbox", key: item.id, raw: try Canonical.data(item)) }
        }
        if validateAbsence { _ = try loadOperations(matchID: persisted.0.matchID, descriptor: persisted.0) }
        return try CommittedCommandV2(request: request, receipt: receipt)
    }
    private func validateV2Coverage(_ request: StoreCommitV2) throws {
        let eventIDs = request.events.map(\.eventID), revisionIDs = request.captureRevisions.map(\.id)
        let operationIDs = request.newCaptureOperations.map(\.id) + request.captureOperationUpdates.map(\.operationID)
        guard Set(eventIDs).count == eventIDs.count, Set(revisionIDs).count == revisionIDs.count,
              Set(operationIDs).count == operationIDs.count,
              Set(request.businessOutbox.map(\.id)).count == request.businessOutbox.count else { throw StoreError.invalidRequest }
        var coveredEvents = Set<String>(), coveredRevisions = Set<String>()
        for item in request.businessOutbox {
            guard item.matchID == request.descriptor.matchID, item.payload.descriptor == request.descriptor else { throw StoreError.invalidRequest }
            for event in item.payload.events {
                guard request.events.contains(event) else { throw StoreError.invalidRequest }; coveredEvents.insert(event.eventID)
            }
            for revision in item.payload.captureRevisions {
                guard request.captureRevisions.contains(revision) else { throw StoreError.invalidRequest }; coveredRevisions.insert(revision.id)
            }
        }
        guard coveredEvents == Set(eventIDs), coveredRevisions == Set(revisionIDs) else { throw StoreError.invalidRequest }
    }
    private func corruptCapture(_ table: String, key: String, raw: Data) -> Quarantined {
        quarantine(.corruptPayload(table: table, key: key), code: "corrupt-" + table, key: key, raw: raw)
    }
    private func checkedCapture<T: Codable>(_ type: T.Type, raw: SQLValue, checksum: SQLValue, table: String, key: String) throws -> T {
        guard let bytes = raw.data, checksum.string == Canonical.hash(bytes) else { throw corruptCapture(table, key: key, raw: raw.data ?? Data()) }
        let value = try decode(type, raw, table: table, key: key)
        guard try Canonical.data(value) == bytes else { throw corruptCapture(table, key: key, raw: bytes) }
        return value
    }
    private func registerCaptureID(_ id: String, kind: String, matchID: String, raw: Data) throws {
        if let row = try db.rows("SELECT kind,match_id,payload,checksum FROM capture_identities WHERE id=?", [.text(id)]).first {
            guard let saved = row[2].data, row[3].string == Canonical.hash(saved) else { throw corruptCapture("capture_identities", key: id, raw: row[2].data ?? Data()) }
            guard row[0].string == kind, row[1].string == matchID, saved == raw else {
                throw quarantine(.captureConflict, code: "capture-id-conflict", key: id, raw: raw)
            }
            return
        }
        try db.execute("INSERT INTO capture_identities VALUES (?,?,?,?,?)", [.text(id), .text(kind), .text(matchID), .blob(raw), .text(Canonical.hash(raw))])
    }
    func verifyCaptureRegistrySet(kind: String, matchID: String, ids: [String], table: String) throws {
        let actualIDs = Set(ids)
        for row in try db.rows("SELECT id,payload,checksum FROM capture_identities WHERE kind=? AND match_id=?", [.text(kind), .text(matchID)]) {
            let id = row[0].string ?? "invalid-id", raw = row[1].data ?? Data()
            guard row[2].string == Canonical.hash(raw) else { throw corruptCapture("capture_identities", key: id, raw: raw) }
            guard actualIDs.contains(id) else { throw corruptCapture(table, key: id, raw: raw) }
        }
    }
    private func verifyCaptureID(_ id: String, kind: String, matchID: String, raw: Data) throws {
        guard let row = try db.rows("SELECT kind,match_id,payload,checksum FROM capture_identities WHERE id=?", [.text(id)]).first,
              row[0].string == kind, row[1].string == matchID, row[2].data == raw,
              row[3].string == Canonical.hash(raw) else { throw corruptCapture("capture_identities", key: id, raw: raw) }
    }
    func loadCaptureRevisions(descriptor: MatchDescriptor) throws -> [CaptureRevision] {
        let matchID = descriptor.matchID
        var result: [CaptureRevision] = []
        for row in try db.rows("SELECT id,parent_id,revision,payload,checksum FROM capture_revisions WHERE match_id=? ORDER BY revision,id", [.text(matchID)]) {
            let id = row[0].string ?? "invalid-id"
            let revision = try checkedCapture(CaptureRevision.self, raw: row[3], checksum: row[4], table: "capture_revisions", key: id)
            guard revision.id == id, revision.binding.matchID == matchID, revision.binding.recordingDeviceID == descriptor.recordingDeviceID,
                  revision.parentID == row[1].string, revision.revision == row[2].number,
                  revision.parentID == result.last?.id,
                  revision.revision == Int64(result.count) + 1 else { throw corruptCapture("capture_revisions", key: id, raw: row[3].data ?? Data()) }
            try verifyCaptureID(id, kind: "revision", matchID: matchID, raw: Canonical.data(revision))
            for segment in revision.metadata.segments { try verifyCaptureID(segment.id, kind: "segment", matchID: matchID, raw: Canonical.data(segment)) }
            for gap in revision.metadata.gaps { try verifyCaptureID(gap.id, kind: "gap", matchID: matchID, raw: Canonical.data(gap)) }
            result.append(revision)
        }
        try verifyCaptureRegistrySet(kind: "revision", matchID: matchID, ids: result.map(\.id), table: "capture_revisions")
        return result
    }
    func appendRevision(_ revision: CaptureRevision, descriptor: MatchDescriptor) throws {
        let matchID = descriptor.matchID, raw = try Canonical.data(revision)
        guard revision.binding.matchID == matchID, revision.binding.recordingDeviceID == descriptor.recordingDeviceID else {
            throw quarantine(.invalidCaptureRevision, code: "capture-binding-conflict", key: revision.id, raw: raw)
        }
        let revisions = try loadCaptureRevisions(descriptor: descriptor)
        if let existing = revisions.first(where: { $0.id == revision.id }) {
            guard existing == revision else { throw quarantine(.captureConflict, code: "capture-revision-conflict", key: revision.id, raw: raw) }; return
        }
        try registerCaptureID(revision.id, kind: "revision", matchID: matchID, raw: raw)
        for segment in revision.metadata.segments { try registerCaptureID(segment.id, kind: "segment", matchID: matchID, raw: Canonical.data(segment)) }
        for gap in revision.metadata.gaps { try registerCaptureID(gap.id, kind: "gap", matchID: matchID, raw: Canonical.data(gap)) }
        if let parentID = revision.parentID {
            guard revisions.contains(where: { $0.id == parentID }) else { throw quarantine(.missingCaptureParent, code: "capture-parent-missing", key: revision.id, raw: raw) }
            guard let head = revisions.last, head.id == parentID, head.revision < Int64.max,
                  revision.revision == head.revision + 1 else { throw quarantine(.captureBranch, code: "capture-branch", key: revision.id, raw: raw) }
        } else if !revisions.isEmpty { throw quarantine(.captureBranch, code: "capture-branch", key: revision.id, raw: raw) }
        try db.execute("INSERT INTO capture_revisions VALUES (?,?,?,?,?,?)", [.text(revision.id), .text(matchID), revision.parentID.map(SQLValue.text) ?? .null,
            .integer(revision.revision), .blob(raw), .text(Canonical.hash(raw))])
    }

    private struct HistoryItem { let commandID: String; let record: CaptureOperationRecord }
    private struct SavedOperation { let record: CaptureOperationRecord; let history: [HistoryItem] }
    private func loadSavedOperations(matchID: String, descriptor: MatchDescriptor) throws -> [SavedOperation] {
        let operations = try db.rows("SELECT id FROM capture_operations WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map {
            try loadOperation(id: $0[0].string ?? "invalid-id", descriptor: descriptor)
        }
        try verifyCaptureRegistrySet(kind: "operation", matchID: matchID, ids: operations.map { $0.record.operation.id }, table: "capture_operations")
        return operations
    }
    func validateCaptureAbsenceIntegrity(descriptor: MatchDescriptor) throws {
        _ = try loadOperations(matchID: descriptor.matchID, descriptor: descriptor)
    }
    func loadOperations(matchID: String, descriptor: MatchDescriptor) throws -> [CaptureOperationRecord] {
        let saved = try loadSavedOperations(matchID: matchID, descriptor: descriptor)
        try validateAbsentCancellations(saved, descriptor: descriptor)
        return saved.map(\.record)
    }
    private func isAbsenceCancellation(_ from: CaptureOperationRecord, _ to: CaptureOperationRecord) -> Bool {
        from.state == .needsReconciliation && to.state == .cancelled && to.observation == nil && to.operation.action == .finish
    }
    private func absenceProven(for finish: CaptureOperation, saved: [SavedOperation], descriptor: MatchDescriptor) throws -> Bool {
        guard finish.action == .finish,
              let start = saved.first(where: { $0.record.operation.id == finish.externalToken }),
              start.record.operation.action == .start, start.record.operation.externalToken == finish.externalToken,
              start.record.operation.binding == finish.binding, start.record.state == .failed,
              case .notCreated = start.record.observation?.outcome else { return false }
        // Rejected late evidence is retained outside the canonical history. It is still
        // known physical evidence, so a later retry cannot ignore that contradiction.
        guard !(try diagnostics(matchID: descriptor.matchID)).contains(where: {
            $0.code == "capture-absence-contradiction" && $0.severity == .blocking
        }) else { return false }
        let token = saved.filter { $0.record.operation.externalToken == finish.externalToken }
        guard !token.contains(where: { $0.record.operation.action == .recover }),
              !token.flatMap(\.history).contains(where: { $0.record.observation?.hasPositiveCaptureEvidence == true }) else { return false }
        // Segment has a binding but no trusted token field. Do not guess from an ID prefix.
        let revisions = try loadCaptureRevisions(descriptor: descriptor)
        guard !revisions.contains(where: { !$0.metadata.segments.isEmpty || $0.metadata.gaps.contains(where: { $0.window.start != nil || $0.window.end != nil }) }) else { return false }
        // Full canonical command/receipt verification is deliberately non-recursive here.
        // The caller validates every exceptional transition after these original commands.
        for history in start.history {
            guard let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(history.commandID)]).first else {
                throw corruptCapture("capture_operation_history", key: start.record.operation.id, raw: try Canonical.data(history.record))
            }
            _ = try verifiedCommandV2(commandID: history.commandID, row: row, validateAbsence: false)
        }
        return true
    }
    private func validateAbsentCancellations(_ saved: [SavedOperation], descriptor: MatchDescriptor) throws {
        for operation in saved {
            for pair in zip(operation.history, operation.history.dropFirst()) where isAbsenceCancellation(pair.0.record, pair.1.record) {
                guard try absenceProven(for: operation.record.operation, saved: saved, descriptor: descriptor) else {
                    throw quarantine(.invalidOperationTransition, code: "capture-absence-proof-invalid", key: operation.record.operation.id, raw: try Canonical.data(pair.1.record))
                }
            }
        }
    }
    /// Authenticated full peer snapshots may expose physical evidence contradicting 011's
    /// negative proof. Retain the complete incoming packet outside the rolled-back transaction.
    func rejectInboundCaptureAbsenceContradictions(descriptor: MatchDescriptor, revisions: [CaptureRevision], raw: Data) throws {
        let saved = try loadSavedOperations(matchID: descriptor.matchID, descriptor: descriptor)
        let cancelled = saved.contains { operation in
            zip(operation.history, operation.history.dropFirst()).contains { isAbsenceCancellation($0.0.record, $0.1.record) }
        }
        if cancelled, let positive = revisions.first(where: { !$0.metadata.segments.isEmpty || $0.metadata.gaps.contains(where: { $0.window.start != nil || $0.window.end != nil }) }) {
            throw quarantine(.captureConflict, code: "capture-absence-contradiction", key: positive.id, raw: raw)
        }
    }
    private func rejectAbsenceContradictions(_ request: StoreCommitV2, saved: [SavedOperation], descriptor: MatchDescriptor) throws {
        let absent = saved.filter { if case .notCreated = $0.record.observation?.outcome { return $0.record.operation.action == .start && $0.record.state == .failed }; return false }
        func conflict(_ id: String, _ raw: Data, error:StoreError = .captureConflict) -> Quarantined {
            quarantine(error, code: "capture-absence-contradiction", key: id, raw: raw)
        }
        for update in request.captureOperationUpdates {
            guard let observation = update.observation else { continue }
            if observation.hasPositiveCaptureEvidence, absent.contains(where: { $0.record.operation.externalToken == observation.externalToken && $0.record.operation.binding == observation.binding }) {
                throw conflict(update.operationID, try Canonical.data(observation))
            }
            if case .notCreated = observation.outcome {
                let history = saved.filter { $0.record.operation.externalToken == observation.externalToken }.flatMap(\.history)
                if history.contains(where: { $0.record.observation?.hasPositiveCaptureEvidence == true }) {
                    throw conflict(update.operationID, try Canonical.data(observation), error:.invalidOperationTransition)
                }
                if request.captureOperationUpdates.contains(where: { $0.observation?.externalToken == observation.externalToken && $0.observation?.hasPositiveCaptureEvidence == true }) {
                    throw conflict(update.operationID, try Canonical.data(observation), error:.invalidOperationTransition)
                }
            }
        }
        let hasCancellation = saved.contains { operation in zip(operation.history,operation.history.dropFirst()).contains(where: { isAbsenceCancellation($0.0.record,$0.1.record) }) }
        if hasCancellation {
            for revision in request.captureRevisions where !revision.metadata.segments.isEmpty || revision.metadata.gaps.contains(where: { $0.window.start != nil || $0.window.end != nil }) {
                throw conflict(revision.id, try Canonical.data(revision))
            }
            for operation in request.newCaptureOperations where operation.action == .recover && absent.contains(where: { $0.record.operation.externalToken == operation.externalToken }) {
                throw conflict(operation.id, try Canonical.data(operation))
            }
        }
    }
    private func loadOperation(id: String, descriptor: MatchDescriptor, uncommittedCommandID: String? = nil) throws -> SavedOperation {
        guard let row = try db.rows("SELECT match_id,operation,checksum,record,record_checksum,history_count FROM capture_operations WHERE id=?", [.text(id)]).first else {
            throw corruptCapture("capture_operations", key: id, raw: Data())
        }
        let operation = try checkedCapture(CaptureOperation.self, raw: row[1], checksum: row[2], table: "capture_operations", key: id)
        let record = try checkedCapture(CaptureOperationRecord.self, raw: row[3], checksum: row[4], table: "capture_operations", key: id)
        guard operation.id == id, row[0].string == descriptor.matchID, operation.binding.matchID == descriptor.matchID,
              operation.binding.recordingDeviceID == descriptor.recordingDeviceID, record.operation == operation else {
            throw corruptCapture("capture_operations", key: id, raw: row[1].data ?? Data())
        }
        try verifyCaptureID(id, kind: "operation", matchID: descriptor.matchID, raw: Canonical.data(operation))
        var history: [HistoryItem] = []
        var commandIDs = Set<String>()
        for entry in try db.rows("SELECT ordinal,command_id,record,checksum FROM capture_operation_history WHERE operation_id=? ORDER BY ordinal", [.text(id)]) {
            let item = try checkedCapture(CaptureOperationRecord.self, raw: entry[2], checksum: entry[3], table: "capture_operation_history", key: id)
            guard let command = entry[1].string, !command.isEmpty, commandIDs.insert(command).inserted,
                  item.operation == operation, entry[0].number == Int64(history.count) else { throw corruptCapture("capture_operation_history", key: id, raw: entry[2].data ?? Data()) }
            if let prior = history.last {
                guard legalTransition(from: prior.record, to: item) else { throw corruptCapture("capture_operation_history", key: id, raw: entry[2].data ?? Data()) }
            } else {
                guard item.state == .pending, item.observation == nil, command == operation.associatedCommandID else { throw corruptCapture("capture_operation_history", key: id, raw: entry[2].data ?? Data()) }
            }
            if command != uncommittedCommandID {
                try verifyHistoryCommand(commandID: command, operation: operation, previous: history.last?.record, record: item, raw: entry[2].data ?? Data())
            }
            history.append(HistoryItem(commandID: command, record: item))
        }
        guard history.last?.record == record, row[5].number == Int64(history.count) else { throw corruptCapture("capture_operation_history", key: id, raw: row[3].data ?? Data()) }
        if operation.action != .start {
            guard let tokenRow = try db.rows("SELECT operation,checksum FROM capture_operations WHERE id=?", [.text(operation.externalToken)]).first else {
                throw corruptCapture("capture_operations", key: id, raw: row[1].data ?? Data())
            }
            let start = try checkedCapture(CaptureOperation.self, raw: tokenRow[0], checksum: tokenRow[1], table: "capture_operations", key: operation.externalToken)
            guard start.action == .start, start.externalToken == start.id, start.binding == operation.binding else { throw corruptCapture("capture_operations", key: id, raw: row[1].data ?? Data()) }
            _ = try loadOperation(id: start.id, descriptor: descriptor, uncommittedCommandID: uncommittedCommandID)
        }
        return SavedOperation(record: record, history: history)
    }
    private func verifyHistoryCommand(commandID: String, operation: CaptureOperation, previous: CaptureOperationRecord?, record: CaptureOperationRecord, raw: Data) throws {
        guard let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(commandID)]).first else {
            throw corruptCapture("capture_operation_history", key: operation.id, raw: raw)
        }
        let request = try checkedCapture(StoreCommitV2.self, raw: row[0], checksum: row[1], table: "commands_v2", key: commandID)
        let receipt = try decode(CommitReceiptV2.self, row[2], table: "commands_v2", key: commandID)
        guard request.commandID == commandID, request.descriptor.matchID == operation.binding.matchID,
              row[3].string == operation.binding.matchID, receipt == (try expectedReceipt(request)),
              try Canonical.data(receipt) == row[2].data else { throw corruptCapture("capture_operation_history", key: operation.id, raw: raw) }
        if let previous {
            guard request.captureOperationUpdates.contains(where: {
                $0.operationID == operation.id && $0.expectedState == previous.state && $0.state == record.state && $0.observation == record.observation
            }) else { throw corruptCapture("capture_operation_history", key: operation.id, raw: raw) }
        } else {
            guard request.newCaptureOperations.contains(operation) else { throw corruptCapture("capture_operation_history", key: operation.id, raw: raw) }
        }
    }
    private func legalTransition(from: CaptureOperationRecord, to: CaptureOperationRecord) -> Bool {
        // Shape only; all mutation/readback paths additionally require the durable proof.
        if isAbsenceCancellation(from, to) { return true }
        guard (from.state == .pending && (to.state == .needsReconciliation || to.state == .cancelled) && to.observation == nil) ||
              (from.state == .needsReconciliation && (to.state == .needsReconciliation || to.state == .settled || to.state == .failed)) else { return false }
        if from.observation?.failure == .routeFailed, to.observation?.failure != .routeFailed { return false }
        if case .savedAwaitingLink = from.observation?.outcome {
            switch (to.state, to.observation?.outcome) {
            case (.needsReconciliation, .some(.savedAwaitingLink)), (.settled, .some(.linked)): break
            default: return false
            }
        }
        if case .stopped = from.observation?.outcome, from.observation?.failure == .captureFailed {
            switch to.observation?.outcome {
            case .some(.stopped):
                guard to.state == .needsReconciliation, to.observation?.failure == .captureFailed else { return false }
            case .some(.savedAwaitingLink), .some(.linked): break
            default: return false
            }
        }
        return true
    }
    private func insertOperation(_ operation: CaptureOperation, commandID: String, descriptor: MatchDescriptor) throws {
        let raw = try Canonical.data(operation)
        guard operation.binding.matchID == descriptor.matchID, operation.binding.recordingDeviceID == descriptor.recordingDeviceID,
              operation.associatedCommandID == commandID else { throw quarantine(.operationConflict, code: "operation-binding-command-conflict", key: operation.id, raw: raw) }
        try registerCaptureID(operation.id, kind: "operation", matchID: descriptor.matchID, raw: raw)
        if !(try db.rows("SELECT id FROM capture_operations WHERE id=?", [.text(operation.id)])).isEmpty {
            guard try loadOperation(id: operation.id, descriptor: descriptor).record.operation == operation else { throw StoreError.operationConflict }; return
        }
        if operation.action != .start {
            let start = try loadOperation(id: operation.externalToken, descriptor: descriptor, uncommittedCommandID: commandID).record.operation
            guard start.action == .start, start.externalToken == operation.externalToken, start.binding == operation.binding else {
                throw quarantine(.operationConflict, code: "operation-token-conflict", key: operation.id, raw: raw)
            }
        }
        let record = try CaptureOperationRecord(operation: operation, state: .pending, observation: nil), recordBytes = try Canonical.data(record)
        try db.execute("INSERT INTO capture_operations VALUES (?,?,?,?,?,?,?)", [.text(operation.id), .text(descriptor.matchID), .blob(raw), .text(Canonical.hash(raw)),
            .blob(recordBytes), .text(Canonical.hash(recordBytes)), .integer(1)])
        try db.execute("INSERT INTO capture_operation_history VALUES (?,?,?,?,?)", [.text(operation.id), .integer(0), .text(commandID), .blob(recordBytes), .text(Canonical.hash(recordBytes))])
    }
    private func updateOperation(_ update: CaptureOperationUpdate, commandID: String, descriptor: MatchDescriptor) throws {
        let saved = try loadOperation(id: update.operationID, descriptor: descriptor), current = saved.record
        guard current.state == update.expectedState else { throw StoreError.invalidOperationTransition }
        let next: CaptureOperationRecord
        do { next = try CaptureOperationRecord(operation: current.operation, state: update.state, observation: update.observation) }
        catch { throw StoreError.invalidOperationTransition }
        guard legalTransition(from: current, to: next) else { throw StoreError.invalidOperationTransition }
        if isAbsenceCancellation(current, next) {
            let operations = try loadSavedOperations(matchID: descriptor.matchID, descriptor: descriptor)
            guard try absenceProven(for: current.operation, saved: operations, descriptor: descriptor) else {
                throw quarantine(.invalidOperationTransition, code: "capture-absence-proof-invalid", key: update.operationID, raw: try Canonical.data(update))
            }
        }
        if case .linked(let workoutID) = next.observation?.outcome {
            let revisions = try loadCaptureRevisions(descriptor: descriptor)
            guard revisions.contains(where: { $0.metadata.segments.contains(where: { $0.workoutID == workoutID && $0.binding == current.operation.binding }) }) else { throw StoreError.invalidCaptureRevision }
        }
        guard saved.history.count < Int.max else { throw StoreError.invalidRequest }
        let raw = try Canonical.data(next), count = Int64(saved.history.count)
        try db.execute("INSERT INTO capture_operation_history VALUES (?,?,?,?,?)", [.text(update.operationID), .integer(count), .text(commandID), .blob(raw), .text(Canonical.hash(raw))])
        try db.execute("UPDATE capture_operations SET record=?,record_checksum=?,history_count=? WHERE id=?", [.blob(raw), .text(Canonical.hash(raw)), .integer(count + 1), .text(update.operationID)])
    }
    private func insertBusinessOutbox(_ item: BusinessOutboxItem) throws {
        let raw = try Canonical.data(item)
        try registerCaptureID(item.id, kind: "outbox", matchID: item.matchID, raw: raw)
        if !(try db.rows("SELECT id FROM business_outbox WHERE id=?", [.text(item.id)])).isEmpty {
            guard try loadBusinessOutbox(id: item.id) == item else { throw StoreError.captureConflict }; return
        }
        try db.execute("INSERT INTO business_outbox VALUES (?,?,?,?,?)", [.text(item.id), .text(item.matchID), .blob(raw), .text(Canonical.hash(raw)), .text("unrouted")])
    }
    func loadBusinessOutbox(id: String) throws -> BusinessOutboxItem {
        guard let row = try db.rows("SELECT match_id,payload,checksum,routing_state FROM business_outbox WHERE id=?", [.text(id)]).first else { throw corruptCapture("business_outbox", key: id, raw: Data()) }
        let item = try checkedCapture(BusinessOutboxItem.self, raw: row[1], checksum: row[2], table: "business_outbox", key: id)
        guard item.id == id, item.matchID == row[0].string, row[3].string == "unrouted" else { throw corruptCapture("business_outbox", key: id, raw: row[1].data ?? Data()) }
        try verifyCaptureID(id, kind: "outbox", matchID: item.matchID, raw: Canonical.data(item))
        return item
    }
}
