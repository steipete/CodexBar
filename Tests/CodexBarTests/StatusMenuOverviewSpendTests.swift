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
    func `shared overview keeps Codex local ledger when global cost tracking is off`() async {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = false
        settings.codexLocalSessionCostLedgerEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)
        let input = SpendDashboardModel.ProviderInput(
            id: "codex:local",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 10,
                sessionCostUSD: 4,
                last30DaysTokens: 10,
                last30DaysCostUSD: 4,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-08-17",
                        inputTokens: 5,
                        outputTokens: 5,
                        totalTokens: 10,
                        costUSD: 4,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now))
        store.spendDashboardPublication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: configuration,
            loadedAt: now,
            isRefreshing: false,
            inputs: [input],
            sources: [
                SpendSourcePublication(
                    id: input.id,
                    provider: .codex,
                    displayName: input.displayName,
                    role: .subscription,
                    state: .available),
            ])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(configuration.costUsageEnabled)
        #expect(configuration.providerIDs == [UsageProvider.codex.rawValue])
        #expect(request.configuration.costUsageEnabled)
        #expect(request.configuration.providerIDs == [UsageProvider.codex.rawValue])
        #expect(controller.overviewSpendDashboardModel(providers: [.codex], now: now).groups.first?.totalCost == 4)
    }

    @Test
    func `overview consumes shared publication without starting a loader`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        let providers: [UsageProvider] = [.codex, .claude]
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        func input(id: String, provider: UsageProvider, cost: Double) -> SpendDashboardModel.ProviderInput {
            SpendDashboardModel.ProviderInput(
                id: id,
                provider: provider,
                displayName: id,
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 10,
                    last30DaysCostUSD: cost,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-08-17",
                            inputTokens: 5,
                            outputTokens: 5,
                            totalTokens: 10,
                            costUSD: cost,
                            modelsUsed: nil,
                            modelBreakdowns: nil),
                    ],
                    updatedAt: now))
        }
        let inputs = [
            input(id: "codex:first", provider: .codex, cost: 2),
            input(id: "codex:second", provider: .codex, cost: 3),
            input(id: "claude", provider: .claude, cost: 7),
        ]
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: providers.map(\.rawValue),
            codexAccountIdentities: ["first|cache-a", "second|cache-b"],
            menuOwnershipFingerprint: SpendDashboardSource.currentMenuOwnershipFingerprint(
                settings: settings,
                store: store))
        store.spendDashboardPublication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: configuration,
            loadedAt: now,
            isRefreshing: false,
            inputs: inputs,
            sources: inputs.map {
                SpendSourcePublication(
                    id: $0.id,
                    provider: $0.provider,
                    displayName: $0.displayName,
                    role: .subscription,
                    state: .available)
            })
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.sharedSpendDashboardControllerStorage == nil)
        let model = controller.overviewSpendDashboardModel(providers: providers, now: now)
        #expect(store.sharedSpendDashboardControllerStorage == nil)
        #expect(Set(model.groups.flatMap(\.providers).map(\.id)) == ["codex:first", "codex:second", "claude"])
        #expect(model.groups.first?.totalCost == 12)
        #expect(controller.overviewSpendSubscriptionCount(providers: providers) == 3)

        guard let claudeMetadata = ProviderRegistry.shared.metadata[.claude] else {
            Issue.record("Claude metadata missing")
            return
        }
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)
        let staleOwnerModel = controller.overviewSpendDashboardModel(providers: providers, now: now)
        #expect(staleOwnerModel.groups.isEmpty)
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
