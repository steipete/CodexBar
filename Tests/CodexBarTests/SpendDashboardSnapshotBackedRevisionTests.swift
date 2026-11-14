import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Snapshot-backed spend sources (Grok, OpenAI API, OpenRouter, ...) republish their token snapshot on
/// every successful provider refresh. The shared Usage & Spend configuration must only change when the
/// published spend changes; otherwise each refresh tick reloads the dashboard and rescans Codex history.
@MainActor
@Suite(.serialized)
struct SpendDashboardSnapshotBackedRevisionTests {
    @Test
    func `unchanged snapshot-backed republication keeps the shared configuration stable`() {
        let fixture = Self.makeFixture(suiteName: "SpendDashboardSnapshotBackedRevisionTests-unchanged")
        defer { fixture.cleanup() }
        let scannedAt = Self.sameDayScanTimes(calendar: fixture.settings.costUsageBucketCalendar)

        Self.completeGrokRefresh(fixture.store, tokens: 40, scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)
        let firstPublicationRevision = fixture.store.tokenSnapshotPublicationRevision(for: .grok)

        Self.completeGrokRefresh(fixture.store, tokens: 40, scannedAt: scannedAt.second)
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        // The provider refresh really did republish; only the dashboard revision must hold still.
        #expect(fixture.store.tokenSnapshotPublicationRevision(for: .grok) != firstPublicationRevision)
        #expect(first.sourceRevisions.contains { $0.hasPrefix("grok:snapshot:") })
        #expect(second.sourceRevisions == first.sourceRevisions)
        #expect(second == first)
    }

    @Test
    func `changed snapshot-backed spend still advances the shared configuration`() {
        let fixture = Self.makeFixture(suiteName: "SpendDashboardSnapshotBackedRevisionTests-changed")
        defer { fixture.cleanup() }
        let scannedAt = Self.sameDayScanTimes(calendar: fixture.settings.costUsageBucketCalendar)

        Self.completeGrokRefresh(fixture.store, tokens: 40, scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        Self.completeGrokRefresh(fixture.store, tokens: 55, scannedAt: scannedAt.second)
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        #expect(second.sourceRevisions != first.sourceRevisions)
    }

    @Test
    func `snapshot-backed scan crossing a bucket day advances the shared configuration`() throws {
        let fixture = Self.makeFixture(suiteName: "SpendDashboardSnapshotBackedRevisionTests-day-rollover")
        defer { fixture.cleanup() }
        let calendar = fixture.settings.costUsageBucketCalendar
        let scannedAt = Self.sameDayScanTimes(calendar: calendar)
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: scannedAt.first))

        Self.completeGrokRefresh(fixture.store, tokens: 40, scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        // Same rows, but source coverage now ends a day later.
        Self.completeGrokRefresh(
            fixture.store,
            tokens: 40,
            scannedAt: nextDay,
            dayKey: Self.dayKey(scannedAt.first, calendar: calendar))
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        #expect(second.sourceRevisions != first.sourceRevisions)
    }

