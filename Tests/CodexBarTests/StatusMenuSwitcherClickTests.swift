import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherClickTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherClickTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `merged switcher routes runtime clicks after overview round-trip`() throws {
        // Regression test for #867: after Provider → Overview, subsequent runtime clicks on a
        // sub-provider tab dropped through NSButton's tracking and never updated state.
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        // Step 1: provider → Overview via the runtime click path.
        let switcher1 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher1._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 2: Overview → provider via the runtime click path. Tag 2 is the second provider
        // (claude) since tag 0 is Overview and tag 1 is the first provider.
        let switcher2 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher2._test_simulateRuntimeClick(buttonTag: 2))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        // Step 3: provider → Overview again.
        let switcher3 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher3._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 4: Overview → other provider. This is the click that previously got dropped.
        let switcher4 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher4._test_simulateRuntimeClick(buttonTag: 1))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
    }
}
