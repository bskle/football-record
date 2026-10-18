import Foundation

private struct PairingState: Codable { let fingerprint: String; let invalidated: Bool }
private struct PairingEnvelope: Codable { let state: PairingState; let checksum: String }
/// Persists only a digest of observable SDK state, never an account or device authority.
/// Once invalidated, the M3 adapter stays paused; activation cannot establish a new pair.
final class PairingBaseline: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private let storage: DeviceSyncStorageContext
    private var state: PairingState?
    var isInvalidated: Bool { (try? storage.withActive { lock.withLock { state?.invalidated ?? false } }) ?? true }
    init(directory: URL) throws {
        self.directory = directory
        storage = try DeviceSyncStorageContext.component(directory, role: "state")
        do { try storage.withActive {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw DeviceSyncError.fileIO }
            let url = directory.appendingPathComponent("pairing-baseline.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 2048 else { throw DeviceSyncError.corruptFile }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let raw = try handle.read(upToCount: 2049) ?? Data()
                guard raw.count == size.intValue else { throw DeviceSyncError.corruptFile }
                let saved = try JSONDecoder().decode(PairingEnvelope.self, from: raw)
                guard raw == (try canonical(saved)), isDigest(saved.state.fingerprint), saved.checksum == digest(try canonical(saved.state)) else { throw DeviceSyncError.corruptFile }
                state = saved.state
            }
        } } catch let error as DeviceSyncError { throw error }
        catch { throw DeviceSyncError.corruptFile }
    }
    @discardableResult func observe(_ fingerprint: String) throws -> Bool {
        try storage.withActive { try lock.withLock {
            let hash = digest(Data(fingerprint.utf8))
            if let state, state.invalidated { return true }
            if state?.fingerprint == hash { return false }
            let changed = state != nil, updated = PairingState(fingerprint: state?.fingerprint ?? hash, invalidated: changed)
            do {
                let envelope = PairingEnvelope(state: updated, checksum: digest(try canonical(updated))), url = directory.appendingPathComponent("pairing-baseline.json")
                try canonical(envelope).write(to: url, options: .atomic)
                let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
                state = updated; return changed
            } catch {
                state = PairingState(fingerprint: updated.fingerprint, invalidated: true)
                throw DeviceSyncError.fileIO
            }
        } }
    }
    static func validate(_ raw: Data) throws {
        let saved = try JSONDecoder().decode(PairingEnvelope.self, from: raw)
        guard raw.count <= 2048, raw == (try canonical(saved)), isDigest(saved.state.fingerprint), saved.checksum == digest(try canonical(saved.state)) else { throw DeviceSyncErasureError.unknownInventory }
    }
}
