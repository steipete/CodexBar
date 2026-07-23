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
        extraRateWindows: [NamedRateWindow]? = nil,
        providerCost: ProviderCostSnapshot? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            updatedAt: Date())
    }

    @Test
    func `switcher prefers weekly allowance over primary session allowance`() {
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 65,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: session, secondary: weekly)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .claude,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 35)
    }

    @Test
    func `switcher uses most constrained named weekly allowance`() {
        let session = RateWindow(
            usedPercent: 10,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = self.makeSnapshot(
            primary: session,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-claude-weekly",
                    title: "Claude/GPT weekly",
                    window: RateWindow(
                        usedPercent: 75,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ])

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .antigravity,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 25)
    }

    @Test
    func `claude switcher ignores exhausted scoped weekly carve outs`() {
        let session = RateWindow(
            usedPercent: 77,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 61,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let sonnet = RateWindow(
            usedPercent: 100,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = self.makeSnapshot(
            primary: session,
            secondary: weekly,
            tertiary: sonnet,
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ])

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .claude,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 39)
    }

    @Test
    func `claude switcher keeps account weekly even when scoped carve out remains`() {
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 40,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = self.makeSnapshot(
            primary: session,
            secondary: weekly,
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 85,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ])

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .claude,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 60)
    }

    @Test
    func `switcher preserves provider quota when no weekly allowance exists`() {
        let monthly = RateWindow(
            usedPercent: 28,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: monthly, secondary: nil)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 72)
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
    func `mistral switcher uses monthly plan metric when selected`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .mistral,
            snapshot: snapshot,
            showUsed: true,
            preference: .monthlyPlan)

        #expect(percent == 42)
    }

    @Test
    func `mistral switcher ignores pay as you go balance primary`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$12.50"),
            secondary: nil,
            updatedAt: Date())

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .mistral,
            snapshot: snapshot,
            showUsed: true,
            preference: .automatic)

        #expect(percent == nil)
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
