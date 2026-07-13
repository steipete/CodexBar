import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test(arguments: StableEmailOnlyRefreshFailureCase.allCases)
    func `stable email only refresh failures preserve public account state`(
        failure: StableEmailOnlyRefreshFailureCase) async throws
    {
        let suite = "CodexWeeklyResetOwnerTransitionTests-stable-email-only-\(failure.rawValue)"
        let email = "stable-email-only@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .emailOnly(normalizedEmail: email))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 64,
            weeklyReset: now.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-60))
        let credits = self.credits(remaining: 17)
        let dashboard = self.dashboard(email: email, creditsRemaining: 17, usedPercent: 64)
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        store.credits = credits
        store.lastCreditsSnapshot = credits
        store.lastCreditsSnapshotAccountKey = email
        store.openAIDashboard = dashboard
        store.lastOpenAIDashboardSnapshot = dashboard
        let refreshGuard = try #require(store.lastCodexAccountScopedRefreshGuard)
        #expect(store.codexLimitResetOwnerKey(
            expectedGuard: refreshGuard,
            visibleAccounts: settings.codexVisibleAccountProjection.visibleAccounts) == nil)
        self.installFailingCodexProvider(on: store, error: failure.error)

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 64)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 64)
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.credits == credits)
        #expect(store.lastCreditsSnapshot == credits)
        #expect(store.openAIDashboard == dashboard)
        #expect(store.lastOpenAIDashboardSnapshot == dashboard)
    }

    @Test
    func `rejected reset confirmation never leaves the previous owner public`() async {
        let suite = "CodexWeeklyResetOwnerTransitionTests-rejected-confirmation"
        let email = "owner-transition@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "owner-before"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let previousReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let previous = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 82,
            weeklyReset: previousReset,
            updatedAt: now.addingTimeInterval(-60))
        let suspiciousLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.2,
            weeklyReset: previousReset.addingTimeInterval(7 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-20))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(suspiciousLow),
            .failure("confirmation unavailable", gated: true),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: previous)
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "owner-after"))
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        #expect(await loader.waitUntilCallCount(2))

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
        #expect(store.codexAccountSnapshots.isEmpty)

        await loader.release(call: 2)
        await refreshTask.value

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
    }
}

enum StableEmailOnlyRefreshFailureCase: String, CaseIterable, Sendable {
    case failure
    case cancellation

    var error: any Error {
        switch self {
        case .failure:
            TestRefreshError(message: "stable account refresh failed")
        case .cancellation:
            CancellationError()
        }
    }
}
