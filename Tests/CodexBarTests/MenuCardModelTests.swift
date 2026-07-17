import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct OverviewMenuCardVisibilityTests {
    @Test
    func `overview hides cards that only contain an error`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: "No Cursor session found.",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))

        #expect(model.isOverviewErrorOnly)
    }

    @Test
    func `overview keeps cards with graceful unavailable placeholders`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: "pro"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))

        #expect(model.placeholder == "Limits not available")
        #expect(!model.isOverviewErrorOnly)
    }

    @Test
    func `claude subscription-only quota keeps local cost content`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 4200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 42000,
            last30DaysCostUSD: 12.50,
            daily: [],
            updatedAt: now)
        let quotaError = ClaudeStatusProbeError.parseFailed(
            ClaudeStatusProbe.subscriptionQuotaUnavailableDescription).localizedDescription
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: quotaError,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            tokenCostMenuSectionEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.placeholder == "Limits not available")
        #expect(model.subtitleStyle == .info)
        #expect(model.tokenUsage != nil)
        #expect(model.metrics.isEmpty)
        #expect(!model.isOverviewErrorOnly)
    }
}

struct ProviderInlineDashboardModelTests {
    @Test
    func `kimi model orders rate limit before weekly quota`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.kimi])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 18.3,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
                resetDescription: "375/2048 requests"),
            secondary: RateWindow(
                usedPercent: 9.5,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: "Rate: 19/200 per 5 hours"),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kimi,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.id) == ["secondary", "primary"])
        #expect(model.metrics.map(\.title) == ["Rate Limit", "Weekly"])
    }

    @Test
    func `openrouter period usage gets inline dashboard`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let usage = OpenRouterUsageSnapshot(
            totalCredits: 100,
            totalUsage: 40,
            balance: 60,
            usedPercent: 40,
            keyDataFetched: true,
            keyLimit: 25,
            keyUsage: 10,
            keyUsageDaily: 1.25,
            keyUsageWeekly: 7.5,
            keyUsageMonthly: 18.75,
            rateLimit: OpenRouterRateLimit(requests: 100, interval: "10s"),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
            metadata: metadata,
            snapshot: usage.toUsageSnapshot(),
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$60.00")
        #expect(model.inlineUsageDashboard?.points.map(\.label) == ["Today", "Week", "Month"])
        #expect(model.inlineUsageDashboard?.detailLines.contains("Rate limit: 100 / 10s") == true)
    }

    @Test
    func `local cost history gets inline dashboard`() throws {
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
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "claude-sonnet-4",
                        costUSD: 0.12,
                        totalTokens: 150),
                ]),
            CostUsageDailyReport.Entry(
                date: "2023-11-15",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 0.25,
                modelsUsed: ["claude-opus-4"],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "claude-opus-4",
                        costUSD: 0.25,
                        totalTokens: 275),
                ]),
        ]
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            daily: daily,
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
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

        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$0.25")
        #expect(model.inlineUsageDashboard?.points.count == 2)
        #expect(model.inlineUsageDashboard?.detailLines.contains { $0.contains("claude-opus-4") } == true)
        #expect(model.tokenUsage?.sessionLine.contains("$0.25") == true)
        #expect(model.tokenUsage?.monthLine.contains("$0.37") == true)
    }

    @Test
    func `mistral daily buckets get inline dashboard`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.5,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 100,
            totalOutputTokens: 50,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: 1.5,
                    inputTokens: 100,
                    cachedTokens: 0,
                    outputTokens: 50,
                    models: [
                        MistralDailyUsageBucket.ModelBreakdown(
                            name: "mistral-large",
                            cost: 1.5,
                            inputTokens: 100,
                            cachedTokens: 0,
                            outputTokens: 50),
                    ]),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot.toUsageSnapshot(),
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
            tokenCostUsageEnabled: false,
            tokenCostInlineDashboardEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.first?.value == "€1.50")
        #expect(model.inlineUsageDashboard?.points.first?.accessibilityValue == "2023-11-14: €1.50")
        #expect(model.inlineUsageDashboard?.detailLines.contains("Top model: mistral-large") == true)
    }

    @Test
    func `mistral billing usage can show cost card summary`() throws {
        let formatter = ISO8601DateFormatter()
        let monthStart = try #require(formatter.date(from: "2023-11-01T00:00:00Z"))
        let monthEnd = try #require(formatter.date(from: "2023-11-30T23:59:59Z"))
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.5,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 100,
            totalOutputTokens: 50,
            totalCachedTokens: 25,
            modelCount: 1,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: 1.5,
                    inputTokens: 100,
                    cachedTokens: 25,
                    outputTokens: 50,
                    models: [
                        MistralDailyUsageBucket.ModelBreakdown(
                            name: "mistral-large",
                            cost: 1.5,
                            inputTokens: 100,
                            cachedTokens: 25,
                            outputTokens: 50),
                    ]),
            ],
            startDate: monthStart,
            endDate: monthEnd,
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot.toCostUsageTokenSnapshot(historyDays: 30),
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

        #expect(ProviderDescriptorRegistry.descriptor(for: .mistral).tokenCost.supportsTokenCost)
        #expect(model.tokenUsage?.sessionLine == "Latest billing day (Nov 14): €1.50 · 175 tokens")
        #expect(model.tokenUsage?.monthLine == "This month: €1.50 · 175 tokens")
        #expect(model.tokenUsage?.hintLine == "Reported by Mistral billing usage.")
    }

    @Test
    func `zai hourly usage gets inline dashboard`() throws {
        let now = try #require(Self.zaiDate("2023-11-15 12:00"))
        let metadata = try #require(ProviderDefaults.metadata[.zai])
        let usage = ZaiUsageSnapshot(
            tokenLimit: nil,
            timeLimit: nil,
            planName: "Pro",
            modelUsage: ZaiModelUsageData(
                xTime: ["2023-11-14 12:00", "2023-11-15 12:00"],
                modelDataList: [
                    ZaiModelDataItem(modelName: "glm-4.5", tokensUsage: [100, 200]),
                ]),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .zai,
            metadata: metadata,
            snapshot: usage.toUsageSnapshot(),
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.first?.value == "300")
        #expect(model.inlineUsageDashboard?.points.map(\.label) == ["12", "12"])
        #expect(Set(model.inlineUsageDashboard?.points.map(\.id) ?? []).count == 2)
        #expect(model.inlineUsageDashboard?.detailLines.contains("Top model: glm-4.5") == true)
    }

    private static func zaiDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }
}

