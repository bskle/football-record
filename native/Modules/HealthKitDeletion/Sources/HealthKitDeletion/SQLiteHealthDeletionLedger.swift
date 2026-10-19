import Foundation
import SQLite3
import Darwin

private enum SQLValue {
    case text(String), data(Data), number(Int64), null
    var text: String? { if case .text(let x)=self { x } else { nil } }
    var data: Data? { if case .data(let x)=self { x } else { nil } }
    var number: Int64? { if case .number(let x)=self { x } else { nil } }
    var isNull: Bool { if case .null=self { true } else { false } }
}
private final class DeletionSQL: @unchecked Sendable {
    private var db: OpaquePointer?
    private var ownerFD: Int32 = -1
    init(url: URL, business: URL) throws {
        guard url.isFileURL, business.isFileURL else { throw HealthDeletionIssue.invalidRequest }
        let path=url.standardizedFileURL.resolvingSymlinksInPath().path
        let erased=business.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != erased, !path.hasPrefix(erased.hasSuffix("/") ? erased : erased+"/") else { throw HealthDeletionIssue.invalidRequest }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        ownerFD=Darwin.open(path+".owner",O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
        guard ownerFD >= 0 else { throw HealthDeletionIssue.storageUnavailable }
        guard flock(ownerFD,LOCK_EX|LOCK_NB) == 0 else { Darwin.close(ownerFD);ownerFD = -1;throw HealthDeletionIssue.ledgerInUse }
        guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
            if let db { sqlite3_close_v2(db) };db=nil;releaseOwner();throw HealthDeletionIssue.storageUnavailable
        }
        guard sqlite3_busy_timeout(db,5000) == SQLITE_OK else { try? close();throw HealthDeletionIssue.storageUnavailable }
    }
    deinit { if let db { sqlite3_close_v2(db) };releaseOwner() }
    private func releaseOwner() { if ownerFD >= 0 { _=flock(ownerFD,LOCK_UN);Darwin.close(ownerFD);ownerFD = -1 } }
    func close() throws {
        if let db { guard sqlite3_close(db) == SQLITE_OK else { throw HealthDeletionIssue.storageUnavailable };self.db=nil }
        releaseOwner()
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value=try body();try execute("COMMIT");return value }
        catch { if let db, sqlite3_get_autocommit(db) == 0 { try? execute("ROLLBACK") };throw error }
    }
    func execute(_ query: String,_ args: [SQLValue] = []) throws { _=try rows(query,args) }
    func rows(_ query: String,_ args: [SQLValue] = []) throws -> [[SQLValue]] {
        guard let db else { throw HealthDeletionIssue.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,query,-1,&statement,nil) == SQLITE_OK,let statement else { throw HealthDeletionIssue.storageUnavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(args.count) else { throw HealthDeletionIssue.invalidRequest }
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (offset,arg) in args.enumerated() {
            let index=Int32(offset+1),code: Int32
            switch arg {
            case .text(let value): code=value.withCString { sqlite3_bind_text(statement,index,$0,-1,transient) }
            case .data(let value): code=value.isEmpty ? sqlite3_bind_zeroblob(statement,index,0) : value.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(value.count),transient) }
            case .number(let value): code=sqlite3_bind_int64(statement,index,value)
            case .null: code=sqlite3_bind_null(statement,index)
            }
            guard code == SQLITE_OK else { throw HealthDeletionIssue.storageUnavailable }
        }
        var result: [[SQLValue]]=[]
        while true {
            let code=sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw HealthDeletionIssue.storageUnavailable }
            var row: [SQLValue]=[]
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement,index) {
                case SQLITE_INTEGER: row.append(.number(sqlite3_column_int64(statement,index)))
                case SQLITE_TEXT:
                    let size=Int(sqlite3_column_bytes(statement,index))
                    guard let pointer=sqlite3_column_text(statement,index),let value=String(data:Data(bytes:pointer,count:size),encoding:.utf8) else { throw HealthDeletionIssue.invalidRequest }
                    row.append(.text(value))
                case SQLITE_BLOB:
                    let size=Int(sqlite3_column_bytes(statement,index))
                    if size == 0 { row.append(.data(Data())) } else {
                        guard let pointer=sqlite3_column_blob(statement,index) else { throw HealthDeletionIssue.invalidRequest }
                        row.append(.data(Data(bytes:pointer,count:size)))
                    }
                case SQLITE_NULL: row.append(.null)
                default: throw HealthDeletionIssue.invalidRequest
                }
            }
            result.append(row)
        }
    }
}

