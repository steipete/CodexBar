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
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        let openedVersion = controller.menuVersions[key]

        controller.refreshOpenMenusAfterExplicitStoreAction()

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `token cost history arrival refreshes a visible parent menu`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        let codexMeta = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)

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
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }

        _ = try #require(controller.menuVersions[key])
        #expect(menu.items.contains { ($0.representedObject as? String) == "menuCardCost" } == false)

        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 0.45,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-05-20",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 456,
                        costUSD: 0.45,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: Date()),
            provider: .codex)

        let shouldRefreshOpenMenus = controller.shouldRefreshOpenMenusForTokenCostHistoryArrival()
        #expect(shouldRefreshOpenMenus)
        controller.invalidateMenus(refreshOpenMenus: shouldRefreshOpenMenus)

        let costItem = try #require(menu.items.first { ($0.representedObject as? String) == "menuCardCost" })
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
    }

    @Test
    func `open menu detects missing cost history as refresh reason`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        let codexMeta = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)

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

        #expect(controller.menuIsMissingCostHistory(for: menu))

        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 0.45,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-05-20",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 456,
                        costUSD: 0.45,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: Date()),
            provider: .codex)

        #expect(controller.menuIsMissingCostHistory(for: menu) == false)
    }
}
