import Foundation
import MatchCore

extension MatchStore {
    /// Lookup is read-only: a saved request is returned only after its complete receipt is verified.
    public func committedCommandV2(commandID: String) throws -> CommittedCommandV2? {
        var diagnosticMatchID = commandID
        do {
            return try db.transaction {
                guard let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(commandID)]).first else { return nil }
                diagnosticMatchID = row[3].string ?? commandID
                return try verifiedCommandV2(commandID: commandID, row: row)
            }
        } catch {
            return try preservingDiagnostics(matchID: diagnosticMatchID) { throw error }
        }
    }

    public func commitV2(_ request: StoreCommitV2) throws -> CommitReceiptV2 {
        let bytes = try Canonical.data(request), hash = Canonical.hash(bytes), matchID = request.descriptor.matchID
        let receipt: CommitReceiptV2 = try preservingDiagnostics(matchID: matchID) {
            try db.transaction {
                if let row = try db.rows("SELECT request,request_hash,receipt,match_id FROM commands_v2 WHERE command_id=?", [.text(request.commandID)]).first {
                    if row[0].data == bytes, row[1].string != hash { throw corruptCapture("commands_v2", key: request.commandID, raw: row[0].data ?? Data()) }
                    guard row[1].string == hash else { throw StoreError.commandConflict }
                    return try verifiedCommandV2(commandID: request.commandID, row: row).receipt
                }
                guard try db.rows("SELECT command_id FROM commands WHERE command_id=?", [.text(request.commandID)]).isEmpty else { throw StoreError.commandConflict }
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
                try fail(.afterReceipt); try fail(.beforeCommit)
                return receipt
            }
        }
        if fault == .afterCommit { throw StoreError.responseLost }
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
                try db.rows("SELECT id FROM business_outbox WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map {
                    let item = try loadBusinessOutbox(id: $0[0].string ?? "invalid-id")
                    guard item.matchID == matchID else { throw corruptCapture("business_outbox", key: item.id, raw: try Canonical.data(item)) }
                    return item
                }
            }
        }
    }

    public func saveCompletionProofV2(evidence: TrustedCompletionEvidence, captureDigest: String,
                                      expectedGeneration: Int64, now: Date) throws {
        try preservingDiagnostics(matchID: evidence.matchID) {
            try db.transaction {
                let snapshot = try loadSnapshot(matchID: evidence.matchID)
                guard snapshot.generation == expectedGeneration else { throw StoreError.staleGeneration }
                guard !snapshot.diagnostics.contains(where: { $0.severity == .blocking }) else { throw StoreError.unresolvedDiagnostics }
                let revisions = try loadCaptureRevisions(descriptor: snapshot.descriptor)
                guard captureDigest == (try CaptureRevision.digest(revisions)) else { throw StoreError.staleCaptureEvidence }
                guard now.timeIntervalSinceReferenceDate.isFinite,
                      MatchReplay.replay(descriptor: snapshot.descriptor, events: snapshot.events, now: now, completionEvidence: evidence).state == .completed else {
                    throw StoreError.staleCompletionEvidence
                }
                try rememberCompletionConfirmation(evidence: evidence, digest: captureDigest, hasCapture: !revisions.isEmpty)
                try db.execute("INSERT INTO completion_v2 VALUES (?,?,?) ON CONFLICT(match_id) DO UPDATE SET evidence=excluded.evidence,capture_digest=excluded.capture_digest",
                    [.text(evidence.matchID), .blob(try Canonical.data(evidence)), .text(captureDigest)])
                try fail(.beforeCommit)
            }
        }
    }

    /// Both snapshot APIs call this boundary, so old evidence cannot bypass capture invalidation.
    func filteredCompletionEvidence(descriptor: MatchDescriptor, legacy: TrustedCompletionEvidence?) throws -> TrustedCompletionEvidence? {
        let revisions = try loadCaptureRevisions(descriptor: descriptor)
        if let row = try db.rows("SELECT evidence,capture_digest FROM completion_v2 WHERE match_id=?", [.text(descriptor.matchID)]).first {
            let evidence = try decode(TrustedCompletionEvidence.self, row[0], table: "completion_v2", key: descriptor.matchID)
            guard evidence.matchID == descriptor.matchID else { throw corruptCapture("completion_v2", key: descriptor.matchID, raw: row[0].data ?? Data()) }
            let digest = row[1].string ?? ""
            let confirmation = try loadCompletionConfirmation(matchID: descriptor.matchID, confirmationID: evidence.confirmationID)
            guard confirmation.evidence == evidence, confirmation.captureDigest == digest else {
                throw corruptCapture("completion_v2", key: descriptor.matchID, raw: row[0].data ?? Data())
            }
            return digest == (try CaptureRevision.digest(revisions)) ? evidence : nil
        }
        return revisions.isEmpty ? legacy : nil
    }

    private struct CompletionConfirmation: Codable, Equatable {
        let evidence: TrustedCompletionEvidence
        let captureDigest: String
    }
    private func loadCompletionConfirmation(matchID: String, confirmationID: String) throws -> CompletionConfirmation {
        guard let row = try db.rows("SELECT proof,checksum FROM completion_confirmations WHERE match_id=? AND confirmation_id=?", [.text(matchID), .text(confirmationID)]).first else {
            throw corruptCapture("completion_confirmations", key: confirmationID, raw: Data())
        }
        let proof = try checkedCapture(CompletionConfirmation.self, raw: row[0], checksum: row[1], table: "completion_confirmations", key: confirmationID)
        guard proof.evidence.matchID == matchID, proof.evidence.confirmationID == confirmationID else {
            throw corruptCapture("completion_confirmations", key: confirmationID, raw: row[0].data ?? Data())
        }
        return proof
    }
    private func rememberCompletionConfirmation(evidence: TrustedCompletionEvidence, digest: String, hasCapture: Bool) throws {
        let proof = CompletionConfirmation(evidence: evidence, captureDigest: digest)
        if !(try db.rows("SELECT confirmation_id FROM completion_confirmations WHERE match_id=? AND confirmation_id=?", [.text(evidence.matchID), .text(evidence.confirmationID)])).isEmpty {
            guard try loadCompletionConfirmation(matchID: evidence.matchID, confirmationID: evidence.confirmationID) == proof else { throw StoreError.staleCaptureEvidence }
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
    private func verifiedCommandV2(commandID: String, row: [SQLValue]) throws -> CommittedCommandV2 {
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
        return result
    }
    private func appendRevision(_ revision: CaptureRevision, descriptor: MatchDescriptor) throws {
        let matchID = descriptor.matchID, raw = try Canonical.data(revision)
        guard revision.binding.matchID == matchID, revision.binding.recordingDeviceID == descriptor.recordingDeviceID else {
            throw quarantine(.invalidCaptureRevision, code: "capture-binding-conflict", key: revision.id, raw: raw)
        }
        try registerCaptureID(revision.id, kind: "revision", matchID: matchID, raw: raw)
        for segment in revision.metadata.segments { try registerCaptureID(segment.id, kind: "segment", matchID: matchID, raw: Canonical.data(segment)) }
        for gap in revision.metadata.gaps { try registerCaptureID(gap.id, kind: "gap", matchID: matchID, raw: Canonical.data(gap)) }
        let revisions = try loadCaptureRevisions(descriptor: descriptor)
        if let existing = revisions.first(where: { $0.id == revision.id }) {
            guard existing == revision else { throw quarantine(.captureConflict, code: "capture-revision-conflict", key: revision.id, raw: raw) }; return
        }
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
    private func loadOperations(matchID: String, descriptor: MatchDescriptor) throws -> [CaptureOperationRecord] {
        try db.rows("SELECT id FROM capture_operations WHERE match_id=? ORDER BY rowid", [.text(matchID)]).map {
            try loadOperation(id: $0[0].string ?? "invalid-id", descriptor: descriptor).record
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
        guard (from.state == .pending && to.state == .needsReconciliation && to.observation == nil) ||
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
            case .some(.stopped), .some(.savedAwaitingLink), .some(.linked): break
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
    private func loadBusinessOutbox(id: String) throws -> BusinessOutboxItem {
        guard let row = try db.rows("SELECT match_id,payload,checksum,routing_state FROM business_outbox WHERE id=?", [.text(id)]).first else { throw corruptCapture("business_outbox", key: id, raw: Data()) }
        let item = try checkedCapture(BusinessOutboxItem.self, raw: row[1], checksum: row[2], table: "business_outbox", key: id)
        guard item.id == id, item.matchID == row[0].string, row[3].string == "unrouted" else { throw corruptCapture("business_outbox", key: id, raw: row[1].data ?? Data()) }
        try verifyCaptureID(id, kind: "outbox", matchID: item.matchID, raw: Canonical.data(item))
        return item
    }
}
