import Foundation
import MatchSync

public struct InboxScan: Sendable {
    public let frames: [SyncDelivery]
    public let failures: [InboxFailure]
}
/// Synchronous entry is deliberate: the SDK deletes its temporary file on delegate return.
/// One lock protects file inventory, quota, atomic adoption and Store persistence release.
public final class DurableFileInbox: @unchecked Sendable {
    public let directory: URL
    let limits: InboxLimits
    let lock = NSLock()
    let storage: DeviceSyncStorageContext
    func critical<T>(_ body: () throws -> T) throws -> T { try storage.withActive { try lock.withLock(body) } }
    public init(directory: URL, limits: InboxLimits? = nil) throws {
        self.directory = directory.standardizedFileURL; self.limits = try limits ?? InboxLimits()
        storage = try DeviceSyncStorageContext.component(directory, role: "inbox")
        do { try storage.withActive {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw DeviceSyncError.fileIO }
        } } catch { throw error }
    }
    func frameURL(_ id: String) throws -> URL {
        guard id.hasPrefix("frame-"), isDigest(String(id.dropFirst(6))) else { throw DeviceSyncError.invalidFrame }
        return directory.appendingPathComponent(id + ".frame")
    }
    func inventory() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "frame" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func size(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, let n = attrs[.size] as? NSNumber, n.int64Value > 0 else { throw DeviceSyncError.corruptFile }
        guard n.int64Value <= Int64(limits.maximumFrameBytes) else { throw DeviceSyncError.quotaExceeded }
        return n.intValue
    }
    /// Stat first, then a bounded read even if the file changes between those operations.
    func read(_ url: URL) throws -> Data {
        let expected = try size(url), handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let raw = try handle.read(upToCount: limits.maximumFrameBytes + 1) ?? Data()
        guard raw.count <= limits.maximumFrameBytes else { throw DeviceSyncError.quotaExceeded }
        guard raw.count == expected, (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw DeviceSyncError.corruptFile }
        return raw
    }
    func verified(_ url: URL) throws -> SyncDelivery {
        let id = url.deletingPathExtension().lastPathComponent, raw = try read(url)
        guard try frameURL(id) == url.standardizedFileURL, id == "frame-" + digest(raw) else { throw DeviceSyncError.corruptFile }
        return try SyncDelivery(bytes: raw, transportDeliveryID: id)
    }
    func audit(_ error: DeviceSyncError, id: String) {
        // Bounded last-error metadata, never interpreted as a receipt or ACK.
        try? canonical(InboxFailure(transportDeliveryID: String(id.prefix(128)), issue: error)).write(to: directory.appendingPathComponent("last-error.json"), options: .atomic)
    }
    public func adoptFile(_ source: URL) throws -> SyncDelivery {
        do { return try storage.withActive { try adoptData(read(source)) } }
        catch let error as DeviceSyncError { try? critical { audit(error, id: source.lastPathComponent) }; throw error }
        catch { try? critical { audit(.fileIO, id: source.lastPathComponent) }; throw DeviceSyncError.fileIO }
    }
    public func adoptData(_ bytes: Data) throws -> SyncDelivery {
        try critical {
            guard !bytes.isEmpty, bytes.count <= limits.maximumFrameBytes else { audit(.quotaExceeded, id: "incoming"); throw DeviceSyncError.quotaExceeded }
            let id = "frame-" + digest(bytes)
            do {
                let target = try frameURL(id)
                if FileManager.default.fileExists(atPath: target.path) {
                    let old = try verified(target); guard old.bytes == bytes else { throw DeviceSyncError.conflictingDelivery }; return old
                }
                let files = try inventory(), used = try files.reduce(0) { try $0 + size($1) }
                guard files.count < limits.maximumFrames, bytes.count <= limits.maximumBytes, used <= limits.maximumBytes - bytes.count else { throw DeviceSyncError.quotaExceeded }
                try bytes.write(to: target, options: .atomic)
                let handle = try FileHandle(forWritingTo: target); try handle.synchronize(); try handle.close()
                return try verified(target)
            } catch let error as DeviceSyncError { audit(error, id: id); throw error }
            catch { audit(.fileIO, id: id); throw DeviceSyncError.fileIO }
        }
    }
    public func scan() -> InboxScan {
        (try? critical {
            var frames: [SyncDelivery] = [], failures: [InboxFailure] = [], used = 0
            do {
                for file in try inventory() {
                    let id = file.deletingPathExtension().lastPathComponent
                    do {
                        let n = try size(file)
                        guard frames.count < limits.maximumFrames, n <= limits.maximumBytes, used <= limits.maximumBytes - n else { throw DeviceSyncError.quotaExceeded }
                        let frame = try verified(file); used += n; frames.append(frame)
                    } catch {
                        let issue = error as? DeviceSyncError ?? .fileIO
                        failures.append(InboxFailure(transportDeliveryID: id, issue: issue)); audit(issue, id: id)
                    }
                }
            } catch { failures.append(InboxFailure(transportDeliveryID: "inbox", issue: .fileIO)); audit(.fileIO, id: "inbox") }
            return InboxScan(frames: frames, failures: failures)
        }) ?? InboxScan(frames: [], failures: [InboxFailure(transportDeliveryID: "inbox", issue: .erased)])
    }
    /// Only SyncTransport.didPersistDelivery calls this for committed application fragments.
    public func didPersist(_ transportDeliveryID: String) throws {
        try critical {
            let url = try frameURL(transportDeliveryID)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do { _ = try verified(url); try FileManager.default.removeItem(at: url) }
            catch let error as DeviceSyncError { audit(error, id: transportDeliveryID); throw error }
            catch { audit(.fileIO, id: transportDeliveryID); throw DeviceSyncError.fileIO }
        }
    }
}