/// Owns only local deletion control facts. One owner holds the file lock until close.
public actor SQLiteHealthDeletionLedger: HealthDeletionLedger {
    private let sql: DeletionSQL
    private let fault: @Sendable (DeletionWrite) -> DeletionFault?
    private static let columns="request_id,digest,original,confirmation,phase,attempt_id,attempt_count,issue,receipt"
    public init(url: URL,businessDataDirectory: URL) throws {
        try self.init(url:url,businessDataDirectory:businessDataDirectory,fault:{ _ in nil })
    }
    init(url: URL,businessDataDirectory: URL,fault: @escaping @Sendable (DeletionWrite) -> DeletionFault?) throws {
        let sql=try DeletionSQL(url:url,business:businessDataDirectory)
        do {
            let version=try sql.rows("PRAGMA user_version").first?.first?.number
            guard version == 0 || version == 1 else { throw HealthDeletionIssue.unsupportedSchema }
            guard try sql.rows("PRAGMA quick_check(1)").first?.first?.text == "ok" else { throw HealthDeletionIssue.storageUnavailable }
            if version == 0 {
                guard try sql.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw HealthDeletionIssue.unsupportedSchema }
                try sql.transaction {
                    try sql.execute("CREATE TABLE health_deletion_requests(request_id TEXT PRIMARY KEY,digest TEXT NOT NULL,original BLOB NOT NULL,confirmation BLOB,phase TEXT NOT NULL,attempt_id TEXT,attempt_count INTEGER NOT NULL,issue TEXT,receipt BLOB) STRICT")
                    _=try sql.rows("SELECT "+Self.columns+" FROM health_deletion_requests LIMIT 0")
                    try sql.execute("PRAGMA user_version=1")
                }
            } else {
                // Validate all existing control facts before journal changes or recovery writes.
                for row in try sql.rows("SELECT "+Self.columns+" FROM health_deletion_requests") { _=try Self.decode(row) }
            }
            guard try sql.rows("PRAGMA journal_mode=WAL").first?.first?.text?.lowercased() == "wal" else { throw HealthDeletionIssue.storageUnavailable }
            try sql.execute("PRAGMA synchronous=FULL")
            try sql.transaction {
                try sql.execute("UPDATE health_deletion_requests SET phase='interrupted',issue='outcomeUnknown' WHERE phase IN ('executing','awaitingOutcome')")
            }
        } catch { try? sql.close();throw error }
        self.sql=sql;self.fault=fault
    }
    public func close() throws { try sql.close() }
    private func write<T>(_ operation: DeletionWrite,_ body: () throws -> T) throws -> T {
        let point=fault(operation)
        let value=try sql.transaction {
            let value=try body()
            if point == .beforeCommit { throw HealthDeletionIssue.storageUnavailable }
            return value
        }
        if point == .afterCommitResponseLost { throw HealthDeletionIssue.storageUnavailable }
        return value
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value)
    }
    private static func decode(_ row: [SQLValue]) throws -> HealthDeletionEntry {
        guard row.count == 9,let rawID=row[0].text,let id=UUID(uuidString:rawID),let digest=row[1].text,
              let raw=row[2].data,let phaseRaw=row[4].text,let phase=HealthDeletionPhase(rawValue:phaseRaw),
              let count=row[6].number,count >= 0,count <= Int64(Int.max) else { throw HealthDeletionIssue.invalidRequest }
        let request=try JSONDecoder().decode(WorkoutDeletionRequestV1.self,from:raw)
        guard request.requestID == id,try request.canonicalBytes() == raw,try request.selectionDigest() == digest else { throw HealthDeletionIssue.invalidRequest }
        let confirmation: WorkoutDeletionConfirmationV1?
        if row[3].isNull { confirmation=nil } else {
            guard let bytes=row[3].data else { throw HealthDeletionIssue.invalidRequest }
            let value=try JSONDecoder().decode(WorkoutDeletionConfirmationV1.self,from:bytes);try value.validate()
            guard value.requestID == id,value.selectionDigest == digest,value.confirmedAt >= request.createdAt,try Self.encoded(value) == bytes else { throw HealthDeletionIssue.invalidRequest }
            confirmation=value
        }
        let attempt: UUID?
        if row[5].isNull { attempt=nil } else {
            guard let raw=row[5].text,let value=UUID(uuidString:raw) else { throw HealthDeletionIssue.invalidRequest };attempt=value
        }
        let issue: HealthDeletionIssue?
        if row[7].isNull { issue=nil } else {
            guard let raw=row[7].text,let value=HealthDeletionIssue(rawValue:raw) else { throw HealthDeletionIssue.invalidRequest };issue=value
        }
        let receipt: WorkoutDeletionReceiptV1?
        if row[8].isNull { receipt=nil } else {
            guard let bytes=row[8].data else { throw HealthDeletionIssue.invalidRequest }
            let value=try JSONDecoder().decode(WorkoutDeletionReceiptV1.self,from:bytes)
            guard value.requestID == id,value.selectionDigest == digest,value.attemptID == attempt,
                  DeletionValidation.time(value.completedAt),value.completedAt >= request.createdAt,
                  value.completedAt >= (confirmation?.confirmedAt ?? Int64.max),try Self.encoded(value) == bytes,
                  value.deletedObjectCount >= 0,value.deletedObjectCount <= request.targets.count else { throw HealthDeletionIssue.invalidRequest }
            receipt=value
        }
        if phase == .awaitingConfirmation {
            guard confirmation == nil,attempt == nil,count == 0,receipt == nil,issue == nil else { throw HealthDeletionIssue.invalidRequest }
        } else {
            guard confirmation != nil else { throw HealthDeletionIssue.invalidRequest }
            if phase == .pending { guard attempt == nil,count == 0,receipt == nil,issue == nil else { throw HealthDeletionIssue.invalidRequest } }
            else { guard attempt != nil,count > 0 else { throw HealthDeletionIssue.invalidRequest } }
            if phase == .succeededLocally { guard receipt != nil,issue == nil else { throw HealthDeletionIssue.invalidRequest } }
            else { guard receipt == nil else { throw HealthDeletionIssue.invalidRequest } }
            if phase == .failed { guard issue != nil else { throw HealthDeletionIssue.invalidRequest } }
            if phase == .executing { guard issue == nil else { throw HealthDeletionIssue.invalidRequest } }
            if phase == .awaitingOutcome { guard issue == .outcomeUnknown else { throw HealthDeletionIssue.invalidRequest } }
            if phase == .interrupted { guard issue == .outcomeUnknown else { throw HealthDeletionIssue.invalidRequest } }
        }
        return HealthDeletionEntry(request:request,selectionDigest:digest,confirmation:confirmation,phase:phase,attemptID:attempt,attemptCount:Int(count),issue:issue,receipt:receipt)
    }
    private func find(_ id: UUID) throws -> HealthDeletionEntry? {
        try sql.rows("SELECT "+Self.columns+" FROM health_deletion_requests WHERE request_id=?",[.text(id.uuidString.lowercased())]).first.map(Self.decode)
    }
    public func entry(_ requestID: UUID) throws -> HealthDeletionEntry {
        guard let value=try find(requestID) else { throw HealthDeletionIssue.invalidRequest };return value
    }
    public func pendingRequests() throws -> [HealthDeletionEntry] {
        try sql.rows("SELECT "+Self.columns+" FROM health_deletion_requests ORDER BY request_id").map(Self.decode).filter { $0.phase != .succeededLocally }
    }
    public func submit(_ request: WorkoutDeletionRequestV1) throws -> HealthDeletionEntry {
        let raw=try request.canonicalBytes(),digest=try request.selectionDigest()
        return try write(.submit) {
            if let prior=try find(request.requestID) {
                guard prior.selectionDigest == digest,try prior.request.canonicalBytes() == raw else { throw HealthDeletionIssue.identityConflict };return prior
            }
            try sql.execute("INSERT INTO health_deletion_requests VALUES(?,?,?,NULL,'awaitingConfirmation',NULL,0,NULL,NULL)",[.text(request.requestID.uuidString.lowercased()),.text(digest),.data(raw)])
            return try entry(request.requestID)
        }
    }
    public func confirm(_ confirmation: WorkoutDeletionConfirmationV1,now: Int64) throws -> HealthDeletionEntry {
        try confirmation.validate()
        guard DeletionValidation.time(now),confirmation.confirmedAt <= now,confirmation.confirmedAt >= 0 else { throw HealthDeletionIssue.invalidRequest }
        return try write(.confirm) {
            let prior=try entry(confirmation.requestID)
            guard prior.selectionDigest == confirmation.selectionDigest else { throw HealthDeletionIssue.identityConflict }
            guard confirmation.confirmedAt >= prior.request.createdAt else { throw HealthDeletionIssue.invalidRequest }
            if let first=prior.confirmation { guard first == confirmation else { throw HealthDeletionIssue.identityConflict };return prior }
            try sql.execute("UPDATE health_deletion_requests SET confirmation=?,phase='pending' WHERE request_id=?",[.data(try Self.encoded(confirmation)),.text(confirmation.requestID.uuidString.lowercased())])
            return try entry(confirmation.requestID)
        }
    }
    public func beginAttempt(_ requestID: UUID,attemptID: UUID) throws -> HealthDeletionEntry {
        try write(.beginAttempt) {
            let prior=try entry(requestID)
            guard prior.confirmation != nil else { throw HealthDeletionIssue.unconfirmed }
            guard [.pending,.failed,.interrupted].contains(prior.phase) else { throw HealthDeletionIssue.outcomeUnknown }
            guard prior.attemptID != attemptID,prior.attemptCount < Int.max else { throw HealthDeletionIssue.identityConflict }
            try sql.execute("UPDATE health_deletion_requests SET phase='executing',attempt_id=?,attempt_count=?,issue=NULL WHERE request_id=?",[.text(attemptID.uuidString.lowercased()),.number(Int64(prior.attemptCount+1)),.text(requestID.uuidString.lowercased())])
            return try entry(requestID)
        }
    }
    private func matching(_ requestID: UUID,_ digest: String,_ attemptID: UUID) throws -> HealthDeletionEntry {
        let prior=try entry(requestID)
        guard prior.selectionDigest == digest,prior.attemptID == attemptID else { throw HealthDeletionIssue.identityConflict };return prior
    }
    public func markAwaitingOutcome(_ requestID: UUID,digest: String,attemptID: UUID) throws {
        try write(.awaitingOutcome) {
            let prior=try matching(requestID,digest,attemptID)
            if prior.phase == .succeededLocally || prior.phase == .failed { return }
            guard prior.phase == .executing || prior.phase == .awaitingOutcome else { throw HealthDeletionIssue.outcomeUnknown }
            try sql.execute("UPDATE health_deletion_requests SET phase='awaitingOutcome',issue='outcomeUnknown' WHERE request_id=?",[.text(requestID.uuidString.lowercased())])
        }
    }
    public func finish(_ requestID: UUID,digest: String,attemptID: UUID,outcome: HealthDeletionDriverOutcome,now: Int64) throws {
        guard DeletionValidation.time(now) else { throw HealthDeletionIssue.invalidResponse }
        try write(.finish) {
            let prior=try matching(requestID,digest,attemptID)
            // A duplicate callback can only observe the first terminal result of this attempt.
            if prior.phase == .succeededLocally || prior.phase == .failed { return }
            guard prior.phase == .executing || prior.phase == .awaitingOutcome else { throw HealthDeletionIssue.outcomeUnknown }
            guard now >= prior.request.createdAt,let confirmedAt=prior.confirmation?.confirmedAt,now >= confirmedAt else { throw HealthDeletionIssue.invalidResponse }
            switch outcome {
            case .success(let count) where count >= 0 && count <= prior.request.targets.count:
                let receipt=WorkoutDeletionReceiptV1(requestID:requestID,selectionDigest:digest,attemptID:attemptID,completedAt:now,deletedObjectCount:count)
                try sql.execute("UPDATE health_deletion_requests SET phase='succeededLocally',issue=NULL,receipt=? WHERE request_id=?",[.data(try Self.encoded(receipt)),.text(requestID.uuidString.lowercased())])
            default:
                let issue: HealthDeletionIssue
                if case .failure(let value)=outcome { issue=value } else { issue = .invalidResponse }
                try sql.execute("UPDATE health_deletion_requests SET phase='failed',issue=? WHERE request_id=?",[.text(issue.rawValue),.text(requestID.uuidString.lowercased())])
            }
        }
    }
}
