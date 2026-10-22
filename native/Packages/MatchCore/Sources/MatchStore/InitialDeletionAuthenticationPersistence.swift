import Foundation

struct InitialDeletionRowsV1 {
    var head: StoredInitialDeletionHeadV1?
    var terminal: StoredInitialDeletionTerminalV1?
    var attempts: [StoredInitialDeletionAttemptV1] = []
    var results: [String: StoredInitialDeletionResultV1] = [:]
    var resolutions: [String: StoredInitialDeletionResolutionV1] = [:]
    var totalBytes = 0
    var rowCount = 0
    var exists: Bool { head != nil || terminal != nil }
    var pendingResponseCount: Int { attempts.filter { $0.authentication != nil && results[$0.authRequestID] == nil && resolutions[$0.authRequestID] == nil }.count }
    var claimedIDs: Set<Data> {
        var ids: Set<Data> = []
        if let head { ids.insert(Data(head.request.creationID.utf8)) }
        if let terminal { ids.insert(Data(terminal.request.creationID.utf8)); ids.insert(Data(terminal.selectedAuthRequestID.utf8)) }
        for attempt in attempts { ids.insert(Data(attempt.authRequestID.utf8)); ids.insert(Data(attempt.challengeRequestID.utf8)) }
        return ids
    }
}

