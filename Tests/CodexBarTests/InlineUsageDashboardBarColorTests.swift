import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct InlineUsageDashboardBarColorTests {
    /// The inline usage bars must be tinted with each provider's branding color (the same color
    /// used by the switcher tab and the detailed cost-history chart) rather than a fixed palette.
    @Test
    func `bar color matches branding for every provider`() {
        for provider in UsageProvider.allCases {
            let branding = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
            let expected = Color(red: branding.red, green: branding.green, blue: branding.blue)
            #expect(
                UsageMenuCardView.Model.inlineDashboardBarColor(for: provider) == expected,
                "inline bar color did not match branding for \(provider.rawValue)")
        }
    }

    /// The resolved dashboard model must actually carry the provider's branding color, and two
    /// providers with different branding must end up with different bar colors.
    @Test
    func `resolved dashboard carries provider branding color`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2023-11-14",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 0.12,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2023-11-15",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 0.25,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: nil),
        ]

        func makeModel(provider: UsageProvider) throws -> UsageMenuCardView.Model {
            let metadata = try #require(ProviderDefaults.metadata[provider])
            let tokenSnapshot = CostUsageTokenSnapshot(
                sessionTokens: 275,
                sessionCostUSD: 0.25,
                last30DaysTokens: 425,
                last30DaysCostUSD: 0.37,
                historyDays: 30,
                daily: daily,
                updatedAt: now)
            return UsageMenuCardView.Model.make(.init(
                provider: provider,
                metadata: metadata,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: tokenSnapshot,
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

        let codex = try makeModel(provider: .codex)
        let claude = try makeModel(provider: .claude)

        #expect(codex.inlineUsageDashboard?.barColor
            == UsageMenuCardView.Model.inlineDashboardBarColor(for: .codex))
        #expect(claude.inlineUsageDashboard?.barColor
            == UsageMenuCardView.Model.inlineDashboardBarColor(for: .claude))
        #expect(codex.inlineUsageDashboard?.barColor != claude.inlineUsageDashboard?.barColor)
    }
}
