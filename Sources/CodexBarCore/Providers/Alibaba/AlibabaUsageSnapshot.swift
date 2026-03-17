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
    let sessionUsage: RateWindow

    /// Usage in the last 7 days (weekly window)
    let weeklyUsage: RateWindow

    /// Usage in the last 30 days (monthly window)
    let monthlyUsage: RateWindow

    /// When this snapshot was taken
    let updatedAt: Date

    /// Convert to CodexBar's standard UsageSnapshot format
    /// Note: UsageSnapshot supports primary (5h), secondary (7d), and tertiary (30d) windows.
    /// All three windows are forwarded to ensure downstream UI receives complete quota data.
    func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: sessionUsage,
            secondary: weeklyUsage,
            tertiary: monthlyUsage,
            updatedAt: updatedAt,
            identity: nil
        )
    }
}
