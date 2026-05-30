import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `store observation marks open menu stale without rebuilding during tracking`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

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
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

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
    func `explicit store actions refresh a visible open menu`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

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
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[key] != openedVersion)
    }

    @Test
    func `repeated explicit store actions coalesce to one open menu rebuild`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

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
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `plain open menu refresh preserves pending switcher hosted submenu cleanup`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

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
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageBreakdownChartID,
            provider: .codex)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menuRefreshEnabledOverrideForTesting = true

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        controller.refreshOpenMenuIfStillVisible(menu, provider: .codex)

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
    }

    @Test
    func `codex parent menu open requests stale OpenAI web refresh with battery saver enabled`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = nil
        store.lastOpenAIDashboardSnapshot = nil
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [],
            updatedAt: Date())))
    }

    @Test
    func `codex parent menu open refreshes recent dashboard cache with no chart history`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: Date())
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        await blocker.waitUntilStarted(count: 1)
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: Date())))
    }

    @Test
    func `codex parent menu open throttles recent empty dashboard retry`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.openAIWebBatterySaverEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: now.addingTimeInterval(-120))
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        store.lastOpenAIDashboardAttemptAt = now.addingTimeInterval(-60)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await blocker.startedCount() == 0)
    }

    @Test
    func `credits history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.showOptionalCreditsAndExtraUsage = true
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: true)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: now)
        store.openAIDashboard = self.makeOpenAIDashboard(dailyBreakdown: [], updatedAt: now)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(self.menuItem(in: menu, id: "menuCardCredits") == nil)

        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now.addingTimeInterval(10))

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let creditsItem = try #require(self.menuItem(in: menu, id: "menuCardCredits"))
        #expect(
            creditsItem.submenu?.items.first?.representedObject as? String ==
                StatusItemController.creditsHistoryChartID)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `fresh dashboard history with same day count rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.showOptionalCreditsAndExtraUsage = true
        self.enableOnlyCodex(settings)

        let now = Date(timeIntervalSince1970: 100)
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: true)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: now)
        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        _ = try #require(self.menuItem(in: menu, id: "menuCardCredits"))

        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 99),
            ],
            updatedAt: now.addingTimeInterval(10))

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let creditsItem = try #require(self.menuItem(in: menu, id: "menuCardCredits"))
        #expect(creditsItem.submenu?.items.first?.representedObject as? String == StatusItemController
            .creditsHistoryChartID)
    }

    @Test
    func `token cost history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodex(settings)

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
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)

        store._setTokenSnapshotForTesting(self.makeCodexTokenCostSnapshot(), provider: .codex)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `fresh token cost history with same day count rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodex(settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 1.23,
                updatedAt: Date(timeIntervalSince1970: 100)),
            provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))

        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 999,
                sessionCostUSD: 0.99,
                last30DaysTokens: 888,
                last30DaysCostUSD: 8.88,
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .codex)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
    }

    @Test
    func `plan utilization history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

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
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        let usageHistoryItem = try #require(self.menuItem(in: menu, id: "usageHistorySubmenu"))
        #expect(usageHistoryItem.submenu?.items.first?.representedObject as? String == StatusItemController
            .usageHistoryChartID)
        let openedRevision = store.planUtilizationHistoryRevision

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: self.makeCodexPlanUtilizationSnapshot(),
            now: Date())

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(store.planUtilizationHistoryRevision > openedRevision)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)
    }

    @Test
    func `dashboard attachment authorization arriving after open rebuilds parent menu after close`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let now = Date()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.openAIDashboard = self.makeOpenAIDashboard(
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(day: "2026-05-24", services: [], totalCreditsUsed: 12),
            ],
            updatedAt: now)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(store.openAIDashboardAttachmentRevision == 0)

        store.openAIDashboardAttachmentAuthorized = true

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(store.openAIDashboardAttachmentRevision == 1)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func menuItem(in menu: NSMenu, id: String) -> NSMenuItem? {
        menu.items.first { ($0.representedObject as? String) == id }
    }

    private func waitUntilMenuVersionChanges(
        _ controller: StatusItemController,
        from version: Int?) async
    {
        for _ in 0..<20 where controller.menuContentVersion == version {
            await Task.yield()
        }
    }

    private func waitUntilOpenMenuStaysStale(
        _ controller: StatusItemController,
        key: ObjectIdentifier,
        after version: Int?) async
    {
        for _ in 0..<40 {
            guard controller.menuContentVersion != version else {
                await Task.yield()
                continue
            }
            guard controller.menuVersions[key] == version else {
                await Task.yield()
                continue
            }
            return
        }
    }

    private func closeMenuAndWaitUntilFresh(
        _ controller: StatusItemController,
        menu: NSMenu,
        key: ObjectIdentifier) async
    {
        controller.menuDidClose(menu)
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        if controller.menuVersions[key] != controller.menuContentVersion {
            controller.menuWillOpen(menu)
        }
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    private func makeOpenAIDashboard(
        dailyBreakdown: [OpenAIDashboardDailyBreakdown],
        updatedAt: Date) -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: dailyBreakdown,
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: updatedAt)
    }

    private func makeCodexTokenCostSnapshot(
        sessionTokens: Int = 123,
        sessionCostUSD: Double = 0.12,
        last30DaysTokens: Int = 456,
        last30DaysCostUSD: Double = 1.23,
        updatedAt: Date = Date()) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-24",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: sessionTokens,
                    costUSD: last30DaysCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }

    private func makeCodexPlanUtilizationSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 35,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(1800),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
    }
}
