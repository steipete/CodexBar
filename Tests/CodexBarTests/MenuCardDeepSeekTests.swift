import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardDeepSeekTests {
    private static func sampleDeepSeekSummary(now: Date = Date()) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 123,
            currentMonthTokens: 456,
            todayCost: 0.0123,
            currentMonthCost: 0.0456,
            requestCount: 7,
            currentMonthRequestCount: 8,
            topModel: "deepseek-chat",
            categoryBreakdown: [
                DeepSeekCategoryBreakdown(category: .promptCacheHitToken, tokens: 10, cost: 0.001),
                DeepSeekCategoryBreakdown(category: .promptCacheMissToken, tokens: 20, cost: 0.002),
                DeepSeekCategoryBreakdown(category: .responseToken, tokens: 30, cost: 0.003),
            ],
            daily: [
                DeepSeekDailyUsage(date: "2026-05-26", totalTokens: 456, cost: 0.0456, requestCount: 8),
            ],
            currency: "CNY",
            updatedAt: now)
    }

    private static func makeSnapshot(
        now: Date,
        usageSummary: DeepSeekUsageSummary? = nil,
        detailedUsageState: DeepSeekDetailedUsageState? = nil) -> UsageSnapshot
    {
        DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 9.32,
            grantedBalance: 0,
            toppedUpBalance: 9.32,
            usageSummary: usageSummary,
            detailedUsageState: detailedUsageState,
            updatedAt: now)
            .toUsageSnapshot()
    }

    @Test
    func `model shows balance as status text instead of percentage detail`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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
        #expect(primary.title == "Balance")
        #expect(primary.statusText == "$9.32 (Paid: $9.32 / Granted: $0.00)")
        #expect(primary.detailText == nil)
        #expect(primary.resetText == nil)
    }

    @Test
    func `model hides deepseek usage when extras are disabled despite cost summary enabled`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, usageSummary: Self.sampleDeepSeekSummary(now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes.isEmpty)
    }

    @Test
    func `model shows deepseek usage when cost summary and extras are enabled`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, usageSummary: Self.sampleDeepSeekSummary(now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        let details = try #require(model.providerDetails.first)
        #expect(details.chart?.title == "Daily tokens")
        #expect(details.chart?.points.map(\.value) == [456])
        #expect(details.rows.first { $0.label == "Today" }?.value == "¥0.0123 · 123 tokens")
        #expect(details.rows.first { $0.label == "This month" }?.value == "¥0.0456 · 456 tokens")
    }

    @Test
    func `model localizes deepseek usage details in simplified chinese`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, usageSummary: Self.sampleDeepSeekSummary(now: now))

        let model = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.make(.init(
                provider: .deepseek,
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
        }

        let details = try #require(model.providerDetails.first)
        #expect(details.title == "用量明细")
        #expect(details.rows.map(\.label) == [
            "今日",
            "本月",
            "请求",
            "最常用模型",
            "缓存命中输入",
            "缓存未命中输入",
            "输出",
        ])
        #expect(details.rows[0].value == "¥0.0123 · 123 token 用量")
        #expect(details.rows[1].value == "¥0.0456 · 456 token 用量")
        #expect(details.rows[3].value == "deepseek-chat")
        #expect(details.chart?.title == "每日 token")
        #expect(details.chart?.unit == "token")
    }

    @Test
    func `model localizes deepseek balance components in simplified chinese`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now)

        let model = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.make(.init(
                provider: .deepseek,
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
        }

        let balance = try #require(model.metrics.first)
        #expect(balance.statusText == "$9.32（付费：$9.32 / 赠送：$0.00）")
    }

    @Test
    func `model localizes deepseek balance fallback messages in simplified chinese`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(
                UsageMenuCardView.Model.localizedDeepSeekBalanceDescription(
                    "¥0.00 — add credits at platform.deepseek.com")
                    == "¥0.00 — 请前往 platform.deepseek.com 充值")
            #expect(
                UsageMenuCardView.Model.localizedDeepSeekBalanceDescription(
                    "Balance unavailable for API calls")
                    == "API 调用余额不可用")
        }
    }

    @Test
    func `model explains unavailable deepseek usage when cost summary is enabled`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes == ["Detailed usage unavailable."])
    }

    @Test
    func `model shows balance without stale deepseek usage while refreshing`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, usageSummary: Self.sampleDeepSeekSummary(now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: true,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes.isEmpty)
        let balance = try #require(model.metrics.first)
        #expect(balance.title == "Balance")
        #expect(balance.statusText == "$9.32 (Paid: $9.32 / Granted: $0.00)")
    }

    @Test
    func `model explains that detailed usage needs a platform session`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, detailedUsageState: .webSessionRequired)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes == ["Sign in to DeepSeek Platform in Chrome for detailed usage."])
    }

    @Test
    func `browser only sign in remains visible when cost summary is disabled`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = DeepSeekUsageSnapshot(
            hasBalance: false,
            isAvailable: false,
            currency: "USD",
            totalBalance: 0,
            grantedBalance: 0,
            toppedUpBalance: 0,
            detailedUsageState: .webSessionRequired,
            updatedAt: now)
            .toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        #expect(model.metrics.isEmpty)
        #expect(model.usageNotes == ["Sign in to DeepSeek Platform in Chrome for detailed usage."])
    }

    @Test
    func `model asks for a profile when multiple deepseek sessions are valid`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, detailedUsageState: .profileSelectionRequired)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes == ["Select a DeepSeek Chrome profile in Settings."])
    }

    @Test
    func `model hides deepseek usage when cost summary is disabled despite extras enabled`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])
        let snapshot = Self.makeSnapshot(now: now, usageSummary: Self.sampleDeepSeekSummary(now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes.isEmpty)
    }
}
