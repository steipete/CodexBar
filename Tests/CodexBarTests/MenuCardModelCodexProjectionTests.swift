import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardModelCodexProjectionTests {
    @Test
    func `builds metrics using used percent when enabled`() throws {
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
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: 73,
            codeReviewLimit: RateWindow(
                usedPercent: 27,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: now)
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: dashboard,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: true,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Plus Plan"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.first?.title == "Session")
        #expect(model.metrics.first?.percent == 22)
        #expect(model.metrics.first?.percentLabel.contains("used") == true)
        #expect(model.metrics.contains { $0.title == "Code review" && $0.percent == 27 })
    }

    @Test
    func `shows code review metric when dashboard present`() throws {
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
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: 73,
            codeReviewLimit: RateWindow(
                usedPercent: 27,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: now)
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: dashboard,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: true,
                dashboardRequiresLogin: false,
                now: now))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.contains { $0.title == "Code review" && $0.percent == 73 })
        let codeReviewMetric = model.metrics.first { $0.id == "code-review" }
        #expect(codeReviewMetric?.resetText?.contains("Resets") == true)
    }

    @Test
    func `uses semantic codex lanes when weekly duration drifts`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.com",
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 11040,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
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
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.id == "secondary")
        #expect(model.metrics.first?.title == "Weekly")
        #expect(model.metrics.first?.percent == 75)
    }

    @Test
    func `hides codex credits when disabled`() throws {
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
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: CreditsSnapshot(remaining: 12, events: [], updatedAt: now),
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
            codexProjection: codexProjection,
            credits: CreditsSnapshot(remaining: 12, events: [], updatedAt: now),
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.creditsText == nil)
    }
}
