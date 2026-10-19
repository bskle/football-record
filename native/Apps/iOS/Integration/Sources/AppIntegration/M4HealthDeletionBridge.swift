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
  static func digest(_ value:String) -> Bool {value.utf8.count == 64 && value.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)}}
  static func uuid(domain:String,fields:[Data]) -> UUID {
    var bytes=Array(SHA256.hash(data:Data(domain.utf8)+Data([0])+frame(fields)).prefix(16))
    bytes[6]=(bytes[6]&0x0f)|0x80;bytes[8]=(bytes[8]&0x3f)|0x80
    return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
  }
  static func frame(_ fields: [Data]) -> Data {
    var result=Data()
    for field in fields { var count=UInt64(field.count).bigEndian; withUnsafeBytes(of:&count) { result.append(contentsOf:$0) }; result.append(field) }; return result
  }
}

struct M4HealthPreparedMapping: Codable, Sendable {
  let version: Int
  let parentID, parentDigest, reservationDigest: String
  let request: WorkoutDeletionRequestV1
  let confirmation: WorkoutDeletionConfirmationV1
  func canonicalBytes() throws -> Data {
    guard version == 1, M4HealthBytes.digest(parentDigest), M4HealthBytes.digest(reservationDigest),
          request.requestID == confirmation.requestID, try request.selectionDigest() == confirmation.selectionDigest,
          confirmation.explicitHealthDeletion, confirmation.confirmedAt >= request.createdAt,
          confirmation.confirmedAt <= 253_402_300_799 else {throw M4HealthBridgeError.identityConflict}
    _ = try request.canonicalBytes(); return try M4HealthBytes.encode(self)
  }
  init(reservation:M4HealthRawReservation,parentDigest:String) throws {
    version=1;parentID=reservation.parentID;self.parentDigest=parentDigest;reservationDigest=try reservation.digest()
    let fields=[Data(parentID.utf8),Data(parentDigest.utf8),Data(reservationDigest.utf8)]
    let requestID=M4HealthBytes.uuid(domain:"football-record.m4.health-request-uuid.v1",fields:fields)
    request=try WorkoutDeletionRequestV1(requestID:requestID,createdAt:reservation.createdAt,targets:reservation.targets())
    let digest=try request.selectionDigest()
    let confirmationID=M4HealthBytes.uuid(domain:"football-record.m4.health-confirmation-uuid.v1",fields:fields+[Data(requestID.uuidString.lowercased().utf8),Data(digest.utf8)])
    confirmation=try WorkoutDeletionConfirmationV1(confirmationID:confirmationID,requestID:requestID,selectionDigest:digest,confirmedAt:reservation.confirmedAt,explicitHealthDeletion:reservation.healthConfirmed)
    _=try canonicalBytes()
  }
}
struct M4HealthFullSeal: Codable, Sendable {
  let version: Int
  let parentID, parentDigest, reservationDigest, preparedDigest, catalogDigest: String
  let scope: CloudScopeV1
  let cloud, local, health: ClientDeletionChoiceV4
  let healthConfirmed: Bool
}
///026 supplies an immutable, retained, transactional adapter. No production journal is created here.
protocol M4HealthMappingStore: Sendable {
  func reserve(_ value:M4HealthRawReservation) async throws
  func readReservation(parentID:String) async throws -> M4HealthRawReservation?
  func putPrepared(_ value:M4HealthPreparedMapping) async throws
  func readPrepared(parentID:String) async throws -> M4HealthPreparedMapping?
  func readFullSeal(parentID:String) async throws -> M4HealthFullSeal?
}
struct M4UnavailableHealthMappingStore: M4HealthMappingStore {
  func reserve(_ value:M4HealthRawReservation) async throws {throw M4HealthBridgeError.mappingUnavailable}
  func readReservation(parentID:String) async throws -> M4HealthRawReservation? {throw M4HealthBridgeError.mappingUnavailable}
  func putPrepared(_ value:M4HealthPreparedMapping) async throws {throw M4HealthBridgeError.mappingUnavailable}
  func readPrepared(parentID:String) async throws -> M4HealthPreparedMapping? {throw M4HealthBridgeError.mappingUnavailable}
  func readFullSeal(parentID:String) async throws -> M4HealthFullSeal? {throw M4HealthBridgeError.mappingUnavailable}
}
actor M4HealthDeletionBridge: AppWorkoutDeletionDriver {
  private let mapping:any M4HealthMappingStore
  private let parents:any LifecycleStateRepository
  private let ledger:any HealthDeletionLedger
  private let service:HealthDeletionService
  private let allowedSourceOrigin:M4HealthSourceEvidence.Origin
  private let clock:@Sendable () -> Int64
  private let timeout:Duration
  private var executingParents=Set<Data>()
  private var closed=false
  init(mapping:any M4HealthMappingStore=M4UnavailableHealthMappingStore(),parents:any LifecycleStateRepository,ledger:any HealthDeletionLedger,driver:any HealthDeletionDriver=UnavailableHealthDeletionDriver(),allowedSourceOrigin:M4HealthSourceEvidence.Origin = .platformObservation,clock:@escaping @Sendable () -> Int64 = {Int64(Date().timeIntervalSince1970)},timeout:Duration = .seconds(5)) {
    self.mapping=mapping;self.parents=parents;self.ledger=ledger;self.allowedSourceOrigin=allowedSourceOrigin;self.clock=clock;self.timeout=timeout
    service=HealthDeletionService(ledger:ledger,driver:driver,clock:clock)
  }
  private func open() throws {guard !closed else {throw M4HealthBridgeError.closed}}
  private func checkSource(_ raw:M4HealthRawReservation) throws {
    _=try raw.targets()
    guard !raw.sources.isEmpty, raw.sources.allSatisfy({$0.origin == allowedSourceOrigin}) else {throw M4HealthBridgeError.sourceUnavailable}
  }
  func reserve(_ value:M4HealthRawReservation) async throws {
    try open();try checkSource(value);let bytes=try value.canonicalBytes()
    try await mapping.reserve(value);try open()
    guard let saved=try await mapping.readReservation(parentID:value.parentID),try saved.canonicalBytes() == bytes else {throw M4HealthBridgeError.identityConflict};try open()
  }
  private func parent(_ raw:M4HealthRawReservation,execution:Bool=false) async throws -> DeletionSagaV4 {
    try open();guard let saga=try await parents.deletionSagaV4(requestID:raw.parentID) else {throw M4HealthBridgeError.parentUnavailable};try open()
    guard saga.intent.operation == .deleteAccount, M4HealthBytes.same(saga.intent.requestID,raw.parentID),
          let scope=saga.originalScope, M4HealthBytes.scope(scope,raw.scope),
          M4HealthBytes.same(saga.accountID,scope.accountID), saga.activationEpoch == scope.activationEpoch,
          saga.cloudChoice == raw.cloud, saga.localChoice == raw.local, saga.healthChoice == raw.health,
          saga.healthChoice == .delete, saga.healthConfirmed, saga.healthConfirmed == raw.healthConfirmed,
          !execution || (saga.backendDeleted && saga.backendReceipt != nil) else {throw M4HealthBridgeError.identityConflict}
    return saga
  }
  private func checked(_ prepared:M4HealthPreparedMapping,raw:M4HealthRawReservation,saga:DeletionSagaV4) throws {
    let expected=try M4HealthPreparedMapping(reservation:raw,parentDigest:saga.intent.digest)
    guard try prepared.canonicalBytes() == expected.canonicalBytes() else {throw M4HealthBridgeError.identityConflict}
  }
  private func checked(_ entry:HealthDeletionEntry,prepared:M4HealthPreparedMapping,confirmed:Bool) throws {
    let confirmationMatches=try entry.confirmation.map {try M4HealthBytes.encode($0)} == M4HealthBytes.encode(prepared.confirmation)
    guard try entry.request.canonicalBytes() == prepared.request.canonicalBytes(),
          entry.selectionDigest == prepared.confirmation.selectionDigest,
          !confirmed || confirmationMatches else {throw M4HealthBridgeError.identityConflict}
  }
  func prepare(parentID:String) async throws -> M4HealthPreparedMapping {
    try open();guard let raw=try await mapping.readReservation(parentID:parentID),M4HealthBytes.same(raw.parentID,parentID) else {throw M4HealthBridgeError.missingMapping};try open();try checkSource(raw)
    let saga=try await parent(raw)
    let prepared:M4HealthPreparedMapping
    if let prior=try await mapping.readPrepared(parentID:parentID) {try checked(prior,raw:raw,saga:saga);prepared=prior}
    else {
      let first=try M4HealthPreparedMapping(reservation:raw,parentDigest:saga.intent.digest);try open()
      try await mapping.putPrepared(first);try open()
      guard let saved=try await mapping.readPrepared(parentID:parentID),try saved.canonicalBytes() == first.canonicalBytes() else {throw M4HealthBridgeError.identityConflict}
      prepared=saved
    }
    try open();_=try await parent(raw)
    let submitted=try await ledger.submit(prepared.request);try open();try checked(submitted,prepared:prepared,confirmed:false)
    let confirmed=try await ledger.confirm(prepared.confirmation,now:clock());try open();try checked(confirmed,prepared:prepared,confirmed:true)
    let entry=try await ledger.entry(prepared.request.requestID);try open();try checked(entry,prepared:prepared,confirmed:true)
    return prepared
  }
  private func sealed(_ raw:M4HealthRawReservation,_ prepared:M4HealthPreparedMapping,_ saga:DeletionSagaV4) async throws {
    guard let seal=try await mapping.readFullSeal(parentID:raw.parentID) else {throw M4HealthBridgeError.unsealed};try open()
    guard seal.version == 1, M4HealthBytes.same(seal.parentID,raw.parentID),
          M4HealthBytes.same(seal.parentDigest,saga.intent.digest),
          M4HealthBytes.same(seal.reservationDigest,try raw.digest()),
          M4HealthBytes.same(seal.preparedDigest,try M4HealthBytes.hash(prepared.canonicalBytes())),
          M4HealthBytes.digest(seal.catalogDigest), M4HealthBytes.scope(seal.scope,raw.scope),
          seal.cloud == raw.cloud, seal.local == raw.local, seal.health == raw.health,
          seal.health == .delete, seal.healthConfirmed, seal.healthConfirmed == raw.healthConfirmed else {throw M4HealthBridgeError.identityConflict}
  }
  private func receipt(_ entry:HealthDeletionEntry,_ prepared:M4HealthPreparedMapping) throws {
    try checked(entry,prepared:prepared,confirmed:true)
    guard entry.phase == .succeededLocally, let receipt=entry.receipt,
          receipt.requestID == prepared.request.requestID,
          receipt.selectionDigest == prepared.confirmation.selectionDigest,
          receipt.attemptID == entry.attemptID,receipt.deletedObjectCount >= 0,
          receipt.deletedObjectCount <= prepared.request.targets.count else {throw M4HealthBridgeError.deletionFailed}
  }
  /// The legacy AccountKit parameter is the original parent saga ID, never the028 confirmation UUID.
  func deleteAppCreatedWorkouts(confirmationID:String) async throws {
    try open();let parentKey=Data(confirmationID.utf8)
    guard executingParents.insert(parentKey).inserted else {throw M4HealthBridgeError.outcomeUnknown}
    defer {executingParents.remove(parentKey)}
    guard let raw=try await mapping.readReservation(parentID:confirmationID), M4HealthBytes.same(raw.parentID,confirmationID),
          let prepared=try await mapping.readPrepared(parentID:confirmationID) else {throw M4HealthBridgeError.missingMapping}
    try open();try checkSource(raw)
    let saga=try await parent(raw,execution:true);try checked(prepared,raw:raw,saga:saga);try await sealed(raw,prepared,saga)
    let prior=try await ledger.entry(prepared.request.requestID);try open();try checked(prior,prepared:prepared,confirmed:true)
    if prior.phase == .succeededLocally {try receipt(prior,prepared);return}
    //028 permits explicit interrupted retry; this integration deliberately preserves unknown outcomes.
    if [.executing,.awaitingOutcome,.interrupted].contains(prior.phase) || prior.issue == .outcomeUnknown {throw M4HealthBridgeError.outcomeUnknown}
    guard [.pending,.failed].contains(prior.phase) else {throw M4HealthBridgeError.unsealed}
    let actual=try await parent(raw,execution:true);try await sealed(raw,prepared,actual);try open()
    let result=try await service.resume(prepared.request.requestID,timeout:timeout);try open()
    let after=try await parent(raw,execution:true);try await sealed(raw,prepared,after)
    if [.executing,.awaitingOutcome,.interrupted].contains(result.phase) || result.issue == .outcomeUnknown {throw M4HealthBridgeError.outcomeUnknown}
    try receipt(result,prepared)
  }
  func close() async throws {closed=true;try await service.close()}
}
