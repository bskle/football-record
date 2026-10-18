import CryptoKit
import Foundation
import MatchCore

public enum CloudIssue: String, Codable, Sendable {
    case identityConflict, invalidPayload, payloadTooLarge, unsupportedSchema, storageUnavailable, closed
    case awaitingBusinessImport, cursorMismatch, staleGeneration, conflict, partialSave, quotaExceeded
    case networkUnavailable, accountUnavailable, permissionDenied, accountChanged, changeTokenExpired, unknown
}
public struct CloudError: Error, Sendable, Equatable {
    public let issue: CloudIssue
    public init(_ issue: CloudIssue) { self.issue = issue }
}

enum CloudCodec {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumEnvelopeBytes = 64 * 1024 * 1024
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decode<T: Codable>(_ type: T.Type, _ bytes: Data, limit: Int = maximumEnvelopeBytes) throws -> T {
        guard bytes.count <= limit else { throw CloudError(.payloadTooLarge) }
        do {
            let value = try JSONDecoder().decode(type, from: bytes)
            guard try encode(value) == bytes else { throw CloudError(.invalidPayload) }
            return value
        } catch let error as CloudError { throw error } catch { throw CloudError(.invalidPayload) }
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func hash<T: Encodable>(_ value: T, domain: String) throws -> String {
        hash(Data(("football-record.cloud." + domain + ".v1\0").utf8) + (try encode(value)))
    }
    static func id(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 512, !value.contains("\0"), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError(.invalidPayload) }
    }
    static func milliseconds(_ value: Date) throws -> Int64 {
        let number = value.timeIntervalSince1970 * 1000
        guard number.isFinite, number > Double(Int64.min), number < Double(Int64.max) else { throw CloudError(.invalidPayload) }
        return Int64(number)
    }
    static func date(_ value: Date) throws { _ = try milliseconds(value) }
}

public struct CloudScope: Codable, Sendable, Equatable, Hashable {
    public let accountID, cloudSpaceID, zoneID: String
    public let activationEpoch: Int64
    public init(accountID: String, cloudSpaceID: String, zoneID: String, activationEpoch: Int64) throws {
        for id in [accountID, cloudSpaceID, zoneID] { try CloudCodec.id(id) }
        guard activationEpoch > 0 else { throw CloudError(.invalidPayload) }
        self.accountID = accountID; self.cloudSpaceID = cloudSpaceID; self.zoneID = zoneID; self.activationEpoch = activationEpoch
    }
    public var stableZoneKey: String { CloudCodec.hash(Data((accountID + "\0" + cloudSpaceID + "\0" + zoneID).utf8)) }
    var key: String { get throws { try CloudCodec.hash(self, domain: "scope") } }
    private enum CodingKeys: String, CodingKey { case accountID, cloudSpaceID, zoneID, activationEpoch }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountID: c.decode(String.self, forKey: .accountID), cloudSpaceID: c.decode(String.self, forKey: .cloudSpaceID), zoneID: c.decode(String.self, forKey: .zoneID), activationEpoch: c.decode(Int64.self, forKey: .activationEpoch))
    }
}

