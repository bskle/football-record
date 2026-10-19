import Foundation

/// First actual metadata callback owns readiness. A caller timeout never calls this gate.
@MainActor final class MetadataReadiness {
  private var received = false
  private(set) var confirmed = false
  func receive(success: Bool, terminal: Bool, startLocation: () -> Void, finishOriginal: () -> Void) {
    guard !received else { return }; received = true; confirmed = success
    guard success else { return }
    if terminal { finishOriginal() } else { startLocation() }
  }
}