struct FactoryMenuCardModelTests {
    @Test
    func `factory token rate billing uses time window labels`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.factory])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .factory,
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

        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly", "Monthly"])
    }

    @Test
    func `factory legacy billing keeps pool labels`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.factory])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .factory,
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

        #expect(model.metrics.map(\.title) == ["Standard", "Premium"])
    }

    @Test
    func `factory extra usage balance renders as optional balance`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.factory])

        let visible = UsageMenuCardView.Model.make(.init(
            provider: .factory,
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
        #expect(visible.providerCost?.title == "Extra usage")
        #expect(visible.providerCost?.spendLine == "Balance: $25.00")
        #expect(visible.providerCost?.percentUsed == nil)
        #expect(visible.providerCost?.percentLine == nil)

        let hidden = UsageMenuCardView.Model.make(.init(
            provider: .factory,
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
        #expect(hidden.providerCost == nil)
    }
}

struct MiniMaxMenuCardModelTests {
    @Test
    func `minimax service metrics use codex aligned quota copy`() throws {
        let now = Date()
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
                    windowType: "5 hours",
                    timeRange: "10:00-15:00(UTC+8)",
                    usage: 2,
                    limit: 10,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let used = UsageMenuCardView.Model.make(.init(
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

        #expect(used.metrics.first?.title == "Text Generation")
        #expect(used.metrics.first?.detailLeftText == "Usage: 2 / 10")
        #expect(used.metrics.first?.detailRightText == nil)
        #expect(used.metrics.first?.detailText == nil)
        #expect(used.metrics.first?.percent == 20)
        #expect(used.metrics.first?.cardStyle == false)
    }

    @Test
    func `text generation badge uses real window type when multiple windows exist`() throws {
        let now = Date()
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
                    timeRange: "2026/05/16 00:00 - 2026/05/17 00:00",
                    usage: 2,
                    limit: 10,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "Weekly",
                    timeRange: "05/11 00:00 - 05/18 00:00(UTC+8)",
                    usage: 20,
                    limit: 100,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(7200),
                    resetDescription: "Resets in 2 hours"),
            ])
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

        #expect(model.metrics.count == 2)
        #expect(model.metrics[0].title == "Text Generation · Today")
        #expect(model.metrics[1].title == "Text Generation · Weekly")
    }

    @Test
    func `minimax token plan model shows weekly quota and points balance`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "Token Plan · TokenPlanPlus-年度会员",
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
                    windowType: "5 hours",
                    timeRange: "10:00-15:00(UTC+8)",
                    usage: 4,
                    limit: 100,
                    percent: 4,
                    resetsAt: now.addingTimeInterval(4 * 3600),
                    resetDescription: "Resets in 4 hours"),
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "Weekly",
                    timeRange: "06/01 00:00 - 06/08 00:00(UTC+8)",
                    usage: 1,
                    limit: 100,
                    percent: 1,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3600),
                    resetDescription: "Resets in 6 days"),
            ],
            pointsBalance: 14000,
            subscriptionRenewsAt: Date(timeIntervalSince1970: 1_810_569_600))
        let snapshot = minimax.toUsageSnapshot()
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

        #expect(model.planText == "Plus")
        #expect(model.metrics[0].title == "Text Generation · 5h")
        #expect(model.metrics[1].title == "Text Generation · Weekly")
        #expect(model.metrics[0].detailLeftText == "Usage: 4 / 100")
        #expect(model.metrics[1].detailLeftText == "Usage: 1 / 100")
        #expect(model.metrics[0].detailRightText == nil)
        #expect(model.metrics[1].detailRightText == nil)
        #expect(model.metrics[0].detailText == nil)
        #expect(model.metrics[1].detailText == nil)
        #expect(model.metrics[0].cardStyle == false)
        #expect(model.metrics[1].cardStyle == false)
        #expect(model.providerCost?.title == "Credits")
        #expect(model.providerCost?.spendLine == "Balance: 14000")
        #expect(model.usageNotes == [String(format: L("Renews: %@"), minimaxRenewDate(1_810_569_600))])
    }
}

