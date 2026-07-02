import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuHostedSubmenuRefreshTests {
    @Test
    func `status components change open menu readiness`() {
        let settings = Self.makeSettings()
        settings.statusChecksEnabled = true
        settings.setProviderEnabled(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            enabled: true)
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

        let before = controller.menuAdjunctReadinessSignature()
        store.statusComponents[.claude] = [
            ProviderStatusComponent(
                id: "api",
                name: "API",
                indicator: .none,
                status: "operational"),
        ]

        #expect(controller.menuAdjunctReadinessSignature() != before)
    }

    @Test
    func `status submenu link stays scoped to its provider`() throws {
        let settings = Self.makeSettings()
        settings.statusChecksEnabled = true
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

        let submenu = NSMenu()
        #expect(controller.appendStatusComponentsItem(
            to: submenu,
            provider: .claude,
            width: StatusItemController.menuCardBaseWidth))
        #expect(controller.hydrateHostedSubviewMenuIfNeeded(submenu))

        let link = try #require(submenu.items.last)
        #expect(link.action == #selector(StatusItemController.openStatusPageFromMenuItem(_:)))
        #expect(link.identifier?.rawValue == UsageProvider.claude.rawValue)
        #expect(link.target === controller)
    }

    @Test
    func `storage native row preserves its plain menu title`() throws {
        let settings = Self.makeSettings()
        settings.providerStorageFootprintsEnabled = true
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        Self.seedStorageFootprint(in: store)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        #expect(controller.addStorageMenuCardSection(
            to: menu,
            provider: .claude,
            width: StatusItemController.menuCardBaseWidth))
        let item = try #require(menu.items.first)
        #expect(item.title.hasPrefix(L("Storage")))
        #expect(item.title == item.attributedTitle?.string)
        #expect(item.view == nil)
        #expect(item.isEnabled)
        #expect(item.submenu != nil)
    }

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
        settings.costSummaryDisplayStyle = .both
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
        #expect(costItem.title == StatusItemController.costMenuTitle)
        #expect(costItem.isEnabled)
        let submenu = try #require(costItem.submenu)
        #expect(submenu.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(submenu.minimumWidth >= StatusItemController.menuCardBaseWidth)
        #expect(submenu.items.first?.view == nil)

        controller.menuRefreshEnabledOverrideForTesting = true
        controller.menuWillOpen(submenu)
        let submenuKey = ObjectIdentifier(submenu)
        #expect(controller.openMenus[submenuKey] === submenu)
        #expect(submenu.items.first?.view != nil)

        let oldParentVersion = try #require(controller.menuVersions[parentKey])
        controller.invalidateMenus(
            refreshOpenMenus: true,
            deferOpenParentMenuRebuild: true)
        #expect(controller.menuVersions[parentKey] == oldParentVersion)
        controller.invalidateMenus(
            refreshOpenMenus: true,
            deferOpenParentMenuRebuild: true)
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

    @Test
    func `hosted chart items size to the displayed view without a throwaway controller`() throws {
        try self.assertHostedChartItemHeightMatchesRefresh(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude,
            seed: Self.seedClaudeSnapshots)
        { controller, submenu, width in
            controller.appendCostHistoryChartItem(to: submenu, provider: .claude, width: width)
        }
        try self.assertHostedChartItemHeightMatchesRefresh(
            chartID: StatusItemController.usageHistoryChartID,
            provider: .claude,
            seed: Self.seedPlanUtilizationHistory)
        { controller, submenu, width in
            controller.appendUsageHistoryChartItem(to: submenu, provider: .claude, width: width)
        }
        try self.assertHostedChartItemHeightMatchesRefresh(
            chartID: StatusItemController.storageBreakdownID,
            provider: .claude,
            seed: Self.seedStorageFootprint)
        { controller, submenu, width in
            controller.appendStorageBreakdownItem(to: submenu, provider: .claude, width: width)
        }
    }

    @Test
    func `zai chart render signature follows time range boundaries`() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let beforeMidnight = try #require(formatter.date(from: "2026-01-01 23:30"))
        let afterMidnight = try #require(formatter.date(from: "2026-01-02 00:30"))
        let modelUsage = ZaiModelUsageData(
            xTime: ["2026-01-01 23:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.5", tokensUsage: [100]),
            ])

        let before = StatusItemController.zaiHourlyUsageRenderSignature(
            modelUsage: modelUsage,
            now: beforeMidnight)
        let after = StatusItemController.zaiHourlyUsageRenderSignature(
            modelUsage: modelUsage,
            now: afterMidnight)

        #expect(before != after)
    }

    @Test
    func `utilization chart invalidates when active account changes`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        Self.enableOnlyClaude(settings)
        settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        let accounts = settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        Self.seedClaudeSnapshots(in: store)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(accounts: [
            aliceKey: [Self.makePlanHistory(usedPercent: 20)],
            bobKey: [Self.makePlanHistory(usedPercent: 50)],
        ])
        settings.setActiveTokenAccountIndex(0, for: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageHistoryChartID,
            provider: .claude,
            width: StatusItemController.menuCardBaseWidth)
        controller.menuWillOpen(submenu)
        let aliceView = try #require(submenu.items.first?.view)

        settings.setActiveTokenAccountIndex(1, for: .claude)
        controller.refreshHostedSubviewMenu(submenu)

        let bobView = try #require(submenu.items.first?.view)
        #expect(bobView !== aliceView)
    }

    private func assertHostedChartItemHeightMatchesRefresh(
        chartID: String,
        provider: UsageProvider,
        seed: (UsageStore) -> Void,
        append: (StatusItemController, NSMenu, CGFloat) -> Bool) throws
    {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
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

        let width = StatusItemController.menuCardBaseWidth
        let submenu = NSMenu()
        submenu.minimumWidth = width
        #expect(append(controller, submenu, width))

        let item = try #require(submenu.items.first)
        let view = try #require(item.view)
        let heightFromAppend = view.frame.height
        // The height the append path assigns must match the authoritative re-measure pass; otherwise
        // dropping the throwaway NSHostingController would have changed sizing behavior.
        controller.refreshHostedSubviewHeights(in: submenu)
        #expect(view.frame.height == heightFromAppend)
        #expect(heightFromAppend > 1)
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
        let hydratedView = hydratedItem.view
        let inflatedHeight = hydratedView.map { view -> CGFloat in
            let inflatedHeight = view.frame.height + 100
            if chartID == StatusItemController.zaiHourlyUsageChartID {
                view.frame.size.height = inflatedHeight
            }
            return inflatedHeight
        }

        controller.refreshHostedSubviewMenu(submenu)

        let refreshedItem = try #require(submenu.items.first)
        #expect(refreshedItem.representedObject as? String == chartID)
        #expect(refreshedItem.toolTip == provider.rawValue)
        #expect(refreshedItem.view != nil)
        #expect(refreshedItem.title != "No data available")
        #expect(refreshedItem.view === hydratedView)
        if chartID == StatusItemController.zaiHourlyUsageChartID {
            #expect(refreshedItem.view?.frame.height != inflatedHeight)
        }

        if chartID == StatusItemController.costHistoryChartID, provider == .claude {
            store._setTokenSnapshotForTesting(Self.makeTokenSnapshot(dailyCost: 2.34), provider: .claude)
            controller.refreshHostedSubviewMenu(submenu)

            let changedItem = try #require(submenu.items.first)
            #expect(changedItem.view != nil)
            #expect(changedItem.view !== hydratedView)
        }
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
                self.makePlanHistory(usedPercent: 24),
            ])
    }

    private static func makePlanHistory(usedPercent: Double) -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: usedPercent,
                    resetsAt: Date(timeIntervalSince1970: 1_700_018_000)),
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

    private static func makeTokenSnapshot(dailyCost: Double = 1.23) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: dailyCost,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: dailyCost,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())
    }
}
