import Foundation

public struct OpenCodeGoUsageSnapshot: Sendable {
    public let isBalanceOnly: Bool
    public let hasWeeklyUsage: Bool
    public let hasMonthlyUsage: Bool
    public let rollingUsagePercent: Double
    public let weeklyUsagePercent: Double
    public let monthlyUsagePercent: Double
    public let rollingResetInSec: Int
    public let weeklyResetInSec: Int
    public let monthlyResetInSec: Int
    public private(set) var zenBalanceUSD: Double?
    public let renewsAt: Date?
    public private(set) var daily: [CostUsageDailyReport.Entry]
    public let updatedAt: Date

    public init(
        isBalanceOnly: Bool = false,
        hasWeeklyUsage: Bool = true,
        hasMonthlyUsage: Bool,
        rollingUsagePercent: Double,
        weeklyUsagePercent: Double,
        monthlyUsagePercent: Double,
        rollingResetInSec: Int,
        weeklyResetInSec: Int,
        monthlyResetInSec: Int,
        zenBalanceUSD: Double? = nil,
        renewsAt: Date? = nil,
        daily: [CostUsageDailyReport.Entry] = [],
        updatedAt: Date)
    {
        self.isBalanceOnly = isBalanceOnly
        self.hasWeeklyUsage = hasWeeklyUsage
        self.hasMonthlyUsage = hasMonthlyUsage
        self.rollingUsagePercent = rollingUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.monthlyUsagePercent = monthlyUsagePercent
        self.rollingResetInSec = rollingResetInSec
        self.weeklyResetInSec = weeklyResetInSec
        self.monthlyResetInSec = monthlyResetInSec
        self.zenBalanceUSD = zenBalanceUSD
        self.renewsAt = renewsAt
        self.daily = daily
        self.updatedAt = updatedAt
    }

    public static func zenBalanceOnly(balanceUSD: Double, updatedAt: Date) -> OpenCodeGoUsageSnapshot {
        OpenCodeGoUsageSnapshot(
            isBalanceOnly: true,
            hasWeeklyUsage: false,
            hasMonthlyUsage: false,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            monthlyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            monthlyResetInSec: 0,
            zenBalanceUSD: balanceUSD,
            updatedAt: updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        if self.isBalanceOnly {
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: self.providerCostSnapshot,
                opencodegoUsage: self,
                updatedAt: self.updatedAt,
                identity: nil)
        }

        let rollingReset = self.updatedAt.addingTimeInterval(TimeInterval(self.rollingResetInSec))
        let primary = RateWindow(
            usedPercent: self.rollingUsagePercent,
            windowMinutes: 5 * 60,
            resetsAt: rollingReset,
            resetDescription: nil)
        let secondary: RateWindow?
        if self.hasWeeklyUsage {
            let weeklyReset = self.updatedAt.addingTimeInterval(TimeInterval(self.weeklyResetInSec))
            secondary = RateWindow(
                usedPercent: self.weeklyUsagePercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil)
        } else {
            secondary = nil
        }
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

        var extraWindows: [NamedRateWindow]?
        if let renewsAt = self.renewsAt {
            let renewalWindow = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: renewsAt,
                resetDescription: nil)
            extraWindows = [NamedRateWindow(id: "renewal", title: "Renews", window: renewalWindow)]
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraWindows,
            providerCost: self.providerCostSnapshot,
            opencodegoUsage: self,
            updatedAt: self.updatedAt,
            identity: nil)
    }

    private var providerCostSnapshot: ProviderCostSnapshot? {
        self.zenBalanceUSD.map {
            ProviderCostSnapshot(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: self.updatedAt)
        }
    }

    public func withZenBalanceUSD(_ balance: Double?) -> OpenCodeGoUsageSnapshot {
        var copy = self
        copy.zenBalanceUSD = balance
        return copy
    }

    public func withDaily(_ daily: [CostUsageDailyReport.Entry]) -> OpenCodeGoUsageSnapshot {
        var copy = self
        copy.daily = daily
        return copy
    }

    /// Projects the local per-day cost buckets into the shared cost-history model so OpenCode Go
    /// can reuse the same daily usage chart as Codex/Claude instead of a bespoke view.
    public func toCostUsageTokenSnapshot(historyDays: Int = 30) -> CostUsageTokenSnapshot {
        CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: self.daily, summary: nil),
            now: self.updatedAt,
            historyDays: historyDays)
    }
}
