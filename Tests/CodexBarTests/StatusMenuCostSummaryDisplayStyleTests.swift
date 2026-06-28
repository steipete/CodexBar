import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension StatusMenuTests {
    @Test
    func `cost summary display style controls codex menu presentation`() throws {
        self.disableMenuCardsForTesting()

        for style in CostSummaryDisplayStyle.allCases {
            let settings = self.makeSettings()
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.mergeIcons = true
            settings.selectedMenuProvider = .codex
            settings.costUsageEnabled = true
            settings.costSummaryDisplayStyle = style

            let registry = ProviderRegistry.shared
            for provider in UsageProvider.allCases {
                guard let metadata = registry.metadata[provider] else { continue }
                settings.setProviderEnabled(
                    provider: provider,
                    metadata: metadata,
                    enabled: provider == .codex)
            }

            let fetcher = UsageFetcher()
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            store._setTokenSnapshotForTesting(
                CostUsageTokenSnapshot(
                    sessionTokens: 85_000_000,
                    sessionCostUSD: 91.63,
                    last30DaysTokens: 1_100_000_000,
                    last30DaysCostUSD: 1001.27,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-06-23",
                            inputTokens: nil,
                            outputTokens: nil,
                            totalTokens: 85_000_000,
                            costUSD: 91.63,
                            modelsUsed: ["fictional-test-model"],
                            modelBreakdowns: nil),
                    ],
                    updatedAt: Date()),
                provider: .codex)

            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: fetcher.loadAccountInfo(),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: self.makeStatusBarForTesting())
            defer { controller.releaseStatusItemsForTesting() }

            let model = try #require(controller.menuCardModel(for: .codex))
            let providerDetailModel = ProvidersPane(settings: settings, store: store)
                ._test_menuCardModel(for: .codex)
            let menu = controller.makeMenu()
            controller.menuWillOpen(menu)

            let ids = menu.items.compactMap { $0.representedObject as? String }
            #expect((model.inlineUsageDashboard != nil) == style.showsInlineSummary)
            #expect((model.tokenUsage != nil) == style.showsCostSubmenu)
            #expect(providerDetailModel.tokenUsage != nil)
            #expect(ids.contains("menuCardCost") == style.showsCostSubmenu)
        }
    }
}
