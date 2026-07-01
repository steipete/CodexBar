import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetCreditsMenuCardTests {
    @Test
    func `reset credits render when optional usage is enabled`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [
                    CodexRateLimitResetCredit(
                        id: "reset-1",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now,
                        expiresAt: now.addingTimeInterval(86400),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                ],
                availableCount: 1,
                updatedAt: now),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let model = UsageMenuCardView.Model.make(Self.input(
            metadata: metadata,
            snapshot: usage,
            showOptionalUsage: true,
            now: now))

        #expect(model.codexResetCredits?.text == "1 available")
        #expect(model.codexResetCredits?.detailText == "Next expires in 1d")
        #expect(model.codexResetCredits?.helpText?.contains("available, in 1d (") == true)
        #expect(model.codexResetCredits?.creditToConsume?.id == "reset-1")
    }

    @Test
    func `reset credits plural count uses trimmed copy`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [
                    CodexRateLimitResetCredit(
                        id: "reset-1",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now,
                        expiresAt: now.addingTimeInterval(86400),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                    CodexRateLimitResetCredit(
                        id: "reset-2",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now,
                        expiresAt: now.addingTimeInterval(172_800),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                ],
                availableCount: 2,
                updatedAt: now),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let model = UsageMenuCardView.Model.make(Self.input(
            metadata: metadata,
            snapshot: usage,
            showOptionalUsage: true,
            now: now))

        #expect(model.codexResetCredits?.text == "2 available")
    }

    @Test
    func `reset credits exclude expired cached entries from count and action`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [
                    CodexRateLimitResetCredit(
                        id: "expired-reset",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now.addingTimeInterval(-172_800),
                        expiresAt: now.addingTimeInterval(-60),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                    CodexRateLimitResetCredit(
                        id: "current-reset",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now.addingTimeInterval(-86400),
                        expiresAt: now.addingTimeInterval(86400),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                ],
                availableCount: 2,
                updatedAt: now.addingTimeInterval(-120)),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let model = UsageMenuCardView.Model.make(Self.input(
            metadata: metadata,
            snapshot: usage,
            showOptionalUsage: true,
            now: now))

        #expect(model.codexResetCredits?.text == "1 available")
        #expect(model.codexResetCredits?.detailText == "Next expires in 1d")
        #expect(model.codexResetCredits?.creditToConsume?.id == "current-reset")
    }

    @Test
    func `reset credits hide with optional usage disabled`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [],
                availableCount: 2,
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(Self.input(
            metadata: metadata,
            snapshot: usage,
            showOptionalUsage: false,
            now: now))

        #expect(model.codexResetCredits == nil)
    }

    @Test
    func `split menu usage card omits reset credits when native reset item exists`() {
        let model = Self.modelWithResetCredits()

        let split = StatusItemController.splitMenuUsageSectionModels(
            model: model,
            layoutModel: model,
            hasNativeResetCreditsItem: true)
        #expect(split.model.codexResetCredits == nil)
        #expect(split.layoutModel.codexResetCredits == nil)

        let unsplit = StatusItemController.splitMenuUsageSectionModels(
            model: model,
            layoutModel: model,
            hasNativeResetCreditsItem: false)
        #expect(unsplit.model.codexResetCredits?.text == "1 available")
        #expect(unsplit.layoutModel.codexResetCredits?.text == "1 available")
    }

    @Test
    func `split reset credit only card has no usage section content`() {
        let model = Self.modelWithResetCredits(includeMetric: false)

        let split = StatusItemController.splitMenuUsageSectionModels(
            model: model,
            layoutModel: model,
            hasNativeResetCreditsItem: true)

        #expect(model.hasUsageContent)
        #expect(split.layoutModel.hasUsageContent == false)
    }

    private static func input(
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool,
        now: Date) -> UsageMenuCardView.Model.Input
    {
        UsageMenuCardView.Model.Input(
            provider: .codex,
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
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: false,
            now: now)
    }

    private static func modelWithResetCredits(includeMetric: Bool = true) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "",
            subtitleText: "Signed in",
            subtitleStyle: .info,
            planText: nil,
            metrics: includeMetric ? [
                .init(
                    id: "primary",
                    title: "5-hour limit",
                    percent: 25,
                    percentStyle: .left,
                    statusText: "25%",
                    resetText: nil,
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true),
            ] : [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            codexResetCredits: CodexResetCreditsPresentation(
                text: "1 available",
                detailText: "Next expires in 1d",
                helpText: nil,
                creditToConsume: nil),
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
