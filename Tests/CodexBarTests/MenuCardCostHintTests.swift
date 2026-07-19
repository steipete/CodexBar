import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardCostHintTests {
    @Test
    func `claude cost hint explains cache tokens and status line drift`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 78.9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-14",
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheReadTokens: 300,
                    cacheCreationTokens: 400,
                    totalTokens: 703,
                    costUSD: 1.23,
                    modelsUsed: ["claude-sonnet-4-6"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.tokenUsage?.hintLine?.contains("cache read/write tokens") == true)
        #expect(model.tokenUsage?.hintLine?.contains("Claude Code /status") == true)
    }

    @Test
    func `one day history label stays today`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 120,
            sessionCostUSD: 1.2,
            last30DaysTokens: 120,
            last30DaysCostUSD: 1.2,
            historyDays: 1,
            daily: [
                .init(
                    date: "2026-05-14",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120,
                    costUSD: 1.2,
                    modelsUsed: ["claude-sonnet-4-6"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.tokenUsage?.monthLine.hasPrefix("Today: ") == true)
    }

    @Test
    func `metadata free Mistral day uses billing label only for a valid bucket`() throws {
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-07-16T12:00:00Z"))
        let billingDay = try #require(formatter.date(from: "2026-07-10T00:00:00Z"))
        let metadata = try #require(ProviderDefaults.metadata[.mistral])
        let makeModel: (CostUsageTokenSnapshot) -> UsageMenuCardView.Model = { snapshot in
            UsageMenuCardView.Model.make(.init(
                provider: .mistral,
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
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
        }
        let valid = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1,
            currencyCode: "EUR",
            historyDays: 1,
            daily: [.init(
                date: "2026-07-10",
                inputTokens: 10,
                outputTokens: 0,
                totalTokens: 10,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: billingDay)
        let invalid = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "EUR",
            historyDays: 1,
            daily: [.init(
                date: "not-a-day",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)

        #expect(makeModel(valid).tokenUsage?.monthLine.hasPrefix("Latest billing day: ") == true)
        #expect(makeModel(invalid).tokenUsage?.monthLine.hasPrefix("Today: ") == true)
    }
}
