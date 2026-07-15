import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardProviderRegressionTests {
    @Test
    func `menu card keeps positive sub percent usage visible`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "sub-percent",
            title: "Monthly",
            percent: 0.1,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(metric.percentLabel == "<1% used")
    }

    @Test
    func `elevenlabs progress color stays visible in light menus`() {
        #expect(UsageMenuCardView.Model.progressColor(for: .elevenlabs) == Color(nsColor: .labelColor))
    }

    @Test
    func `open router model shows daily and weekly key spend`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: 20,
            keyUsage: 0.5,
            keyUsageDaily: 0.12,
            keyUsageWeekly: 0.74,
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

        #expect(model.usageNotes == ["Today: $0.12 · This week: $0.74"])
    }

    @Test
    func `ollama api key model explains browser session quota requirement`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.ollama])
        let snapshot = OllamaAPIUsageSnapshot(modelCount: 3, updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .ollama,
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
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == nil)
        #expect(model.planText == "API key")
        #expect(model.usageNotes == [
            "API key verified. Cloud quotas need browser cookies. Sign in to Ollama.",
        ])
    }

    @Test
    func `wayfinder model shows gateway routing savings and latency`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.wayfinder])
        let usage = WayfinderUsageSnapshot(
            gatewayStatus: "ok",
            offline: false,
            dryRun: true,
            missingKeys: [],
            modelCount: 2,
            requests: 14,
            tokens: 1028,
            realized: 0.003558,
            baseline: 0.009252,
            saved: 0.005694,
            savedPct: 61.5,
            priced: true,
            routes: [
                .init(name: "local", requests: 10, saved: 0.005694, tokens: 662),
                .init(name: "cloud", requests: 4, saved: 0, tokens: 366),
            ],
            avgDecisionMs: 0.0804,
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .wayfinder,
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

        #expect(model.usageNotes == [
            "Gateway: ok · 2 models · dry run",
            "Routed: local: 10 · cloud: 4",
            "Saved: <$0.01 · 61.5% vs highest-cost route",
            "Avg decision: 0.1 ms",
        ])
    }

    @Test
    func `copilot over quota usage keeps used percentage detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.copilot])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 115, windowMinutes: nil, resetsAt: nil, resetDescription: "115% used"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .copilot,
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

        let metric = try #require(model.metrics.first)
        #expect(metric.percent == 0)
        #expect(metric.percentLabel == "0% left")
        #expect(metric.detailLeftText == "115% used")
    }
}
