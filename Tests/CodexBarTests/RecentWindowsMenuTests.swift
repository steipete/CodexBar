import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct RecentWindowsMenuTests {
    private func makeController(suiteName: String) -> StatusItemController {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar.system)
    }

    private func dashboard(windows: [InlineUsageDashboardModel.QuotaWindow]) -> InlineUsageDashboardModel {
        var model = InlineUsageDashboardModel(
            accessibilityLabel: "Cost",
            valueStyle: .currencyUSD,
            kpis: [],
            points: [],
            detailLines: [])
        model.quotaWindows = windows
        return model
    }

    @Test
    func `recent windows appear as a titled submenu row`() throws {
        let controller = self.makeController(suiteName: "RecentWindowsMenuTests-row")
        let menu = NSMenu()
        let windows: [InlineUsageDashboardModel.QuotaWindow] = [
            .init(id: "current", title: "Current window", range: "Sep 20 – Sep 27", value: "$10.00 · 1K"),
            .init(id: "previous", title: "Previous window", range: "Sep 13 – Sep 20", value: "$4.00 · 400"),
        ]

        let added = controller.addRecentWindowsMenuItemIfNeeded(
            to: menu,
            dashboard: self.dashboard(windows: windows),
            width: 310)

        #expect(added)
        let item = try #require(menu.items.first)
        #expect(item.title == L("Recent windows"))
        #expect(item.view == nil)
        #expect(item.isEnabled)
        #expect(item.representedObject as? String == StatusItemController.recentWindowsSubmenuID)
        #expect(item.submenu?.items.count == 1)
    }

    @Test
    func `recent windows row is omitted without quota windows`() {
        let controller = self.makeController(suiteName: "RecentWindowsMenuTests-empty")
        let menu = NSMenu()

        #expect(!controller.addRecentWindowsMenuItemIfNeeded(
            to: menu,
            dashboard: self.dashboard(windows: []),
            width: 310))
        #expect(!controller.addRecentWindowsMenuItemIfNeeded(to: menu, dashboard: nil, width: 310))
        #expect(menu.items.isEmpty)
    }
}
