import Foundation

/// One waiter, two independent clocks: timeout releases the waiter but never invalidates the real work.
/// Unstructured work is intentional: a task group would wait forever for an uncooperative SDK callback.
private final class DeadlineResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value?, Never>?
  private var completed = false
  func install(_ c: CheckedContinuation<Value?, Never>) { lock.lock(); continuation = c; lock.unlock() }
  func resolve(_ value: Value?) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning: value)
  }
}
func withDeadline<Value: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async -> Value) async -> Value? {
  await withCheckedContinuation { c in
    let gate = DeadlineResult<Value>(); gate.install(c)
    Task { gate.resolve(await operation()) }
    Task { try? await Task.sleep(for: timeout); gate.resolve(nil) }
  }
}
/// Callback duplication and waiter timeout are deliberately independent. A late FIRST callback still owns the result.
final class FirstCallback: @unchecked Sendable {
  private let lock = NSLock()
  private var received = false
  func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !received else { return false }; received = true; return true }
}
