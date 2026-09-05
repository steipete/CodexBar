import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuHelmcodeDashboardTests {
    @Test
    func `helmcode dashboard action follows selected deployment`() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.helmcode.com/credits")
        settings.helmcodeDeployment = .nanBuilders
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.nan.builders/credits")
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuHelmcodeDashboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}
