import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GrokTokenSnapshotProjectionTests: GrokLocalSessionScannerTestSupport {
    @Test
    func `menu projections reuse published grok session data after the session tree disappears`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-menu-session-tree-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/%2Ftmp%2Frealistic", isDirectory: true)
        let now = Date()
        for index in 0..<192 {
            let directory = sessions.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try self.writeUpdates(
                [self.turn(timestamp: now, usage: self.singleModelUsage(input: 5, output: 2))],
                to: directory.appendingPathComponent("updates.jsonl"),
                modificationDate: now)
        }

        let store = Self.makeStore(environment: ["GROK_HOME": root.path])
        let published = try #require(await store.loadGrokLocalTokenSnapshot(historyDays: 30))
        #expect(published.last30DaysTokens == 1344)
        #expect(published.last30DaysRequests == 192)

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
    func `requested history wider than the published grok scan is marked incomplete`() throws {
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

        #expect(projected.historyDays == 60)
        #expect(!projected.historyCoverageIsEstablished)
        #expect(projected.last30DaysTokens == 85)
    }

    private static func makeStore(environment: [String: String]) -> UsageStore {
        let suite = "GrokTokenSnapshotProjectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    /// The projection recomputes tokens and requests from the days it keeps, so the cost has to follow. A
    /// 30-day view rendering the 365-day dollar total beside a 30-day token count is the visible symptom.
    @Test
    func `grok projection recomputes window cost from the days it keeps`() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let older = try #require(calendar.date(byAdding: .day, value: -120, to: now))
        let published = Self.snapshot(
            daily: [
                Self.entry(date: Self.dayKey(older, calendar: calendar), tokens: 900, costUSD: 9),
                Self.entry(date: Self.dayKey(recent, calendar: calendar), tokens: 100, costUSD: 1),
            ],
            updatedAt: now,
            historyDays: 365,
            costProvenance: .vendorMetered)
        let store = Self.makeStore(environment: [:])

        let narrowed = try #require(store.grokLocalTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, costUsage: published, updatedAt: now),
            historyDays: 30))

        #expect(published.last30DaysCostUSD == 10)
        #expect(narrowed.last30DaysTokens == 100)
        #expect(narrowed.last30DaysCostUSD == 1)
    }

    /// A narrowed window can drop every row of one kind, and its disclosure has to follow the rows it kept.
    @Test
    func `grok projection derives window provenance from the days it keeps`() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let older = try #require(calendar.date(byAdding: .day, value: -120, to: now))
        let store = Self.makeStore(environment: [:])

        let recordedRecently = Self.snapshot(
            daily: [
                Self.entry(
                    date: Self.dayKey(older, calendar: calendar),
                    tokens: 900,
                    costUSD: 9,
                    estimatedRequestCount: 1),
                Self.entry(date: Self.dayKey(recent, calendar: calendar), tokens: 100, costUSD: 1),
            ],
            updatedAt: now,
            historyDays: 365,
            costProvenance: .mixed)
        let narrowedToRecorded = try #require(store.grokLocalTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, costUsage: recordedRecently, updatedAt: now),
            historyDays: 30))
        #expect(narrowedToRecorded.costProvenance == .vendorMetered)

        let estimatedRecently = Self.snapshot(
            daily: [
                Self.entry(date: Self.dayKey(older, calendar: calendar), tokens: 900, costUSD: 9),
                Self.entry(
                    date: Self.dayKey(recent, calendar: calendar),
                    tokens: 100,
                    costUSD: 1,
                    estimatedRequestCount: 1),
            ],
            updatedAt: now,
            historyDays: 365,
            costProvenance: .mixed)
        let narrowedToEstimated = try #require(store.grokLocalTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, costUsage: estimatedRecently, updatedAt: now),
            historyDays: 30))
        #expect(narrowedToEstimated.costProvenance == .listPriceEstimate)
    }

    @Test(arguments: [false, true], [false, true])
    func `live Grok consumers retain the source of a narrowed mixed publication`(
        estimatedRecently: Bool,
        hasRemoteSnapshot: Bool) throws
    {
        let published = try Self.mixedSnapshot(estimatedRecently: estimatedRecently)
        let store = Self.makeStore(environment: [:])
        store.publishTokenSnapshot(published, for: .grok)
        let remote = hasRemoteSnapshot ? UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: Self.snapshot(daily: published.daily, updatedAt: published.updatedAt.addingTimeInterval(-60)),
            updatedAt: published.updatedAt.addingTimeInterval(-60)) : nil

        let selected = try #require(store.tokenSnapshotForLiveProviderConsumer(
            fromProviderSnapshot: remote,
            provider: .grok,
            historyDays: 30))

        #expect(selected.last30DaysTokens == 100)
        #expect(selected.last30DaysCostUSD == 1)
        #expect(selected.updatedAt == published.updatedAt)
        #expect(selected.costProvenance == (estimatedRecently ? .listPriceEstimate : .vendorMetered))
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .grok, displayName: "Grok", snapshot: selected)],
            requestedDays: 30,
            now: selected.updatedAt)
        #expect(dashboard.groups.first?.provenance == selected.costProvenance)
    }

    @Test(arguments: [false, true])
    func `new and shared Grok scans retain the source of the requested window`(estimatedRecently: Bool) async throws {
        let published = try Self.mixedSnapshot(estimatedRecently: estimatedRecently)
        let store = Self.makeStore(environment: [:])
        let metadata = try #require(ProviderRegistry.shared.metadata[.grok])
        store.settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)
        store._test_grokLocalTokenScannerOverride = { _ in published }

        let first = try #require(await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 30))
        #expect(first.costProvenance == (estimatedRecently ? .listPriceEstimate : .vendorMetered))
        #expect(first.last30DaysCostUSD == 1)

        store.grokLocalTokenScanTask = Task { published }
        defer { store.grokLocalTokenScanTask = nil }
        let shared = try #require(await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 30))
        #expect(shared.costProvenance == (estimatedRecently ? .listPriceEstimate : .vendorMetered))
        #expect(shared == first)
    }

    private static func mixedSnapshot(estimatedRecently: Bool) throws -> CostUsageTokenSnapshot {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let older = try #require(calendar.date(byAdding: .day, value: -120, to: now))
        return Self.snapshot(
            daily: [
                Self.entry(
                    date: Self.dayKey(older, calendar: calendar),
                    tokens: 900,
                    costUSD: 9,
                    estimatedRequestCount: estimatedRecently ? nil : 1),
                Self.entry(
                    date: Self.dayKey(recent, calendar: calendar),
                    tokens: 100,
                    costUSD: 1,
                    estimatedRequestCount: estimatedRecently ? 1 : nil),
            ],
            updatedAt: now,
            historyDays: 365,
            costProvenance: .mixed)
    }

    private static func snapshot(
        daily: [CostUsageDailyReport.Entry],
        updatedAt: Date,
        historyDays: Int = 30,
        costProvenance: CostProvenance = .unknown) -> CostUsageTokenSnapshot
    {
        let costs = daily.compactMap(\.costUSD)
        return CostUsageTokenSnapshot(
            sessionTokens: daily.last?.totalTokens,
            sessionCostUSD: nil,
            last30DaysTokens: daily.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            historyDays: historyDays,
            costProvenance: costProvenance,
            daily: daily,
            updatedAt: updatedAt)
    }

    private static func entry(
        date: String,
        tokens: Int,
        costUSD: Double? = nil,
        estimatedRequestCount: Int? = nil) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: costUSD,
            modelsUsed: ["grok-4.6"],
            modelBreakdowns: nil,
            estimatedRequestCount: estimatedRequestCount)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