/// Full non-health facts. Corrections and deleted revisions remain in this immutable set.
public struct CloudMatchFacts: Codable, Sendable, Equatable {
    public let startIntent: StartIntent
    public let starter: Bool
    public let events: [MatchEvent]
    public let captureRevisions: [CaptureRevision]
    public var matchID: String { startIntent.matchID }
    public var captureDigest: String { get throws { try CaptureRevision.digest(captureRevisions) } }
    public var factDigest: String { get throws { try CloudCodec.hash(self, domain: "facts") } }
    public init(startIntent: StartIntent, starter: Bool, events: [MatchEvent], captureRevisions: [CaptureRevision]) throws {
        for id in [startIntent.id, startIntent.matchID, startIntent.recordingDeviceID] { try CloudCodec.id(id) }
        try CloudCodec.date(startIntent.requestedAt)
        let sorted = events.sorted { $0.eventID < $1.eventID }
        guard Set(events.map(\.eventID)).count == events.count else { throw CloudError(.invalidPayload) }
        let ids = Set(events.map(\.eventID))
        for event in events {
            for id in [event.eventID, event.sourceDeviceID] { try CloudCodec.id(id) }
            for date in [event.occurredAt, event.createdAt, event.updatedAt] { try CloudCodec.date(date) }
            guard event.matchID == startIntent.matchID, event.sequence > 0,
                  event.matchElapsed.map({ $0.isFinite && $0 >= 0 }) != false,
                  event.correctionOfEventID.map(ids.contains) != false else { throw CloudError(.invalidPayload) }
        }
        let captures = captureRevisions.sorted { ($0.revision, $0.id) < ($1.revision, $1.id) }
        guard Set(captures.map(\.id)).count == captures.count else { throw CloudError(.invalidPayload) }
        for (i, revision) in captures.enumerated() {
            guard revision.binding.matchID == startIntent.matchID, revision.binding.recordingDeviceID == startIntent.recordingDeviceID,
                  revision.revision == Int64(i) + 1, revision.parentID == (i == 0 ? nil : captures[i-1].id) else { throw CloudError(.invalidPayload) }
        }
        // Scratch replay validates structure only; this permit never enters the payload, ledger or authority.
        let descriptor = MatchDescriptor(startIntent: startIntent, starter: starter, startPermit: DevelopmentStartFixture.permit(for: startIntent))
        let invalid: Set<DiagnosticCode> = [.invalidEvent, .invalidRevision, .unauthorizedWriter, .conflictingEventID, .duplicateSequence, .duplicateTermination]
        let horizon = ([startIntent.requestedAt] + events.map(\.updatedAt) + events.map(\.occurredAt)).max() ?? startIntent.requestedAt
        guard !MatchReplay.replay(descriptor: descriptor, events: events, now: horizon).diagnostics.contains(where: { invalid.contains($0.code) }) else { throw CloudError(.invalidPayload) }
        self.startIntent = startIntent; self.starter = starter; self.events = sorted; self.captureRevisions = captures
    }
    private enum CodingKeys: String, CodingKey { case startIntent, starter, events, captureRevisions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startIntent: c.decode(StartIntent.self, forKey: .startIntent), starter: c.decode(Bool.self, forKey: .starter), events: c.decode([MatchEvent].self, forKey: .events), captureRevisions: c.decode([CaptureRevision].self, forKey: .captureRevisions))
    }
}
public struct CloudDeletion: Codable, Sendable, Equatable {
    public let matchID, deletionID: String
    public let deletedAt: Date
    public init(matchID: String, deletionID: String, deletedAt: Date) throws {
        try CloudCodec.id(matchID); try CloudCodec.id(deletionID); try CloudCodec.date(deletedAt)
        self.matchID = matchID; self.deletionID = deletionID; self.deletedAt = deletedAt
    }
    private enum CodingKeys: String, CodingKey { case matchID, deletionID, deletedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(matchID: c.decode(String.self, forKey: .matchID), deletionID: c.decode(String.self, forKey: .deletionID), deletedAt: c.decode(Date.self, forKey: .deletedAt))
    }
}
public struct CloudCheckpoint: Codable, Sendable, Equatable {
    public let matchID, checkpointID: String
    public let recordIDs: [String]
    public init(matchID: String, checkpointID: String, recordIDs: [String]) throws {
        for id in [matchID, checkpointID] + recordIDs { try CloudCodec.id(id) }
        guard !recordIDs.isEmpty, Set(recordIDs).count == recordIDs.count else { throw CloudError(.invalidPayload) }
        self.matchID = matchID; self.checkpointID = checkpointID; self.recordIDs = recordIDs.sorted()
    }
    private enum CodingKeys: String, CodingKey { case matchID, checkpointID, recordIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(matchID: c.decode(String.self, forKey: .matchID), checkpointID: c.decode(String.self, forKey: .checkpointID), recordIDs: c.decode([String].self, forKey: .recordIDs))
    }
}
public enum CloudPayload: Codable, Sendable, Equatable {
    case matchFacts(CloudMatchFacts), checkpoint(CloudCheckpoint), deletion(CloudDeletion)
    public var matchID: String { switch self { case .matchFacts(let f): f.matchID; case .checkpoint(let c): c.matchID; case .deletion(let d): d.matchID } }
    public var recordType: String { switch self { case .matchFacts: "MatchFactsV1"; case .checkpoint: "CheckpointV1"; case .deletion: "DeletionV1" } }
}
public struct CloudRecord: Codable, Sendable, Equatable {
    public let scope: CloudScope
    public let recordID, digest: String
    public let canonicalBytes: Data
    public var payload: CloudPayload { get throws { try CloudCodec.decode(CloudPayload.self, canonicalBytes, limit: CloudCodec.maximumBytes) } }
    public init(scope: CloudScope, payload: CloudPayload) throws {
        let bytes = try CloudCodec.encode(payload)
        guard bytes.count <= CloudCodec.maximumBytes else { throw CloudError(.payloadTooLarge) }
        self.scope = scope; self.canonicalBytes = bytes; self.digest = CloudCodec.hash(bytes)
        self.recordID = try CloudCodec.hash([scope.stableZoneKey, payload.recordType, payload.matchID, digest], domain: "record-id")
    }
    public init(scope: CloudScope, canonicalBytes: Data) throws { try self.init(scope: scope, payload: CloudCodec.decode(CloudPayload.self, canonicalBytes, limit: CloudCodec.maximumBytes)) }
    private enum CodingKeys: String, CodingKey { case scope, recordID, digest, canonicalBytes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(CloudScope.self, forKey: .scope), canonicalBytes: c.decode(Data.self, forKey: .canonicalBytes))
        guard recordID == (try c.decode(String.self, forKey: .recordID)), digest == (try c.decode(String.self, forKey: .digest)) else { throw CloudError(.invalidPayload) }
    }
}
public struct CloudUpload: Codable, Sendable, Equatable {
    public let id: String
    public let scope: CloudScope
    public let record: CloudRecord
    public let expectedChangeTag: String?
    public init(id: String? = nil, scope: CloudScope, record: CloudRecord, expectedChangeTag: String? = nil) throws {
        guard scope == record.scope else { throw CloudError(.accountChanged) }
        if let expectedChangeTag { try CloudCodec.id(expectedChangeTag) }
        self.scope = scope; self.record = record; self.expectedChangeTag = expectedChangeTag
        self.id = try id ?? CloudCodec.hash([scope.key, record.recordID], domain: "upload-id"); try CloudCodec.id(self.id)
    }
    public func canonicalBytes() throws -> Data { try CloudCodec.encode(self) }
    private enum CodingKeys: String, CodingKey { case id, scope, record, expectedChangeTag }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), scope: c.decode(CloudScope.self, forKey: .scope), record: c.decode(CloudRecord.self, forKey: .record), expectedChangeTag: c.decodeIfPresent(String.self, forKey: .expectedChangeTag))
    }
}
public enum CloudDeliveryState: String, Codable, Sendable { case pending, confirmed, blocked }
public struct CloudUploadEntry: Sendable, Equatable {
    public let upload: CloudUpload
    public let originalBytes: Data
    public let state: CloudDeliveryState
    public let attemptCount: Int
    public let issue: CloudIssue?
    public let nextAttemptAt: Date?
}


