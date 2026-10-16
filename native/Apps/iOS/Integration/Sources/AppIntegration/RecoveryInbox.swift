import Foundation

/// One in-memory recovery signal, never a second current-match index or a new session.
@MainActor public final class RecoveryInbox {
  private var pending = false
  private var ready: (() -> Bool)?
  private var recover: (() async -> Void)?
  private var worker: Task<Void, Never>?
  public init() {}
  public func request() { pending = true; drain() }
  public func attach(isReady: @escaping () -> Bool, recover: @escaping () async -> Void) {
    self.ready = isReady; self.recover = recover; drain()
  }
  private func drain() {
    guard pending, worker == nil, ready != nil, recover != nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      while pending {
        guard !Task.isCancelled else { break }
        guard ready?() == true else { try? await Task.sleep(for: .milliseconds(100)); continue }
        pending = false
        await recover?()
      }
      worker = nil
    }
  }
}
