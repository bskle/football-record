import Foundation
public enum SyncRetryPolicy {
    public static func delay(afterAttempts count: Int) -> TimeInterval {
        let values: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 120]
        return count >= 0 && count < values.count ? values[count] : 300
    }
}
