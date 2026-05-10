import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardQuotaWarningMarkerTests {
    @Test
    func `omits quota warning markers for disabled windows`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Plus Plan")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: now,
            identity: identity)
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
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            quotaWarningThresholds: [.session: [50], .weekly: []],
            now: now))

        #expect(model.metrics.count == 2)
        #expect(model.metrics.first?.warningMarkerPercents == [50])
        #expect(model.metrics[1].warningMarkerPercents.isEmpty)
    }
}
