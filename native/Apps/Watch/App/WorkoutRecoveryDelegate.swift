import AppIntegration
import WatchKit

final class WorkoutRecoveryDelegate: NSObject, WKApplicationDelegate {
    nonisolated func handleActiveWorkoutRecovery() {
        Task { @MainActor in AppRecoverySignal.shared.request() }
    }
}
