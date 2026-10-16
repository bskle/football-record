import Foundation
import MatchCore
import MatchSession

@MainActor public final class AppleWorkoutGateway: WorkoutGateway {
  private final class Entry {
    let context: WorkoutContext
    var driver: (any WorkoutDriver)?
    var state = DriverState(outcome: .unknown)
    var terminal = false
    var finishTask: Task<DriverState, Never>?
    var finishCompleted = false
    var freshStartOperationID: String?
    var creationAttempted = false
    var recoveryAttempted = false
    var existenceObserved = false
    var negativeStartProof = false
    var canProveNoCreation: Bool {
      terminal && freshStartOperationID == context.externalToken && !creationAttempted && !recoveryAttempted
        && !existenceObserved && driver == nil && state.start == nil && state.end == nil
    }
    func terminalStartResult() -> DriverState {
      guard canProveNoCreation else { return DriverState(outcome: .unknown, start: state.start, end: state.end) }
      negativeStartProof = true
      return DriverState(outcome: .notCreated(.unavailable), failure: .unavailable)
    }
    init(_ context: WorkoutContext) { self.context = context }
    func merge(_ next: DriverState) {
      switch next.outcome {
      case .running, .paused, .stopped, .linked, .savedAwaitingLink: existenceObserved = true
      default: break
      }
      if next.start != nil || next.end != nil { existenceObserved = true }
      if existenceObserved { negativeStartProof = false }
      if negativeStartProof { state = DriverState(outcome: .notCreated(.unavailable), failure: .unavailable) }
      else { state = state.merging(next) }
    }
  }
  private let factory: any WorkoutDriverFactory
  private let timeout: Duration
  private var entries: [String: Entry] = [:]
  private var operations: [String: CaptureOperation] = [:]
  private var work: [String: Task<DriverState, Never>] = [:]
  public init(factory: any WorkoutDriverFactory, timeout: Duration = .seconds(10)) { self.factory = factory; self.timeout = timeout }

  public func perform(_ operation: CaptureOperation) async -> WorkoutObservation {
    guard let entry = entry(for: operation) else { return observation(operation, state: DriverState(outcome: .unknown)) }
    if let prior = operations[operation.id], prior != operation { return observation(operation, state: DriverState(outcome: .unknown)) }
    if operation.action == .start, operations[operation.id] == nil { entry.freshStartOperationID = operation.id }
    operations[operation.id] = operation
    if operation.action == .finish { entry.terminal = true }
    if let driver = entry.driver { entry.merge(driver.currentState()) }
    if entry.state.saved { return observation(operation, state: entry.state) }
    let task: Task<DriverState, Never>
    if let old = work[operation.id] { task = old } else {
      task = Task { @MainActor [self] in
        let next = await run(operation, entry: entry); entry.merge(next)
        // A late start response cannot resume capture after the terminal fact has arrived.
        if entry.terminal, operation.action != .finish, !entry.state.saved, entry.driver != nil {
          entry.merge(await finish(entry))
        }
        return entry.state
      }
      work[operation.id] = task
    }
    let result = await withDeadline(timeout) { await task.value }
    if let result { entry.merge(result) }
    return observation(operation, state: result == nil && !entry.state.saved ? DriverState(outcome: .unknown, start: entry.state.start, end: entry.state.end, failure: entry.state.failure) : entry.state)
  }

  public func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation {
    guard let entry = entry(for: operation) else { return observation(operation, state: DriverState(outcome: .unknown)) }
    if let prior = operations[operation.id], prior != operation { return observation(operation, state: DriverState(outcome: .unknown)) }
    operations[operation.id] = operation
    if entry.negativeStartProof { return observation(operation, state: DriverState(outcome: .notCreated(.unavailable), failure: .unavailable)) }
    entry.recoveryAttempted = true
    if operation.action == .finish { entry.terminal = true }
    if case .linked = entry.state.outcome { return observation(operation, state: entry.state) }
    if let driver = entry.driver { entry.merge(driver.currentState()) }
    if entry.terminal, entry.driver != nil, !entry.state.saved {
      let task = Task { @MainActor [self] in await finish(entry) }
      guard let state = await withDeadline(timeout, operation: { await task.value }) else {
        return observation(operation, state: DriverState(outcome: .unknown, start: entry.state.start, end: entry.state.end))
      }
      entry.merge(state)
    }
    if !entry.state.saved, entry.driver != nil, entry.state.outcome != .unknown {
      return observation(operation, state: entry.state)
    }
    let factory = factory; let context = entry.context
    let lookup = await withDeadline(timeout) { await factory.recover(context: context) }
    switch lookup {
    case .active(let driver):
      entry.driver = driver; entry.merge(driver.currentState())
      if entry.terminal {
        let task = Task { @MainActor [self] in await finish(entry) }
        if let state = await withDeadline(timeout, operation: { await task.value }) { entry.merge(state) }
        else { return observation(operation, state: DriverState(outcome: .unknown, start: entry.state.start, end: entry.state.end)) }
      }
    case .saved(var state):
      if operation.action == .recover { state.failure = state.failure ?? .recoveryUnavailable }
      entry.merge(state)
    case .unknown, nil: break
    }
    return observation(operation, state: entry.state)
  }

