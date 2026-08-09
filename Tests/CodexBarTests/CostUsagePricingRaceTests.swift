import Foundation
import Testing
@testable import CodexBarCore

struct CostUsagePricingRaceTests {
    @Test
    func `persisted fallback scan reprices from the current catalog at read time`() throws {
        let fixture = try PricingRaceFixture()
        defer { fixture.environment.cleanup() }

        let fallbackReport = fixture.scan()
        let fallbackCost = try #require(fallbackReport.summary?.totalCostUSD)
        #expect(ModelsDevCache.save(
            catalog: fixture.catalog,
            fetchedAt: fixture.day,
            cacheRoot: fixture.environment.cacheRoot))

        let repriced = fixture.readReport()
        let expected = (100.0 * 10e-6) + (900.0 * 0.1e-6) + (100.0 * 20e-6)
        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - expected) < 1e-12)
        #expect((repriced.summary?.totalCostUSD ?? 0) != fallbackCost)
        #expect(repriced.summary?.cacheReadTokens == 900)
    }

    @Test
    func `cold rebuild cost is independent of pricing table load order`() throws {
        let fallbackFirst = try PricingRaceFixture()
        defer { fallbackFirst.environment.cleanup() }
        _ = fallbackFirst.scan()
        #expect(ModelsDevCache.save(
            catalog: fallbackFirst.catalog,
            fetchedAt: fallbackFirst.day,
            cacheRoot: fallbackFirst.environment.cacheRoot))
        let fallbackFirstReport = fallbackFirst.readReport()

        let catalogFirst = try PricingRaceFixture()
        defer { catalogFirst.environment.cleanup() }
        #expect(ModelsDevCache.save(
            catalog: catalogFirst.catalog,
            fetchedAt: catalogFirst.day,
            cacheRoot: catalogFirst.environment.cacheRoot))
        _ = catalogFirst.scan()
        let catalogFirstReport = catalogFirst.readReport()

        #expect(fallbackFirstReport.data == catalogFirstReport.data)
        #expect(fallbackFirstReport.summary == catalogFirstReport.summary)
    }

    @Test
    func `project usage index reprices persisted tokens from the current catalog`() throws {
        let fixture = try PricingRaceFixture()
        defer { fixture.environment.cleanup() }
        _ = fixture.scan()
        #expect(ModelsDevCache.save(
            catalog: fixture.catalog,
            fetchedAt: fixture.day,
            cacheRoot: fixture.environment.cacheRoot))

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: fixture.day,
            historyDays: 1,
            since: fixture.day,
            until: fixture.day,
            options: fixture.options)
        let expected = (100.0 * 10e-6) + (900.0 * 0.1e-6) + (100.0 * 20e-6)

        #expect(abs((snapshot.projects.first?.estimatedCostUSD ?? 0) - expected) < 1e-12)
        #expect(snapshot.projects.first?.modelBreakdowns.first?.hasUnknownCost == false)
    }

    @Test
    func `project usage snapshot invalidates cached cost when catalog changes`() throws {
        let fixture = try PricingRaceFixture()
        defer { fixture.environment.cleanup() }
        var scannerOptions = fixture.options
        scannerOptions.forceRescan = false
        scannerOptions.refreshMinIntervalSeconds = 60
        let options = CodexLocalProjectUsageIndexer.Options(scannerOptions: scannerOptions)

        let fallback = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.day,
            historyDays: 1,
            forceRefresh: true,
            options: options)
        #expect(ModelsDevCache.save(
            catalog: fixture.catalog,
            fetchedAt: fixture.day,
            cacheRoot: fixture.environment.cacheRoot))

        let repriced = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.day,
            historyDays: 1,
            forceRefresh: false,
            options: options)
        let expected = (100.0 * 10e-6) + (900.0 * 0.1e-6) + (100.0 * 20e-6)

        #expect(fallback.projects.first?.estimatedCostUSD != repriced.projects.first?.estimatedCostUSD)
        #expect(abs((repriced.projects.first?.estimatedCostUSD ?? 0) - expected) < 1e-12)
    }

    @Test
    func `authoritative source cost is not repriced`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 7)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "authoritative-test-model"
        let row = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: nil,
            eventIndex: 0,
            input: 100,
            cached: 90,
            output: 10,
            knownCostNanos: 42_000_000_000)
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            size: 1,
            days: [dayKey: [model: [100, 90, 10]]],
            parsedBytes: 1,
            codexRows: [row],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files[environment.codexSessionsRoot.appendingPathComponent("authoritative.jsonl").path] = usage
        cache.days = usage.days
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier
        _ = CostUsageStoreAccess.replace(
            cacheRoot: environment.cacheRoot,
            cache: cache,
            calendar: range.calendar)

        let expensiveCatalog = try Self.catalog(
            model: model,
            input: 999,
            output: 999,
            cacheRead: 999)
        let restored = CostUsageStoreAccess.read(
            cacheRoot: environment.cacheRoot,
            calendar: range.calendar)
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: restored,
            range: range,
            modelsDevCatalog: expensiveCatalog)

        #expect(report.summary?.totalCostUSD == 42)
        #expect(report.data.first?.modelBreakdowns?.first?.costUSD == 42)
    }

    fileprivate static func catalog(
        model: String,
        input: Double,
        output: Double,
        cacheRead: Double) throws -> ModelsDevCatalog
    {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": { "input": \(input), "output": \(output), "cache_read": \(cacheRead) }
              }
            }
          }
        }
        """.utf8))
    }
}

private struct PricingRaceFixture {
    let environment: CostUsageTestEnvironment
    let day: Date
    let options: CostUsageScanner.Options
    let range: CostUsageScanner.CostUsageDayRange
    let catalog: ModelsDevCatalog

    init() throws {
        let environment = try CostUsageTestEnvironment()
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = environment.isoString(for: day)
        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.6-sol"]],
            [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 1000,
                            "cached_input_tokens": 900,
                            "output_tokens": 100,
                        ],
                    ],
                ],
            ],
        ]
        _ = try environment.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: environment.jsonl(entries))

        self.environment = environment
        self.day = day
        self.options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            cacheRoot: environment.cacheRoot,
            forceRescan: true)
        self.range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        self.catalog = try CostUsagePricingRaceTests.catalog(
            model: "gpt-5.6-sol",
            input: 10,
            output: 20,
            cacheRead: 0.1)
    }

    func scan() -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: self.day,
            until: self.day,
            now: self.day,
            options: self.options)
    }

    func readReport() -> CostUsageDailyReport {
        let cache = CostUsageStoreAccess.read(
            cacheRoot: self.environment.cacheRoot,
            calendar: self.range.calendar)
        return CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: self.range,
            modelsDevCacheRoot: self.environment.cacheRoot)
    }
}
