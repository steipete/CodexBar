import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `dashboard cannot publish an unconfirmed first weekly low`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexDashboardWeeklyPublicationTests-first-low")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "dashboard-low@example.com",
            identity: .providerAccount(id: "dashboard-low-owner"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let store = self.makeUsageStore(settings: settings)
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: "dashboard-low@example.com",
                codeReviewRemainingPercent: nil,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                primaryLimit: nil,
                secondaryLimit: RateWindow(
                    usedPercent: 0.2,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                    resetDescription: nil),
                creditsRemaining: nil,
                accountPlan: "Pro",
                updatedAt: now),
            targetEmail: "dashboard-low@example.com",
            allowCodexUsageBackfill: true)

        #expect(store.openAIDashboard?.signedInEmail == "dashboard-low@example.com")
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
    }

    @Test
    func `dashboard publishes an ordinary first weekly observation`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexDashboardWeeklyPublicationTests-ordinary")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "dashboard-ordinary@example.com",
            identity: .providerAccount(id: "dashboard-ordinary-owner"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let store = self.makeUsageStore(settings: settings)
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: "dashboard-ordinary@example.com",
                codeReviewRemainingPercent: nil,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                primaryLimit: nil,
                secondaryLimit: RateWindow(
                    usedPercent: 28,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                    resetDescription: nil),
                creditsRemaining: nil,
                accountPlan: "Pro",
                updatedAt: now),
            targetEmail: "dashboard-ordinary@example.com",
            allowCodexUsageBackfill: true)

        #expect(store.openAIDashboard?.signedInEmail == "dashboard-ordinary@example.com")
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 28)
        #expect(store.lastSourceLabels[.codex] == "openai-web")
    }
}
