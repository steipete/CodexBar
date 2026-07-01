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
    func `codex dashboard credit cost uses dashboard hint and omits token suffix`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 19.95,
            last30DaysTokens: nil,
            last30DaysCostUSD: 123.45,
            valueBasis: .codexDashboardCredits,
            daily: [
                .init(
                    date: "2026-06-19",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: 19.95,
                    modelsUsed: ["Exec"],
                    modelBreakdowns: [
                        .init(modelName: "Exec", costUSD: 18.29, totalTokens: nil),
                    ]),
            ],
            updatedAt: now)
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.tokenUsage?.sessionLine == "Est. total (Today): ≈ $19.95")
        #expect(model.tokenUsage?.monthLine == "Est. total (Last 30 days): ≈ $123.45")
        #expect(model.tokenUsage?.hintLine?.contains("25 credits = $1") == true)
    }

    @Test
    func `codex dashboard credit cost keeps local token suffix when merged`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 30_000_000,
            sessionCostUSD: 19.64,
            last30DaysTokens: 4_700_000_000,
            last30DaysCostUSD: 123.45,
            valueBasis: .codexDashboardCredits,
            daily: [
                .init(
                    date: "2026-06-19",
                    inputTokens: 20_000_000,
                    outputTokens: 10_000_000,
                    totalTokens: 30_000_000,
                    costUSD: 19.64,
                    modelsUsed: ["Exec", "Desktop App"],
                    modelBreakdowns: [
                        .init(modelName: "Exec", costUSD: 18.29, totalTokens: nil),
                    ]),
            ],
            updatedAt: now)
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.tokenUsage?.sessionLine == "Est. total (Today): ≈ $19.64 · 30M tokens")
        #expect(model.tokenUsage?.monthLine == "Est. total (Last 30 days): ≈ $123.45 · 4.7B tokens")
        #expect(model.tokenUsage?.hintLine?.contains("25 credits = $1") == true)
    }

    @Test
    func `codex local exec model name does not imply dashboard credit values`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1,
            daily: [
                .init(
                    date: "2026-06-19",
                    inputTokens: 5,
                    outputTokens: 5,
                    totalTokens: 10,
                    costUSD: 1,
                    modelsUsed: ["Exec"],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())

        #expect(UsageMenuCardView.Model.tokenCostString(1, snapshot: snapshot) == "$1.00")
        #expect(
            UsageMenuCardView.Model.tokenUsageHint(provider: .codex, snapshot: snapshot)?
                .contains("local Codex logs") == true)
    }
}
