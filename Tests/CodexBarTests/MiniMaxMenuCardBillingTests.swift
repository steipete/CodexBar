import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MiniMaxMenuCardBillingTests {
    @Test
    func `minimax usage summary renders cost inline dashboard when pricing is available`() throws {
        let now = Date()
        let summary = MiniMaxUsageSummary(
            totalDays: 77,
            totalTokenConsumed: "2.37B",
            usageRankingPercent: 3.8,
            activeDays: 60,
            currentConsecutiveDays: 31,
            lastUpdateTime: "07-02 20:00",
            dailyTokenUsage: [201_889, 2_800_317, 4_486_224, 88000],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-06-29",
                    totalInputToken: 200_395,
                    totalCacheReadToken: 172_249,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 1494,
                    totalToken: 201_889,
                    cacheHitPercent: 85.95,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "MiniMax-M3-512k",
                            inputToken: 200_395,
                            cacheReadToken: 172_249,
                            cacheCreateToken: 0,
                            outputToken: 1494,
                            totalToken: 374_138,
                            cacheHitPercent: 85.95),
                    ]),
                MiniMaxUsageSummaryDay(
                    date: "2026-06-30",
                    totalInputToken: 2_778_091,
                    totalCacheReadToken: 1_809_827,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 22226,
                    totalToken: 2_800_317,
                    cacheHitPercent: 65.15,
                    models: []),
                MiniMaxUsageSummaryDay(
                    date: "2026-07-01",
                    totalInputToken: 4_454_050,
                    totalCacheReadToken: 3_139_433,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 32174,
                    totalToken: 4_486_224,
                    cacheHitPercent: 70.48,
                    models: []),
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 86000,
                    totalCacheReadToken: 64000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 2500,
                    totalToken: 88000,
                    cacheHitPercent: 74.63,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "MiniMax-M3-512k",
                            inputToken: 86000,
                            cacheReadToken: 64000,
                            cacheCreateToken: 0,
                            outputToken: 2500,
                            totalToken: 88000,
                            cacheHitPercent: 74.6),
                    ]),
            ])
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: nil,
            billingSummary: nil,
            usageSummary: summary)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis[0].title == "Today")
        #expect(model.inlineUsageDashboard?.kpis[0].value == "$0.01")
        #expect(model.inlineUsageDashboard?.kpis[1].title == "30d cost")
        #expect(model.inlineUsageDashboard?.kpis[2].title == "07-02 20:00 usage")
        #expect(model.inlineUsageDashboard?.kpis[2].value == "88.00K")
        #expect(model.inlineUsageDashboard?.kpis[3].title == "7d tokens")
        #expect(model.inlineUsageDashboard?.kpis[3].value == "7.58M")
        #expect(model.inlineUsageDashboard?.kpis[4].title == "Cache hit")
        #expect(model.inlineUsageDashboard?.kpis[4].value == "74.63%")
        #expect(model.inlineUsageDashboard?.kpis[5].title == "30d tokens")
        #expect(model.inlineUsageDashboard?.kpis[5].value == "7.58M")
        #expect(
            model.inlineUsageDashboard?.detailLines.contains {
                $0.contains("Top model")
            } == true)
    }

    @Test
    func `minimax usage summary still renders token inline dashboard without priced models`() throws {
        let now = Date()
        let summary = MiniMaxUsageSummary(
            totalDays: 1,
            totalTokenConsumed: "1",
            usageRankingPercent: nil,
            activeDays: 1,
            currentConsecutiveDays: 1,
            lastUpdateTime: "07-02 20:00",
            dailyTokenUsage: [1],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 1,
                    totalCacheReadToken: 0,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 0,
                    totalToken: 1,
                    cacheHitPercent: 0,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "coding-plan-vlm",
                            inputToken: 1,
                            cacheReadToken: 0,
                            cacheCreateToken: 0,
                            outputToken: 0,
                            totalToken: 1,
                            cacheHitPercent: 0),
                    ]),
            ])
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: nil,
            billingSummary: nil,
            usageSummary: summary)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(summary.toCostUsageTokenSnapshot() == nil)
        #expect(model.inlineUsageDashboard?.kpis[0].title == "07-02 20:00 usage")
        #expect(model.inlineUsageDashboard?.kpis[0].value == "1")
    }

    @Test
    func `minimax usage summary KPIs format tokens to two decimal places`() throws {
        let now = Date()
        let summary = MiniMaxUsageSummary(
            totalDays: 77,
            totalTokenConsumed: "1.1B",
            usageRankingPercent: 3.8,
            activeDays: 60,
            currentConsecutiveDays: 31,
            lastUpdateTime: "07-02 21:00",
            dailyTokenUsage: [88000],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 86000,
                    totalCacheReadToken: 64000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 2500,
                    totalToken: 88000,
                    cacheHitPercent: 74.63,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "coding-plan-vlm",
                            inputToken: 86000,
                            cacheReadToken: 64000,
                            cacheCreateToken: 0,
                            outputToken: 2500,
                            totalToken: 88000,
                            cacheHitPercent: 74.63),
                    ]),
            ])
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: nil,
            billingSummary: nil,
            usageSummary: summary)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis[0].value == "88.00K")
        #expect(model.inlineUsageDashboard?.kpis[1].value == "88.00K")
        #expect(model.inlineUsageDashboard?.kpis[2].value == "74.63%")
        #expect(model.inlineUsageDashboard?.kpis[3].value == "88.00K")
    }

    @Test
    func `minimax billing history renders inline dashboard`() throws {
        let now = Date()
        let billing = MiniMaxBillingSummary(
            todayTokens: 1234,
            last30DaysTokens: 5678,
            todayCash: 1.5,
            last30DaysCash: 4.25,
            daily: [
                MiniMaxBillingDay(day: "2026-05-16", tokens: 1111, cash: 2.75),
                MiniMaxBillingDay(day: "2026-05-17", tokens: 1234, cash: 1.5),
            ],
            topMethods: [MiniMaxBillingBreakdown(name: "chat", tokens: 2345, cash: 4.25)],
            topModels: [MiniMaxBillingBreakdown(name: "MiniMax-M1", tokens: 2345, cash: 4.25)],
            updatedAt: now)
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "Today",
                    timeRange: "2026/05/17 00:00 - 2026/05/18 00:00",
                    usage: 2,
                    limit: 10,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
            ],
            billingSummary: billing)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.accessibilityLabel == "MiniMax 30 day token usage trend")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "1.2K")
        #expect(model.inlineUsageDashboard?.points.count == 2)
        #expect(model.usageNotes.contains("Last 30 days: 5.7K tokens"))

        let hiddenModel = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(hiddenModel.inlineUsageDashboard == nil)
        #expect(!hiddenModel.usageNotes.contains("Last 30 days: 5.7K tokens"))
    }
}
