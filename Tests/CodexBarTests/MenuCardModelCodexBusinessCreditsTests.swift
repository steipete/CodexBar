import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardModelCodexBusinessCreditsTests {
    @Test
    func `codex business override card shows monthly credit instead of limits unavailable`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "biz@example.com",
            accountOrganization: "Team",
            loginMethod: "business")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 73,
                resetsAt: nil,
                updatedAt: now))
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "biz@example.com", plan: "business"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let monthly = try #require(model.metrics.first { $0.id == "monthly" })
        #expect(model.placeholder == nil)
        #expect(monthly.title == "Monthly credit limit")
        #expect(monthly.percent == 27)
        #expect(model.metrics.count == 1)
        #expect(model.subtitleStyle != .error)
    }

    @Test
    func `codex business override card hides monthly credit when optional credits are off`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "biz@example.com",
            accountOrganization: "Team",
            loginMethod: "business")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 73,
                resetsAt: nil,
                updatedAt: now))
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "biz@example.com", plan: "business"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.contains { $0.id == "monthly" } == false)
        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
    }
}
