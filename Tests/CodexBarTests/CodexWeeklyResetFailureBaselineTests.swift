import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `hard failure keeps trusted weekly baseline for later low observations`() async {
        let suite = "CodexWeeklyResetFailureBaselineTests-hard-failure"
        let email = "failure-baseline@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "failure-baseline-owner"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let boundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 73,
            weeklyReset: boundary,
            updatedAt: now.addingTimeInterval(-60))
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installFailingCodexProvider(
            on: store,
            error: TestRefreshError(message: "non-preservable failure"))

        await store.refreshProvider(.codex, allowDisabled: true)
        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastCodexUsagePublicationGuard?.accountKey == email)

        let primaryOnly = OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: 18,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: "Pro",
            updatedAt: now.addingTimeInterval(-40))
        await store.applyOpenAIDashboard(
            primaryOnly,
            targetEmail: email,
            allowCodexUsageBackfill: true)
        let primaryOnlyPublishedAt = store.snapshots[.codex]?.updatedAt
        #expect(primaryOnlyPublishedAt == primaryOnly.updatedAt)
        #expect(store.snapshots[.codex]?.secondary == nil)

        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: 0.2,
                weeklyReset: boundary,
                updatedAt: now.addingTimeInterval(-30))),
            .success(self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: 0.5,
                weeklyReset: boundary,
                updatedAt: now.addingTimeInterval(-20))),
        ])
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == primaryOnlyPublishedAt)
        #expect(store.snapshots[.codex]?.secondary == nil)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 73)
    }
}
