import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStoreResetBoundaryRefreshTests {
    @Test
    func `schedules refresh at reset boundary before normal poll`() {
        let now = Date(timeIntervalSince1970: 1000)
        let resetsAt = now.addingTimeInterval(10 * 60)
        let snapshot = Self.snapshot(updatedAt: now, primaryResetsAt: resetsAt)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            now: now)

        #expect(refreshAt == resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds))
    }

    @Test
    func `schedules prompt refresh when reset boundary already passed`() {
        let now = Date(timeIntervalSince1970: 2000)
        let resetsAt = now.addingTimeInterval(-3 * 60)
        let snapshot = Self.snapshot(
            updatedAt: resetsAt.addingTimeInterval(-60),
            primaryResetsAt: resetsAt)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            now: now)

        #expect(refreshAt == now.addingTimeInterval(UsageStore.resetBoundaryRefreshMinimumDelaySeconds))
    }

    @Test
    func `suppresses repeated prompt refresh after attempted boundary`() {
        let now = Date(timeIntervalSince1970: 2500)
        let resetsAt = now.addingTimeInterval(-3 * 60)
        let boundaryRefreshAt = resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds)
        let snapshot = Self.snapshot(
            updatedAt: resetsAt.addingTimeInterval(-60),
            primaryResetsAt: resetsAt)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            attemptedBoundaryRefreshes: [boundaryRefreshAt],
            now: now)

        #expect(refreshAt == nil)
    }

    @Test
    func `in flight boundary refresh remains retryable`() {
        let now = Date(timeIntervalSince1970: 2750)
        let resetsAt = now.addingTimeInterval(-3 * 60)
        let boundaryRefreshAt = resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds)
        let snapshot = Self.snapshot(
            updatedAt: resetsAt.addingTimeInterval(-60),
            primaryResetsAt: resetsAt)

        #expect(UsageStore.shouldRecordResetBoundaryAttempt(isRefreshing: true) == false)
        #expect(UsageStore.shouldRecordResetBoundaryAttempt(isRefreshing: false) == true)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            attemptedBoundaryRefreshes: [],
            now: now)

        #expect(refreshAt == now.addingTimeInterval(UsageStore.resetBoundaryRefreshMinimumDelaySeconds))

        let suppressedAfterRecordedAttempt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            attemptedBoundaryRefreshes: [boundaryRefreshAt],
            now: now)

        #expect(suppressedAfterRecordedAttempt == nil)
    }

    @Test
    @MainActor
    func `in flight boundary refresh clears fired schedule marker`() async {
        let now = Date(timeIntervalSince1970: 2800)
        let resetsAt = now.addingTimeInterval(-3 * 60)
        let boundaryRefreshAt = resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds)
        let retryAt = now.addingTimeInterval(UsageStore.resetBoundaryRefreshMinimumDelaySeconds)
        let snapshot = Self.snapshot(
            updatedAt: resetsAt.addingTimeInterval(-60),
            primaryResetsAt: resetsAt)
        let settings = testSettingsStore(suiteName: "UsageStoreResetBoundaryRefreshTests-inflight-marker")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.snapshots[.codex] = snapshot
        store.isRefreshing = true
        store.scheduledResetBoundaryRefreshAt = retryAt

        await store.runResetBoundaryRefresh(boundaryRefreshAt: boundaryRefreshAt)

        #expect(store.scheduledResetBoundaryRefreshAt == nil)
        #expect(store.attemptedResetBoundaryRefreshes.isEmpty)

        store.isRefreshing = false
        store.scheduleResetBoundaryRefreshIfNeeded(normalRefreshInterval: 30 * 60, now: now)
        defer { store.cancelResetBoundaryRefresh() }

        #expect(store.scheduledResetBoundaryRefreshAt == retryAt)
    }

    @Test
    @MainActor
    func `boundary refresh records its attempt before waiting for forced enrichment`() async {
        let settings = testSettingsStore(suiteName: "UsageStoreResetBoundaryRefreshTests-waits-for-tail")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let tokenGate = BlockingForcedTokenRefresh()
        var providerRefreshes = 0
        var didObserveWait = false
        store._test_providerRefreshOverride = { _ in
            providerRefreshes += 1
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            guard force else { return }
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        store._test_forcedRefreshEnrichmentWaitObserver = {
            didObserveWait = true
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_forcedRefreshEnrichmentWaitObserver = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        #expect(await tokenGate.waitUntilStarted(count: 1))
        settings.costUsageEnabled = false

        let boundaryRefreshAt = Date(timeIntervalSince1970: 12345)
        let boundaryTask = Task { @MainActor in
            await store.runResetBoundaryRefresh(boundaryRefreshAt: boundaryRefreshAt)
        }
        for _ in 0..<100 where !didObserveWait {
            await Task.yield()
        }

        #expect(didObserveWait)
        #expect(providerRefreshes == 1)
        #expect(store.attemptedResetBoundaryRefreshes.contains(boundaryRefreshAt))

        await tokenGate.resumeNext()
        await boundaryTask.value

        #expect(providerRefreshes == 2)
        #expect(store.attemptedResetBoundaryRefreshes.contains(boundaryRefreshAt))
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    @MainActor
    func `boundary refresh does not reschedule unchanged stale snapshot`() async {
        let settings = testSettingsStore(suiteName: "UsageStoreResetBoundaryRefreshTests-no-duplicate")
        settings.refreshFrequency = .oneMinute
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let now = Date()
        let boundaryRefreshAt = now.addingTimeInterval(1)
        store.snapshots[.codex] = Self.snapshot(
            updatedAt: now.addingTimeInterval(-60),
            primaryResetsAt: boundaryRefreshAt.addingTimeInterval(-UsageStore.resetBoundaryRefreshGraceSeconds))
        var providerRefreshes = 0
        store._test_providerRefreshOverride = { _ in
            providerRefreshes += 1
        }
        defer {
            store._test_providerRefreshOverride = nil
            store.cancelResetBoundaryRefresh()
        }

        await store.runResetBoundaryRefresh(boundaryRefreshAt: boundaryRefreshAt)

        #expect(providerRefreshes == 1)
        #expect(store.attemptedResetBoundaryRefreshes.contains(boundaryRefreshAt))
        #expect(store.resetBoundaryRefreshTask == nil)
        #expect(store.scheduledResetBoundaryRefreshAt == nil)
    }

    @Test
    func `ignores reset boundary after normal poll`() {
        let now = Date(timeIntervalSince1970: 3000)
        let resetsAt = now.addingTimeInterval(40 * 60)
        let snapshot = Self.snapshot(updatedAt: now, primaryResetsAt: resetsAt)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            now: now)

        #expect(refreshAt == nil)
    }

    @Test
    func `ignores already refreshed reset boundary`() {
        let now = Date(timeIntervalSince1970: 4000)
        let resetsAt = now.addingTimeInterval(-3 * 60)
        let snapshot = Self.snapshot(updatedAt: now, primaryResetsAt: resetsAt)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            now: now)

        #expect(refreshAt == nil)
    }

    @Test
    func `uses earliest boundary across secondary and extra windows`() {
        let now = Date(timeIntervalSince1970: 5000)
        let secondaryResetsAt = now.addingTimeInterval(8 * 60)
        let extraResetsAt = now.addingTimeInterval(4 * 60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(20 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 80,
                windowMinutes: 10080,
                resetsAt: secondaryResetsAt,
                resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "extra",
                    title: "Extra",
                    window: RateWindow(
                        usedPercent: 50,
                        windowMinutes: 60,
                        resetsAt: extraResetsAt,
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: 30 * 60,
            now: now)

        #expect(refreshAt == extraResetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds))
    }

    @Test
    func `manual refresh cadence does not schedule boundary refresh`() {
        let now = Date(timeIntervalSince1970: 6000)
        let snapshot = Self.snapshot(
            updatedAt: now,
            primaryResetsAt: now.addingTimeInterval(10 * 60))

        let refreshAt = UsageStore.nextResetBoundaryRefreshDate(
            snapshots: [.codex: snapshot],
            normalRefreshInterval: nil,
            now: now)

        #expect(refreshAt == nil)
    }

    private static func snapshot(updatedAt: Date, primaryResetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: primaryResetsAt,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt)
    }
}
