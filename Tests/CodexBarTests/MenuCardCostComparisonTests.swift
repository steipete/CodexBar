import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardCostComparisonTests {
    @Test
    func `cost section adds shorter periods from the same history snapshot`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 10,
            historyDays: 90,
            daily: [
                Self.entry(day: "2026-06-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-06-25", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-01", cost: 4, tokens: 400),
            ],
            updatedAt: Self.localNoon(year: 2026, month: 7, day: 1))

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .claude,
            enabled: true,
            comparisonPeriodsEnabled: true,
            snapshot: snapshot,
            error: nil))

        #expect(section.comparisonLines == [
            "Last 7 days: $6.00 · 600 tokens",
            "Last 30 days: $6.00 · 600 tokens",
        ])
    }

    @Test
    func `comparison periods remain opt in`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 1,
            last30DaysTokens: 1,
            last30DaysCostUSD: 1,
            historyDays: 90,
            daily: [],
            updatedAt: Date())

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .claude,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))
        #expect(section.comparisonLines.isEmpty)
    }

    @Test
    func `inline dashboard shows enabled comparison periods`() throws {
        let now = Date(timeIntervalSince1970: 1_783_123_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 10,
            historyDays: 90,
            daily: [
                Self.entry(day: "2026-06-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-06-25", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-01", cost: 4, tokens: 400),
            ],
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costComparisonPeriodsEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.detailLines.prefix(2) == [
            "Last 7 days: $4.00 · 400 tokens",
            "Last 30 days: $6.00 · 600 tokens",
        ])
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func localNoon(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
