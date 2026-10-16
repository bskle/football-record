import Foundation
import MatchCore
import MatchStore

public protocol SessionRepository: Sendable {
  func matchIDs() async throws -> [String]
  func databaseNamespace() async -> String
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2?
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord]
}
public protocol DeviceIdentityProvider: Sendable { func localDeviceID() async throws -> String }
public protocol SessionClock: Sendable { func now() -> Date }
public protocol SessionIDFactory: Sendable { func nextID() -> String }
public protocol StartPermitProvider: Sendable {
  func acquire(for intent: StartIntent) async throws -> TrustedStartPermit
}
public protocol WorkoutGateway: Sendable {
  func perform(_ operation: CaptureOperation) async -> WorkoutObservation
  func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation
}
public struct SystemSessionClock: SessionClock {
  public init() {}
  public func now() -> Date { Date() }
}
public struct UUIDSessionIDFactory: SessionIDFactory {
  public init() {}
  public func nextID() -> String { UUID().uuidString }
}
public struct UnavailableStartPermitProvider: StartPermitProvider {
  public init() {}
  public func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    throw SessionError.permitUnavailable
  }
}
/// Must only be injected into a separate development database. MatchSession verifies that boundary.
public struct DevelopmentStartPermitProvider: StartPermitProvider {
  public init() {}
  public func acquire(for intent: StartIntent) async throws -> TrustedStartPermit {
    DevelopmentStartFixture.permit(for: intent)
  }
}
public struct UnavailableWorkoutGateway: WorkoutGateway {
  public init() {}
  private func observation(_ operation: CaptureOperation) -> WorkoutObservation {
    try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: Date(),
      outcome: operation.action == .start ? .notCreated(.unavailable) : .unknown,
      window: CaptureWindow(start: nil, end: nil), failure: .unavailable)
  }
  public func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    observation(operation)
  }
  public func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    // An unavailable adapter cannot prove that an earlier cross-system action did not create a Workout.
    try! WorkoutObservation(
      operationID: operation.id, binding: operation.binding, externalToken: operation.externalToken,
      observedAt: Date(), outcome: .unknown, window: CaptureWindow(start: nil, end: nil),
      failure: .unavailable)
  }
}
/// Namespace selects the actual database path; callers cannot relabel an already-open production store.
public actor SQLiteSessionRepository: SessionRepository {
  public static let productionNamespace = "production"
  private let store: MatchStore
  private let namespace: String
  public let databaseURL: URL
  public init(rootDirectory: URL, databaseNamespace: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !databaseNamespace.isEmpty, databaseNamespace.unicodeScalars.allSatisfy(allowed.contains)
    else { throw SessionError.invalidRequest }
    namespace = databaseNamespace
    let directory = rootDirectory.appendingPathComponent(databaseNamespace, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appendingPathComponent("matches.sqlite")
    store = try MatchStore(url: databaseURL)
  }
  public func databaseNamespace() async -> String { namespace }
  public func matchIDs() async throws -> [String] { try await store.matchIDs() }
  public func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 {
    try await store.snapshotV2(matchID: matchID)
  }
  public func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? {
    try await store.committedCommandV2(commandID: commandID)
  }
  public func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    try await store.commitV2(request)
  }
  public func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] {
    try await store.pendingCaptureOperations(matchID: matchID)
  }
  public func close() async throws { try await store.close() }
}
/// One durable installation identity. Missing/corrupt identity with existing matches fails closed.
public actor PersistentDeviceIdentityProvider: DeviceIdentityProvider {
  private let url: URL
  private let repository: any SessionRepository
  private var load: Task<String, Error>?
  public init(url: URL, repository: any SessionRepository) {
    self.url = url
    self.repository = repository
  }
  public func localDeviceID() async throws -> String {
    if let load { return try await load.value }
    let url = url
    let repository = repository
    let task = Task<String, Error> {
      func read() throws -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
          raw.hasPrefix("football-record.identity.v1:"),
          let uuid = UUID(uuidString: String(raw.dropFirst("football-record.identity.v1:".count)))
        else { throw SessionError.identityUnavailable }
        return uuid.uuidString
      }
      if FileManager.default.fileExists(atPath: url.path) { return try read() }
      guard try await repository.matchIDs().isEmpty else { throw SessionError.identityUnavailable }
      let value = UUID().uuidString
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("football-record.identity.v1:" + value).utf8).write(
          to: url, options: .withoutOverwriting)
      } catch {
        if FileManager.default.fileExists(atPath: url.path) { return try read() }
        throw SessionError.identityUnavailable
      }
      return value
    }
    load = task
    return try await task.value
  }
}
