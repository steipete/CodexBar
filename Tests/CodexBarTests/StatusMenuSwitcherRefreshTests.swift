import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherRefreshTests {
    @Test
    func `merged provider switch rebuilds stale width switcher rows`() async throws {
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
        controller.menuWillOpen(menu)
        #expect(controller.openMenus[ObjectIdentifier(menu)] === menu)

        let initialSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        let initialSwitcherID = ObjectIdentifier(initialSwitcher)
        initialSwitcher.frame.size.width = 250

        let nextProviderButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .off })
        #expect(initialSwitcher._test_simulateRuntimeClick(buttonTag: nextProviderButton.tag) == true)

        var replacementSwitcher: ProviderSwitcherView?
        for _ in 0..<100 {
            await Task.yield()
            if let currentSwitcher = menu.items.first?.view as? ProviderSwitcherView,
               initialSwitcherID != ObjectIdentifier(currentSwitcher)
            {
                replacementSwitcher = currentSwitcher
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let updatedSwitcher = try #require(replacementSwitcher)
        #expect(initialSwitcherID != ObjectIdentifier(updatedSwitcher))
        #expect(updatedSwitcher.frame.width == 310)
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
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
