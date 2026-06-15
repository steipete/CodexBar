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
    func `status item schedules countdown refresh only for countdown reset dates`() {
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
    func `all metrics mode schedules countdown refresh for codex weekly reset`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "MenuBarCountdownRefreshTests-all-metrics"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .allMetrics
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
                secondary: RateWindow(
                    usedPercent: 55,
                    windowMinutes: 10080,
                    resetsAt: Date().addingTimeInterval(4 * 24 * 3600),
                    resetDescription: nil),
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

        settings.codexAllMetricsResetFormat = .weekdayMonthDay
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        settings.codexAllMetricsResetFormat = .compactCountdown
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.codexAllMetricsResetFormat = .monthDayTimeCompactCountdown
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.codexAllMetricsShowsReset = false
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        settings.codexAllMetricsShowsReset = true
        settings.codexAllMetricsResetFormat = .default
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

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

        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }
}
