import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `stale data refresh suppresses icon attached closed menu preparation`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
            }
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Simulate a closed menu that was attached by an icon update but has never been opened.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu
        let key = ObjectIdentifier(menu)

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.prepareAttachedClosedMenusIfNeeded()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == nil)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }
}
