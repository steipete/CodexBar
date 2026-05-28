import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherRefreshTests {
    @Test
    func `merged provider switch updates tracked parent body from cache`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)

        let activeProviders: [UsageProvider] = [.codex, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.isRefreshing = true
        defer { store.isRefreshing = false }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        #expect(controller.openMenus[key] === menu)
        let openedVersion = controller.menuVersions[key]

        let initialSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        initialSwitcher.frame.size.width = 250

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let nextProviderButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .off })
        #expect(initialSwitcher._test_simulateRuntimeClick(buttonTag: nextProviderButton.tag) == true)

        await Task.yield()

        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.menuNeedsRefresh(menu) == false)
        let updatedSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(updatedSwitcher.frame.width == 250)
        #expect(Self.switcherButtons(in: menu).first { $0.tag == nextProviderButton.tag }?.state == .on)
    }

    @Test
    func `stale cached merged parent menu hydrates after opening`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)

        let activeProviders: [UsageProvider] = [.codex, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

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
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = try #require(controller.menuVersions[key])
        controller.menuDidClose(menu)

        controller.menuContentVersion &+= 1
        let staleVersion = controller.menuContentVersion
        var updateCount = 0
        controller._test_openMenuRefreshYieldOverride = {}
        controller._test_openMenuRebuildObserver = { _ in
            updateCount += 1
        }
        defer {
            controller._test_openMenuRefreshYieldOverride = nil
            controller._test_openMenuRebuildObserver = nil
        }

        controller.menuWillOpen(menu)
        #expect(controller.menuVersions[key] == openedVersion)

        for _ in 0..<10 where updateCount == 0 {
            await Task.yield()
        }

        #expect(updateCount == 1)
        #expect(controller.menuVersions[key] == staleVersion)
        #expect(controller.menuNeedsRefresh(menu) == false)
    }

    @Test
    func `stale merged parent menu rebuilds immediately when provider list changes`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)

        let activeProviders: [UsageProvider] = [.codex, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

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
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.menuDidClose(menu)

        let geminiMetadata = try #require(ProviderRegistry.shared.metadata[.gemini])
        settings.setProviderEnabled(provider: .gemini, metadata: geminiMetadata, enabled: true)
        controller.menuContentVersion &+= 1
        let changedVersion = controller.menuContentVersion

        controller.menuWillOpen(menu)

        #expect(controller.menuVersions[key] == changedVersion)
        #expect(controller.menuNeedsRefresh(menu) == false)
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func enableCodexAndClaude(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
    }

    private static func switcherButtons(in menu: NSMenu) -> [NSButton] {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView else { return [] }
        return switcherView.subviews
            .compactMap { $0 as? NSButton }
            .sorted { $0.tag < $1.tag }
    }
}
