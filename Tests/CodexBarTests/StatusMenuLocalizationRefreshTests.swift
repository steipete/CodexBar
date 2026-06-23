import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuLocalizationRefreshTests {
    @Test
    func `open merged menu refreshes localized switcher and cost title when language changes`() async {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        let previousAppleLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
            if let previousAppleLanguages {
                UserDefaults.standard.set(previousAppleLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        Self.disableMenuCardsForTesting()
        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.switcherShowsIcons = false
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: Self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        CodexBarLocalizationOverride.$appLanguage.withValue("es") {
            controller.menuWillOpen(menu)
        }
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        #expect(Self.switcherButtons(in: menu).first?.title == "Resumen")
        #expect(menu.items.first(where: { $0.representedObject as? String == "menuCardCost" })?.title == "Coste")

        let initialSwitcher = menu.items.first?.view as? ProviderSwitcherView
        let initialSwitcherID = initialSwitcher.map(ObjectIdentifier.init)
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            settings.appLanguage = "en"
            controller.handleProviderConfigChange(reason: "appLanguage")
        }

        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rebuildCount == 1)
        let updatedSwitcher = menu.items.first?.view as? ProviderSwitcherView
        #expect(Self.switcherButtons(in: menu).first?.title == "Overview")
        #expect(menu.items.first(where: { $0.representedObject as? String == "menuCardCost" })?.title == "Cost")
        if let initialSwitcherID, let updatedSwitcher {
            #expect(initialSwitcherID != ObjectIdentifier(updatedSwitcher))
        }
    }

    private static func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private static func makeStatusBarForTesting() -> NSStatusBar {
        .system
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuLocalizationRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func switcherButtons(in menu: NSMenu) -> [NSButton] {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView else { return [] }
        return switcherView.subviews
            .compactMap { $0 as? NSButton }
            .sorted { $0.tag < $1.tag }
    }
}
