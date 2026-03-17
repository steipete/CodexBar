import Foundation

/// Usage snapshot for Alibaba Cloud Model Studio Coding Plan
struct AlibabaUsageSnapshot {
    /// Plan name (e.g., "Lite Basic Plan", "Pro")
    let plan: String

    /// Plan status (e.g., "Taking Effect", "Expired")
    let status: String

    /// Remaining days text (e.g., "17days")
    let remainingDays: String

    /// Usage in the last 5 hours (session window)
    let sessionUsage: UsageWindow

    /// Usage in the last 7 days (weekly window)
    let weeklyUsage: UsageWindow

    /// Usage in the last 30 days (monthly window)
    let monthlyUsage: UsageWindow

    /// When this snapshot was taken
    let updatedAt: Date

    /// Convert to CodexBar's standard UsageSnapshot format
    /// Note: UsageSnapshot only supports primary (5h) and secondary (7d) windows.
    /// monthlyUsage (30d) is collected but cannot be forwarded to the shared model.
    func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: sessionUsage,
            secondary: weeklyUsage,
            updatedAt: updatedAt,
            identity: nil
        )
    }
}

/// Represents a usage window with percentage and reset time
struct UsageWindow {
    /// Percentage of quota used (0.0 to 100.0)
    let usedPercent: Double

    /// Window duration in minutes
    let windowMinutes: Int

    /// When the window resets
    let resetsAt: Date

    /// Human-readable reset description
    let resetDescription: String

    /// Calculate remaining percentage
    var remainingPercent: Double {
        max(0, 100.0 - usedPercent)
    }

    /// Calculate time until reset
    var timeUntilReset: TimeInterval {
        resetsAt.timeIntervalSince(Date())
    }

    /// Check if usage is critical (>90%)
    var isCritical: Bool {
        usedPercent >= 90.0
    }

    /// Check if usage is warning (>50%)
    var isWarning: Bool {
        usedPercent >= 50.0 && usedPercent < 90.0
    }
}
