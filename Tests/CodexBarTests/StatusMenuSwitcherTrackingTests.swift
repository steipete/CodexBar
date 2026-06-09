import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherTrackingTests {
    @Test
    func `pointer switch defers structural menu rebuild until mouse up`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .claude)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        let mouseDown = try #require(switcher._test_mouseDownEvent(buttonTag: 2))
        let mouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 2))

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        #expect(controller.handleProviderSwitcherTrackingEvent(mouseDown, menu: menu))
        #expect(settings.selectedMenuProvider == .codex)
        #expect(controller.providerSwitcherPointerInteractionMenuID == ObjectIdentifier(menu))
        #expect(controller.pendingProviderSwitcherPointerRebuild == nil)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(rebuildCount == 0)

        #expect(controller.handleProviderSwitcherTrackingEvent(mouseUp, menu: menu))
        #expect(settings.selectedMenuProvider == .claude)
        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(rebuildCount == 1)
        #expect(controller.providerSwitcherPointerInteractionMenuID == nil)
        #expect(controller.pendingProviderSwitcherPointerRebuild == nil)
    }

    @Test
    func `pointer switch cancels when mouse up leaves pressed segment`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .claude)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        let mouseDown = try #require(switcher._test_mouseDownEvent(buttonTag: 2))
        let mouseUpElsewhere = try #require(switcher._test_mouseUpEvent(buttonTag: 1))

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        #expect(controller.handleProviderSwitcherTrackingEvent(mouseDown, menu: menu))
        #expect(controller.handleProviderSwitcherTrackingEvent(mouseUpElsewhere, menu: menu))
        #expect(settings.selectedMenuProvider == .codex)
        #expect(rebuildCount == 0)
        #expect(controller.providerSwitcherPointerInteractionMenuID == nil)
        #expect(controller.pendingProviderSwitcherPointerRebuild == nil)
    }

    @Test
    func `unrelated mouse up remains available to normal menu items`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let fetcher = UsageFetcher()
        let controller = StatusItemController(
            store: UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings),
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let item = NSMenuItem()
        item.view = switcher
        menu.addItem(item)
        let unrelatedMouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 1))

        #expect(!controller.handleProviderSwitcherTrackingEvent(unrelatedMouseUp, menu: menu))
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherTrackingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
