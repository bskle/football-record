import Foundation
import AccountKit
import MatchStore

enum M4WatchRegistrationRelayError: Error, Sendable, Equatable { case unavailable, invalidMessage, closed }
/// Registration-only RPC. It is not a business packet, peer proof or business ACK.
enum M4WatchRegistrationRequest: Sendable {
  case context(UUID)
  case authorize(UUID, WatchRegistrationAttemptV4, WatchRegistrationAction)
  var correlationID: UUID { switch self { case .context(let id), .authorize(let id, _, _): return id } }
}
/// The authorization body can contain a private Watch credential. Adapters must not log or persist it.
enum M4WatchRegistrationResponse: Sendable {
  case context(UUID, WatchRegistrationContextV4)
  case authorized(UUID, String, String, WatchRegistrationAction, Data)
}
/// A channel is owned by one relay. cancel/close must settle its outstanding exchange waiters.
/// A WC adapter must keep this channel separate from business sync and never infer authentication.
protocol M4WatchRegistrationChannel: Sendable {
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse
  func cancel(_ correlationID: UUID) async
  func close() async
}
struct M4UnavailableWatchRegistrationChannel: M4WatchRegistrationChannel {
  func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse { throw M4WatchRegistrationRelayError.unavailable }
  func cancel(_ correlationID: UUID) async {}
  func close() async {}
}
actor M4WatchRegistrationRelay: WatchRegistrationAuthorizing {
  private let channel: any M4WatchRegistrationChannel
  private var closed = false
  private var operations: [UUID: Task<M4WatchRegistrationResponse, any Error>] = [:]
  private var cancellations: [UUID: Task<Void, Never>] = [:]
  private var closing: Task<Void, Never>?
  init(channel: any M4WatchRegistrationChannel = M4UnavailableWatchRegistrationChannel()) { self.channel = channel }
  private func exchange(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    guard !closed else { throw M4WatchRegistrationRelayError.closed }
    try Task.checkCancellation()
    let id = request.correlationID, channel = channel
    let operation = Task { try Task.checkCancellation(); return try await channel.exchange(request) }
    operations[id] = operation
    defer { operations[id] = nil }
    do {
      let reply = try await withTaskCancellationHandler { try await operation.value } onCancel: {
        Task { await self.cancel(id) }
      }
      guard !closed else { throw M4WatchRegistrationRelayError.closed }
      try Task.checkCancellation(); return reply
    } catch {
      guard !closed else { throw M4WatchRegistrationRelayError.closed }
      throw error
    }
  }
  private func cancel(_ id: UUID) async {
    guard !closed, let operation = operations[id] else { return }
    operation.cancel()
    if let prior = cancellations[id] { await prior.value; return }
    let channel = channel, task = Task { await channel.cancel(id) }
    cancellations[id] = task; await task.value; cancellations[id] = nil
  }
  func registrationContext() async throws -> WatchRegistrationContextV4 {
    let id = UUID()
    guard case let .context(replyID, context) = try await exchange(.context(id)), replyID == id else { throw M4WatchRegistrationRelayError.invalidMessage }
    return try WatchRegistrationContextV4(accountID: context.accountID, cloudSpaceID: context.cloudSpaceID, phoneID: context.phoneID, activationEpoch: context.activationEpoch, environment: context.environment)
  }
  func authorizeRegistration(_ attempt: WatchRegistrationAttemptV4, action: WatchRegistrationAction) async throws -> Data {
    try attempt.validate(); let id = UUID()
    guard case let .authorized(replyID, requestID, digest, replyAction, bytes) = try await exchange(.authorize(id, attempt, action)),
          replyID == id, Data(requestID.utf8) == Data(attempt.requestID.utf8), Data(digest.utf8) == Data(attempt.requestDigest.utf8),
          replyAction == action, !bytes.isEmpty, bytes.count <= 65536 else { throw M4WatchRegistrationRelayError.invalidMessage }
    return bytes
  }
  func close() async {
    if let closing { await closing.value; return }
    closed = true
    let owned = operations, cancelling = cancellations, channel = channel
    owned.values.forEach { $0.cancel() }
    let task = Task {
      for id in owned.keys where cancelling[id] == nil { await channel.cancel(id) }
      await channel.close()
      for operation in owned.values { _ = await operation.result }
      for cancellation in cancelling.values { await cancellation.value }
    }
    closing = task; await task.value
  }
}
/// Inject the already admitted PhoneWatchRegistrationService from the original facade.
/// This endpoint never owns or installs either device's credential vault.
actor M4PhoneWatchRegistrationEndpoint {
  private let authorizer: any WatchRegistrationAuthorizing
  private var closed = false
  private var operations: [UUID: Task<M4WatchRegistrationResponse, any Error>] = [:]
  private var closing: Task<Void, Never>?
  init(authorizer: any WatchRegistrationAuthorizing) { self.authorizer = authorizer }
  func handle(_ request: M4WatchRegistrationRequest) async throws -> M4WatchRegistrationResponse {
    guard !closed else { throw M4WatchRegistrationRelayError.closed }
    try Task.checkCancellation()
    if case .authorize(_, let attempt, _) = request { try attempt.validate() }
    let id = request.correlationID
    guard operations[id] == nil else { throw M4WatchRegistrationRelayError.invalidMessage }
    let authorizer = authorizer
    let operation = Task<M4WatchRegistrationResponse, any Error> {
      try Task.checkCancellation()
      switch request {
      case .context(let id):
        let context = try await authorizer.registrationContext(); try Task.checkCancellation(); return .context(id, context)
      case let .authorize(id, attempt, action):
        let bytes = try await authorizer.authorizeRegistration(attempt, action: action)
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= 65536 else { throw M4WatchRegistrationRelayError.invalidMessage }
        return .authorized(id, attempt.requestID, attempt.requestDigest, action, bytes)
      }
    }
    operations[id] = operation
    defer { operations[id] = nil }
    do {
      let response = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
      guard !closed else { throw M4WatchRegistrationRelayError.closed }
      try Task.checkCancellation(); return response
    } catch {
      guard !closed else { throw M4WatchRegistrationRelayError.closed }
      throw error
    }
  }
  func cancel(_ id: UUID) async {
    guard let operation = operations[id] else { return }
    operation.cancel(); _ = await operation.result
  }
  func close() async {
    if let closing { await closing.value; return }
    closed = true
    let owned = operations
    owned.values.forEach { $0.cancel() }
    let task = Task { for operation in owned.values { _ = await operation.result } }
    closing = task; await task.value
  }
}