    @Test
    func `unchanged confirmed-empty snapshot-backed republication keeps the shared configuration stable`() {
        let fixture = Self.makeFixture(suiteName: "SpendDashboardSnapshotBackedRevisionTests-empty")
        defer { fixture.cleanup() }
        let scannedAt = Self.sameDayScanTimes(calendar: fixture.settings.costUsageBucketCalendar)

        Self.completeEmptyGrokRefresh(fixture.store, scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)
        let firstPublicationRevision = fixture.store.tokenSnapshotPublicationRevision(for: .grok)

        Self.completeEmptyGrokRefresh(fixture.store, scannedAt: scannedAt.second)
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        #expect(fixture.store.tokenSnapshotPublicationRevision(for: .grok) != firstPublicationRevision)
        #expect(first.sourceRevisions.contains("grok:empty"))
        #expect(second == first)

        // Empty -> data is a real change.
        Self.completeGrokRefresh(fixture.store, tokens: 40, scannedAt: scannedAt.second)
        let third = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)
        #expect(third.sourceRevisions != second.sourceRevisions)
    }

    @Test
    func `correction outside the menu range still advances the shared configuration`() throws {
        let fixture = Self.makeFixture(suiteName: "SpendDashboardSnapshotBackedRevisionTests-wide-window")
        defer { fixture.cleanup() }
        // The menu publication is narrowed to 7 days; Usage & Spend loads the full scan window.
        fixture.settings.costReportingPeriod = .rolling(days: 7)
        let calendar = fixture.settings.costUsageBucketCalendar
        let scannedAt = Self.sameDayScanTimes(calendar: calendar)
        let olderDay = try #require(calendar.date(byAdding: .day, value: -12, to: scannedAt.first))
        let today = Self.entry(day: Self.dayKey(scannedAt.first, calendar: calendar), tokens: 40)

        Self.completeRefresh(
            fixture.store,
            provider: .grok,
            daily: [Self.entry(day: Self.dayKey(olderDay, calendar: calendar), tokens: 90), today],
            scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        Self.completeRefresh(
            fixture.store,
            provider: .grok,
            daily: [Self.entry(day: Self.dayKey(olderDay, calendar: calendar), tokens: 95), today],
            scannedAt: scannedAt.second)
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        #expect(second.sourceRevisions != first.sourceRevisions)
    }

    @Test
    func `UTC-bucketed source advances at its own day boundary`() {
        let fixture = Self.makeFixture(
            suiteName: "SpendDashboardSnapshotBackedRevisionTests-utc-boundary",
            snapshotBackedProvider: .openrouter)
        defer { fixture.cleanup() }
        // 23:59 and 00:01 UTC fall on the same Kiritimati (UTC+14) display day, but OpenRouter
        // coverage is projected in UTC, so the loaded window moves forward a day.
        fixture.settings.costUsageBucketTimeZoneIdentifier = "Pacific/Kiritimati"
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let utcMidnight = utc.startOfDay(for: Date())
        let beforeMidnight = utcMidnight.addingTimeInterval(-60)
        let afterMidnight = utcMidnight.addingTimeInterval(60)
        let display = fixture.settings.costUsageBucketCalendar
        #expect(display.isDate(beforeMidnight, inSameDayAs: afterMidnight))
        let daily = [Self.entry(day: Self.dayKey(beforeMidnight, calendar: utc), tokens: 40)]

        Self.completeRefresh(fixture.store, provider: .openrouter, daily: daily, scannedAt: beforeMidnight)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        Self.completeRefresh(fixture.store, provider: .openrouter, daily: daily, scannedAt: afterMidnight)
        let second = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        #expect(first.sourceRevisions.contains { $0.hasPrefix("openrouter:snapshot:") })
        #expect(second.sourceRevisions != first.sourceRevisions)
    }

    @Test
    func `reasoning-only correction advances the shared configuration`() {
        let fixture = Self.makeFixture(
            suiteName: "SpendDashboardSnapshotBackedRevisionTests-reasoning",
            snapshotBackedProvider: .openrouter)
        defer { fixture.cleanup() }
        let calendar = fixture.settings.costUsageBucketCalendar
        let scannedAt = Self.sameDayScanTimes(calendar: calendar)
        let day = Self.dayKey(scannedAt.first, calendar: calendar)

        Self.completeRefresh(
            fixture.store,
            provider: .openrouter,
            daily: [Self.entry(day: day, tokens: 40, reasoningTokens: 5)],
            scannedAt: scannedAt.first)
        let first = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)

        Self.completeRefresh(
            fixture.store,
            provider: .openrouter,
            daily: [Self.entry(day: day, tokens: 40, reasoningTokens: 5)],
            scannedAt: scannedAt.second)
        let unchanged = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)
        #expect(unchanged == first)

        // Totals, requests, cost, and dates are identical; only the reasoning attribution moved.
        Self.completeRefresh(
            fixture.store,
            provider: .openrouter,
            daily: [Self.entry(day: day, tokens: 40, reasoningTokens: 9)],
            scannedAt: scannedAt.second)
        let corrected = SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store)
        #expect(corrected.sourceRevisions != first.sourceRevisions)
    }

    private actor RefreshFailure {
        private var enabled = false
        func set(_ enabled: Bool) { self.enabled = enabled }
        func get() -> Bool { self.enabled }
    }

    @Test
    func `unchanged refreshes do not reload the dashboard`() async throws {
        let fixture = Self.makeFixture(
            suiteName: "SpendDashboardSnapshotBackedRevisionTests-work", snapshotBackedProvider: .openrouter)
        defer { fixture.cleanup() }
        let now = Self.sameDayScanTimes(calendar: fixture.settings.costUsageBucketCalendar).first
        let events = AsyncStream<SpendDashboardPublication>.makeStream()
        let failures = RefreshFailure()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: SpendDashboardSource.configuration(settings: fixture.settings, store: fixture.store),
                    capturedInputs: [.init(
                        provider: .openrouter,
                        displayName: "OpenRouter",
                        snapshot: fixture.store.snapshot(for: .openrouter)!.costUsage!)],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: now,
                    force: mode.forcesLoader)
            },
            loader: { request in
                if await failures.get() { return .init(inputs: [], failedSourceIDs: ["openrouter"]) }
                return .init(inputs: request.capturedInputs, failedSourceIDs: [])
            },
            nowProvider: { now },
            publicationHandler: { _ = events.continuation.yield($0) })
        defer { controller.stop(); events.continuation.finish() }
        var iterator = events.stream.makeAsyncIterator()
        for cycle in 0..<6 {
            let entry = CostUsageDailyReport.Entry(
                date: Self.dayKey(now, calendar: fixture.settings.costUsageBucketCalendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 40,
                requestCount: 1,
                costUSD: 3,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [.init(modelName: "fixture-model", costUSD: 3, totalTokens: 40)])
            Self.completeRefresh(
                fixture.store,
                provider: .openrouter,
                daily: [entry],
                scannedAt: now.addingTimeInterval(Double(cycle * 60)))
            let previous = controller.generation
            controller.update(configuration: SpendDashboardSource.configuration(
                settings: fixture.settings,
                store: fixture.store))
            if controller.generation != previous {
                while let publication = await iterator.next() {
                    if !publication.isRefreshing { break }
                }
            }
            #expect(controller.model.groups.first?.totalTokens == 40)
            #expect(controller.model.groups.first?.totalCost == 3)
        }
        print("[snapshot-refresh-work] refreshes=6 loads=\(controller.generation) tokens=40 cost=3")
        #expect(controller.generation == 1)
        await failures.set(true)
        controller.refresh()
        while let publication = await iterator.next() {
            if !publication.isRefreshing { break }
        }
        #expect(controller.failedSourceCount == 1)
        await failures.set(false)
        let priorGeneration = controller.generation
        try Self.completeRefresh(
            fixture.store,
            provider: .openrouter,
            daily: #require(fixture.store.snapshot(for: .openrouter)?.costUsage?.daily),
            scannedAt: now.addingTimeInterval(7 * 60))
        controller.update(configuration: SpendDashboardSource.configuration(
            settings: fixture.settings,
            store: fixture.store))
        #expect(controller.generation > priorGeneration)
        if controller.generation > priorGeneration {
            while let publication = await iterator.next() {
                if !publication.isRefreshing { break }
            }
        }
        #expect(controller.failedSourceCount == 0)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.model.groups.first?.totalTokens == 40)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let cleanup: () -> Void
    }

    private static func makeFixture(
        suiteName: String,
        snapshotBackedProvider: UsageProvider = .grok) -> Fixture
    {
        let settings = testSettingsStore(suiteName: suiteName, userDefaults: InMemoryUserDefaults())
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == snapshotBackedProvider)
        }
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        // Isolate from any real ~/.codex or ~/.grok corpus on a developer machine.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-snapshot-backed-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            "CODEX_HOME": root.appendingPathComponent("codex", isDirectory: true).path,
            "GROK_HOME": root.appendingPathComponent("grok", isDirectory: true).path,
        ]
        settings._test_codexReconciliationEnvironment = environment
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return Fixture(settings: settings, store: store, cleanup: {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: root)
        })
    }

    /// Mirrors a successful provider refresh: the usage snapshot is stored, then its derived token
    /// snapshot is published (`UsageStore.publishProviderDerivedTokenSnapshot`).
    private static func completeRefresh(
        _ store: UsageStore,
        provider: UsageProvider,
        daily: [CostUsageDailyReport.Entry],
        scannedAt: Date)
    {
        let tokens = daily.compactMap(\.totalTokens).reduce(0, +)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: CostUsageTokenSnapshot(
                sessionTokens: daily.last?.totalTokens,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: daily,
                updatedAt: scannedAt),
            updatedAt: scannedAt)
        store._setSnapshotForTesting(usage, provider: provider)
        store.publishProviderDerivedTokenSnapshot(from: usage, for: provider)
    }

    private static func completeGrokRefresh(
        _ store: UsageStore,
        tokens: Int,
        scannedAt: Date,
        dayKey: String? = nil)
    {
        let day = dayKey ?? Self.dayKey(scannedAt, calendar: store.settings.costUsageBucketCalendar)
        self.completeRefresh(
            store,
            provider: .grok,
            daily: [Self.entry(day: day, tokens: tokens)],
            scannedAt: scannedAt)
    }

    private static func entry(day: String, tokens: Int, reasoningTokens: Int? = nil) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: reasoningTokens,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: nil,
            modelsUsed: ["grok-4.6"],
            modelBreakdowns: nil)
    }

    private static func completeEmptyGrokRefresh(_ store: UsageStore, scannedAt: Date) {
        let usage = UsageSnapshot(primary: nil, secondary: nil, updatedAt: scannedAt)
        store._setSnapshotForTesting(usage, provider: .grok)
        store.publishProviderDerivedTokenSnapshot(from: usage, for: .grok)
    }

    /// Two scan times one minute apart that can never straddle a bucket-day boundary.
    private static func sameDayScanTimes(calendar: Calendar) -> (first: Date, second: Date) {
        let noon = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        return (noon, noon.addingTimeInterval(60))
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
