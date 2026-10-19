import Foundation
import CryptoKit
import MatchCore
import MatchStore
import AccountKit
import HealthKitDeletion

enum M4HealthBridgeError: Error, Sendable, Equatable {
  case invalidReservation, sourceUnavailable, missingMapping, unsupportedSelection, identityConflict,
       mappingUnavailable, unsealed, parentUnavailable, outcomeUnknown, deletionFailed, closed
}
struct M4HealthSourceEvidence: Codable, Sendable {
  enum Platform: String, Codable, Sendable { case iOS, watchOS }
  enum Origin: String, Codable, Sendable { case controlledFixture, platformObservation }
  let recordingDeviceID, bundleID: String
  let platform: Platform
  let origin: Origin
  let evidenceID: String
}
struct M4HealthCaptureFacts: Codable, Sendable {
  let binding: CaptureBinding
  let revisions: [CaptureRevision]
  let operations: [CaptureOperationRecord]
  init(binding: CaptureBinding, revisions: [CaptureRevision], operations: [CaptureOperationRecord]) {
    self.binding = binding; self.revisions = revisions; self.operations = operations
  }
  init(snapshot: StoreSnapshotV2) throws {
    self.init(binding: try CaptureBinding(matchID: snapshot.business.descriptor.matchID, recordingDeviceID: snapshot.business.descriptor.recordingDeviceID), revisions: snapshot.captureRevisions, operations: snapshot.captureOperations)
  }
}
struct M4HealthRawReservation: Codable, Sendable {
  let version: Int
  let parentID: String
  let scope: CloudScopeV1
  let cloud, local, health: ClientDeletionChoiceV4
  let healthConfirmed: Bool
  let createdAt, confirmedAt: Int64
  let facts: [M4HealthCaptureFacts]
  let sources: [M4HealthSourceEvidence]
  init(parentID: String, scope: CloudScopeV1, cloud: ClientDeletionChoiceV4, local: ClientDeletionChoiceV4, health: ClientDeletionChoiceV4, healthConfirmed: Bool, createdAt: Int64, confirmedAt: Int64, facts: [M4HealthCaptureFacts], sources: [M4HealthSourceEvidence]) throws {
    version=1; self.parentID=parentID; self.scope=scope; self.cloud=cloud; self.local=local; self.health=health; self.healthConfirmed=healthConfirmed; self.createdAt=createdAt; self.confirmedAt=confirmedAt; self.facts=facts; self.sources=sources
    _ = try targets()
  }
  func targets() throws -> [WorkoutDeletionTargetV1] {
    guard version == 1, !parentID.isEmpty, parentID.utf8.count <= 4096, !parentID.utf8.contains(0),
          health == .delete, healthConfirmed, (0...253_402_300_799).contains(createdAt),
          confirmedAt >= createdAt, confirmedAt <= 253_402_300_799 else { throw M4HealthBridgeError.invalidReservation }
    var result: [UUID: WorkoutDeletionTargetV1] = [:]
    var sourceDomains = Set<Data>()
    var factBindings = Set<Data>()
    for fact in facts {
      let binding = fact.binding
      guard factBindings.insert(M4HealthBytes.frame([Data(binding.matchID.utf8), Data(binding.recordingDeviceID.utf8)])).inserted else { throw M4HealthBridgeError.missingMapping }
      let candidates = sources.filter { M4HealthBytes.same($0.recordingDeviceID, binding.recordingDeviceID) }
      guard candidates.count == 1, let source = candidates.first,
            !source.evidenceID.isEmpty, source.evidenceID.utf8.count <= 4096, !source.evidenceID.utf8.contains(0) else { throw M4HealthBridgeError.sourceUnavailable }
      sourceDomains.insert(M4HealthBytes.frame([Data(source.bundleID.utf8), Data(source.platform.rawValue.utf8), Data(source.origin.rawValue.utf8)]))
      var operations: [Data: Data] = [:]
      for record in fact.operations {
        guard M4HealthBytes.binding(record.operation.binding, binding) else { throw M4HealthBridgeError.missingMapping }
        let key = Data(record.operation.id.utf8), bytes = try M4HealthBytes.encode(record)
        if let prior = operations[key], prior != bytes { throw M4HealthBridgeError.missingMapping }; operations[key] = bytes
        if let observation = record.observation {
          guard M4HealthBytes.binding(observation.binding, binding), M4HealthBytes.same(observation.operationID, record.operation.id),
                M4HealthBytes.same(observation.externalToken, record.operation.externalToken) else { throw M4HealthBridgeError.missingMapping }
        }
      }
      var coveredTokens = Set<Data>(), revisions: [Data: Data] = [:]
      for revision in fact.revisions {
        guard M4HealthBytes.binding(revision.binding, binding), M4HealthBytes.binding(revision.metadata.binding, binding) else { throw M4HealthBridgeError.missingMapping }
        let revisionKey = Data(revision.id.utf8), revisionBytes = try M4HealthBytes.encode(revision)
        if let prior = revisions[revisionKey], prior != revisionBytes { throw M4HealthBridgeError.missingMapping }; revisions[revisionKey] = revisionBytes
        for segment in revision.metadata.segments {
          guard M4HealthBytes.binding(segment.binding, binding), let uuid = UUID(uuidString: segment.workoutID) else { throw M4HealthBridgeError.missingMapping }
          let linked = fact.operations.filter {
            guard let observation = $0.observation, case .linked(let workoutID) = observation.outcome else { return false }
            return UUID(uuidString: workoutID) == uuid
          }
          guard !linked.isEmpty else { throw M4HealthBridgeError.missingMapping }
          for record in linked {
            let target = try WorkoutDeletionTargetV1(workoutUUID: uuid, matchID: binding.matchID, recordingDeviceID: binding.recordingDeviceID, segmentToken: record.operation.externalToken, expectedSourceBundleID: source.bundleID)
            if let prior = result[uuid], try M4HealthBytes.encode(prior) != M4HealthBytes.encode(target) { throw M4HealthBridgeError.missingMapping }
            result[uuid] = target; coveredTokens.insert(Data(record.operation.externalToken.utf8))
          }
        }
      }
      for record in fact.operations {
        // Linked proof for the same original token covers historical running/unknown siblings.
        // A gap or nil time window describes missing timing, not another inferred Workout.
        if record.state == .cancelled { continue }
        if case .notCreated = record.observation?.outcome { continue }
        guard coveredTokens.contains(Data(record.operation.externalToken.utf8)) else { throw M4HealthBridgeError.missingMapping }
        if case .linked(let workoutID) = record.observation?.outcome {
          guard let uuid = UUID(uuidString: workoutID), result[uuid] != nil else { throw M4HealthBridgeError.missingMapping }
        }
      }
    }
    guard sourceDomains.count <= 1, !result.isEmpty, result.count <= WorkoutDeletionRequestV1.maximumTargets else { throw M4HealthBridgeError.unsupportedSelection }
    return result.values.sorted { $0.workoutUUID.uuidString < $1.workoutUUID.uuidString }
  }
  func canonicalBytes() throws -> Data {
    _ = try targets(); return try M4HealthBytes.encode(self)
  }
  func digest() throws -> String { SHA256.hash(data: Data("football-record.m4.health-reservation.v1\n".utf8) + (try canonicalBytes())).map { String(format: "%02x", $0) }.joined() }
}

/// Identity and immutability compare original UTF-8 bytes, never Swift's Unicode equivalence.
enum M4HealthBytes {
  static let maximumArtifactBytes = 16 * 1024 * 1024
  static func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
  static func binding(_ a: CaptureBinding, _ b: CaptureBinding) -> Bool { same(a.matchID,b.matchID) && same(a.recordingDeviceID,b.recordingDeviceID) }
  static func scope(_ a: CloudScopeV1, _ b: CloudScopeV1) -> Bool { same(a.accountID,b.accountID) && same(a.cloudSpaceID,b.cloudSpaceID) && same(a.zoneID,b.zoneID) && a.activationEpoch == b.activationEpoch }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    let bytes=try encoder.encode(value)
    guard bytes.count <= maximumArtifactBytes else { throw M4HealthBridgeError.unsupportedSelection }; return bytes
  }
  static func hash(_ value: Data) -> String { SHA256.hash(data:value).map { String(format:"%02x",$0) }.joined() }
  static func frame(_ fields: [Data]) -> Data {
    var result=Data()
    for field in fields { var count=UInt64(field.count).bigEndian; withUnsafeBytes(of:&count) { result.append(contentsOf:$0) }; result.append(field) }; return result
  }
}
