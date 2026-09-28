import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GrokTokenSnapshotProjectionTests {
    @Test
    func `menu projections reuse published grok session data after the session tree disappears`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-menu-session-tree-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/%2Ftmp%2Frealistic", isDirectory: true)
        let now = Date()
        for index in 0..<192 {
            let directory = sessions.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("signals.json")
            try JSONSerialization.data(withJSONObject: [
                "contextTokensUsed": 5,
                "totalTokensBeforeCompaction": 2,
                "primaryModelId": "grok-4.6",
                "modelsUsed": ["grok-4.6"],
            ]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }

        let store = Self.makeStore(environment: ["GROK_HOME": root.path])
        let published = try #require(await store.loadGrokLocalTokenSnapshot(historyDays: 30))
        #expect(published.last30DaysTokens == 1344)
        #expect(published.last30DaysRequests == nil)
        let day = try #require(published.daily.first?.date)
        let rows = CostHistoryChartMenuView._detailRowsForTesting(
            provider: .grok,
            daily: published.daily,
            selectedDateKey: day)
        #expect(rows.map(\.title) == ["grok-4.6"])
        #expect(rows.allSatisfy { $0.subtitle == nil })

        let providerSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: published,
            updatedAt: now)
        try FileManager.default.removeItem(at: root)

        for _ in 0..<128 {
            #expect(store.tokenSnapshot(fromProviderSnapshot: providerSnapshot, provider: .grok) == published)
        }
    }

    @Test
    func `grok projection narrows published history without another filesystem scan`() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let older = try #require(calendar.date(byAdding: .day, value: -12, to: now))
        let published = Self.snapshot(
            daily: [
                Self.entry(date: Self.dayKey(older, calendar: calendar), tokens: 90),
                Self.entry(date: Self.dayKey(recent, calendar: calendar), tokens: 40),
                Self.entry(date: Self.dayKey(now, calendar: calendar), tokens: 10),
            ],
            updatedAt: now)
        let store = Self.makeStore(environment: [:])
        let providerSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: published,
            updatedAt: now)

        let projected = try #require(store.tokenSnapshot(
            fromProviderSnapshot: providerSnapshot,
            provider: .grok,
            historyDays: 7))

        #expect(projected.historyDays == 7)
        #expect(projected.last30DaysTokens == 50)
        #expect(projected.last30DaysRequests == 2)
        #expect(projected.daily.map(\.totalTokens) == [40, 10])
        #expect(projected.historyCoverageIsEstablished)
    }

    @Test
    func `missing grok billing reuses only its already published fallback`() {
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let published = Self.snapshot(
            daily: [Self.entry(date: Self.dayKey(now, calendar: .current), tokens: 85)],
            updatedAt: now)
        let store = Self.makeStore(environment: [:])

        #expect(store.tokenSnapshot(fromProviderSnapshot: nil, provider: .grok) == nil)
        store.publishTokenSnapshot(published, for: .grok)
        #expect(store.tokenSnapshot(fromProviderSnapshot: nil, provider: .grok) == published)

        let newAccountSnapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now)
        #expect(store.tokenSnapshot(fromProviderSnapshot: newAccountSnapshot, provider: .grok) == nil)
    }

    @Test
    func `requested history wider than the published grok scan preserves its actual coverage`() throws {
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let published = Self.snapshot(
            daily: [Self.entry(date: Self.dayKey(now, calendar: .current), tokens: 85)],
            updatedAt: now)
        let store = Self.makeStore(environment: [:])
        let providerSnapshot = UsageSnapshot(primary: nil, secondary: nil, costUsage: published, updatedAt: now)

        let projected = try #require(store.tokenSnapshot(
            fromProviderSnapshot: providerSnapshot,
            provider: .grok,
            historyDays: 60))

        #expect(projected.historyDays == 30)
        #expect(projected.historyCoverageIsEstablished)
        #expect(projected.last30DaysTokens == 85)
    }

    @Test
    func `successful quota refresh keeps local tokens in wider dashboard requests`() async throws {
        let now = Date()
        let published = Self.snapshot(
            daily: [Self.entry(date: Self.dayKey(now, calendar: .current), tokens: 85)],
            updatedAt: now)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-dashboard-\(UUID())")
        let store = Self.makeStore(environment: ["GROK_HOME": home.path])
        store.settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.grok])
        store.settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)
        store._test_providerFetchOutcomeOverride = { _ in
            .init(result: .success(ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: .init(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    costUsage: published,
                    updatedAt: now),
                credits: nil,
                dashboard: nil,
                sourceLabel: "grok-cli-proxy",
                strategyID: "grok.fixture",
                strategyKind: .web)), attempts: [])
        }

        await store.refreshProvider(.grok, allowDisabled: true)
        #expect(store.snapshot(for: .grok)?.costUsage?.last30DaysTokens == 85)
        let request = await SpendDashboardSource.makeRequest(
            settings: store.settings, store: store, mode: .captureOnly, now: now)
        let history = try #require(request.capturedInputs.first { $0.provider == .grok }?.snapshot)
        #expect(history.historyDays == 30)
        #expect(history.historyCoverageIsEstablished)
        let model = SpendDashboardModel.build(inputs: request.capturedInputs, requestedDays: 60, now: now)
        let row = try #require(model.groups.flatMap(\.providers).first { $0.provider == .grok })
        #expect(row.totalTokens == 85)
        #expect(row.coveredDayCount == 30)
        let shared = try #require(ShareStatsBuilder.make(model: model))
        #expect(shared.providers.first { $0.provider == .grok }?.totalTokens == 85)
        #expect(shared.providers.first { $0.provider == .grok }?.estimatedCost == nil)
    }

    private static func makeStore(environment: [String: String]) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "GrokTokenSnapshotProjectionTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(
                homeDirectory: environment["GROK_HOME"] ?? "/nonexistent",
                cacheTTL: 0,
                fileExists: { _ in false },
                directoryContents: { _ in [] }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    private static func snapshot(
        daily: [CostUsageDailyReport.Entry],
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: daily.last?.totalTokens,
            sessionCostUSD: nil,
            last30DaysTokens: daily.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: daily,
            updatedAt: updatedAt)
    }

    private static func entry(date: String, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: nil,
            modelsUsed: ["grok-4.6"],
            modelBreakdowns: nil)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
