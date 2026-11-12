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

    // MARK: - Fixtures

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let cleanup: () -> Void
    }

    private static func makeFixture(suiteName: String) -> Fixture {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .grok)
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
    private static func completeGrokRefresh(
        _ store: UsageStore,
        tokens: Int,
        scannedAt: Date,
        dayKey: String? = nil)
    {
        let calendar = store.settings.costUsageBucketCalendar
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: CostUsageTokenSnapshot(
                sessionTokens: tokens,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: dayKey ?? Self.dayKey(scannedAt, calendar: calendar),
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: tokens,
                        requestCount: 1,
                        costUSD: nil,
                        modelsUsed: ["grok-4.6"],
                        modelBreakdowns: nil),
                ],
                updatedAt: scannedAt),
            updatedAt: scannedAt)
        store._setSnapshotForTesting(usage, provider: .grok)
        store.publishProviderDerivedTokenSnapshot(from: usage, for: .grok)
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
