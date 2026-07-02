import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `open AI API primary dashboard ignores optional cost summary toggle`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .openai
        settings.costUsageEnabled = false

        let metadata = try #require(ProviderRegistry.shared.metadata[.openai])
        settings.setProviderEnabled(provider: .openai, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 9,
                    requests: 12,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .openai)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = try #require(controller.menuCardModel(for: .openai))
        #expect(model.inlineUsageDashboard != nil)
        #expect(model.tokenUsage == nil)
    }

    @Test
    func `open AI API usage submenu ignores optional local cost preferences`() throws {
        self.disableMenuCardsForTesting()

        for style in CostSummaryDisplayStyle.allCases {
            let settings = self.makeSettings()
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.selectedMenuProvider = .openai
            settings.costUsageEnabled = false
            settings.costSummaryDisplayStyle = style

            let registry = ProviderRegistry.shared
            let metadata = try #require(registry.metadata[.openai])
            settings.setProviderEnabled(provider: .openai, metadata: metadata, enabled: true)

            let fetcher = UsageFetcher()
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let usage = OpenAIAPIUsageSnapshot(
                daily: [
                    OpenAIAPIUsageSnapshot.DailyBucket(
                        day: "2023-11-14",
                        startTime: now,
                        endTime: now.addingTimeInterval(86400),
                        costUSD: 9,
                        requests: 12,
                        inputTokens: 100,
                        cachedInputTokens: 0,
                        outputTokens: 50,
                        totalTokens: 150,
                        lineItems: [],
                        models: []),
                ],
                updatedAt: now)
            store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .openai)

            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: fetcher.loadAccountInfo(),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: self.makeStatusBarForTesting())
            defer { controller.releaseStatusItemsForTesting() }

            #expect(controller.makeOpenAIAPIUsageSubmenu(provider: .openai) != nil)
        }
    }

    @Test
    func `open AI API usage submenu ignores stale token snapshot without current admin usage`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .openai

        let registry = ProviderRegistry.shared
        let metadata = try #require(registry.metadata[.openai])
        settings.setProviderEnabled(provider: .openai, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            provider: .openai)
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
            updatedAt: now), provider: .openai)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.makeOpenAIAPIUsageSubmenu(provider: .openai) == nil)
    }

    @Test
    func `mistral native billing submenus ignore optional local cost preferences`() throws {
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer { self.disableMenuCardsForTesting() }
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .mistral
        settings.costUsageEnabled = false
        settings.costSummaryDisplayStyle = .inlineSummary

        let metadata = try #require(ProviderRegistry.shared.metadata[.mistral])
        settings.setProviderEnabled(provider: .mistral, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let usage = MistralUsageSnapshot(
            totalCost: 1.5,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 100,
            totalOutputTokens: 50,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: 1.5,
                    inputTokens: 100,
                    cachedTokens: 0,
                    outputTokens: 50,
                    models: []),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .mistral)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = try #require(controller.menuCardModel(for: .mistral))
        #expect(model.inlineUsageDashboard != nil)
        #expect(model.tokenUsage == nil)
        #expect(controller.makeOverviewRowSubmenu(provider: .mistral, model: model, width: 320) != nil)

        let menu = controller.makeMenu(for: .mistral)
        controller.menuWillOpen(menu)
        let usageItem = menu.items.first { ($0.representedObject as? String) == "menuCardUsage" }
        #expect(usageItem?.submenu != nil)

        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        let costsEnabledModel = try #require(controller.menuCardModel(for: .mistral))
        #expect(costsEnabledModel.inlineUsageDashboard != nil)
        #expect(costsEnabledModel.tokenUsage == nil)
    }
}
