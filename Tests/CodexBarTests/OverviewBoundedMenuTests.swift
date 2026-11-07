import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OverviewBoundedMenuTests {
    private func controller(
        layout: MergedOverviewLayout,
        configure: (SettingsStore) -> Void = { _ in }) -> StatusItemController
    {
        let suite = "OverviewBoundedMenuTests-\(UUID().uuidString)"
        let settings = SettingsStore(
            userDefaults: UserDefaults(suiteName: suite)!,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        settings.mergedOverviewLayout = layout
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: [.claude, .codex].contains(provider))
        }
        configure(settings)
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
    }

    private func overflowingController() -> StatusItemController {
        self.controller(layout: .compact) { settings in
            settings.mergedOverviewAllAccounts = true
            settings.multiAccountMenuLayout = .stacked
            for index in 0..<14 {
                settings.addTokenAccount(provider: .claude, label: "Account \(index)", token: "fixture-\(index)")
            }
        }
    }

    @Test
    func `rows past the inline limit move to a submenu and the footer stays last`() throws {
        let controller = self.overflowingController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)

        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.filter { $0.hasPrefix("overviewRow-") }.count == StatusItemController.overviewInlineRowLimit)
        let overflow = try #require(menu.items.first { ($0.representedObject as? String) == "overviewOverflow" })
        #expect(overflow.submenu?.items.count == 3)
        #expect(menu.items.last?.title == L("Quit"))
    }

    @Test
    func `an overflow row opens its provider from the parent menu`() throws {
        let controller = self.overflowingController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let overflow = try #require(menu.items.first { ($0.representedObject as? String) == "overviewOverflow" })
        let child = try #require(overflow.submenu?.items.first)
        #expect(child.menu?.supermenu === menu)

        controller.selectOverviewProvider(child)

        #expect(controller.settings.mergedMenuLastSelectedWasOverview == false)
        #expect(controller.settings.selectedMenuProvider == .claude)
    }

    @Test
    func `selecting an overflow row rebuilds the root menu it opened from`() async throws {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh) }

        let controller = self.overflowingController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        controller.openMenus[ObjectIdentifier(menu)] = menu
        let overflow = try #require(menu.items.first { ($0.representedObject as? String) == "overviewOverflow" })
        let child = try #require(overflow.submenu?.items.first)

        var rebuilt: [NSMenu] = []
        controller._test_openMenuRebuildObserver = { rebuilt.append($0) }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.selectOverviewProvider(child)
        for _ in 0..<100 where rebuilt.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rebuilt.first === menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(!ids.contains("overviewOverflow"))
        #expect(!ids.contains { $0.hasPrefix("overviewRow-") })
    }

    /// A click that lands after AppKit collapsed the submenu reaches no row: the menus just close.
    @Test
    func `closing the overflow submenu without activating a row stays on Overview`() throws {
        let controller = self.overflowingController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        let providerBefore = controller.settings.selectedMenuProvider

        // Opening the root rebuilds it, so the submenu has to come from the opened menu.
        controller.menuWillOpen(menu)
        let overflow = try #require(menu.items.first { ($0.representedObject as? String) == "overviewOverflow" })
        let submenu = try #require(overflow.submenu)
        #expect(submenu.supermenu === menu)
        controller.menuWillOpen(submenu)
        controller.menuDidClose(submenu)
        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)

        #expect(controller.settings.mergedMenuLastSelectedWasOverview)
        #expect(controller.settings.selectedMenuProvider == providerBefore)
        #expect(menu.items.contains { ($0.representedObject as? String) == "overviewOverflow" })
    }

    @Test
    func `a short roster has no overflow row`() {
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        #expect(!menu.items.contains { ($0.representedObject as? String) == "overviewOverflow" })
    }
}
