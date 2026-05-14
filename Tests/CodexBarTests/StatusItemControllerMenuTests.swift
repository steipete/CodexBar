import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct StatusItemControllerMenuTests {
    @MainActor
    private final class RecordingUpdater: UpdaterProviding {
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false
        let isAvailable = true
        let unavailableReason: String? = nil
        let updateStatus = UpdateStatus(isUpdateReady: true)
        var checkForUpdatesCount = 0
        var installUpdateCount = 0

        func checkForUpdates(_ sender: Any?) {
            _ = sender
            self.checkForUpdatesCount += 1
        }

        func installUpdate() {
            self.installUpdateCount += 1
        }
    }

    private func makeSnapshot(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        providerCost: ProviderCostSnapshot? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: providerCost,
            updatedAt: Date())
    }

    @Test
    func `cursor switcher falls back to on demand budget when plan exhausted and showing remaining`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let providerCost = ProviderCostSnapshot(
            used: 12,
            limit: 200,
            currencyCode: "USD",
            updatedAt: Date())
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary, providerCost: providerCost)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 94)
    }

    @Test
    func `cursor switcher uses primary when showing used`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: true)

        #expect(percent == 100)
    }

    @Test
    func `cursor switcher keeps primary when remaining is positive`() {
        let primary = RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 80)
    }

    @Test
    func `cursor switcher does not treat auto lane as extra remaining quota`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 0)
    }

    @Test
    func `perplexity switcher falls back after recurring credits are exhausted`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let tertiary = RateWindow(usedPercent: 24, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary, tertiary: tertiary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .perplexity,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 76)
    }

    @Test
    @MainActor
    func `menu card width stays at base width when menu accessories are present`() {
        let shortcutMenu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "r")
        shortcutMenu.addItem(refreshItem)
        #expect(ceil(shortcutMenu.size.width) < 310)

        let submenuMenu = NSMenu()
        let parentItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        parentItem.submenu = NSMenu(title: "Session")
        submenuMenu.addItem(parentItem)
        #expect(ceil(submenuMenu.size.width) < 310)
    }

    @Test
    @MainActor
    func `update menu action installs prepared update instead of checking again`() throws {
        let suite = "StatusItemControllerMenuTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let updater = RecordingUpdater()
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: updater,
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        controller.installUpdate()

        #expect(updater.installUpdateCount == 1)
        #expect(updater.checkForUpdatesCount == 0)
    }
}
