import CodexBarCore
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `menu card height cache is reused within one content version`() {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
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

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        let firstKeys = Set(controller.menuCardHeightCache.keys)

        #expect(!firstKeys.isEmpty)

        controller.populateMenu(menu, provider: .codex)
        #expect(Set(controller.menuCardHeightCache.keys) == firstKeys)

        controller.invalidateMenus()
        #expect(controller.menuCardHeightCache.isEmpty)
    }
}
