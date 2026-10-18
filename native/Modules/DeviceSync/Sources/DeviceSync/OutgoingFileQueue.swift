import Foundation

struct OutgoingRecord: Codable, Sendable {
    let deliveryID, checksum, token: String
    let byteCount: Int
}
/// Outgoing SDK input is separate from the inbox; only a matching native completion
/// releases it. Stable IDs coalesce retries across processes using outstanding metadata.
enum OutgoingQueueFault { case afterRecordRemoval }
final class OutgoingFileQueue: @unchecked Sendable {
    let directory: URL
    let lock = NSLock()
    let storage: DeviceSyncStorageContext
    func critical<T>(_ body: () throws -> T) throws -> T { try storage.withActive { try lock.withLock(body) } }
    let limits: InboxLimits
    let fault: OutgoingQueueFault?
    init(directory: URL, limits: InboxLimits? = nil, fault: OutgoingQueueFault? = nil) throws {
        self.fault = fault
        self.directory = directory.standardizedFileURL; self.limits = try limits ?? InboxLimits()
        storage = try DeviceSyncStorageContext.component(directory, role: "outbox")
        do { try storage.withActive {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw DeviceSyncError.fileIO }
        } } catch { throw error }
    }
    func key(_ id: String) throws -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 4096 else { throw DeviceSyncError.invalidFrame }
        return digest(Data(id.utf8))
    }
    func urls(_ id: String) throws -> (URL, URL) { let k = try key(id); return (directory.appendingPathComponent(k + ".json"), directory.appendingPathComponent(k + ".frame")) }
    func load(_ id: String) throws -> OutgoingRecord? {
        let (metadata, file) = try urls(id)
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            // A crash between payload and record leaves data that can only be reclaimed by
            // the same original request after exact verification in stage().
            return nil
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: metadata.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 8192 else { throw DeviceSyncError.corruptFile }
        let raw = try Data(contentsOf: metadata), saved = try JSONDecoder().decode(OutgoingRecord.self, from: raw)
        guard raw == (try canonical(saved)), Data(saved.deliveryID.utf8) == Data(id.utf8), isDigest(saved.checksum), UUID(uuidString: saved.token) != nil, saved.byteCount > 0, saved.byteCount <= limits.maximumFrameBytes else { throw DeviceSyncError.corruptFile }
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard fileAttrs[.type] as? FileAttributeType == .typeRegular, (fileAttrs[.size] as? NSNumber)?.intValue == saved.byteCount else { throw DeviceSyncError.corruptFile }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limits.maximumFrameBytes + 1) ?? Data()
        guard bytes.count == saved.byteCount, digest(bytes) == saved.checksum else { throw DeviceSyncError.corruptFile }
        return saved
    }
    func existing(_ id: String, bytes: Data) throws -> DriverFileTransfer? {
        try critical {
            guard let saved = try load(id) else { return nil }
            guard saved.checksum == digest(bytes), saved.byteCount == bytes.count else { throw DeviceSyncError.conflictingDelivery }
            return DriverFileTransfer(deliveryID: id, checksum: saved.checksum, token: saved.token, url: try urls(id).1)
        }
    }
    func stage(_ bytes: Data, id: String) throws -> DriverFileTransfer {
        try critical {
            guard !bytes.isEmpty, bytes.count <= limits.maximumFrameBytes else { throw DeviceSyncError.quotaExceeded }
            let (metadata, file) = try urls(id), checksum = digest(bytes)
            if let saved = try load(id) { guard saved.checksum == checksum, saved.byteCount == bytes.count else { throw DeviceSyncError.conflictingDelivery } }
            else if FileManager.default.fileExists(atPath: file.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue == bytes.count,
                      try Data(contentsOf: file) == bytes else { throw DeviceSyncError.corruptFile }
            } else {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "frame" }
                let used = try files.reduce(0) { sum, url in
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= Int64(limits.maximumBytes) else { throw DeviceSyncError.corruptFile }
                    guard sum <= limits.maximumBytes - size.intValue else { throw DeviceSyncError.quotaExceeded }; return sum + size.intValue
                }
                guard files.count < limits.maximumFrames, bytes.count <= limits.maximumBytes, used <= limits.maximumBytes - bytes.count else { throw DeviceSyncError.quotaExceeded }
                try bytes.write(to: file, options: .atomic)
                let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
            }
            let record = OutgoingRecord(deliveryID: id, checksum: checksum, token: UUID().uuidString, byteCount: bytes.count)
            try canonical(record).write(to: metadata, options: .atomic)
            return DriverFileTransfer(deliveryID: id, checksum: checksum, token: record.token, url: file)
        }
    }
    func recoverOrphans(outstanding: [DriverFileTransfer]) throws {
        try critical {
            let retained = try Set(outstanding.map { try key($0.deliveryID) })
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "frame" {
                let key = file.deletingPathExtension().lastPathComponent
                guard isDigest(key), !retained.contains(key) else { continue }
                let metadata = file.deletingPathExtension().appendingPathExtension("json")
                if !FileManager.default.fileExists(atPath: metadata.path) {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular else { throw DeviceSyncError.corruptFile }
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }
    func completed(_ transfer: DriverFileTransfer) throws {
        try critical {
            let (metadata, file) = try urls(transfer.deliveryID)
            guard let saved = try load(transfer.deliveryID) else { return }
            guard saved.token == transfer.token else { return } // late completion from an older attempt
            guard saved.checksum == transfer.checksum else { throw DeviceSyncError.conflictingDelivery }
            // Make the record unreachable first. A crash can leave reclaimable raw data,
            // never a live record whose payload was already deleted.
            try FileManager.default.removeItem(at: metadata)
            if fault == .afterRecordRemoval { throw DeviceSyncError.fileIO }
            try FileManager.default.removeItem(at: file)
        }
    }
}
