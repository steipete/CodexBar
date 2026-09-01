import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MuseMenuBarSpendTests {
    @Test
    func `spend renders in legacy custom and preview menu bar paths`() {
        let settings = self.makeSettings()
        let layout = MenuBarLayout(lines: [[.balance]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5.23,
                limit: 0,
                currencyCode: "USD",
                period: "Last 7 days",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .muse)
        store._setErrorForTesting(nil, provider: .muse)

        #expect(controller.menuBarDisplayText(for: .muse, snapshot: snapshot) == "$5.23")

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .muse,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .muse,
            settings: settings,
            store: store)
            .liveData(provider: .muse, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.balance == "$5.23")
            #expect(rendered.attributedTitle.string == "$5.23")
        }
    }

    private func makeSettings() -> SettingsStore {
        let settings = testSettingsStore(suiteName: "MuseMenuBarSpendTests")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.muse.instanceID
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[.muse] {
            settings.setProviderEnabled(provider: .muse, metadata: metadata, enabled: true)
        }
        return settings
    }

    private func makeStoreAndController(settings: SettingsStore) -> (UsageStore, StatusItemController) {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}
