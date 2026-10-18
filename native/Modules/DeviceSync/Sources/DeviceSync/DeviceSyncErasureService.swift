import Foundation

public struct DeviceSyncErasureService: DeviceSyncLocalTransportErasing {
    let context: DeviceSyncStorageContext
    let driver: any DeviceSyncErasureDriving
    let fault: DeviceSyncErasureFault?
    public init(context: DeviceSyncStorageContext, driver: any DeviceSyncErasureDriving = UnavailableDeviceSyncErasureDriver()) { self.context = context; self.driver = driver; fault = nil }
    init(context: DeviceSyncStorageContext, driver: any DeviceSyncErasureDriving, fault: DeviceSyncErasureFault?) { self.context = context; self.driver = driver; self.fault = fault }
    public func erase(_ request: DeviceSyncLocalEraseRequest) async throws -> DeviceSyncEraseResult {
        try request.validate()
        let prepared: (DeviceSyncLocalEraseReceipt?, [DeviceSyncTransferIdentity]) = try context.withLocked {
            guard context.managed, request.binding.rootIdentity == context.rootIdentity else { throw DeviceSyncErasureError.intentMismatch }
            let state = try context.ledger.state()
            guard state.owner == request.binding else { throw DeviceSyncErasureError.intentMismatch }
            if let previous = state.request { guard previous == request else { throw DeviceSyncErasureError.intentMismatch } }
            if let receipt = state.receipt { return (receipt, state.transfers) }
            let inventory = try inventory()
            if state.request == nil { try context.ledger.begin(request, transfers: inventory.transfers, fault: fault) }
            return (nil, try context.ledger.state().transfers)
        }
        if let receipt = prepared.0 { return .completed(receipt) }
        let drain = try await driver.quiesceForErasure(request, expected: prepared.1)
        guard drain == .drained else { return .pending(drain) }
        return try context.withFenced(request) {
            if let receipt = try context.ledger.state().receipt { return .completed(receipt) }
            let files = try inventory().files
            for (index, file) in files.enumerated() {
                try FileManager.default.removeItem(at: file)
                try context.synchronize(file.deletingLastPathComponent())
                if fault == .afterUnlink(index + 1) { throw DeviceSyncErasureError.faultInjected }
            }
            guard try inventory().files.isEmpty else { throw DeviceSyncErasureError.unknownInventory }
            return .completed(try context.ledger.complete(request, fault: fault))
        }
    }
    private func inventory() throws -> (files: [URL], transfers: [DeviceSyncTransferIdentity]) {
        var files: [URL] = [], transfers: [DeviceSyncTransferIdentity] = []
        for entry in try FileManager.default.contentsOfDirectory(at: context.root, includingPropertiesForKeys: nil) {
            guard [".control", "inbox", "outbox", "state"].contains(entry.lastPathComponent) else { throw DeviceSyncErasureError.unknownInventory }
            _ = try DeviceSyncStorageContext.identity(entry, directory: true)
            if entry.lastPathComponent == ".control" {
                for control in try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    guard [".owner", "control.sqlite", "control.sqlite-journal", "control.sqlite-wal", "control.sqlite-shm"].contains(control.lastPathComponent) else { throw DeviceSyncErasureError.unknownInventory }
                    _ = try DeviceSyncStorageContext.identity(control, directory: false)
                }
                continue
            }
            let entries = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
            for file in entries {
                let raw = try DeviceSyncStorageContext.readRegular(file, limit: file.pathExtension == "frame" ? DeviceSyncPolicy.maximumFrameBytes : 8192)
                switch entry.lastPathComponent {
                case "inbox":
                    if file.lastPathComponent == "last-error.json" {
                        let value = try JSONDecoder().decode(InboxFailure.self, from: raw)
                        guard try canonical(value) == raw else { throw DeviceSyncErasureError.unknownInventory }
                    } else {
                        guard file.pathExtension == "frame", file.deletingPathExtension().lastPathComponent == "frame-" + digest(raw) else { throw DeviceSyncErasureError.unknownInventory }
                    }
                case "outbox":
                    let key = file.deletingPathExtension().lastPathComponent
                    guard isDigest(key), ["frame", "json"].contains(file.pathExtension) else { throw DeviceSyncErasureError.unknownInventory }
                    if file.pathExtension == "json" {
                        let saved = try JSONDecoder().decode(OutgoingRecord.self, from: raw)
                        guard try canonical(saved) == raw, validOpaqueID(saved.deliveryID), key == digest(Data(saved.deliveryID.utf8)), saved.byteCount > 0, saved.byteCount <= DeviceSyncPolicy.maximumFrameBytes else { throw DeviceSyncErasureError.unknownInventory }
                        let bytes = try DeviceSyncStorageContext.readRegular(file.deletingPathExtension().appendingPathExtension("frame"), limit: DeviceSyncPolicy.maximumFrameBytes)
                        guard bytes.count == saved.byteCount, digest(bytes) == saved.checksum else { throw DeviceSyncErasureError.unknownInventory }
                        transfers.append(try DeviceSyncTransferIdentity(deliveryIDHash: key, checksum: saved.checksum, token: saved.token))
                    }
                case "state":
                    guard file.lastPathComponent == "pairing-baseline.json" else { throw DeviceSyncErasureError.unknownInventory }
                    try PairingBaseline.validate(raw)
                default: throw DeviceSyncErasureError.unknownInventory
                }
                files.append(file)
            }
        }
        // Metadata first leaves a verified owned orphan payload if unlink is interrupted.
        return (files.sorted { left, right in
            let lp = left.deletingLastPathComponent().lastPathComponent == "outbox" && left.pathExtension == "json" ? 0 : 1
            let rp = right.deletingLastPathComponent().lastPathComponent == "outbox" && right.pathExtension == "json" ? 0 : 1
            return lp != rp ? lp < rp : left.path.utf8.lexicographicallyPrecedes(right.path.utf8)
        }, transfers.sorted { $0.token < $1.token })
    }
}
