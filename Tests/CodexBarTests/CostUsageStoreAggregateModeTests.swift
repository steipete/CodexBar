import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageStoreAggregateModeTests {
    private struct Fixture: Sendable {
        let root: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBar-AggregateModeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private static func makeCache(path: String) -> CostUsageCache {
        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 200,
            days: ["2026-08-01": ["model-a": [10, 2, 5]]])
        usage.parsedBytes = 200
        usage.codexScanFileId = "1:42"
        usage.codexScanComplete = true
        usage.codexTokenTimestampsMonotonic = true
        usage.codexTokenSnapshots = [
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-08-01T12:00:00Z",
                last: CostUsageCodexTotals(input: 3, cached: 1, output: 2),
                total: CostUsageCodexTotals(input: 30, cached: 10, output: 20),
                endOffset: 100),
        ]
        usage.codexRows = [
            CostUsageScanner.CodexUsageRow(
                day: "2026-08-01",
                model: "model-a",
                turnID: "turn-0",
                eventIndex: 0,
                timestampUnixMs: 1_754_046_000_000,
                input: 10,
                cached: 2,
                output: 5,
                reasoning: 3),
        ]

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-08-01"
        cache.scanUntilKey = "2026-08-01"
        cache.files = [path: usage]
        cache.days = usage.days
        cache.lastScanUnixMs = 1000
        return cache
    }

    @Test
    func `aggregate mode skips rows and token snapshots`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        _ = store.syncSaveCodexCache(
            Self.makeCache(path: "/rollouts/a.jsonl"),
            calendar: .current,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"))

        // Aggregate mode must not query the row/token tables at all, so their snapshots
        // are empty while files and day aggregates remain populated.
        let aggregateSnapshot = await store.readSnapshot(skipRowTables: true)
        #expect(aggregateSnapshot.usageRows.isEmpty)
        #expect(aggregateSnapshot.tokenSnapshots.isEmpty)
        #expect(!aggregateSnapshot.files.isEmpty)
        #expect(!aggregateSnapshot.dayAggregates.isEmpty)

        let aggregate = store.syncLoadCodexCache(calendar: .current, mode: .aggregateReport)
        let scanReady = store.syncLoadCodexCache(calendar: .current, mode: .scanReady)

        for (path, usage) in aggregate.files {
            // Aggregate mode synthesizes rows from day aggregates instead of decoding stored
            // row payloads, and leaves token snapshots empty.
            #expect(usage.codexRows?.isEmpty == false)
            #expect(usage.codexRows?.allSatisfy { $0.turnID == nil && $0.eventIndex == nil } == true)
            #expect(usage.codexTokenSnapshots?.isEmpty == true)
            let scanUsage = try #require(scanReady.files[path])
            #expect(scanUsage.codexRows?.isEmpty == false)
            #expect(scanUsage.codexRows?.contains { $0.turnID != nil } == true)
            #expect(scanUsage.codexTokenSnapshots?.isEmpty == false)
        }
        #expect(!scanReady.files.isEmpty)
        #expect(aggregate.days == scanReady.days)
    }

    @Test
    func `report output is equivalent across load modes`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        _ = store.syncSaveCodexCache(
            Self.makeCache(path: "/rollouts/a.jsonl"),
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"))

        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)

        let aggregateReport = CostUsageScanner.buildCodexReportFromCache(
            cache: store.syncLoadCodexCache(calendar: calendar, mode: .aggregateReport),
            range: range)
        let scanReadyReport = CostUsageScanner.buildCodexReportFromCache(
            cache: store.syncLoadCodexCache(calendar: calendar, mode: .scanReady),
            range: range)

        #expect(aggregateReport.data == scanReadyReport.data)
        #expect(aggregateReport.summary?.totalInputTokens == scanReadyReport.summary?.totalInputTokens)
        #expect(aggregateReport.summary?.totalOutputTokens == scanReadyReport.summary?.totalOutputTokens)
        let aggregateReasoning = aggregateReport.data.reduce(0) { $0 + ($1.reasoningTokens ?? 0) }
        let scanReadyReasoning = scanReadyReport.data.reduce(0) { $0 + ($1.reasoningTokens ?? 0) }
        #expect(aggregateReasoning > 0)
        #expect(aggregateReasoning == scanReadyReasoning)
        #expect(aggregateReport.summary?.totalCostUSD == scanReadyReport.summary?.totalCostUSD)
    }
}
