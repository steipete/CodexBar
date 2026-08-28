import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuCodexCostHistoryRefreshTests {
    @Test
    func `codex cost history preserves identity when hidden project nested data changes`() throws {
        try self.assertCodexCostHistoryPreservesIdentity(
            mutate: { snapshot in
                var projects = snapshot.projects
                guard projects.count > 5 else { return snapshot }
                projects[5] = Self.makeCodexProject(
                    index: 5,
                    sourceCount: 1,
                    nestedDailyCost: 99.0)
                return Self.copySnapshot(snapshot, projects: projects)
            })
    }

    @Test
    func `codex cost history preserves identity when visible project nested data changes`() throws {
        try self.assertCodexCostHistoryPreservesIdentity(
            mutate: { snapshot in
                var projects = snapshot.projects
                guard !projects.isEmpty else { return snapshot }
                projects[0] = Self.makeCodexProject(
                    index: 0,
                    sourceCount: 1,
                    nestedDailyCost: 99.0)
                return Self.copySnapshot(snapshot, projects: projects)
            })
    }

    @Test
    func `codex cost history rebuilds when daily cost changes`() throws {
        try self.assertCodexCostHistoryRebuilds(
            mutate: { snapshot in
                Self.copySnapshot(snapshot, dailyCost: 9.87)
            })
    }

    @Test
    func `hydrated codex cost history stores the same fingerprint as refresh`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = Self.makeSettings()
        settings.costUsageEnabled = true
        Self.enableOnly(settings, provider: .codex)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(Self.makeCodexCostSnapshot(), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let width = StatusItemController.menuCardBaseWidth
        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex,
            width: width)
        controller.menuWillOpen(submenu)

        let stored = try #require(controller._storedHostedSubviewRenderSignatureForTesting(menu: submenu))
        let recomputed = try #require(controller._hostedSubviewRenderSignatureForTesting(menu: submenu, width: width))
        #expect(stored == recomputed)

        controller.refreshHostedSubviewMenu(submenu)
        #expect(controller._storedHostedSubviewRenderSignatureForTesting(menu: submenu) == recomputed)
    }

    private func assertCodexCostHistoryPreservesIdentity(
        mutate: (CostUsageTokenSnapshot) -> CostUsageTokenSnapshot) throws
    {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = Self.makeSettings()
        settings.costUsageEnabled = true
        Self.enableOnly(settings, provider: .codex)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(Self.makeCodexCostSnapshot(), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex,
            width: StatusItemController.menuCardBaseWidth)
        controller.menuWillOpen(submenu)

        let hydratedView = try #require(submenu.items.first?.view)
        store._setTokenSnapshotForTesting(mutate(Self.makeCodexCostSnapshot()), provider: .codex)
        controller.refreshHostedSubviewMenu(submenu)

        #expect(submenu.items.first?.view === hydratedView)
    }

    private func assertCodexCostHistoryRebuilds(
        mutate: (CostUsageTokenSnapshot) -> CostUsageTokenSnapshot) throws
    {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = Self.makeSettings()
        settings.costUsageEnabled = true
        Self.enableOnly(settings, provider: .codex)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(Self.makeCodexCostSnapshot(), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex,
            width: StatusItemController.menuCardBaseWidth)
        controller.menuWillOpen(submenu)

        let hydratedView = try #require(submenu.items.first?.view)
        store._setTokenSnapshotForTesting(mutate(Self.makeCodexCostSnapshot()), provider: .codex)
        controller.refreshHostedSubviewMenu(submenu)

        #expect(submenu.items.first?.view !== hydratedView)
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexCostHistoryRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func enableOnly(_ settings: SettingsStore, provider enabledProvider: UsageProvider) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == enabledProvider)
        }
    }

    private static func makeCodexCostSnapshot(
        dailyCost: Double = 1.23,
        projectCount: Int = 6) -> CostUsageTokenSnapshot
    {
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
            projects: (0..<projectCount).map { Self.makeCodexProject(index: $0, sourceCount: 1) },
            updatedAt: Date())
    }

    private static func copySnapshot(
        _ snapshot: CostUsageTokenSnapshot,
        dailyCost: Double? = nil,
        projects: [CostUsageProjectBreakdown]? = nil) -> CostUsageTokenSnapshot
    {
        let daily = snapshot.daily.map { entry in
            CostUsageDailyReport.Entry(
                date: entry.date,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                totalTokens: entry.totalTokens,
                costUSD: dailyCost ?? entry.costUSD,
                modelsUsed: entry.modelsUsed,
                modelBreakdowns: entry.modelBreakdowns)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: dailyCost ?? snapshot.last30DaysCostUSD,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyLabel: snapshot.historyLabel,
            daily: daily,
            projects: projects ?? snapshot.projects,
            updatedAt: snapshot.updatedAt)
    }

    private static func makeCodexProject(
        index: Int,
        sourceCount: Int,
        nestedDailyCost: Double = 0.01) -> CostUsageProjectBreakdown
    {
        let nestedDaily = [
            CostUsageDailyReport.Entry(
                date: "2025-12-23",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 10,
                costUSD: nestedDailyCost,
                modelsUsed: ["nested"],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "nested-model",
                        costUSD: nestedDailyCost,
                        totalTokens: 10),
                ]),
        ]
        return CostUsageProjectBreakdown(
            name: "Project-\(index)",
            path: "/tmp/project-\(index)",
            totalTokens: 100 + index,
            totalCostUSD: 1.0 + Double(index),
            daily: nestedDaily,
            modelBreakdowns: [
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "project-model",
                    costUSD: nestedDailyCost,
                    totalTokens: 10),
            ],
            sources: (0..<sourceCount).map { sourceIndex in
                CostUsageProjectSourceBreakdown(
                    name: "Source-\(sourceIndex)",
                    path: "/tmp/project-\(index)/source-\(sourceIndex)",
                    totalTokens: 10 + sourceIndex,
                    totalCostUSD: 0.5,
                    daily: nestedDaily,
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "source-model",
                            costUSD: nestedDailyCost,
                            totalTokens: 10),
                    ])
            })
    }
}
