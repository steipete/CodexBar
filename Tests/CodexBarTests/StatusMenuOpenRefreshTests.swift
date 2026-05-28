import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `store observation marks open menu stale without rebuilding during tracking`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 33,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .codex)

        for _ in 0..<20 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(rebuildCount == 0)
    }

    @Test
    func `explicit store actions refresh a visible open menu`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        let openedVersion = controller.menuVersions[key]

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `repeated explicit store actions coalesce to one open menu rebuild`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `plain open menu refresh preserves pending switcher hosted submenu cleanup`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageBreakdownChartID,
            provider: .codex)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        controller.refreshOpenMenuIfStillVisible(menu, provider: .codex)

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
    }
}
