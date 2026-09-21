import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendDashboardClaudeCacheRoutingTests {
    @Test
    func `real dashboard and menu loaders keep separate Claude cache windows`() async throws {
        let fixture = try CostUsageClaudeReportContextTests.Fixture(now: Date())
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "same", input: 10)
            + fixture.event(day: fixture.day(-120), id: "same", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "session.jsonl", contents: contents)
        #expect(try ModelsDevCache.save(
            catalog: CostUsageClaudeResolverTests.simpleCatalog([
                "claude-sonnet-4-20250514": 3,
                "claude-sonnet-4": 3,
            ]),
            fetchedAt: Date(),
            cacheRoot: fixture.env.cacheRoot))
        let pricingURL = ModelsDevCache.cacheFileURL(cacheRoot: fixture.env.cacheRoot)
        let pricingData = try Data(contentsOf: pricingURL)
        let settings = testSettingsStore(
            suiteName: "SpendDashboardClaudeCacheRoutingTests",
            userDefaults: InMemoryUserDefaults())
        var options = fixture.options
        options.calendar = settings.costUsageBucketCalendar
        let costFetcher = CostUsageFetcher(scannerOptions: options)
        for days in [365, 30] {
            _ = try await costFetcher.loadTokenSnapshot(
                provider: .claude,
                environment: [:],
                now: fixture.now,
                historyDays: days,
                allowPricingRefresh: false,
                includePiSessions: false)
        }
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude || provider == .pi)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: costFetcher,
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["HOME": fixture.env.root.path],
            widgetSnapshotURL: fixture.env.root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})

        let menu = try await store.loadTokenUsageSnapshot(
            provider: .claude,
            force: false,
            now: fixture.now,
            codexHomePath: nil,
            historyDays: 30,
            includePiSessions: false)
        #expect(menu.snapshot.last30DaysTokens == 10)
        let regularURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let regularData = try Data(contentsOf: regularURL)

        await store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        let dashboard = try #require(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .claude)?
            .snapshot)
        #expect(dashboard.historyDays == 365)
        #expect(dashboard.last30DaysTokens == 20)
        #expect(try Data(contentsOf: regularURL) == regularData)
        #expect(try Data(contentsOf: pricingURL) == pricingData)
        let history = CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: fixture.env.cacheRoot,
            reportContext: .spendDashboard)
        let regular = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        #expect(try #require(history.usage.scanSinceKey) < #require(regular.usage.scanSinceKey))
    }
}
