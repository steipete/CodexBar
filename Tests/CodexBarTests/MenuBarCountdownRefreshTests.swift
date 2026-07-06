import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarCountdownRefreshTests {
    @Test
    func `countdown refresh delay follows the next displayed minute boundary`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let delay = StatusItemController.menuBarCountdownRefreshDelay(
            resetDates: [
                now.addingTimeInterval(2 * 3600 + 15 * 60 + 30),
                now.addingTimeInterval(45),
            ],
            now: now)

        #expect(abs((delay ?? 0) - 30.05) < 0.001)
    }

    @Test
    func `countdown refresh ignores elapsed reset dates`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let delay = StatusItemController.menuBarCountdownRefreshDelay(
            resetDates: [now.addingTimeInterval(-1)],
            now: now)

        #expect(delay == nil)
    }

    @Test
    func `status item schedules countdown and exhausted lane refreshes`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "MenuBarCountdownRefreshTests-scheduling"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .resetTime
        settings.resetTimesShowAbsolute = false
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.resetTimesShowAbsolute = true
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(-1),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.resetTimesShowAbsolute = false
        store._setSnapshotForTesting(nil, provider: .codex)
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        controller.prepareForAppShutdown()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `merged highest usage observes reset for noncurrent Codex candidate`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "MenuBarCountdownRefreshTests-merged-highest"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsHighestUsage = true
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent
        settings.resetTimesShowAbsolute = true

        let registry = ProviderRegistry.shared
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(registry.metadata[.codex]),
            enabled: true)
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(registry.metadata[.claude]),
            enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        controller.updateIcons()
        #expect(controller.primaryProviderForUnifiedIcon() == .claude)
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }
}
