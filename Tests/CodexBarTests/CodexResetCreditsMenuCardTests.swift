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

        #expect(model.codexResetCreditsText == "1 available")
        #expect(model.codexResetCreditsDetailText == "Next expires in 1d")
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

        #expect(model.codexResetCreditsText == "2 available")
    }

    @Test
    func `reset credits render when optional usage is disabled`() throws {
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
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(Self.input(
            metadata: metadata,
            snapshot: usage,
            showOptionalUsage: false,
            now: now))

        #expect(model.codexResetCreditsText == "2 available")
        #expect(model.codexResetCreditsDetailText == "Next expires in 1d")
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
}
