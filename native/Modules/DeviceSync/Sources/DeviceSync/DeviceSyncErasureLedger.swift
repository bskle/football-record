import Foundation
import CSQLite

private struct DeviceSyncControlIntent: Codable {
    let request: DeviceSyncLocalEraseRequest
    let transfers: [DeviceSyncTransferIdentity]
}
struct DeviceSyncControlState {
    let transfers: [DeviceSyncTransferIdentity]
    let owner: DeviceSyncNamespaceBinding?
    let request: DeviceSyncLocalEraseRequest?
    let receipt: DeviceSyncLocalEraseReceipt?
}
/// All access is serialized by the retained storage owner lock, including other processes.
final class DeviceSyncErasureLedger: @unchecked Sendable {
    private var db: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if db != nil { sqlite3_close(db) }; throw DeviceSyncErasureError.corruptControl }
        do {
            sqlite3_busy_timeout(db, 5000)
            guard try textQuery("PRAGMA quick_check") == ["ok"] else { throw DeviceSyncErasureError.corruptControl }
            let version = try integerQuery("PRAGMA user_version")
            guard version <= 1 else { throw DeviceSyncErasureError.futureControl }
            if version == 0 {
                guard try textQuery("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw DeviceSyncErasureError.corruptControl }
                try transaction {
                    try exec("CREATE TABLE control(id INTEGER PRIMARY KEY CHECK(id=1), owner BLOB, request BLOB, receipt BLOB)")
                    try exec("INSERT INTO control(id) VALUES(1)")
                    try exec("PRAGMA user_version=1")
                    try validateStructure()
                }
            } else { try validateStructure() }
            try exec("PRAGMA synchronous=FULL")
            _ = try state()
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func validateStructure() throws {
        guard try textQuery("SELECT name FROM sqlite_master WHERE type='table'") == ["control"], try textQuery("SELECT name FROM pragma_table_info('control')") == ["id", "owner", "request", "receipt"], try integerQuery("SELECT count(*) FROM control") == 1 else { throw DeviceSyncErasureError.corruptControl }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw DeviceSyncErasureError.corruptControl }
        return value
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DeviceSyncErasureError.corruptControl } }
    private func textQuery(_ sql: String) throws -> [String] {
        let s = try statement(sql); defer { sqlite3_finalize(s) }; var result: [String] = []
        while true {
            let code = sqlite3_step(s); if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_TEXT, let ptr = sqlite3_column_text(s, 0), let value = String(data: Data(bytes: ptr, count: Int(sqlite3_column_bytes(s, 0))), encoding: .utf8), !value.utf8.contains(0) else { throw DeviceSyncErasureError.corruptControl }
            result.append(value)
        }
    }
    private func integerQuery(_ sql: String) throws -> Int64 {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_INTEGER else { throw DeviceSyncErasureError.corruptControl }
        let v = sqlite3_column_int64(s, 0); guard sqlite3_step(s) == SQLITE_DONE else { throw DeviceSyncErasureError.corruptControl }; return v
    }
    private func decode<T: Codable>(_ type: T.Type, from s: OpaquePointer, column: Int32) throws -> T? {
        if sqlite3_column_type(s, column) == SQLITE_NULL { return nil }
        let n = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_BLOB, n > 0, n <= 65536, let p = sqlite3_column_blob(s, column) else { throw DeviceSyncErasureError.corruptControl }
        let raw = Data(bytes: p, count: n)
        do { let value = try JSONDecoder().decode(type, from: raw); guard try canonical(value) == raw else { throw DeviceSyncErasureError.corruptControl }; return value } catch { throw DeviceSyncErasureError.corruptControl }
    }
    func state() throws -> DeviceSyncControlState {
        let version = try integerQuery("PRAGMA user_version")
        guard version == 1 else { throw version > 1 ? DeviceSyncErasureError.futureControl : DeviceSyncErasureError.corruptControl }
        try validateStructure()
        let s = try statement("SELECT owner,request,receipt FROM control WHERE id=1"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw DeviceSyncErasureError.corruptControl }
        let owner = try decode(DeviceSyncNamespaceBinding.self, from: s, column: 0), intent = try decode(DeviceSyncControlIntent.self, from: s, column: 1), receipt = try decode(DeviceSyncLocalEraseReceipt.self, from: s, column: 2)
        let request = intent?.request
        for transfer in intent?.transfers ?? [] { _ = try DeviceSyncTransferIdentity(deliveryIDHash: transfer.deliveryIDHash, checksum: transfer.checksum, token: transfer.token) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw DeviceSyncErasureError.corruptControl }
        do { try owner?.validate(); try request?.validate() } catch { throw DeviceSyncErasureError.corruptControl }
        if let request { guard owner == request.binding else { throw DeviceSyncErasureError.corruptControl } }
        if let receipt { guard let request, receipt.request == request, receipt.fenceGeneration == 1, receipt.intentDigest == (try request.intentDigest) else { throw DeviceSyncErasureError.corruptControl } }
        return DeviceSyncControlState(transfers: intent?.transfers ?? [], owner: owner, request: request, receipt: receipt)
    }
    private func set<T: Encodable>(_ column: String, _ value: T) throws {
        let raw = try canonical(value), s = try statement("UPDATE control SET \(column)=? WHERE id=1"); defer { sqlite3_finalize(s) }
        let code = raw.withUnsafeBytes { sqlite3_bind_blob(s, 1, $0.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard code == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw DeviceSyncErasureError.corruptControl }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result } catch { try? exec("ROLLBACK"); throw error }
    }
    func bind(_ owner: DeviceSyncNamespaceBinding) throws { try transaction { try set("owner", owner) } }
    func begin(_ request: DeviceSyncLocalEraseRequest, transfers: [DeviceSyncTransferIdentity], fault: DeviceSyncErasureFault?) throws {
        try transaction { try set("request", DeviceSyncControlIntent(request: request, transfers: transfers)); if fault == .beforeFenceCommit { throw DeviceSyncErasureError.faultInjected } }
        if fault == .afterFenceCommit { throw DeviceSyncErasureError.faultInjected }
    }
    func complete(_ request: DeviceSyncLocalEraseRequest, fault: DeviceSyncErasureFault?) throws -> DeviceSyncLocalEraseReceipt {
        let value = DeviceSyncLocalEraseReceipt(request: request, intentDigest: try request.intentDigest, fenceGeneration: 1)
        try transaction { try set("receipt", value); if fault == .beforeReceiptCommit { throw DeviceSyncErasureError.faultInjected } }
        if fault == .afterReceiptCommit { throw DeviceSyncErasureError.faultInjected }
        return value
    }
}