/// Opaque archive bytes. Token contents have no ordering or timestamp semantics here.
public struct CloudCursor: Codable, Sendable, Equatable {
    public let appliedToken: Data?
    public let fetchGeneration: Int64
    public init(appliedToken: Data?, fetchGeneration: Int64) throws {
        guard fetchGeneration >= 0, appliedToken.map({ $0.count <= 1024*1024 }) != false else { throw CloudError(.invalidPayload) }
        self.appliedToken = appliedToken; self.fetchGeneration = fetchGeneration
    }
    private enum CodingKeys: String, CodingKey { case appliedToken, fetchGeneration }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(appliedToken: c.decodeIfPresent(Data.self, forKey: .appliedToken), fetchGeneration: c.decode(Int64.self, forKey: .fetchGeneration))
    }
}
public struct CloudFetchBatch: Codable, Sendable, Equatable {
    public let scope: CloudScope
    public let batchID: String
    public let records: [CloudRecord]
    public let expectedAppliedToken, nextToken: Data?
    public let fetchGeneration: Int64
    public let moreComing: Bool
    public var digest: String { get throws { try CloudCodec.hash(self, domain: "batch") } }
    public init(scope: CloudScope, batchID: String, records: [CloudRecord], expectedAppliedToken: Data?, nextToken: Data?, fetchGeneration: Int64, moreComing: Bool) throws {
        try CloudCodec.id(batchID)
        _ = try CloudCursor(appliedToken: expectedAppliedToken, fetchGeneration: fetchGeneration)
        _ = try CloudCursor(appliedToken: nextToken, fetchGeneration: fetchGeneration)
        guard records.count <= 64, Set(records.map(\.recordID)).count == records.count else { throw CloudError(.invalidPayload) }
        // Epoch fences current writes; legitimate history is read from the same stable zone.
        guard records.allSatisfy({ $0.scope.stableZoneKey == scope.stableZoneKey }) else { throw CloudError(.accountChanged) }
        self.scope = scope; self.batchID = batchID; self.records = records; self.expectedAppliedToken = expectedAppliedToken
        self.nextToken = nextToken; self.fetchGeneration = fetchGeneration; self.moreComing = moreComing
        guard try CloudCodec.encode(self).count <= CloudCodec.maximumEnvelopeBytes else { throw CloudError(.payloadTooLarge) }
    }
    public func canonicalBytes() throws -> Data { try CloudCodec.encode(self) }
    private enum CodingKeys: String, CodingKey { case scope, batchID, records, expectedAppliedToken, nextToken, fetchGeneration, moreComing }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(CloudScope.self, forKey: .scope), batchID: c.decode(String.self, forKey: .batchID), records: c.decode([CloudRecord].self, forKey: .records), expectedAppliedToken: c.decodeIfPresent(Data.self, forKey: .expectedAppliedToken), nextToken: c.decodeIfPresent(Data.self, forKey: .nextToken), fetchGeneration: c.decode(Int64.self, forKey: .fetchGeneration), moreComing: c.decode(Bool.self, forKey: .moreComing))
    }
}
public struct CloudImportAcknowledgement: Codable, Sendable, Equatable {
    public let scope: CloudScope
    public let batchID, batchDigest: String
    public let appliedToken: Data?
    public let fetchGeneration: Int64
    public init(batch: CloudFetchBatch) throws {
        scope = batch.scope; batchID = batch.batchID; batchDigest = try batch.digest
        appliedToken = batch.nextToken; fetchGeneration = batch.fetchGeneration
    }
    public func matches(_ batch: CloudFetchBatch) throws -> Bool {
        let digest = try batch.digest
        return scope == batch.scope && batchID == batch.batchID && batchDigest == digest && appliedToken == batch.nextToken && fetchGeneration == batch.fetchGeneration
    }
}
public struct CloudBatchEntry: Sendable, Equatable {
    public let batch: CloudFetchBatch
    public let originalBytes: Data
    public let state: CloudDeliveryState
    public let attemptCount: Int
    public let issue: CloudIssue?
    public let nextAttemptAt: Date?
}
public struct CloudSyncOutcome: Sendable, Equatable {
    public let importedBatchIDs: [String]
    public let issue: CloudIssue?
    public init(importedBatchIDs: [String] = [], issue: CloudIssue? = nil) { self.importedBatchIDs = importedBatchIDs; self.issue = issue }
}
