import Foundation

public struct OpenCodeGoUsageSnapshot: Sendable {
    public let hasMonthlyUsage: Bool
    public let rollingUsagePercent: Double
    public let weeklyUsagePercent: Double
    public let monthlyUsagePercent: Double
    public let rollingResetInSec: Int
    public let weeklyResetInSec: Int
    public let monthlyResetInSec: Int
    public let updatedAt: Date

    public init(
        hasMonthlyUsage: Bool,
        rollingUsagePercent: Double,
        weeklyUsagePercent: Double,
        monthlyUsagePercent: Double,
        rollingResetInSec: Int,
        weeklyResetInSec: Int,
        monthlyResetInSec: Int,
        updatedAt: Date)
    {
        self.hasMonthlyUsage = hasMonthlyUsage
        self.rollingUsagePercent = rollingUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.monthlyUsagePercent = monthlyUsagePercent
        self.rollingResetInSec = rollingResetInSec
        self.weeklyResetInSec = weeklyResetInSec
        self.monthlyResetInSec = monthlyResetInSec
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let rollingReset = self.updatedAt.addingTimeInterval(TimeInterval(self.rollingResetInSec))
        let weeklyReset = self.updatedAt.addingTimeInterval(TimeInterval(self.weeklyResetInSec))

        let primary = RateWindow(
            usedPercent: self.rollingUsagePercent,
            windowMinutes: 5 * 60,
            resetsAt: rollingReset,
            resetDescription: nil)
        let secondary = RateWindow(
            usedPercent: self.weeklyUsagePercent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: weeklyReset,
            resetDescription: nil)
        let tertiary: RateWindow?
        if self.hasMonthlyUsage {
            let monthlyReset = self.updatedAt.addingTimeInterval(TimeInterval(self.monthlyResetInSec))
            tertiary = RateWindow(
                usedPercent: self.monthlyUsagePercent,
                windowMinutes: 30 * 24 * 60,
                resetsAt: monthlyReset,
                resetDescription: nil)
        } else {
            tertiary = nil
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: self.updatedAt,
            identity: nil)
    }
}
