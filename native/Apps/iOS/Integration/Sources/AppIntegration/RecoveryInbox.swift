import Foundation

/// One in-memory recovery signal, never a second current-match index or a new session.
@MainActor public final class RecoveryInbox {
  private var pending = false
  private var ready: (() -> Bool)?
  private var recover: (() async -> Void)?
  private var worker: Task<Void, Never>?
  private var workerID: UUID?
  private var detachment: Task<Void, Never>?
  public init() {}
  public func request() {
    guard detachment == nil else { return }
    pending = true; drain()
  }
  /// An active worker owns its callbacks until explicitly detached and joined.
  @discardableResult public func attach(isReady: @escaping () -> Bool, recover: @escaping () async -> Void) -> Bool {
    guard detachment == nil, worker == nil else { return false }
    self.ready = isReady; self.recover = recover; drain(); return true
  }
  /// Drops this context's queued signals and joins even cancellation-insensitive
  /// in-flight recovery. A replacement cannot attach until the join completes.
  public func detach() async {
    if let detachment { await detachment.value; return }
    pending = false; ready = nil; recover = nil
    let old = worker; old?.cancel()
    let join = Task<Void, Never> { await old?.value }
    detachment = join
    await join.value
    worker = nil; workerID = nil; detachment = nil
  }
  private func drain() {
    guard pending, worker == nil, detachment == nil, let ready, let recover else { return }
    let id = UUID(); workerID = id
    worker = Task { [weak self] in
      guard let self else { return }
      while pending {
        guard !Task.isCancelled else { break }
        guard ready() else { try? await Task.sleep(for: .milliseconds(100)); continue }
        pending = false
        await recover()
      }
      if workerID == id { worker = nil; workerID = nil }
    }
  }
}
