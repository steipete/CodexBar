import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `opening fresh menu does not schedule deferred refresh`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var providerRefreshCount = 0
        var refreshInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            refreshInteractions.append(ProviderInteractionContext.current)
            providerRefreshCount += 1
        }
        defer { store._test_providerRefreshOverride = nil }

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
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(providerRefreshCount == 0)
        #expect(!controller.deferredMenuInteractionRefreshPending)

        controller.menuDidClose(menu)
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(providerRefreshCount == 0)
        #expect(refreshInteractions.isEmpty)
    }

    @Test
    func `menu open with missing data defers automatic refresh until tracking ends`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setSnapshotForTesting(nil, provider: .codex)
        var providerRefreshCount = 0
        var refreshInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            refreshInteractions.append(ProviderInteractionContext.current)
            providerRefreshCount += 1
        }
        defer { store._test_providerRefreshOverride = nil }

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
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(providerRefreshCount == 0)
        #expect(controller.deferredMenuInteractionRefreshPending)

        controller.menuDidClose(menu)
        for _ in 0..<40 where providerRefreshCount == 0 {
            await Task.yield()
        }

        #expect(providerRefreshCount == 1)
        #expect(refreshInteractions == [.background])
        #expect(!controller.deferredMenuInteractionRefreshPending)
    }

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
        controller.menuRefreshEnabledOverrideForTesting = true

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
    func `closed merged menu defers rebuild until next open instead of pre-warming`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        // Background data-refresh tick (stale allowed): closed prep is skipped entirely, so
        // the closed merged menu must not be pre-warmed or marked deferred.
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 {
            await Task.yield()
        }
        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(!controller.closedMenusDeferredUntilNextOpen.contains(key))

        // A required (non-stale) invalidation must also leave the closed merged menu deferred.
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.closedMenusDeferredUntilNextOpen.contains(key))

        // The deferred merged menu is repopulated synchronously on the next open.
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(!controller.closedMenusDeferredUntilNextOpen.contains(key))
    }

    @Test
    func `data refresh invalidation does not rebuild closed non merged attached menu`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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
        // Use a non-merged attached menu: stale data-refresh invalidations should not pre-warm any
        // closed attached menu, while required invalidations still may prepare non-merged menus.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `required non merged closed menu preparation survives later data refresh invalidation`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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
        // Use a non-merged attached menu so this covers the delayed closed-menu rebuild path. Merged
        // menus are intentionally deferred until next open on current main (#1274).
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus()
        let requiredVersion = controller.latestRequiredMenuRebuildVersion
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(requiredVersion > (openedVersion ?? -1))
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed attached menu preparation waits for store refresh to finish`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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
        // Use a non-merged attached menu: the merged menu is intentionally never pre-warmed while
        // closed (#1274), so the in-flight-refresh prep machinery is exercised via the fallback menu.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.menuVersions[key] == openedVersion)

        store.isRefreshing = false
        controller.invalidateMenus()
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed attached menu preparation waits for token refresh to finish`() async {
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Use a non-merged attached menu: the merged menu is intentionally never pre-warmed while
        // closed (#1274), so the in-flight-refresh prep machinery is exercised via the fallback menu.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.tokenRefreshInFlight.insert(.codex)
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.menuVersions[key] == openedVersion)

        store.tokenRefreshInFlight.remove(.codex)
        controller.invalidateMenus()
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed menu rebuild cleanup runs when weak menu disappears`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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

        let key: ObjectIdentifier
        do {
            let menu = NSMenu()
            key = ObjectIdentifier(menu)
            controller.rebuildClosedMenuIfNeeded(menu)
            #expect(controller.closedMenuRebuildTasks[key] != nil)
            #expect(controller.closedMenuRebuildTokens[key] != nil)
        }

        for _ in 0..<40 where controller.closedMenuRebuildTasks[key] != nil {
            await Task.yield()
        }

        #expect(controller.closedMenuRebuildTasks[key] == nil)
        #expect(controller.closedMenuRebuildTokens[key] == nil)
    }

    @Test
    func `merged menu close defers stale rebuild until next open`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

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
        controller.mergedMenu = menu
        controller.statusItem.menu = menu
        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        controller.menuWillOpen(menu)

        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        controller.invalidateMenus(refreshOpenMenus: false)
        #expect(controller.menuNeedsRefresh(menu))

        controller.menuDidClose(menu)
        await self.waitUntilClosedMenuRebuildRemainsDeferred(controller, key: key, openedVersion: openedVersion)

        #expect(controller.closedMenuRebuildTasks[key] == nil)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `menu open keeps stale nonempty content while store refresh is active`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        let openedItemCount = menu.items.count

        store.isRefreshing = true
        defer { store.isRefreshing = false }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(menu.items.count == openedItemCount)
        #expect(controller.openMenus[key] === menu)
    }

    @Test
    func `menu open rebuilds stale content after privacy setting changes during refresh`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        defer { store.isRefreshing = false }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        settings.hidePersonalInfo = true
        controller.invalidateMenus()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(controller.menuVersions[key] != openedVersion)
    }

    @Test
    func `menu open keeps stale nonempty content while token refresh is active`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        let openedItemCount = menu.items.count

        store.tokenRefreshInFlight.insert(.codex)
        defer { store.tokenRefreshInFlight.remove(.codex) }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(menu.items.count == openedItemCount)
        #expect(controller.openMenus[key] === menu)
    }

    @Test
    func `explicit store actions defer visible parent menu rebuild`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(key))
    }

    @Test
    func `repeated explicit store actions keep parent rebuild deferred`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(key))
    }

    @Test
    func `explicit refresh keeps stale parent deferred after hosted submenu closes`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[menuKey]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[menuKey] == openedVersion)

        controller.menuDidClose(submenu)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[menuKey] == openedVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(menuKey))
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
        controller.menuRefreshEnabledOverrideForTesting = true

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

    @Test
    func `rapid switcher rebuild requests coalesce before populating open menu`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = 0
        defer { controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = nil }

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        var refreshGateEntries = 0
        var pendingRefreshGates: [CheckedContinuation<Void, Never>] = []
        func resumePendingRefreshGates() {
            let gates = pendingRefreshGates
            pendingRefreshGates.removeAll(keepingCapacity: true)
            for gate in gates {
                gate.resume()
            }
        }
        controller._test_openMenuRefreshYieldOverride = {
            refreshGateEntries += 1
            await withCheckedContinuation { continuation in
                pendingRefreshGates.append(continuation)
            }
        }
        defer {
            resumePendingRefreshGates()
            controller._test_openMenuRefreshYieldOverride = nil
        }

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        for _ in 0..<20 where refreshGateEntries == 0 {
            await Task.yield()
        }
        #expect(refreshGateEntries == 1)
        #expect(rebuildCount == 0)

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        resumePendingRefreshGates()
        for _ in 0..<20 where refreshGateEntries < 2 {
            await Task.yield()
        }
        #expect(refreshGateEntries == 2)
        #expect(rebuildCount == 0)
        resumePendingRefreshGates()

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(rebuildCount == 1)
    }

    @Test
    func `codex parent menu open defers stale OpenAI web refresh until tracking ends`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        var refreshInteractions: [ProviderInteraction] = []
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            refreshInteractions.append(ProviderInteractionContext.current)
            return try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await blocker.startedCount() == 0)
        #expect(controller.deferredOpenAIDashboardRefreshReason != nil)

        controller.menuDidClose(menu)
        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)
        #expect(refreshInteractions == [.background])

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `programmatic parent menu close schedules deferred OpenAI web refresh`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        #expect(controller.deferredOpenAIDashboardRefreshReason != nil)

        controller.forgetClosedMenu(menu)
        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `deferred OpenAI web refresh retries after active store refresh completes`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        store.isRefreshing = true
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        controller.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "parent menu open")
        controller.scheduleDeferredMenuInteractionRefreshIfNeeded()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await blocker.startedCount() == 0)
        #expect(controller.deferredOpenAIDashboardRefreshReason != nil)

        store.isRefreshing = false
        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `deferred OpenAI web refresh waits for deferred store refresh`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setSnapshotForTesting(nil, provider: .codex)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        let providerBlocker = BlockingStatusMenuProviderRefresh()
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            await providerBlocker.awaitRelease()
        }
        defer { store._test_providerRefreshOverride = nil }
        let dashboardBlocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await dashboardBlocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        await providerBlocker.waitUntilStarted()
        #expect(await dashboardBlocker.startedCount() == 0)

        await providerBlocker.resumeNext()
        await dashboardBlocker.waitUntilStarted(count: 1)
        #expect(await dashboardBlocker.startedCount() == 1)

        await dashboardBlocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `reopened menu keeps dashboard refresh deferred after store refresh`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setSnapshotForTesting(nil, provider: .codex)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        let providerBlocker = BlockingStatusMenuProviderRefresh()
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            await providerBlocker.awaitRelease()
        }
        defer { store._test_providerRefreshOverride = nil }
        let dashboardBlocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await dashboardBlocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)
        await providerBlocker.waitUntilStarted()

        let reopenedMenu = controller.makeMenu()
        controller.menuWillOpen(reopenedMenu)
        await providerBlocker.resumeNext()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await dashboardBlocker.startedCount() == 0)
        #expect(controller.deferredOpenAIDashboardRefreshReason != nil)

        controller.menuDidClose(reopenedMenu)
        await dashboardBlocker.waitUntilStarted(count: 1)
        #expect(await dashboardBlocker.startedCount() == 1)

        await dashboardBlocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `codex parent menu close refreshes recent dashboard cache with no chart history`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: Date())
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        StatusItemController.setDeferredMenuInteractionRefreshDelayForTesting(.zero)
        defer { StatusItemController.resetDeferredMenuInteractionRefreshDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await blocker.startedCount() == 0)

        controller.menuDidClose(menu)
        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: Date())))
    }

    @Test
    func `codex parent menu open throttles recent empty dashboard retry`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: now.addingTimeInterval(-120))
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        store.lastOpenAIDashboardAttemptAt = now.addingTimeInterval(-60)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await blocker.startedCount() == 0)
    }

    @Test
    func `credits history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.showOptionalCreditsAndExtraUsage = true
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: true)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: now)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: now)
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(self.menuItem(in: menu, id: "menuCardCredits") == nil)

        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now.addingTimeInterval(10))

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let creditsItem = try #require(self.menuItem(in: menu, id: "menuCardCredits"))
        #expect(
            creditsItem.submenu?.items.first?.representedObject as? String ==
                StatusItemController.creditsHistoryChartID)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `fresh dashboard history with same day count rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.showOptionalCreditsAndExtraUsage = true
        self.enableOnlyCodex(settings)

        let now = Date(timeIntervalSince1970: 100)
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: true)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: now)
        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now)
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        _ = try #require(self.menuItem(in: menu, id: "menuCardCredits"))

        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 99),
            ],
            updatedAt: now.addingTimeInterval(10))

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let creditsItem = try #require(self.menuItem(in: menu, id: "menuCardCredits"))
        #expect(creditsItem.submenu?.items.first?.representedObject as? String == StatusItemController
            .creditsHistoryChartID)
    }

    @Test
    func `token cost history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodex(settings)

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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)

        store._setTokenSnapshotForTesting(self.makeCodexTokenCostSnapshot(), provider: .codex)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `fresh token cost history with same day count rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 1.23,
                updatedAt: Date(timeIntervalSince1970: 100)),
            provider: .codex)
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))

        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 999,
                sessionCostUSD: 0.99,
                last30DaysTokens: 888,
                last30DaysCostUSD: 8.88,
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .codex)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
    }

    @Test
    func `plan utilization history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        let usageHistoryItem = try #require(self.menuItem(in: menu, id: "usageHistorySubmenu"))
        #expect(usageHistoryItem.submenu?.items.first?.representedObject as? String == StatusItemController
            .usageHistoryChartID)
        let openedRevision = store.planUtilizationHistoryRevision

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: self.makeCodexPlanUtilizationSnapshot(),
            now: Date())

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(store.planUtilizationHistoryRevision > openedRevision)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)
    }

    @Test
    func `dashboard attachment authorization arriving after open rebuilds parent menu after close`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now)
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(store.openAIDashboardAttachmentRevision == 0)

        store.openAIDashboardAttachmentAuthorized = true

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(store.openAIDashboardAttachmentRevision == 1)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func menuItem(in menu: NSMenu, id: String) -> NSMenuItem? {
        menu.items.first { ($0.representedObject as? String) == id }
    }

    private func waitUntilMenuVersionChanges(
        _ controller: StatusItemController,
        from version: Int?) async
    {
        for _ in 0..<20 where controller.menuContentVersion == version {
            await Task.yield()
        }
    }

    private func waitUntilOpenMenuStaysStale(
        _ controller: StatusItemController,
        key: ObjectIdentifier,
        after version: Int?) async
    {
        for _ in 0..<40 {
            guard controller.menuContentVersion != version else {
                await Task.yield()
                continue
            }
            guard controller.menuVersions[key] == version else {
                await Task.yield()
                continue
            }
            return
        }
    }

    private func closeMenuAndWaitUntilFresh(
        _ controller: StatusItemController,
        menu: NSMenu,
        key: ObjectIdentifier) async
    {
        controller.menuDidClose(menu)
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        if controller.menuVersions[key] != controller.menuContentVersion {
            controller.menuWillOpen(menu)
        }
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    private func waitUntilClosedMenuRebuildRemainsDeferred(
        _ controller: StatusItemController,
        key: ObjectIdentifier,
        openedVersion: Int?) async
    {
        for _ in 0..<40
            where controller.closedMenuRebuildTasks[key] != nil ||
            controller.menuVersions[key] != openedVersion
        {
            await Task.yield()
        }
    }

    private func makeOpenAIDashboard(
        dailyBreakdown: [OpenAIDashboardDailyBreakdown],
        updatedAt: Date) -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: dailyBreakdown,
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: updatedAt)
    }

    private func makeCodexTokenCostSnapshot(
        sessionTokens: Int = 123,
        sessionCostUSD: Double = 0.12,
        last30DaysTokens: Int = 456,
        last30DaysCostUSD: Double = 1.23,
        updatedAt: Date = Date()) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-24",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: sessionTokens,
                    costUSD: last30DaysCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }

    private func makeCodexPlanUtilizationSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 35,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(1800),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
    }
}

private actor BlockingStatusMenuProviderRefresh {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    func awaitRelease() async {
        self.started += 1
        self.resumeStartWaiters()
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.started > 0 { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().resume()
    }

    private func resumeStartWaiters() {
        let waiters = self.startWaiters
        self.startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
