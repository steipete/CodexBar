import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuHostedSubmenuRefreshTests {
    @Test
    func `open parent menu defers data rebuild until parent tracking ends`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
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
        controller.menuRefreshEnabledOverrideForTesting = false

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let parentKey = ObjectIdentifier(menu)
        controller.openMenus[parentKey] = menu
        controller.menuVersions[parentKey] = controller.menuContentVersion

        let costItem = try #require(menu.items.first { ($0.representedObject as? String) == "menuCardCost" })
        #expect(costItem.view == nil)
        let submenu = try #require(costItem.submenu)
        let submenuAction = try #require(costItem.action)
        #expect(NSStringFromSelector(submenuAction) == "submenuAction:")
        #expect((costItem.target as? NSMenu) === submenu)
        #expect(submenu.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(submenu.minimumWidth >= StatusItemController.menuCardBaseWidth)
        #expect(submenu.items.first?.view == nil)

        controller.menuRefreshEnabledOverrideForTesting = true
        controller.menuWillOpen(submenu)
        let submenuKey = ObjectIdentifier(submenu)
        #expect(controller.openMenus[submenuKey] === submenu)
        #expect(submenu.items.first?.view != nil)

        let oldParentVersion = try #require(controller.menuVersions[parentKey])
        controller.menuContentVersion &+= 1
        controller.refreshOpenMenusIfNeeded()
        #expect(controller.menuVersions[parentKey] == oldParentVersion)
        controller.menuContentVersion &+= 1
        controller.refreshOpenMenusIfNeeded()
        #expect(controller.menuVersions[parentKey] == oldParentVersion)

        controller.menuDidClose(submenu)
        #expect(controller.openMenus[submenuKey] == nil)

        for _ in 0..<40 where controller.menuVersions[parentKey] != oldParentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[parentKey] == oldParentVersion)

        controller.menuDidClose(menu)
        for _ in 0..<40 where controller.menuVersions[parentKey] != controller.menuContentVersion {
            await Task.yield()
        }
        if controller.menuVersions[parentKey] != controller.menuContentVersion {
            controller.menuWillOpen(menu)
        }
        for _ in 0..<40 where controller.menuVersions[parentKey] != controller.menuContentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[parentKey] == controller.menuContentVersion)
    }

    @Test
    func `open hosted submenu rebuilds from unavailable placeholder when data arrives`() async {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude,
            width: StatusItemController.menuCardBaseWidth)
        controller.menuWillOpen(submenu)
        let submenuKey = ObjectIdentifier(submenu)
        #expect(controller.openMenus[submenuKey] === submenu)
        #expect(submenu.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(submenu.items.first?.view == nil)
        #expect(submenu.items.first?.title == "No data available")

        let openedVersion = controller.menuContentVersion
        store._setTokenSnapshotForTesting(Self.makeTokenSnapshot(), provider: .claude)
        controller.invalidateMenus(refreshOpenMenus: true)

        for _ in 0..<40 {
            if controller.menuContentVersion != openedVersion,
               submenu.items.first?.view != nil
            {
                break
            }
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(submenu.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(submenu.items.first?.view != nil)
        #expect(submenu.items.first?.title != "No data available")
    }

    @Test
    func `open hydrated provider submenu preserves identity across refresh`() throws {
        try self.assertHostedSubmenuPreservesIdentity(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude,
            seed: Self.seedClaudeSnapshots)
        try self.assertHostedSubmenuPreservesIdentity(
            chartID: StatusItemController.costHistoryChartID,
            provider: .openai,
            seed: Self.seedOpenAICostSnapshot)
        try self.assertHostedSubmenuPreservesIdentity(
            chartID: StatusItemController.usageHistoryChartID,
            provider: .claude,
            seed: Self.seedPlanUtilizationHistory)
        try self.assertHostedSubmenuPreservesIdentity(
            chartID: StatusItemController.storageBreakdownID,
            provider: .claude,
            seed: Self.seedStorageFootprint)
        try self.assertHostedSubmenuPreservesIdentity(
            chartID: StatusItemController.zaiHourlyUsageChartID,
            provider: .zai,
            seed: Self.seedZaiHourlyUsage)
    }

    private func assertHostedSubmenuPreservesIdentity(
        chartID: String,
        provider: UsageProvider,
        seed: (UsageStore) -> Void) throws
    {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider
        settings.costUsageEnabled = true
        settings.providerStorageFootprintsEnabled = true
        Self.enableOnly(settings, provider: provider)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        seed(store)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: chartID,
            provider: provider,
            width: StatusItemController.menuCardBaseWidth)
        controller.menuWillOpen(submenu)

        let hydratedItem = try #require(submenu.items.first)
        #expect(hydratedItem.representedObject as? String == chartID)
        #expect(hydratedItem.toolTip == provider.rawValue)
        #expect(hydratedItem.view != nil)
        #expect(hydratedItem.title != "No data available")

        controller.refreshHostedSubviewMenu(submenu)

        let refreshedItem = try #require(submenu.items.first)
        #expect(refreshedItem.representedObject as? String == chartID)
        #expect(refreshedItem.toolTip == provider.rawValue)
        #expect(refreshedItem.view != nil)
        #expect(refreshedItem.title != "No data available")
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
        self.enableOnly(settings, provider: .claude)
    }

    private static func enableOnly(_ settings: SettingsStore, provider enabledProvider: UsageProvider) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == enabledProvider)
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
        store._setTokenSnapshotForTesting(Self.makeTokenSnapshot(), provider: .claude)
    }

    private static func seedOpenAICostSnapshot(in store: UsageStore) {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2025-12-23",
                    startTime: day,
                    endTime: day.addingTimeInterval(86400),
                    costUSD: 1.23,
                    requests: 12,
                    inputTokens: 100,
                    cachedInputTokens: 20,
                    outputTokens: 40,
                    totalTokens: 160,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_086_400))
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            openAIAPIUsage: apiUsage,
            updatedAt: Date(timeIntervalSince1970: 1_700_086_400),
            identity: ProviderIdentitySnapshot(
                providerID: .openai,
                accountEmail: "openai@example.com",
                accountOrganization: nil,
                loginMethod: "API"))
        store._setSnapshotForTesting(snapshot, provider: .openai)
    }

    private static func seedPlanUtilizationHistory(in store: UsageStore) {
        self.seedClaudeSnapshots(in: store)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            unscoped: [
                PlanUtilizationSeriesHistory(
                    name: .session,
                    windowMinutes: 300,
                    entries: [
                        PlanUtilizationHistoryEntry(
                            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            usedPercent: 24,
                            resetsAt: Date(timeIntervalSince1970: 1_700_018_000)),
                    ]),
            ])
    }

    private static func seedStorageFootprint(in store: UsageStore) {
        let root = "/Users/test/.claude"
        store.providerStorageFootprints[.claude] = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 1024,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [.init(path: "\(root)/projects", totalBytes: 1024)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func seedZaiHourlyUsage(in store: UsageStore) {
        let modelUsage = ZaiModelUsageData(
            xTime: ["2026-05-26 00:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.5", tokensUsage: [512]),
            ])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            zaiUsage: ZaiUsageSnapshot(
                tokenLimit: nil,
                timeLimit: nil,
                planName: "Pro",
                modelUsage: modelUsage,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: "zai@example.com",
                accountOrganization: nil,
                loginMethod: "OAuth"))
        store._setSnapshotForTesting(snapshot, provider: .zai)
    }

    private static func makeTokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
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
            updatedAt: Date())
    }
}