struct ClaudeMenuCardCostTests {
    @Test
    func `claude extra usage labels monthly denominator as cap`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                updatedAt: now),
            updatedAt: now,
            identity: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.spendLine == "Monthly cap: $5.00 / $20.00")
    }
}

struct MenuCardModelTests {
    @Test
    func `builds metrics using remaining percent`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.com",
            accountOrganization: nil,
            loginMethod: "Plus Plan")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(6000),
                resetDescription: nil),
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let updatedSnap = try UsageSnapshot(
            primary: snapshot.primary,
            secondary: RateWindow(
                usedPercent: #require(snapshot.secondary?.usedPercent),
                windowMinutes: #require(snapshot.secondary?.windowMinutes),
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            tertiary: snapshot.tertiary,
            updatedAt: now,
            identity: identity)
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: updatedSnap,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: updatedSnap,
            codexProjection: codexProjection,
            credits: CreditsSnapshot(remaining: 12, events: [], updatedAt: now),
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Plus Plan"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            quotaWarningThresholds: [.session: [50, 20], .weekly: [25, 0]],
            now: now))

        #expect(model.providerName == "Codex")
        #expect(model.metrics.count == 2)
        #expect(model.metrics.first?.percent == 78)
        #expect(model.metrics.first?.warningMarkerPercents == [50, 20])
        #expect(model.metrics[1].warningMarkerPercents == [25])
        #expect(model.planText == "Plus")
        #expect(model.subtitleText.hasPrefix("Updated"))
        #expect(model.progressColor != Color.clear)
        #expect(model.metrics[1].resetText?.isEmpty == false)
    }

    @Test
    func `claude model hides weekly when unavailable`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Max")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 2,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "plus"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.title == "Session")
        #expect(model.planText == "Max")
    }

    @Test
    func `claude model includes routines bar when present`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Max")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 2,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 8,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 16,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7800),
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(
                        usedPercent: 7,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(9200),
                        resetDescription: nil)),
            ],
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "plus"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.title) == ["Session", "Weekly", "Sonnet", "Daily Routines"])
    }

    @Test
    func `shows error subtitle when present`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: "Probe failed for Codex",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))

        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText.contains("Probe failed"))
        #expect(model.placeholder == nil)
    }

    @Test
    func `cost section includes last30 days tokens`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 78.9,
            daily: [],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
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

        #expect(model.tokenUsage?.monthLine.contains("456") == true)
        #expect(model.tokenUsage?.monthLine.contains("tokens") == true)
        #expect(model.tokenUsage?.hintLine ==
            "Estimated from local Codex logs for the selected account.\n" +
            "not a subscription bill or plan value\n" +
            "Local usage × public API prices · not a subscription bill or plan value")
    }

    @Test
    func `claude model does not leak codex plan`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "plus"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))

        #expect(model.planText == nil)
        #expect(model.email.isEmpty)
    }

    @Test
    func `hides claude extra usage when disabled`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "claude@example.com",
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(used: 12, limit: 200, currencyCode: "USD", updatedAt: now),
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.claude])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost == nil)
    }

    @Test
    @MainActor
    func `open router model uses API key quota bar and quota detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: 20,
            keyUsage: 0.5,
            rateLimit: nil,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.creditsText == nil)
        #expect(model.metrics.count == 1)
        #expect(model.usageNotes.isEmpty)
        let metric = try #require(model.metrics.first)
        let popupTitle = UsageMenuCardView.popupMetricTitle(
            provider: .openrouter,
            metric: metric)
        #expect(popupTitle == "API key limit")
        #expect(metric.resetText == "$19.50/$20.00 left")
        #expect(metric.detailRightText == nil)
    }

    @Test
    func `open router model without key limit shows text only summary`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.creditsText == nil)
        #expect(model.placeholder == nil)
        #expect(model.usageNotes == ["No limit set for the API key"])
    }

    @Test
    func `open router model when key fetch unavailable shows unavailable note`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyDataFetched: false,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.usageNotes == ["API key limit unavailable right now"])
    }

    @Test
    func `hides email when personal info hidden`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.com",
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: "OpenAI dashboard signed in as codex@example.com.",
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: "OpenAI dashboard signed in as codex@example.com.",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))

        #expect(model.email.isEmpty)
        #expect(model.subtitleText.contains("codex@example.com") == false)
        #expect(model.creditsHintCopyText?.isEmpty == true)
        #expect(model.creditsHintText?.contains("codex@example.com") == false)
    }

    @Test
    func `kilo model splits pass and activity and shows fallback note`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "40/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Kilo Pass Pro · Auto top-up: visa"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            sourceLabel: "cli",
            kiloAutoMode: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.planText == "Kilo Pass Pro")
        #expect(model.usageNotes.contains("Auto top-up: visa"))
        #expect(model.usageNotes.contains("Using CLI fallback"))
    }

    @Test
    func `kilo model treats auto top up only login as activity`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Auto top-up: off"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.planText == nil)
        #expect(model.usageNotes.contains("Auto top-up: off"))
    }

    @Test
    func `kilo model does not show fallback note when not auto to CLI`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "40/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Kilo Pass Pro · Auto top-up: visa"))

        let apiModel = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            sourceLabel: "api",
            kiloAutoMode: true,
            hidePersonalInfo: false,
            now: now))

        let nonAutoModel = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            sourceLabel: "cli",
            kiloAutoMode: false,
            hidePersonalInfo: false,
            now: now))

        #expect(!apiModel.usageNotes.contains("Using CLI fallback"))
        #expect(!nonAutoModel.usageNotes.contains("Using CLI fallback"))
    }

    @Test
    func `kilo model shows primary detail when reset date missing`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "10/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Kilo Pass Pro"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText == nil)
        #expect(primary.detailText == "10/100 credits")
    }

    @Test
    func `kilo model keeps zero total edge state visible`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = KiloUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 0,
            creditsRemaining: 0,
            planName: "Kilo Pass Pro",
            autoTopUpEnabled: true,
            autoTopUpMethod: "visa",
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.percent == 0)
        #expect(primary.detailText == "0/0 credits")
        #expect(model.placeholder == nil)
    }

    @Test
    func `warp model shows primary detail when reset date missing`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .warp,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "10/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.warp])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .warp,
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

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText == nil)
        #expect(primary.detailText == "10/100 credits")
    }
}
