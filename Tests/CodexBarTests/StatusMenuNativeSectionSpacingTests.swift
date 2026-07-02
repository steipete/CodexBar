import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuNativeSectionSpacingTests {
    @Test
    func `storage credits and cost never create adjacent separators`() throws {
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
        let storageIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardStorage"
        })
        let creditsIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCredits"
        })
        let costIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCost"
        })
        #expect(storageIndex < creditsIndex)
        #expect(creditsIndex < costIndex)
        #expect(menu.items[costIndex + 1].isSeparatorItem)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { first, second in
            first.isSeparatorItem && second.isSeparatorItem
        })
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
}
