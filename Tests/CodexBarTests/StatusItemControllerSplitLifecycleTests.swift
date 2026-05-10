import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemControllerSplitLifecycleTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusItemControllerSplitLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func containsHostingView(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("NSHostingView") {
            return true
        }
        return view.subviews.contains { self.containsHostingView($0) }
    }

    private func makeSplitController() throws -> (SettingsStore, StatusItemController) {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(registry.metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(registry.metadata[.claude]),
            enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        return (settings, controller)
    }

    @Test
    func `merged mode removes split provider status items`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.statusItems[.codex] != nil)
        #expect(controller.statusItems[.claude] != nil)

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        #expect(controller.statusItem.isVisible == true)
        #expect(controller.statusItems.isEmpty)
    }

    @Test
    func `menu bar icons stay appkit hosted`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let codexButton = try #require(controller.statusItems[.codex]?.button)
        #expect(codexButton.image != nil)
        #expect(!self.containsHostingView(codexButton))

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        let mergedButton = try #require(controller.statusItem.button)
        #expect(mergedButton.image != nil)
        #expect(!self.containsHostingView(mergedButton))
    }
}
