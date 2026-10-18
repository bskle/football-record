import Foundation
import CryptoKit

public enum HealthDeletionIssue: String, Error, Codable, Sendable {
    case invalidRequest, identityConflict, unconfirmed, sourceMismatch, authorizationNotDetermined,
         authorizationDenied, unavailable, storageUnavailable, unsupportedSchema, invalidResponse,
         outcomeUnknown, ledgerInUse, closed
}
enum DeletionValidation {
    static func id(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,58,95].contains($0)
        }
    }
    static func source(_ value: String) -> Bool {
        id(value) && value.contains(".") && !value.split(separator: ".", omittingEmptySubsequences: false).contains("")
            && !value.contains(":") && !value.contains("_")
    }
    static func time(_ value: Int64) -> Bool { (0...253_402_300_799).contains(value) }
    static func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
public struct WorkoutDeletionTargetV1: Codable, Equatable, Sendable {
    public let workoutUUID: UUID
    public let matchID, recordingDeviceID, segmentToken, expectedSourceBundleID: String
    public init(workoutUUID: UUID, matchID: String, recordingDeviceID: String, segmentToken: String, expectedSourceBundleID: String) throws {
        self.workoutUUID=workoutUUID; self.matchID=matchID; self.recordingDeviceID=recordingDeviceID
        self.segmentToken=segmentToken; self.expectedSourceBundleID=expectedSourceBundleID
        try validate()
    }
    func validate() throws {
        guard [matchID,recordingDeviceID,segmentToken].allSatisfy(DeletionValidation.id),
              DeletionValidation.source(expectedSourceBundleID) else { throw HealthDeletionIssue.invalidRequest }
    }
}
public struct WorkoutDeletionRequestV1: Codable, Equatable, Sendable {
    public static let maximumTargets = 256
    public let version: Int
    public let requestID: UUID
    public let createdAt: Int64
    public let targets: [WorkoutDeletionTargetV1]
    public init(requestID: UUID, createdAt: Int64, targets: [WorkoutDeletionTargetV1]) throws {
        version=1; self.requestID=requestID; self.createdAt=createdAt; self.targets=targets
        try validate()
    }
    func validate() throws {
        guard version == 1, DeletionValidation.time(createdAt), !targets.isEmpty, targets.count <= Self.maximumTargets,
              Set(targets.map(\.workoutUUID)).count == targets.count else { throw HealthDeletionIssue.invalidRequest }
        for target in targets { try target.validate() }
    }
    public func canonicalBytes() throws -> Data {
        try validate()
        let ordered = targets.sorted { $0.workoutUUID.uuidString < $1.workoutUUID.uuidString }.map {
            ["workoutUUID":$0.workoutUUID.uuidString.lowercased(), "matchID":$0.matchID,
             "recordingDeviceID":$0.recordingDeviceID,"segmentToken":$0.segmentToken,"expectedSourceBundleID":$0.expectedSourceBundleID]
        }
        return try JSONSerialization.data(withJSONObject: ["version":version,"requestID":requestID.uuidString.lowercased(),"createdAt":createdAt,"targets":ordered], options:[.sortedKeys,.withoutEscapingSlashes])
    }
    public func selectionDigest() throws -> String {
        let raw = Data("football-record.health-workout-delete.v1\n".utf8) + (try canonicalBytes())
        return SHA256.hash(data: raw).map { String(format:"%02x",$0) }.joined()
    }
}
public struct WorkoutDeletionConfirmationV1: Codable, Equatable, Sendable {
    public let confirmationID, requestID: UUID
    public let selectionDigest: String
    public let confirmedAt: Int64
    public let explicitHealthDeletion: Bool
    public init(confirmationID: UUID, requestID: UUID, selectionDigest: String, confirmedAt: Int64, explicitHealthDeletion: Bool) throws {
        self.confirmationID=confirmationID; self.requestID=requestID; self.selectionDigest=selectionDigest
        self.confirmedAt=confirmedAt; self.explicitHealthDeletion=explicitHealthDeletion
        try validate()
    }
    func validate() throws {
        guard explicitHealthDeletion, DeletionValidation.digest(selectionDigest), DeletionValidation.time(confirmedAt) else { throw HealthDeletionIssue.invalidRequest }
    }
}
public enum HealthDeletionPhase: String, Codable, Sendable { case awaitingConfirmation, pending, executing, awaitingOutcome, interrupted, failed, succeededLocally }
public struct WorkoutDeletionReceiptV1: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let selectionDigest: String
    public let attemptID: UUID
    public let completedAt: Int64
    /// Zero describes no matching objects in this exact local scope, not global absence.
    public let deletedObjectCount: Int
    public var noMatchingObjectsInScope: Bool { deletedObjectCount == 0 }
}
public struct HealthDeletionEntry: Equatable, Sendable {
    public let request: WorkoutDeletionRequestV1
    public let selectionDigest: String
    public let confirmation: WorkoutDeletionConfirmationV1?
    public let phase: HealthDeletionPhase
    public let attemptID: UUID?
    public let attemptCount: Int
    public let issue: HealthDeletionIssue?
    public let receipt: WorkoutDeletionReceiptV1?
}
public enum HealthDeletionDriverOutcome: Equatable, Sendable { case success(deletedObjectCount: Int), failure(HealthDeletionIssue) }
