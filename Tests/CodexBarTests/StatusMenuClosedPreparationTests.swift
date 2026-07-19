import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
private final class ClosedMenuManualRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }
}

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
        for _ in 0..<20 {
            await Task.yield()
        }
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

    @Test
    func `stale refresh completion requeues required closed menu preparation blocked by refresh`() async {
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
        for _ in 0..<20 {
            await Task.yield()
        }
        let menu = controller.makeMenu()
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus()
        let requiredVersion = controller.latestRequiredMenuRebuildVersion
        store.isRefreshing = true
        for _ in 0..<40 where controller.closedMenuRebuildTasks[key] != nil {
            await Task.yield()
        }

        #expect(requiredVersion > (openedVersion ?? -1))
        #expect(controller.closedMenuRebuildTasks[key] == nil)
        #expect(controller.menuVersions[key] == openedVersion)

        store.isRefreshing = false
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `manual refresh completion requeues required closed menu preparation`() async throws {
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
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu
        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let initialVersion = controller.menuVersions[key]

        let gate = ClosedMenuManualRefreshGate()
        controller._test_manualRefreshOperation = { await gate.wait() }
        defer {
            gate.resume()
            controller._test_manualRefreshOperation = nil
        }
        controller.refreshNow()
        let task = try #require(controller.manualRefreshTasks[.global])

        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.menuVersions[key] == initialVersion)

        gate.resume()
        await task.value
        for _ in 0..<40 where controller.menuVersions[key] == initialVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed menu prewarm waits for other menu tracking to end`() async {
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
        StatusItemController.setClosedMenuPreparationDelayForTesting(.milliseconds(50))
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let closedMenu = controller.makeMenu(for: .claude)
        controller.providerMenus[.claude] = closedMenu
        controller.populateMenu(closedMenu, provider: .claude)
        controller.markMenuFresh(closedMenu)
        let closedKey = ObjectIdentifier(closedMenu)
        let closedVersion = controller.menuVersions[closedKey]

        controller.invalidateMenus()
        controller.rebuildClosedMenuIfNeeded(closedMenu)
        #expect(controller.closedMenuRebuildTasks[closedKey] != nil)

        let visibleMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(visibleMenu)
        try? await Task.sleep(for: .milliseconds(80))
        for _ in 0..<20 where controller.closedMenuRebuildTasks[closedKey] != nil {
            await Task.yield()
        }

        #expect(controller.menuVersions[closedKey] == closedVersion)
        #expect(controller.openMenus[ObjectIdentifier(visibleMenu)] != nil)

        controller.menuDidClose(visibleMenu)
        try? await Task.sleep(for: .milliseconds(80))
        for _ in 0..<20 where controller.menuVersions[closedKey] == closedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[closedKey] == controller.menuContentVersion)
    }

    @Test
    func `data refresh while persistent menu is open rebuilds on close`() async {
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
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuDidClose(menu)
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(controller.menuVersions[key] != openedVersion)
    }
}
