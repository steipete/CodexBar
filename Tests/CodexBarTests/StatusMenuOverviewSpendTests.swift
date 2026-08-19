import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `overview spend uses the configured dashboard bucket calendar`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 1
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let currentOffset = Calendar.current.timeZone.secondsFromGMT(for: now)
        let bucketIdentifier = currentOffset == 14 * 60 * 60
            ? "Etc/GMT+12"
            : "Pacific/Kiritimati"
        settings.costUsageBucketTimeZoneIdentifier = bucketIdentifier
        let bucketCalendar = settings.costUsageBucketCalendar
        let dayComponents = bucketCalendar.dateComponents([.year, .month, .day], from: now)
        let year = try #require(dayComponents.year)
        let month = try #require(dayComponents.month)
        let dayOfMonth = try #require(dayComponents.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            historyDays: 1,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 60,
                    outputTokens: 40,
                    totalTokens: 100,
                    requestCount: 1,
                    costUSD: 1,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = controller.overviewSpendDashboardModel(providers: [.codex], now: now)
        let group = try #require(model.groups.first)
        let bucketStart = bucketCalendar.startOfDay(for: now)

        #expect(bucketStart != Calendar.current.startOfDay(for: now))
        #expect(group.chartDomain.lowerBound == bucketStart)
        #expect(group.timeZone.identifier == bucketCalendar.timeZone.identifier)
        #expect(group.totalCost == 1)
        #expect(group.totalTokens == 100)
        #expect(group.dailyPoints.map(\.day) == [bucketStart])
    }

    @Test
    func `overview accounts for all six selected providers while summing only available spend`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        let selected: [UsageProvider] = [.openai, .claude, .gemini, .antigravity, .openrouter, .grok]
        settings.mergedOverviewSelectedProviders = selected
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: selected.contains(provider))
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        func snapshot(cost: Double) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: cost,
                costProvenance: .vendorMetered,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-08-17",
                        inputTokens: 0,
                        outputTokens: 0,
                        totalTokens: 0,
                        requestCount: 1,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now)
        }
        store._setTokenSnapshotForTesting(snapshot(cost: 35.09), provider: .claude)
        store._setTokenSnapshotForTesting(snapshot(cost: 39.79), provider: .openrouter)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let overviewProviders = settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: selected)
        let model = controller.overviewSpendDashboardModel(providers: overviewProviders, now: now)
        let summary = OverviewSpendSummary(model: model, providerCount: overviewProviders.count)

        #expect(overviewProviders == selected)
        #expect(model.groups.first?.providers.map(\.provider).sorted { $0.rawValue < $1.rawValue } == [
            .claude,
            .openrouter,
        ])
        #expect(abs((model.groups.first?.totalCost ?? -1) - 74.88) < 1e-9)
        #expect(summary.providerCoverageText == "2 of 6 subscriptions have spend")
        #expect(summary.isPartial)
    }

    @Test
    func `overview spend follows the inline display preference`() throws {
        for (style, enabled) in [
            (CostSummaryDisplayStyle.inlineSummary, true),
            (.both, true),
            (.costSubmenu, false),
        ] {
            let result = try self.overviewSpendSummaryIsPresent(style: style, costUsageEnabled: true)
            #expect(result == enabled, "Unexpected Overview spend visibility for \(style.rawValue)")
        }

        #expect(try !self.overviewSpendSummaryIsPresent(style: .both, costUsageEnabled: false))
    }

    private func overviewSpendSummaryIsPresent(
        style: CostSummaryDisplayStyle,
        costUsageEnabled: Bool) throws -> Bool
    {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costSummaryDisplayStyle = style
        settings.costUsageEnabled = costUsageEnabled

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let dayOfMonth = try #require(components.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 60,
                    outputTokens: 40,
                    totalTokens: 100,
                    requestCount: 1,
                    costUSD: 1,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now), provider: .codex)

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
        return menu.items.contains { ($0.representedObject as? String) == "overviewSpendSummary" }
    }
}
