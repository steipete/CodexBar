import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStoreResetBoundaryRefreshTests {
    @Test
    func schedulesRefreshAtResetBoundaryBeforeNormalPoll() {
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
    func schedulesPromptRefreshWhenResetBoundaryAlreadyPassed() {
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
    func suppressesRepeatedPromptRefreshAfterAttemptedBoundary() {
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
    func inFlightBoundaryRefreshRemainsRetryable() {
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
    func inFlightBoundaryRefreshClearsFiredScheduleMarker() async {
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
    func ignoresResetBoundaryAfterNormalPoll() {
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
    func ignoresAlreadyRefreshedResetBoundary() {
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
    func usesEarliestBoundaryAcrossSecondaryAndExtraWindows() {
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
    func manualRefreshCadenceDoesNotScheduleBoundaryRefresh() {
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
