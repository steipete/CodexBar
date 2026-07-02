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