extension MatchStore {
    // Byte-prefix admission includes malformed TEXT and BLOB ids which SQLite GLOB skips.
    private var initialDeletionPredicateV1: String { "substr(CAST(id AS BLOB),1,19)=?" }
    private var initialDeletionPrefixV1: [SQLValue] { [.blob(Data(InitialDeletionWireV1.prefix.utf8))] }
    private func decodeInitialDeletionV1<T: Codable>(_ type: T.Type, raw: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: raw)
        guard try Canonical.data(value) == raw else { throw AuthorityError.invalidWire }
        return value
    }
    /// Shallow, self-contained namespace validation. Never calls another validator.
    func initialDeletionRowsLockedV1() throws -> InitialDeletionRowsV1 {
        let maximumKeyBytes = (InitialDeletionWireV1.namespace + "resolution:").utf8.count + 64
        let sizes = try db.rows("SELECT typeof(id),typeof(payload),length(payload),typeof(checksum),length(checksum),length(CAST(id AS BLOB)) FROM lifecycle_steps_v4 WHERE " + initialDeletionPredicateV1 + " LIMIT 50", initialDeletionPrefixV1)
        guard sizes.count <= 49 else { throw InitialDeletionIssueV1.capacity }
        var result = InitialDeletionRowsV1(); result.rowCount = sizes.count
        for row in sizes {
            guard let keyBytes = row[5].number, keyBytes >= 0, keyBytes <= maximumKeyBytes else { throw InitialDeletionIssueV1.capacity }
            guard let size = row[2].number, size >= 0, size <= InitialDeletionWireV1.maximumPayload else { throw InitialDeletionIssueV1.capacity }
            result.totalBytes += Int(size)
            guard result.totalBytes <= InitialDeletionWireV1.maximumTotal else { throw InitialDeletionIssueV1.capacity }
            guard row[0].string == "text", row[1].string == "blob", row[3].string == "text", row[4].number == 64 else { throw AuthorityError.invalidWire }
        }
        let rows = try db.rows("SELECT id,payload,checksum,CAST(id AS BLOB) FROM lifecycle_steps_v4 WHERE " + initialDeletionPredicateV1 + " AND length(CAST(id AS BLOB))<=? ORDER BY rowid LIMIT 49", initialDeletionPrefixV1 + [.integer(Int64(maximumKeyBytes))])
        guard rows.count == sizes.count else { throw AuthorityError.invalidWire }
        for row in rows {
            guard let key = row[0].string, row[3].data == Data(key.utf8), let raw = row[1].data,
                let checksum = row[2].string, checksum == Canonical.hash(raw), key.hasPrefix(InitialDeletionWireV1.namespace) else { throw AuthorityError.invalidWire }
            try InitialDeletionWireV1.digest(checksum)
            if key == InitialDeletionWireV1.namespace + "head" {
                guard result.head == nil else { throw AuthorityError.conflict }
                result.head = try decodeInitialDeletionV1(StoredInitialDeletionHeadV1.self, raw: raw)
            } else if key == InitialDeletionWireV1.namespace + "terminal" {
                guard result.terminal == nil else { throw AuthorityError.conflict }
                result.terminal = try decodeInitialDeletionV1(StoredInitialDeletionTerminalV1.self, raw: raw)
            } else if key.hasPrefix(InitialDeletionWireV1.namespace + "attempt:") {
                let value = try decodeInitialDeletionV1(StoredInitialDeletionAttemptV1.self, raw: raw)
                guard key == InitialDeletionWireV1.key("attempt", value.authRequestID) else { throw AuthorityError.invalidWire }
                result.attempts.append(value)
            } else if key.hasPrefix(InitialDeletionWireV1.namespace + "result:") {
                let value = try decodeInitialDeletionV1(StoredInitialDeletionResultV1.self, raw: raw)
                guard key == InitialDeletionWireV1.key("result", value.authRequestID), result.results.updateValue(value, forKey: value.authRequestID) == nil else { throw AuthorityError.invalidWire }
            } else if key.hasPrefix(InitialDeletionWireV1.namespace + "resolution:") {
                let value = try decodeInitialDeletionV1(StoredInitialDeletionResolutionV1.self, raw: raw)
                guard key == InitialDeletionWireV1.key("resolution", value.authRequestID), result.resolutions.updateValue(value, forKey: value.authRequestID) == nil else { throw AuthorityError.invalidWire }
            } else { throw AuthorityError.invalidWire }
        }
        if result.terminal != nil {
            guard rows.count == 1, result.head == nil else { throw AuthorityError.intentMismatch }
            return result
        }
        guard let head = result.head else {
            guard rows.isEmpty else { throw AuthorityError.intentMismatch }
            return result
        }
        guard !result.attempts.isEmpty, result.attempts.count <= 16 else { throw AuthorityError.intentMismatch }
        result.attempts.sort { $0.ordinal < $1.ordinal }
        var ids = Set<Data>([Data(head.request.creationID.utf8)])
        guard !ids.contains(Data(head.source.currentAuthRequestID.utf8)) else { throw AuthorityError.conflict }
        for (ordinal, attempt) in result.attempts.enumerated() {
            guard attempt.ordinal == ordinal, attempt.creationID == head.request.creationID else { throw AuthorityError.intentMismatch }
            for id in [attempt.authRequestID, attempt.challengeRequestID] {
                guard id != head.source.currentAuthRequestID, ids.insert(Data(id.utf8)).inserted else { throw AuthorityError.conflict }
            }
            if let auth = attempt.authentication {
                guard auth.deviceID == head.source.attempt.deviceID, auth.publicKey == head.source.attempt.publicKey,
                    auth.keyID == head.source.attempt.keyID, auth.cloudSpaceID == head.source.attempt.cloudSpaceID,
                    auth.environment == head.source.attempt.environment else { throw AuthorityError.identityChanged }
            }
            if let value = result.results[attempt.authRequestID] {
                guard value.creationID == head.request.creationID, let auth = attempt.authentication,
                    value.requestDigest == auth.requestDigest, result.resolutions[attempt.authRequestID] == nil else { throw AuthorityError.intentMismatch }
            }
            if let value = result.resolutions[attempt.authRequestID] {
                guard value.creationID == head.request.creationID,
                    (value.resolution == .notDispatched) == (attempt.authentication == nil) else { throw AuthorityError.intentMismatch }
            }
            if ordinal + 1 < result.attempts.count {
                guard result.resolutions[attempt.authRequestID] != nil, result.results[attempt.authRequestID] == nil else { throw InitialDeletionIssueV1.unresolved }
            }
        }
        let attemptIDs = Set(result.attempts.map(\.authRequestID))
        guard Set(result.results.keys).isSubset(of: attemptIDs), Set(result.resolutions.keys).isSubset(of: attemptIDs),
            result.results.count <= 1 else { throw AuthorityError.intentMismatch }
        if head.phase == .preparing {
            guard result.results.isEmpty else { throw AuthorityError.intentMismatch }
        } else {
            guard let selected = head.selectedAuthRequestID, result.results[selected] != nil,
                selected == result.attempts.last?.authRequestID else { throw AuthorityError.intentMismatch }
        }
        return result
    }
    /// Used by reverse Watch/052/control guards; does not recurse into their validators.
    func initialDeletionClaimedIDsLockedV1() throws -> Set<Data> { try initialDeletionRowsLockedV1().claimedIDs }

    private func initialDeletionSignedAuthV1(_ raw: Data, attempt: AuthAttemptV4, source: StoredInitialDeletionSourceV1) throws -> VerifiedAuthorityReceiptV1 {
        guard raw.count <= 32_768, let trust = authorityTrust, trust.environment == source.binding.environment else { throw AuthorityError.unavailable }
        let receipt = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID: attempt.requestID,
            digest: attempt.requestDigest, operation: .authApple, accountID: source.binding.accountID, epoch: source.binding.activationEpoch), trust: trust)
        let body = receipt.body
        guard body.result == .registered, body.matchID.isEmpty, body.lockID.isEmpty, body.recordingDeviceID.isEmpty,
            body.migration == nil, body.peerGrant == nil, body.registration == nil, body.lostRecovery == nil, body.deletion == nil else { throw AuthorityError.intentMismatch }
        return receipt
    }
    private func initialDeletionOtherIDsLockedV1() throws -> Set<Data> {
        var ids: Set<Data> = []
        for row in try db.rows("SELECT id,CAST(id AS BLOB) FROM control_intents_v4") {
            guard let id = row[0].string, row[1].data == Data(id.utf8) else { throw AuthorityError.invalidWire }
            ids.insert(Data(id.utf8))
        }
        let prefixes = ["auth-attempt:", "auth-receipt:", "auth-resolved:", "auth-admission:", "watch-attempt:", "watch-receipt:", "watch-admission:"]
        for row in try db.rows("SELECT id,CAST(id AS BLOB) FROM lifecycle_steps_v4") {
            guard let key = row[0].string, row[1].data == Data(key.utf8) else { throw AuthorityError.invalidWire }
            for prefix in prefixes where key.hasPrefix(prefix) { ids.insert(Data(key.dropFirst(prefix.count).utf8)) }
        }
        for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'watch-attempt:%'") {
            let attempt = try checkedV4(WatchRegistrationAttemptV4.self, row: row, table: "lifecycle_steps_v4", key: "watch-attempt")
            try attempt.validate(); ids.insert(Data(attempt.requestID.utf8)); ids.insert(Data(attempt.challengeRequestID.utf8))
        }
        for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:attempt:%'") {
            let attempt = try checkedV4(DeletionControlAttemptV1.self, row: row, table: "lifecycle_steps_v4", key: "delete-control-attempt")
            ids.insert(Data(attempt.authentication.requestID.utf8)); ids.insert(Data(attempt.challengeRequestID.utf8))
        }
        for row in try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id LIKE 'delete-control-v1:confirmation:%'") {
            let confirmation = try checkedV4(DeletionControlLockConfirmationV1.self, row: row, table: "lifecycle_steps_v4", key: "delete-control-confirmation")
            ids.insert(Data(confirmation.confirmationID.utf8)); ids.insert(Data(confirmation.intent.requestID.utf8))
        }
        return ids
    }
    @discardableResult
    func validateInitialDeletionRowsLockedV1() throws -> InitialDeletionRowsV1 {
        let rows = try initialDeletionRowsLockedV1()
        guard rows.exists else { return rows }
        if let head = rows.head {
            _ = try initialDeletionSignedAuthV1(head.source.receiptRaw, attempt: head.source.attempt, source: head.source)
            for result in rows.results.values {
                guard let attempt = rows.attempts.first(where: { $0.authRequestID == result.authRequestID })?.authentication else { throw AuthorityError.intentMismatch }
                _ = try initialDeletionSignedAuthV1(result.receiptRaw, attempt: attempt, source: head.source)
            }
            if head.phase == .consumed {
                guard let saga = try deletionSagaV4(requestID: head.request.creationID), saga.localProgress != .completed else { throw AuthorityError.intentMismatch }
                try validateInitialDeletionParentLockedV1(head, rows: rows)
            } else {
                guard try deletionSagasV4().isEmpty else { throw InitialDeletionIssueV1.parentExists }
            }
        }
        if let terminal = rows.terminal { try validateInitialDeletionTerminalLockedV1(terminal) }
        var otherIDs = try initialDeletionOtherIDsLockedV1()
        if let head = rows.head, head.phase == .consumed { otherIDs.remove(Data(head.request.creationID.utf8)) }
        if let terminal = rows.terminal { otherIDs.remove(Data(terminal.request.creationID.utf8)) }
        guard rows.claimedIDs.isDisjoint(with: otherIDs) else { throw AuthorityError.conflict }
        // These old validators are independent; reverse purpose checks use only the shallow helper.
        try validateDeletionControlRowsLockedV4()
        try validateCurrentWatchRegistrationRowsLockedV4()
        return rows
    }
    private func initialDeletionCurrentSourceLockedV1(generation: Int64, expected: StoredInitialDeletionSourceV1? = nil) throws -> VerifiedLocalAuthenticationEvidenceV4 {
        try InitialDeletionWireV1.generation(generation)
        try authenticationEvidenceBudgetV4(table: "lifecycle_steps_v4", id: "identity-generation")
        guard try identityGenerationV4() == generation, let current = try currentAuthenticationEvidenceLockedV4(generation: generation),
            current.binding.role == .phone, current.receipt.body.result == .registered else { throw AuthorityError.identityChanged }
        if let expected { guard try expected.matches(current) else { throw AuthorityError.identityChanged } }
        return current
    }
    private func initialDeletionContextLockedV1(_ rows: InitialDeletionRowsV1, creationID: String, generation: Int64) throws -> InitialDeletionContextV1? {
        try AuthorityWire.identifier(creationID)
        guard rows.terminal == nil, rows.head?.phase != .consumed else { throw InitialDeletionIssueV1.parentExists }
        guard let head = rows.head else {
            guard try deletionSagasV4().isEmpty else { throw InitialDeletionIssueV1.parentExists }
            return nil
        }
        guard head.request.creationID == creationID else { throw AuthorityError.conflict }
        let source = try initialDeletionCurrentSourceLockedV1(generation: generation, expected: head.source)
        let association = try head.selectedAuthRequestID.map { id -> InitialDeletionAssociationV1 in
            guard let result = rows.results[id], let attempt = rows.attempts.first(where: { $0.authRequestID == id })?.authentication else { throw AuthorityError.intentMismatch }
            return InitialDeletionAssociationV1(creationID: head.request.creationID, authRequestID: id, requestDigest: result.requestDigest,
                receipt: try initialDeletionSignedAuthV1(result.receiptRaw, attempt: attempt, source: head.source), opaqueReauthenticationID: result.opaqueReauthenticationID)
        }
        let reservation: InitialDeletionReservationV1?
        if head.phase == .reserved {
            try initialDeletionAbsenceLockedV1()
            reservation = try initialDeletionReservationLockedV1(rows, head: head)
        } else { reservation = nil }
        return InitialDeletionContextV1(request: head.request, originalAuthentication: source, phase: head.phase,
            attempts: rows.attempts.map { InitialDeletionAttemptV1(authRequestID: $0.authRequestID, challengeRequestID: $0.challengeRequestID,
                authentication: $0.authentication, resolution: rows.resolutions[$0.authRequestID]?.resolution) }, association: association, reservation: reservation)
    }
    private func insertInitialDeletionLockedV1<T: Encodable>(_ value: T, key: String) throws {
        let raw = try Canonical.data(value)
        guard raw.count <= InitialDeletionWireV1.maximumPayload else { throw InitialDeletionIssueV1.capacity }
        if let prior = try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?", [.text(key)]).first {
            guard prior[0].data == raw, prior[1].string == Canonical.hash(raw) else { throw AuthorityError.conflict }
            return
        }
        try db.execute("INSERT INTO lifecycle_steps_v4 VALUES (?,?,?)", [.text(key), .blob(raw), .text(Canonical.hash(raw))])
    }
    func replaceInitialDeletionHeadLockedV1(_ head: StoredInitialDeletionHeadV1, prior: StoredInitialDeletionHeadV1) throws {
        try replaceInitialDeletionLockedV1(head, prior: prior, key: InitialDeletionWireV1.namespace + "head")
    }
    private func replaceInitialDeletionLockedV1<T: Encodable>(_ value: T, prior: T, key: String) throws {
        let old = try Canonical.data(prior), new = try Canonical.data(value)
        guard new.count <= InitialDeletionWireV1.maximumPayload,
            let row = try db.rows("SELECT payload,checksum FROM lifecycle_steps_v4 WHERE id=?", [.text(key)]).first,
            row[0].data == old, row[1].string == Canonical.hash(old) else { throw AuthorityError.conflict }
        try db.execute("UPDATE lifecycle_steps_v4 SET payload=?,checksum=? WHERE id=? AND payload=? AND checksum=?", [.blob(new), .text(Canonical.hash(new)), .text(key), .blob(old), .text(Canonical.hash(old))])
    }
    private func reserveInitialDeletionBudgetV1(_ rows: InitialDeletionRowsV1, addedBytes: Int = 0, addedRows: Int = 0, responseSlots: Int = 0, terminal: Bool = false) throws {
        let slots = rows.pendingResponseCount + responseSlots
        guard addedBytes >= 0, rows.totalBytes + addedBytes + (slots + (terminal ? 1 : 0)) * 65_536 <= InitialDeletionWireV1.maximumTotal,
            rows.rowCount + addedRows + slots + (terminal ? 1 : 0) <= 49 else { throw InitialDeletionIssueV1.capacity }
    }
    private func initialDeletionAbsenceLockedV1() throws {
        try validateDeletionControlRowsLockedV4()
        try validateCurrentWatchRegistrationRowsLockedV4()
        guard try deletionSagasV4().isEmpty else { throw InitialDeletionIssueV1.parentExists }
        guard try pendingControlsV4().isEmpty, try pendingOrdinaryAuthAttemptsLockedV4().isEmpty,
            try pendingWatchRegistrationAttemptsV4().isEmpty, try !migrationBlocksBusinessV4() else { throw AuthorityError.conflict }
        for id in try matchIDs() {
            guard try ![.held, .terminationPending].contains(authorityStateV4(matchID: id, now: Date()).status) else { throw AuthorityError.terminalLock }
        }
    }
    private func completedInitialDeletionMutationV1() throws { if fault == .afterCommit { throw StoreError.responseLost } }

    /// Only this original write transaction can mint a token for its exact canonical intent.
    func initialDeletionConsumptionForSagaLockedV1(_ saga: DeletionSagaV4, rows: InitialDeletionRowsV1) throws -> InitialDeletionSagaConsumptionV1? {
        guard rows.exists else { return nil }
        let request: InitialDeletionRequestV1
        if let head = rows.head { request = head.request }
        else if let terminal = rows.terminal { request = terminal.request }
        else { throw AuthorityError.intentMismatch }
        guard request.creationID == saga.intent.requestID else { throw InitialDeletionIssueV1.parentExists }
        guard saga.originalScope == request.originalScope, saga.cloudChoice == request.cloud,
            saga.localChoice == request.local, saga.healthChoice == request.health, saga.healthConfirmed == request.healthConfirmed,
            saga.accountID == request.originalScope.accountID, saga.activationEpoch == request.originalScope.activationEpoch else { throw AuthorityError.intentMismatch }
        if rows.terminal != nil || rows.head?.phase == .consumed {
            guard let prior = try deletionSagaV4(requestID: request.creationID), prior.intent == saga.intent,
                prior.recoveryCapability == saga.recoveryCapability else { throw AuthorityError.conflict }
            return nil
        }
        guard let head = rows.head, head.phase == .reserved, let selected = head.selectedAuthRequestID,
            let result = rows.results[selected], let reauthenticationID = result.opaqueReauthenticationID,
            saga.intent.fields.reauthenticationID == reauthenticationID, try deletionSagasV4().isEmpty else { throw AuthorityError.intentMismatch }
        _ = try initialDeletionCurrentSourceLockedV1(generation: head.source.identityGeneration, expected: head.source)
        _ = try DeletionSagaV4(intent: saga.intent, accountID: saga.accountID, activationEpoch: saga.activationEpoch,
            recoveryCapability: saga.recoveryCapability, cloudChoice: saga.cloudChoice, localChoice: saga.localChoice,
            healthChoice: saga.healthChoice, healthConfirmed: saga.healthConfirmed, originalScope: saga.originalScope)
        return InitialDeletionSagaConsumptionV1(creationID: request.creationID,
            sourceDigest: AuthorityWire.hash(try Canonical.data(head.source)), selectedAuthRequestID: selected, intentDigest: saga.intent.digest)
    }
    func finishInitialDeletionConsumptionLockedV1(_ token: InitialDeletionSagaConsumptionV1, rows: InitialDeletionRowsV1) throws {
        guard let head = rows.head, head.phase == .reserved, head.request.creationID == token.creationID,
            head.selectedAuthRequestID == token.selectedAuthRequestID,
            AuthorityWire.hash(try Canonical.data(head.source)) == token.sourceDigest else { throw AuthorityError.intentMismatch }
        var next = head; next.phase = .consumed; next.parentIntentDigest = token.intentDigest
        try replaceInitialDeletionHeadLockedV1(next, prior: head)
    }
    func requireInitialDeletionControlClaimLockedV1(_ intent: ControlIntentV1, consumption: InitialDeletionSagaConsumptionV1?) throws {
        let rows = try initialDeletionRowsLockedV1()
        guard rows.claimedIDs.contains(Data(intent.requestID.utf8)) else {
            guard consumption == nil else { throw AuthorityError.intentMismatch }
            return
        }
        if let consumption, let head = rows.head, head.phase == .reserved {
            guard intent.operation == .deleteAccount, intent.requestID == consumption.creationID,
                intent.requestID == head.request.creationID, intent.digest == consumption.intentDigest,
                head.selectedAuthRequestID == consumption.selectedAuthRequestID,
                AuthorityWire.hash(try Canonical.data(head.source)) == consumption.sourceDigest,
                let selected = head.selectedAuthRequestID, let result = rows.results[selected],
                result.opaqueReauthenticationID == intent.fields.reauthenticationID else { throw AuthorityError.intentMismatch }
            return
        }
        let creationID = rows.head?.request.creationID ?? rows.terminal?.request.creationID
        guard consumption == nil, creationID == intent.requestID,
            rows.head?.phase == .consumed || rows.terminal != nil,
            let saga = try deletionSagaV4(requestID: intent.requestID),
            let control = try controlV4(intent.requestID), try Canonical.data(saga.intent) == Canonical.data(intent),
            try Canonical.data(control) == Canonical.data(intent) else { throw AuthorityError.conflict }
        try validateInitialDeletionRowsLockedV1()
    }

    public func initialDeletionContextV4(creationID: String, expectedIdentityGeneration: Int64) throws -> InitialDeletionContextV1? {
        try db.transaction { try initialDeletionContextLockedV1(validateInitialDeletionRowsLockedV1(), creationID: creationID, generation: expectedIdentityGeneration) }
    }
    public func prepareInitialDeletionAuthenticationV4(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) throws -> InitialDeletionContextV1 {
        let context = try db.transaction {
            var rows = try validateInitialDeletionRowsLockedV1()
            guard rows.terminal == nil, rows.head?.phase != .consumed else { throw InitialDeletionIssueV1.parentExists }
            guard rows.head?.phase != .reserved else { throw InitialDeletionIssueV1.alreadyReserved }
            try initialDeletionAbsenceLockedV1()
            let source = try initialDeletionCurrentSourceLockedV1(generation: expectedSource.identityGeneration)
            guard try StoredInitialDeletionSourceV1(expectedSource).matches(source) else { throw AuthorityError.identityChanged }
            var head = rows.head ?? StoredInitialDeletionHeadV1(request: request, source: StoredInitialDeletionSourceV1(source))
            guard try Canonical.data(head.request) == Canonical.data(request), try head.source.matches(source), head.phase == .preparing else { throw AuthorityError.conflict }
            for id in [authRequestID, challengeRequestID] { try AuthorityWire.identifier(id) }
            if let prior = rows.attempts.first(where: { $0.authRequestID == authRequestID }) {
                guard prior.challengeRequestID == challengeRequestID else { throw AuthorityError.conflict }
                return try requireInitialDeletionContextLockedV1(rows, creationID: request.creationID, generation: source.identityGeneration)
            }
            guard rows.attempts.allSatisfy({ rows.resolutions[$0.authRequestID] != nil && rows.results[$0.authRequestID] == nil }) else { throw InitialDeletionIssueV1.unresolved }
            guard rows.attempts.count < 16 else { throw InitialDeletionIssueV1.capacity }
            let newIDs = Set([Data(authRequestID.utf8), Data(challengeRequestID.utf8), Data(request.creationID.utf8)])
            guard newIDs.count == 3, !newIDs.contains(Data(source.currentAuthRequestID.utf8)),
                Set([Data(authRequestID.utf8), Data(challengeRequestID.utf8)]).isDisjoint(with: rows.claimedIDs),
                newIDs.isDisjoint(with: try initialDeletionOtherIDsLockedV1()) else { throw AuthorityError.conflict }
            let attempt = StoredInitialDeletionAttemptV1(creationID: request.creationID, ordinal: rows.attempts.count,
                authRequestID: authRequestID, challengeRequestID: challengeRequestID)
            let newHeadBytes = rows.head == nil ? try Canonical.data(head).count : 0
            try reserveInitialDeletionBudgetV1(rows, addedBytes: newHeadBytes + (try Canonical.data(attempt).count), addedRows: (rows.head == nil ? 2 : 1), responseSlots: 1)
            if rows.head == nil { try insertInitialDeletionLockedV1(head, key: InitialDeletionWireV1.namespace + "head") }
            try insertInitialDeletionLockedV1(attempt, key: InitialDeletionWireV1.key("attempt", authRequestID))
            rows = try validateInitialDeletionRowsLockedV1(); head = try requireInitialDeletionHeadV1(rows, creationID: request.creationID)
            try fail(.beforeCommit)
            return try requireInitialDeletionContextLockedV1(rows, creationID: head.request.creationID, generation: source.identityGeneration)
        }
        try completedInitialDeletionMutationV1(); return context
    }
    private func requireInitialDeletionContextLockedV1(_ rows: InitialDeletionRowsV1, creationID: String, generation: Int64) throws -> InitialDeletionContextV1 {
        guard let context = try initialDeletionContextLockedV1(rows, creationID: creationID, generation: generation) else { throw AuthorityError.intentMismatch }
        return context
    }
    private func requireInitialDeletionHeadV1(_ rows: InitialDeletionRowsV1, creationID: String) throws -> StoredInitialDeletionHeadV1 {
        try AuthorityWire.identifier(creationID)
        guard rows.terminal == nil, rows.head?.phase != .consumed else { throw InitialDeletionIssueV1.parentExists }
        guard let head = rows.head, head.request.creationID == creationID else { throw AuthorityError.intentMismatch }
        return head
    }
    public func saveInitialDeletionAttemptV4(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) throws {
        try db.transaction {
            let rows = try validateInitialDeletionRowsLockedV1(), head = try requireInitialDeletionHeadV1(rows, creationID: creationID)
            _ = try initialDeletionCurrentSourceLockedV1(generation: expectedIdentityGeneration, expected: head.source)
            guard head.phase == .preparing, let prior = rows.attempts.first(where: { $0.authRequestID == authentication.requestID }),
                rows.resolutions[authentication.requestID] == nil, rows.results[authentication.requestID] == nil else { throw AuthorityError.conflict }
            if let existing = prior.authentication { guard existing == authentication else { throw AuthorityError.conflict }; return }
            var next = prior; next.authentication = authentication; try next.validate()
            guard authentication.deviceID == head.source.attempt.deviceID, authentication.publicKey == head.source.attempt.publicKey,
                authentication.cloudSpaceID == head.source.attempt.cloudSpaceID, authentication.environment == head.source.attempt.environment else { throw AuthorityError.identityChanged }
            try reserveInitialDeletionBudgetV1(rows, addedBytes: (try Canonical.data(next).count) - (try Canonical.data(prior).count), responseSlots: 1)
            try replaceInitialDeletionLockedV1(next, prior: prior, key: InitialDeletionWireV1.key("attempt", authentication.requestID))
            try validateInitialDeletionRowsLockedV1(); try fail(.beforeCommit)
        }
        try completedInitialDeletionMutationV1()
    }
    public func acceptInitialDeletionAuthenticationV4(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) throws {
        try db.transaction {
            let rows = try validateInitialDeletionRowsLockedV1(), head = try requireInitialDeletionHeadV1(rows, creationID: creationID)
            _ = try initialDeletionCurrentSourceLockedV1(generation: expectedIdentityGeneration, expected: head.source)
            guard head.phase == .preparing || head.phase == .associated,
                let attempt = rows.attempts.first(where: { $0.authRequestID == authRequestID })?.authentication,
                rows.resolutions[authRequestID] == nil else { throw AuthorityError.conflict }
            _ = try initialDeletionSignedAuthV1(receipt.raw, attempt: attempt, source: head.source)
            let result = StoredInitialDeletionResultV1(creationID: creationID, authRequestID: authRequestID, requestDigest: attempt.requestDigest,
                receiptRaw: receipt.raw, opaqueReauthenticationID: opaqueReauthenticationID)
            try result.validate()
            if let first = rows.results[authRequestID] { guard first == result else { throw AuthorityError.conflict }; return }
            try insertInitialDeletionLockedV1(result, key: InitialDeletionWireV1.key("result", authRequestID))
            var next = head; next.phase = .associated; next.selectedAuthRequestID = authRequestID
            try replaceInitialDeletionHeadLockedV1(next, prior: head)
            try validateInitialDeletionRowsLockedV1(); try fail(.afterReceipt); try fail(.beforeCommit)
        }
        try completedInitialDeletionMutationV1()
    }
    public func closePreparedInitialDeletionAttemptV4(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) throws {
        try resolveInitialDeletionLockedMutationV1(creationID: creationID, authRequestID: authRequestID, resolution: .notDispatched, generation: expectedIdentityGeneration, prepared: true)
    }
    public func resolveInitialDeletionAttemptV4(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) throws {
        guard resolution != .notDispatched else { throw AuthorityError.invalidWire }
        try resolveInitialDeletionLockedMutationV1(creationID: creationID, authRequestID: authRequestID, resolution: resolution, generation: expectedIdentityGeneration, prepared: false)
    }
    private func resolveInitialDeletionLockedMutationV1(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, generation: Int64, prepared: Bool) throws {
        try db.transaction {
            let rows = try validateInitialDeletionRowsLockedV1(), head = try requireInitialDeletionHeadV1(rows, creationID: creationID)
            _ = try initialDeletionCurrentSourceLockedV1(generation: generation, expected: head.source)
            guard head.phase == .preparing, let attempt = rows.attempts.first(where: { $0.authRequestID == authRequestID }),
                (attempt.authentication == nil) == prepared, rows.results[authRequestID] == nil else { throw AuthorityError.conflict }
            let record = StoredInitialDeletionResolutionV1(creationID: creationID, authRequestID: authRequestID, resolution: resolution)
            try insertInitialDeletionLockedV1(record, key: InitialDeletionWireV1.key("resolution", authRequestID))
            try validateInitialDeletionRowsLockedV1(); try fail(.beforeCommit)
        }
        try completedInitialDeletionMutationV1()
    }
    public func reserveInitialDeletionV4(creationID: String, expectedIdentityGeneration: Int64) throws -> InitialDeletionReservationV1 {
        let reservation = try db.transaction {
            let rows = try validateInitialDeletionRowsLockedV1(), head = try requireInitialDeletionHeadV1(rows, creationID: creationID)
            _ = try initialDeletionCurrentSourceLockedV1(generation: expectedIdentityGeneration, expected: head.source)
            try initialDeletionAbsenceLockedV1()
            let descriptor = try initialDeletionReservationLockedV1(rows, head: head)
            try reserveInitialDeletionBudgetV1(rows, terminal: true)
            if head.phase != .reserved {
                var next = head; next.phase = .reserved; try replaceInitialDeletionHeadLockedV1(next, prior: head)
                try validateInitialDeletionRowsLockedV1(); try fail(.beforeCommit)
            }
            return descriptor
        }
        try completedInitialDeletionMutationV1(); return reservation
    }

    private func initialDeletionReservationLockedV1(_ rows: InitialDeletionRowsV1, head: StoredInitialDeletionHeadV1) throws -> InitialDeletionReservationV1 {
        guard head.phase == .associated || head.phase == .reserved, let selected = head.selectedAuthRequestID,
            let result = rows.results[selected], let attempt = rows.attempts.first(where: { $0.authRequestID == selected })?.authentication else { throw InitialDeletionIssueV1.unresolved }
        _ = try initialDeletionSignedAuthV1(result.receiptRaw, attempt: attempt, source: head.source)
        guard let opaqueID = result.opaqueReauthenticationID else { throw InitialDeletionIssueV1.missingReauthentication }
        try AuthorityWire.identifier(opaqueID)
        return InitialDeletionReservationV1(request: head.request, identityGeneration: head.source.identityGeneration,
            originalAuthRequestID: head.source.currentAuthRequestID, originalAuthReceiptDigest: AuthorityWire.hash(head.source.receiptRaw),
            initialAuthRequestID: selected, initialAuthRequestDigest: result.requestDigest,
            initialAuthReceiptDigest: AuthorityWire.hash(result.receiptRaw), opaqueReauthenticationID: opaqueID)
    }

    func validateInitialDeletionSagaContractLockedV1(_ saga: DeletionSagaV4, request: InitialDeletionRequestV1) throws {
        guard saga.intent.requestID == request.creationID, saga.originalScope == request.originalScope,
            saga.accountID == request.originalScope.accountID, saga.activationEpoch == request.originalScope.activationEpoch,
            saga.cloudChoice == request.cloud, saga.localChoice == request.local, saga.healthChoice == request.health,
            saga.healthConfirmed == request.healthConfirmed, saga.revision >= 0,
            let control = try controlV4(request.creationID), try Canonical.data(control) == Canonical.data(saga.intent),
            try db.scalar("SELECT match_id FROM control_intents_v4 WHERE id=?", [.text(request.creationID)]).string == "" else { throw AuthorityError.intentMismatch }
        _ = try DeletionSagaV4(intent: saga.intent, accountID: saga.accountID, activationEpoch: saga.activationEpoch,
            recoveryCapability: saga.recoveryCapability, cloudChoice: saga.cloudChoice, localChoice: saga.localChoice,
            healthChoice: saga.healthChoice, healthConfirmed: saga.healthConfirmed, originalScope: saga.originalScope)
        guard try deletionSagasV4().count == 1 else { throw InitialDeletionIssueV1.parentExists }
        if saga.backendDeleted {
            _ = try initialDeletionBackendReceiptLockedV1(saga)
        } else {
            guard saga.backendReceipt == nil, saga.localProgress != .completed else { throw AuthorityError.intentMismatch }
        }
    }
    @discardableResult
    private func initialDeletionBackendReceiptLockedV1(_ saga: DeletionSagaV4) throws -> VerifiedAuthorityReceiptV1 {
        guard saga.backendDeleted, let raw = saga.backendReceipt, let trust = authorityTrust else { throw AuthorityError.intentMismatch }
        let proof = try VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(saga.intent,
            accountID: saga.accountID, epoch: saga.activationEpoch), trust: trust)
        guard proof.body.result == .deleted, proof.body.deletion?.backend == "backendDeleted", proof.body.deletion?.apple == "revoked" else { throw AuthorityError.intentMismatch }
        return proof
    }
    private func validateInitialDeletionRetiredSourceLockedV1(_ source: StoredInitialDeletionSourceV1) throws {
        guard source.identityGeneration < 9_007_199_254_740_991,
            try identityGenerationV4() == source.identityGeneration + 1,
            try currentAuthRequestIDV4() == source.currentAuthRequestID,
            try authAttemptV4(requestID: source.currentAuthRequestID) == source.attempt,
            try readLifecycleV4(Int64.self, "auth-admission:" + source.currentAuthRequestID) == source.admissionGeneration,
            try readLifecycleV4(Data.self, "auth-receipt:" + source.currentAuthRequestID) == source.receiptRaw,
            try authResolutionV4(requestID: source.currentAuthRequestID) == nil,
            let binding = try currentBindingV4() else { throw AuthorityError.identityChanged }
        let suspended = try AccountBindingV4(accountID: source.binding.accountID, cloudSpaceID: source.binding.cloudSpaceID,
            deviceID: source.binding.deviceID, activationEpoch: source.binding.activationEpoch, role: source.binding.role,
            environment: source.binding.environment, suspended: true)
        guard try Canonical.data(binding) == Canonical.data(suspended) else { throw AuthorityError.identityChanged }
    }
    private func validateInitialDeletionParentLockedV1(_ head: StoredInitialDeletionHeadV1, rows: InitialDeletionRowsV1) throws {
        guard let saga = try deletionSagaV4(requestID: head.request.creationID),
            let selected = head.selectedAuthRequestID, let result = rows.results[selected],
            let reauthenticationID = result.opaqueReauthenticationID,
            head.parentIntentDigest == saga.intent.digest, saga.intent.fields.reauthenticationID == reauthenticationID else { throw AuthorityError.intentMismatch }
        try validateInitialDeletionSagaContractLockedV1(saga, request: head.request)
        if saga.backendDeleted { try validateInitialDeletionRetiredSourceLockedV1(head.source) }
        else { _ = try initialDeletionCurrentSourceLockedV1(generation: head.source.identityGeneration, expected: head.source) }
    }
    /// Called only after the original erase has written completed progress, inside that same transaction.
    func compactInitialDeletionAfterEraseLockedV1(_ saga: DeletionSagaV4, rows: InitialDeletionRowsV1) throws {
        guard let head = rows.head else { return }
        guard head.phase == .consumed, head.request.creationID == saga.intent.requestID, saga.localProgress == .completed,
            let selected = head.selectedAuthRequestID, let result = rows.results[selected],
            let backend = saga.backendReceipt else { throw AuthorityError.intentMismatch }
        _ = try initialDeletionBackendReceiptLockedV1(saga)
        try validateInitialDeletionParentLockedV1(head, rows: rows)
        let terminal = StoredInitialDeletionTerminalV1(request: head.request, sourceAuthRequestID: head.source.currentAuthRequestID,
            sourceReceiptDigest: AuthorityWire.hash(head.source.receiptRaw), sourceGeneration: head.source.identityGeneration,
            selectedAuthRequestID: selected, selectedRequestDigest: result.requestDigest,
            selectedReceiptDigest: AuthorityWire.hash(result.receiptRaw), parentIntentDigest: saga.intent.digest,
            backendReceiptDigest: AuthorityWire.hash(backend))
        // The earlier reservation budgets this record; rollback preserves every original raw row on any failure.
        try db.execute("DELETE FROM lifecycle_steps_v4 WHERE " + initialDeletionPredicateV1, initialDeletionPrefixV1)
        try insertInitialDeletionLockedV1(terminal, key: InitialDeletionWireV1.namespace + "terminal")
        try validateInitialDeletionRowsLockedV1()
    }
    private func validateInitialDeletionTerminalLockedV1(_ terminal: StoredInitialDeletionTerminalV1) throws {
        guard let saga = try deletionSagaV4(requestID: terminal.request.creationID), saga.localProgress == .completed,
            let receipt = saga.backendReceipt, terminal.parentIntentDigest == saga.intent.digest,
            terminal.backendReceiptDigest == AuthorityWire.hash(receipt),
            try currentAuthRequestIDV4() == terminal.sourceAuthRequestID,
            let original = try authAttemptV4(requestID: terminal.sourceAuthRequestID),
            let sourceRaw = try readLifecycleV4(Data.self, "auth-receipt:" + terminal.sourceAuthRequestID),
            AuthorityWire.hash(sourceRaw) == terminal.sourceReceiptDigest,
            try readLifecycleV4(Int64.self, "auth-admission:" + terminal.sourceAuthRequestID) == terminal.sourceGeneration,
            try authResolutionV4(requestID: terminal.sourceAuthRequestID) == nil,
            terminal.sourceGeneration < 9_007_199_254_740_991, try identityGenerationV4() == terminal.sourceGeneration + 1,
            let binding = try currentBindingV4(), binding.suspended, binding.role == .phone,
            binding.accountID == saga.accountID, binding.cloudSpaceID == terminal.request.originalScope.cloudSpaceID,
            binding.activationEpoch == saga.activationEpoch, binding.deviceID == original.deviceID,
            original.cloudSpaceID == binding.cloudSpaceID, original.environment == binding.environment,
            let trust = authorityTrust, trust.environment == binding.environment, sourceRaw.count <= 32_768 else { throw AuthorityError.intentMismatch }
        try validateInitialDeletionSagaContractLockedV1(saga, request: terminal.request)
        let sourceProof = try VerifiedAuthorityReceiptV1.verify(sourceRaw, expected: AuthorityExpectedIntent(requestID: original.requestID,
            digest: original.requestDigest, operation: .authApple, accountID: saga.accountID, epoch: saga.activationEpoch), trust: trust)
        let body = sourceProof.body
        guard body.result == .registered, body.matchID.isEmpty, body.lockID.isEmpty, body.recordingDeviceID.isEmpty,
            body.migration == nil, body.peerGrant == nil, body.registration == nil, body.lostRecovery == nil, body.deletion == nil else { throw AuthorityError.intentMismatch }
    }
}
