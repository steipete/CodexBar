import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuHostedSubmenuRefreshTests {
    @Test
    func `open hosted submenu defers parent menu rebuild until submenu closes`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.costUsageEnabled = true
        Self.enableOnlyClaude(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        Self.seedClaudeSnapshots(in: store)

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
        let parentKey = ObjectIdentifier(menu)
        controller.openMenus[parentKey] = menu
        controller.menuVersions[parentKey] = controller.menuContentVersion

        let costItem = try #require(menu.items.first { ($0.representedObject as? String) == "menuCardCost" })
        let submenu = try #require(costItem.submenu)

        StatusItemController.setMenuRefreshEnabledForTesting(true)
        controller.menuWillOpen(submenu)
        let submenuKey = ObjectIdentifier(submenu)
        #expect(controller.openMenus[submenuKey] === submenu)

        let oldParentVersion = try #require(controller.menuVersions[parentKey])
        controller.menuContentVersion &+= 1
        controller.refreshOpenMenusIfNeeded()
        #expect(controller.menuVersions[parentKey] == oldParentVersion)

        controller.menuDidClose(submenu)
        #expect(controller.openMenus[submenuKey] == nil)
        #expect(controller.menuVersions[parentKey] == controller.menuContentVersion)
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuHostedSubmenuRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func enableOnlyClaude(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
    }

    private static func seedClaudeSnapshots(in store: UsageStore) {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "Team"))
        store._setSnapshotForTesting(snapshot, provider: .claude)
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
            updatedAt: Date()), provider: .claude)
    }
}
