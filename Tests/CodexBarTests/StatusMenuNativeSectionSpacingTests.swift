import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuNativeSectionSpacingTests {
    @Test
    func `buy credits stays available without an error only credits section`() {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.showOptionalCreditsAndExtraUsage = true
        self.enableOnlyCodex(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.lastCreditsError = UsageError.noRateLimitsFound.errorDescription
        store.lastOpenAIDashboardError =
            "No matching OpenAI web session found. Sign in to chatgpt.com, then refresh OpenAI cookies."
        let event = CreditEvent(date: Date(), service: "CLI", creditsUsed: 1)
        let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: [event], maxDays: 30)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [event],
            dailyBreakdown: breakdown,
            usageBreakdown: breakdown,
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboardAttachmentAuthorized = true
        store.openAIDashboardRequiresLogin = false

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.contains { ($0.representedObject as? String) == "menuCardCredits" } == false)
        #expect(menu.items.contains { $0.title == "Buy Credits..." })
        #expect(menu.items.contains { item in
            item.submenu?.items.contains { ($0.representedObject as? String) == "creditsHistoryChart" } == true
        })

        settings.showOptionalCreditsAndExtraUsage = false
        let hiddenMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(hiddenMenu)
        #expect(hiddenMenu.items.contains { $0.title == "Buy Credits..." } == false)
        #expect(hiddenMenu.items.contains { item in
            item.submenu?.items.contains { ($0.representedObject as? String) == "creditsHistoryChart" } == true
        } == false)
    }

    @Test
    func `usage history cost and storage stay together without adjacent separators`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.providerStorageFootprintsEnabled = true
        self.enableOnlyCodex(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let storageRoot = "/Users/test/.codex"
        store.providerStorageFootprints[.codex] = ProviderStorageFootprint(
            provider: .codex,
            totalBytes: 1024,
            paths: [storageRoot],
            missingPaths: [],
            unreadablePaths: [],
            components: [.init(path: storageRoot, totalBytes: 1024)],
            updatedAt: Date())
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboardAttachmentAuthorized = true
        store.openAIDashboardRequiresLogin = false
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
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let usageHistoryIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "usageHistorySubmenu"
        })
        let storageIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardStorage"
        })
        let creditsIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCredits"
        })
        let costIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCost"
        })
        #expect(creditsIndex < usageHistoryIndex)
        #expect(usageHistoryIndex < costIndex)
        #expect(costIndex < storageIndex)
        #expect(menu.items[usageHistoryIndex].title == "Plan Usage")
        #expect(menu.items[storageIndex].view == nil)
        #expect(menu.items[storageIndex].title.hasPrefix("Storage"))
        #expect(menu.items[storageIndex].title.contains("1 KB"))
        #expect(menu.items[storageIndex + 1].isSeparatorItem)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { first, second in
            first.isSeparatorItem && second.isSeparatorItem
        })
    }

    @Test
    func `opencodego cost history hangs off the cost row not the usage pane`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .opencodego
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        self.enableOnlyOpenCodeGo(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let opencodegoSnapshot = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 12,
            weeklyUsagePercent: 57,
            monthlyUsagePercent: 34,
            rollingResetInSec: 3600,
            weeklyResetInSec: 86400,
            monthlyResetInSec: 864_000,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    requestCount: 5,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())
        let opencodegoUsageSnapshot = opencodegoSnapshot.toUsageSnapshot()
        store._setSnapshotForTesting(opencodegoUsageSnapshot, provider: .opencodego)
        // A completed refresh also caches the projected token snapshot (UsageStore+Refresh.swift);
        // populate it here so `openAIWebContext.hasCostHistory` matches real post-refresh state.
        store._setTokenSnapshotForTesting(
            store.tokenSnapshot(fromProviderSnapshot: opencodegoUsageSnapshot, provider: .opencodego),
            provider: .opencodego)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .opencodego)
        controller.menuWillOpen(menu)

        let usageIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardUsage"
        })
        let usageHistoryIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "usageHistorySubmenu"
        })
        let costIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCost"
        })

        // The rate-limit bars pane keeps its own submenu-free row; the cost history chart hangs
        // off the dedicated "Cost" row instead, matching Codex/Claude's structure.
        #expect(menu.items[usageIndex].submenu == nil)
        #expect(menu.items[usageHistoryIndex].title == "Plan Usage")
        #expect(usageIndex < usageHistoryIndex)
        #expect(usageHistoryIndex < costIndex)
        #expect(menu.items[costIndex].submenu != nil)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuNativeSectionSpacingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func enableOnlyOpenCodeGo(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .opencodego)
        }
    }
}