  private func entry(for op: CaptureOperation) -> Entry? {
    if let entry = entries[op.externalToken] { return entry.context.binding == op.binding ? entry : nil }
    let entry = Entry(WorkoutContext(binding: op.binding, externalToken: op.externalToken)); entries[op.externalToken] = entry; return entry
  }
  private func run(_ op: CaptureOperation, entry: Entry) async -> DriverState {
    if entry.state.saved { return entry.state }
    switch op.action {
    case .start:
      guard entry.driver == nil else { return entry.state }
      guard !entry.terminal else { return entry.terminalStartResult() }
      let authorization = await factory.requestAuthorization()
      guard !entry.terminal else { return entry.terminalStartResult() }
      guard authorization.available else { return DriverState(outcome: .notCreated(.unavailable), failure: .unavailable) }
      guard authorization.write == .allowed else {
        return authorization.write == .denied ? DriverState(outcome: .notCreated(.writeDenied), failure: .writeDenied) : DriverState(outcome: .notCreated(.unavailable), failure: .unavailable)
      }
      entry.creationAttempted = true
      do { entry.driver = try factory.makeDriver(context: entry.context) }
      catch { return DriverState(outcome: .notCreated(.unavailable), failure: .unavailable) }
      var state = await entry.driver!.start()
      if authorization.location == .denied, state.failure == nil { state.failure = .locationDenied }
      return state
    case .pause:
      guard !entry.terminal, let driver = entry.driver else { return entry.state }
      return await driver.pause()
    case .resume:
      guard !entry.terminal, let driver = entry.driver else { return entry.state }
      return await driver.resume()
    case .finish: return await finish(entry)
    case .recover:
      _ = await reconcile(op); return entry.state
    }
  }
  private func finish(_ entry: Entry) async -> DriverState {
    if entry.state.saved { return entry.state }
    if entry.finishCompleted { entry.finishTask = nil; entry.finishCompleted = false }
    if let task = entry.finishTask { return await task.value }
    guard let driver = entry.driver else { return entry.state }
    driver.requestStop()
    let task = Task { @MainActor in
      let stopped = await driver.stop()
      if stopped.saved { return stopped }
      guard stopped.outcome == .stopped else { return stopped }
      guard await driver.endCollection() else {
        return DriverState(outcome: .stopped, start: stopped.start, end: stopped.end, failure: .captureFailed)
      }
      let saved = await driver.save()
      if saved.saved { driver.endSession() }
      return saved
    }
    entry.finishTask = task
    let result = await task.value
    entry.finishCompleted = true
    // No blind repeated finish after unknown save. Reconciliation uses actual driver state or a source-checked query.
    return result
  }
  private func observation(_ op: CaptureOperation, state: DriverState) -> WorkoutObservation {
    var state = state
    if case .notCreated = state.outcome, op.action != .start { state.outcome = .unknown }
    let start = state.start.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
    var end = state.end.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
    if let start, let boundary = end, boundary < start { end = nil }
    let window = try! CaptureWindow(start: start, end: end)
    if let value = try? WorkoutObservation(operationID: op.id, binding: op.binding, externalToken: op.externalToken, observedAt: Date(), outcome: state.outcome, window: window, failure: state.failure) { return value }
    return try! WorkoutObservation(operationID: op.id, binding: op.binding, externalToken: op.externalToken, observedAt: Date(), outcome: .unknown, window: window, failure: .captureFailed)
  }
}
