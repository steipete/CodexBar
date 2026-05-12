import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuOpenRefreshTests {
    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuOpenRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeCodexStore(settings: SettingsStore) -> UsageStore {
        let now = Date()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 22,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .codex)
        return store
    }

    @Test
    func `store observation marks open menu stale without rebuilding during tracking`() async {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 33,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .codex)

        for _ in 0..<20 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(rebuildCount == 0)
    }

    @Test
    func `explicit store actions refresh a visible open menu`() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        let openedVersion = controller.menuVersions[key]

        controller.refreshOpenMenusAfterExplicitStoreAction()

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }
}
