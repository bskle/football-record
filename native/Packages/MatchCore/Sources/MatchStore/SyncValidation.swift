import Foundation
import MatchCore

extension MatchStore {
    func validateSyncPeer(_ peer: PeerAuthorization, now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= peer.issuedAt, now < peer.expiresAt,
              peer.environment == syncEnvironment else { throw StoreError.invalidPeerAuthorization }
        guard case .development = syncEnvironment else { throw StoreError.trustUnavailable }
    }

    /// Full raw facts, including tombstones. Legacy receive intentionally keeps its looser semantics.
    func validateSyncSnapshot(_ packet: MatchPacketV2, peer: PeerAuthorization) throws {
        try packet.validate()
        let b = packet.body, d = b.descriptor, pair = Set([peer.localDeviceID, peer.remoteDeviceID])
        for id in [d.startIntent.id, d.matchID, d.recordingDeviceID] { try SyncWire.id(id) }
        guard d.startIntent.requestedAt.timeIntervalSinceReferenceDate.isFinite,
              pair.contains(d.recordingDeviceID), d.backendLockState == .unknown || d.backendLockState == .held,
              d.startPermit == DevelopmentStartFixture.permit(for: d.startIntent),
              b.events.allSatisfy({ pair.contains($0.sourceDeviceID) && $0.matchID == d.matchID }) else { throw StoreError.invalidPacket }
        try validatePeerSnapshotFactsV4(packet,pair:pair)
    }

    func validatePeerSnapshotFactsV4(_ packet:MatchPacketV2,pair:Set<String>)throws {
        try packet.validate();let b=packet.body,d=b.descriptor
        guard b.events.allSatisfy({pair.contains($0.sourceDeviceID) && $0.matchID==d.matchID}) else {throw StoreError.invalidPacket}
        for event in b.events {
            try SyncWire.id(event.eventID); try SyncWire.id(event.sourceDeviceID)
            if let parent = event.correctionOfEventID { try SyncWire.id(parent) }
            if let termination = event.terminationID { try SyncWire.id(termination) }
        }
        let ids = Set(b.events.map(\.eventID))
        guard b.events.allSatisfy({ $0.correctionOfEventID.map(ids.contains) ?? true }) else { throw StoreError.ancestryIncomplete }
        let invalid: Set<DiagnosticCode> = [.invalidEvent, .invalidRevision, .unauthorizedWriter, .conflictingEventID, .duplicateSequence, .duplicateTermination]
        let dates = [d.startIntent.requestedAt] + b.events.flatMap { [$0.occurredAt, $0.createdAt, $0.updatedAt] }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw StoreError.invalidPacket }
        // Structural validation uses the finite fact horizon, never a peer's wall clock or CAS.
        let horizon = dates.max() ?? d.startIntent.requestedAt
        guard !MatchReplay.replay(descriptor: d, events: b.events, now: horizon).diagnostics.contains(where: { invalid.contains($0.code) }) else { throw StoreError.invalidPacket }
        for (index, revision) in b.captureRevisions.enumerated() {
            guard revision.binding.matchID == d.matchID, revision.binding.recordingDeviceID == d.recordingDeviceID,
                  revision.revision == Int64(index) + 1,
                  revision.parentID == (index == 0 ? nil : b.captureRevisions[index - 1].id) else { throw StoreError.invalidCaptureRevision }
        }
    }

    /// The original payload never becomes a proof source. A current local proof is checked locally.
    func acceptedSyncProjection(_ incoming: MatchDescriptor, current: StoreSnapshot?, now: Date) throws -> MatchDescriptor {
        guard let current else { return incoming }
        let d = current.descriptor
        guard d.startIntent == incoming.startIntent, d.starter == incoming.starter else { throw StoreError.descriptorConflict }
        guard d.startPermit == nil || d.startPermit == DevelopmentStartFixture.permit(for: d.startIntent) else { throw StoreError.trustUnavailable }
        if d.backendLockState == .releaseRequested || d.backendLockState == .releasedConfirmed {
            // M4 has not supplied a server release-proof verifier. Preserve the projection,
            // refuse the receive, and never use completionEvidence as a lock-release proof.
            throw StoreError.trustUnavailable
        }
        guard d.backendLockState == .unknown || d.backendLockState == .held else { throw StoreError.trustUnavailable }
        return MatchDescriptor(startIntent: d.startIntent, starter: d.starter, startPermit: d.startPermit ?? incoming.startPermit,
            backendLockState: d.backendLockState == .held ? .held : incoming.backendLockState)
    }

    func verifySyncProjection(_ accepted: MatchDescriptor, current: StoreSnapshot, now: Date) throws {
        let checked = try acceptedSyncProjection(accepted, current: current, now: now)
        guard checked == current.descriptor, accepted.startPermit == nil || accepted.startPermit == current.descriptor.startPermit,
              accepted.backendLockState != .held || current.descriptor.backendLockState != .unknown else {
            throw StoreError.descriptorConflict
        }
    }
}
