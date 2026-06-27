import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardModelCodexDegradedQuotaTests {
    @Test
    func `codex local token usage keeps remote quota unavailable error visible`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 721_966,
            sessionCostUSD: 1.081155,
            last30DaysTokens: 824_405_060,
            last30DaysCostUSD: 583.1287345,
            daily: [
                .init(
                    date: "2026-06-05",
                    inputTokens: 710_217,
                    outputTokens: 11749,
                    totalTokens: 721_966,
                    costUSD: 1.081155,
                    modelsUsed: ["gpt-5.5"],
                    modelBreakdowns: nil),
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
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: "Codex usage is temporarily unavailable. Try refreshing.",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.placeholder == nil)
        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText == "Codex usage is temporarily unavailable. Try refreshing.")
        #expect(model.usesStackedDetailLayout)
        #expect(model.tokenUsage?.sessionLine.contains("$1.08") == true)
        #expect(model.tokenUsage?.sessionLine.contains("tokens") == true)
        #expect(model.tokenUsage?.monthLine.contains("$583.13") == true)
        #expect(model.tokenUsage?.monthLine.contains("tokens") == true)
    }

    @Test
    func `codex remote quota unavailable error stays visible when token usage is hidden`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 721_966,
            sessionCostUSD: 1.081155,
            last30DaysTokens: 824_405_060,
            last30DaysCostUSD: 583.1287345,
            daily: [],
            updatedAt: now)
        let error = "Codex usage is temporarily unavailable. Try refreshing."

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
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
            lastError: error,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.placeholder == nil)
        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText == error)
        #expect(model.tokenUsage == nil)
    }

    @Test
    func `codex local token usage preserves limits unavailable placeholder`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 721_966,
            sessionCostUSD: 1.081155,
            last30DaysTokens: 824_405_060,
            last30DaysCostUSD: 583.1287345,
            daily: [],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.placeholder == "Limits not available")
        #expect(model.subtitleStyle == .info)
        #expect(model.tokenUsage != nil)
        #expect(model.usesStackedDetailLayout)
    }

    @Test
    func `codex local token usage preserves sign-in guidance`() throws {
        let model = try self.makeModel(
            tokenCostUsageEnabled: true,
            lastError: "Codex CLI is not signed in. Run `codex login --device-auth`, then refresh.")

        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText.contains("codex login"))
        #expect(model.tokenUsage != nil)
        #expect(model.usesStackedDetailLayout)
    }

    @Test
    func `codex local token usage preserves mapped transport error`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 721_966,
            sessionCostUSD: 1.081155,
            last30DaysTokens: 824_405_060,
            last30DaysCostUSD: 583.1287345,
            daily: [],
            updatedAt: now)
        let error = try #require(CodexUIErrorMapper.userFacingMessage("Codex connection failed: timed out."))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
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
            lastError: error,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.placeholder == nil)
        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText == "Codex usage is temporarily unavailable. Try refreshing.")
        #expect(model.tokenUsage?.sessionLine.contains("$1.08") == true)
    }

    @Test
    func `credits select stacked detail layout without quota metrics`() {
        let model = UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "user@example.com",
            subtitleText: "Not fetched yet",
            subtitleStyle: .info,
            planText: nil,
            metrics: [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: "$12.34 remaining",
            creditsRemaining: 12.34,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: "No usage yet",
            progressColor: .blue)

        #expect(model.usesStackedDetailLayout)
    }

    private func makeModel(
        tokenCostUsageEnabled: Bool,
        lastError: String?) throws -> UsageMenuCardView.Model
    {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 721_966,
            sessionCostUSD: 1.081155,
            last30DaysTokens: 824_405_060,
            last30DaysCostUSD: 583.1287345,
            daily: [],
            updatedAt: now)

        return UsageMenuCardView.Model.make(.init(
            provider: .codex,
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
            lastError: lastError,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: tokenCostUsageEnabled,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }
}
