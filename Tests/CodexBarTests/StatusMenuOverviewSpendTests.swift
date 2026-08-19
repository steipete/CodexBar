import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
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
    func `overview keeps six visible providers while accounting for all seven connected providers`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        let connected: [UsageProvider] = [
            .openai,
            .claude,
            .gemini,
            .antigravity,
            .openrouter,
            .grok,
            .codex,
        ]
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: connected.contains(provider))
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let enabledRoster = store.enabledFirstPartyProvidersForDisplay()
        #expect(Set(enabledRoster) == Set(connected))
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let dayOfMonth = try #require(components.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        for provider in enabledRoster {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                provider: provider)
        }
        func snapshot(cost: Double) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: cost,
                costProvenance: .vendorMetered,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: day,
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let scopes = controller.overviewProviderScopes(enabledProviders: enabledRoster)
        let hiddenProvider = try #require(scopes.spend.first { !scopes.visible.contains($0) })
        let pricedProviders = [scopes.visible[0], scopes.visible[1], hiddenProvider]
        store._setTokenSnapshotForTesting(snapshot(cost: 35.09), provider: pricedProviders[0])
        store._setTokenSnapshotForTesting(snapshot(cost: 39.79), provider: pricedProviders[1])
        store._setTokenSnapshotForTesting(snapshot(cost: 10.12), provider: pricedProviders[2])
        store._setTokenSnapshotForTesting(snapshot(cost: 1000), provider: .cursor)

        let duplicateScopes = controller.overviewProviderScopes(
            enabledProviders: enabledRoster + [enabledRoster[0]])
        let model = controller.overviewSpendDashboardModel(providers: scopes.spend, now: now)
        let summary = OverviewSpendSummary(model: model, providerCount: scopes.spend.count)
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let ids = menu.items.compactMap { $0.representedObject as? String }
        let overviewRows = ids.filter { $0.hasPrefix("overviewRow-") }

        #expect(scopes.visible.count == 6)
        #expect(!scopes.visible.contains(hiddenProvider))
        #expect(scopes.spend == enabledRoster)
        #expect(duplicateScopes.spend == enabledRoster)
        #expect(Set(overviewRows) == Set(scopes.visible.map { "overviewRow-\($0.rawValue)" }))
        #expect(overviewRows.count == 6)
        #expect(ids.contains("overviewSpendSummary"))
        #expect(Set(model.groups.first?.providers.map(\.provider) ?? []) == Set(pricedProviders))
        #expect(abs((model.groups.first?.totalCost ?? -1) - 85) < 1e-9)
        #expect(summary.primarySpendText == "~$85.00")
        #expect(summary.providerCoverageText == "3 of 7 subscriptions have spend")
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
