import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct InlineCostHistoryDashboardLabelTests {
    @Test
    func `local cost history Today KPI uses current day session value`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 275,
            last30DaysCostUSD: 0.25,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
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

        #expect(model.inlineUsageDashboard?.kpis.first?.title == "Today")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$0.00")
        #expect(model.inlineUsageDashboard?.points.first?.accessibilityValue == "2023-11-15: $0.25")
    }

    @Test
    func `local cost history KPI titles preserve one day and dynamic windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2023-11-14",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 0.12,
                modelsUsed: ["claude-sonnet-4"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2023-11-15",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 0.25,
                modelsUsed: ["claude-opus-4"],
                modelBreakdowns: nil),
        ]

        func makeModel(historyDays: Int) -> UsageMenuCardView.Model {
            let tokenSnapshot = CostUsageTokenSnapshot(
                sessionTokens: 275,
                sessionCostUSD: 0.25,
                last30DaysTokens: 425,
                last30DaysCostUSD: 0.37,
                historyDays: historyDays,
                daily: daily,
                updatedAt: now)
            return UsageMenuCardView.Model.make(.init(
                provider: .claude,
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

        let oneDay = makeModel(historyDays: 1)
        #expect(oneDay.inlineUsageDashboard?.kpis[1].title == "Today")
        #expect(oneDay.inlineUsageDashboard?.kpis[2].title == "Today tokens")

        let sevenDays = makeModel(historyDays: 7)
        #expect(sevenDays.inlineUsageDashboard?.kpis[1].title == "Last 7 days Cost")
        #expect(sevenDays.inlineUsageDashboard?.kpis[2].title == "Last 7 days tokens")

        let thirtyDays = makeModel(historyDays: 30)
        #expect(thirtyDays.inlineUsageDashboard?.kpis[1].title == "30d cost")
        #expect(thirtyDays.inlineUsageDashboard?.kpis[2].title == "30d tokens")
    }

    @Test
    func `custom cost history KPI title keeps token label distinct`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            historyLabel: "This month",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
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

        #expect(model.inlineUsageDashboard?.kpis[1].title == "This month")
        #expect(model.inlineUsageDashboard?.kpis[2].title == "This month tokens")
    }

    @Test
    func `costHistoryInlineDashboard sets currencyCode from snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            currencyCode: "USD",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
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

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.currencyCode == "USD")
    }

    @Test
    func `token-only inline dashboard leaves currencyCode nil`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.zai])
        let modelUsage = ZaiModelUsageData(
            xTime: ["2023-11-17 00:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-test", tokensUsage: [123]),
            ])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            zaiUsage: ZaiUsageSnapshot(
                tokenLimit: nil,
                timeLimit: nil,
                planName: nil,
                modelUsage: modelUsage,
                updatedAt: now),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .zai,
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
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.currencyCode == nil)
    }
}
