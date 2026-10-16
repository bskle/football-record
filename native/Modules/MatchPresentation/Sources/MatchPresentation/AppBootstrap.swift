import Foundation
import MatchCore
import MatchStore
import MatchSession

public enum AppBootstrap {
  @MainActor public static func production() throws -> RecordingModel {
    try make(namespace: SQLiteSessionRepository.productionNamespace, development: false)
  }
  @MainActor private static func make(namespace: String, development: Bool, failFirstScore: Bool = false) throws -> RecordingModel {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record", isDirectory: true)
    let repository = try SQLiteSessionRepository(rootDirectory: support, databaseNamespace: namespace)
    let identity = PersistentDeviceIdentityProvider(url: support.appendingPathComponent(namespace).appendingPathComponent("device.identity"), repository: repository)
    var store: any SessionRepository = repository
    var permits: any StartPermitProvider = UnavailableStartPermitProvider()
    var environment: SessionEnvironment = .production
    #if DEBUG
    if development {
      permits = DevelopmentStartPermitProvider()
      environment = .development(databaseNamespace: namespace)
      if failFirstScore { store = DebugFailureRepository(repository) }
    }
    #endif
    let session = MatchSession(store: store, deviceIdentity: identity, clock: SystemSessionClock(), ids: UUIDSessionIDFactory(), permits: permits, workout: UnavailableWorkoutGateway(), environment: environment)
    return RecordingModel(session: session, repository: store, development: development)
  }
  #if DEBUG
  @MainActor public static func development(dataset: String, failFirstScore: Bool = false) throws -> RecordingModel {
    let canonical = String(dataset.lowercased().utf8.filter { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }.map { Character(UnicodeScalar($0)) }.prefix(80))
    guard !canonical.isEmpty else { throw SessionError.invalidRequest }
    return try make(namespace: "ui-simulation-" + canonical, development: true, failFirstScore: failFirstScore)
  }
  #endif
}

#if DEBUG
/// Explicit UI-test failure injection, reachable only through the separate Debug dataset factory.
private actor DebugFailureRepository: SessionRepository {
  let repository: SQLiteSessionRepository
  var failed = false
  init(_ repository: SQLiteSessionRepository) { self.repository = repository }
  func databaseNamespace() async -> String { await repository.databaseNamespace() }
  func matchIDs() async throws -> [String] { try await repository.matchIDs() }
  func snapshotV2(matchID: String) async throws -> StoreSnapshotV2 { try await repository.snapshotV2(matchID: matchID) }
  func committedCommandV2(commandID: String) async throws -> CommittedCommandV2? { try await repository.committedCommandV2(commandID: commandID) }
  func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord] { try await repository.pendingCaptureOperations(matchID: matchID) }
  func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2 {
    if !failed, request.events.contains(where: { $0.type == .scoreEvent }) { failed = true; throw StoreError.injectedFailure }
    return try await repository.commitV2(request)
  }
}
#endif
