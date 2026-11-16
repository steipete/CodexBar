import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityIncrementalScanCacheTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `histories exceeding cumulative 64 MiB encoding budget converge across sharded batches`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])

        // Seed 265 cached databases with 1,050 cached events each (278,250 events total; > 64 MiB at 256B/event),
        // while keeping every individual database entry well below the 64 MiB per-fragment limit.
        var seededEntries: [String: AntigravityLocalScanCache.CachedDatabaseEntry] = [:]
        for dbIndex in 0..<265 {
            let dbURL = try fixture.database("seeded-\(dbIndex)", blobs: [Fixture.blob()])
            let key = dbURL.standardizedFileURL.path
            let fingerprint = try #require(AntigravityLocalScanCache.DatabaseFingerprint.current(for: dbURL))
            let events = (0..<1050).map { row in
                let event = AntigravityLocalReader.Event(
                    session: "seeded-\(dbIndex)",
                    row: Int64(row),
                    turn: AntigravityProtoReader.ParsedTurn(
                        usage: AntigravityProtoReader.ParsedUsage(
                            newInput: 1,
                            cacheRead: 0,
                            output: 1,
                            reasoning: 0,
                            responseID: "resp-\(dbIndex)-\(row)",
                            modelID: 1298,
                            botID: nil),
                        timestampMs: 1_787_832_000_000,
                        model: "claude-sonnet-4-6",
                        label: "Claude Sonnet 4.6",
                        stepUUID: nil),
                    cacheWrite: 0)!
                return AntigravityLocalScanCache.CachedEvent(event: event)!
            }
            seededEntries[key] = AntigravityLocalScanCache.CachedDatabaseEntry(
                fingerprint: fingerprint,
                containsHistorySource: true,
                events: events)
        }
        #expect(AntigravityLocalScanCacheIO.saveIncremental(
            scope: scope,
            activeKeys: Set(seededEntries.keys),
            updatedEntries: seededEntries,
            retainedComplete: nil,
            cacheRoot: cacheRoot))

        // Add two pending databases and cap each batch at 1 database to force multi-batch convergence beyond 64 MiB.
        try fixture.database("pending-a", blobs: [Fixture.blob(input: 10, output: 5, cacheRead: 0, reasoning: 0)])
        try fixture.database("pending-b", blobs: [Fixture.blob(input: 20, output: 5, cacheRead: 0, reasoning: 0)])

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1
        limits.rows = 1_000_000
        limits.duration = 120

        let batch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch1.coverage == .partial)
        #expect(batch1.catchUpPending)
        #expect(batch1.batchMadeProgress)

        let batch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch2.coverage == .complete)
        #expect(!batch2.catchUpPending)
        #expect(batch2.batchMadeProgress)
        #expect(batch2.report.summary?.totalTokens == 265 * 1050 * 2 + 15 + 25)

        let reloaded = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: cacheRoot, scope: scope)
        #expect(reloaded.indexedKeys.count == 267)
    }

    @Test
    func `legacy inline v2 cache exceeding 16 MiB index ceiling loads and migrates to sharded fragments`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        let dbURL = try fixture.database("legacy-big", blobs: [Fixture.blob()])
        let key = dbURL.standardizedFileURL.path
        let fingerprint = try #require(AntigravityLocalScanCache.DatabaseFingerprint.current(for: dbURL))
        let events = (0..<75000).map { row in
            let event = AntigravityLocalReader.Event(
                session: "legacy-big",
                row: Int64(row),
                turn: AntigravityProtoReader.ParsedTurn(
                    usage: AntigravityProtoReader.ParsedUsage(
                        newInput: 1,
                        cacheRead: 0,
                        output: 1,
                        reasoning: 0,
                        responseID: "legacy-resp-\(row)",
                        modelID: 1298,
                        botID: nil),
                    timestampMs: 1_787_832_000_000,
                    model: "claude-sonnet-4-6",
                    label: "Claude Sonnet 4.6",
                    stepUUID: nil),
                cacheWrite: 0)!
            return AntigravityLocalScanCache.CachedEvent(event: event)!
        }
        let retained = AntigravityLocalScanCache.RetainedCompleteReport(
            updatedAtUnixMs: 1_787_832_000_000,
            timeZoneIdentifier: Fixture.calendar.timeZone.identifier,
            estimateCost: false,
            report: CostUsageDailyReport(data: [], summary: .init(
                totalInputTokens: 65000,
                totalOutputTokens: 65000,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                totalTokens: 130_000,
                totalCostUSD: nil)))
        let legacyCache = AntigravityLocalScanCache(
            version: AntigravityLocalScanCacheIO.cacheVersion,
            scope: scope,
            databases: [
                key: AntigravityLocalScanCache.CachedDatabaseEntry(
                    fingerprint: fingerprint,
                    containsHistorySource: true,
                    events: events),
            ],
            retainedComplete: retained)

        let legacyURL = AntigravityLocalScanCacheIO.cacheFileURL(cacheRoot: cacheRoot, scope: scope)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encodedLegacy = try JSONEncoder().encode(legacyCache)
        #expect(encodedLegacy.count > 16 * 1024 * 1024)
        try encodedLegacy.write(to: legacyURL, options: [.atomic])

        let loaded = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: cacheRoot, scope: scope)
        #expect(loaded.indexedKeys.count == 1)
        #expect(loaded.legacyDatabases?[key]?.events.count == 75000)
        #expect(loaded.retainedComplete?.report.summary?.totalTokens == 130_000)

        let migrated = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(migrated.coverage == .complete)
        #expect(migrated.report.summary?.totalTokens == 150_000)
        let migratedIndexData = try Data(contentsOf: legacyURL)
        #expect(migratedIndexData.count < 4096)
        let migratedIndex = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: cacheRoot, scope: scope)
        #expect(migratedIndex.legacyDatabases == nil)
        #expect(AntigravityLocalScanCacheIO.loadFragment(cacheRoot: cacheRoot, scope: scope, key: key)?
            .events.count == 75000)
    }

    @Test
    func `fragment replay stops at byte limit and preserves retained complete report`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        var seededEntries: [String: AntigravityLocalScanCache.CachedDatabaseEntry] = [:]
        for index in 0..<4 {
            let dbURL = try fixture.database("frag-\(index)", blobs: [Fixture.blob()])
            let key = dbURL.standardizedFileURL.path
            let fingerprint = try #require(AntigravityLocalScanCache.DatabaseFingerprint.current(for: dbURL))
            let event = try #require(AntigravityLocalReader.Event(
                session: "frag-\(index)",
                row: 0,
                turn: AntigravityProtoReader.ParsedTurn(
                    usage: AntigravityProtoReader.ParsedUsage(
                        newInput: 100,
                        cacheRead: 50,
                        output: 37,
                        reasoning: 0,
                        responseID: "resp-\(index)",
                        modelID: 1298,
                        botID: nil),
                    timestampMs: 1_787_832_000_000,
                    model: "claude-sonnet-4-6",
                    label: "Claude Sonnet 4.6",
                    stepUUID: nil),
                cacheWrite: 0))
            seededEntries[key] = try AntigravityLocalScanCache.CachedDatabaseEntry(
                fingerprint: fingerprint,
                containsHistorySource: true,
                events: [#require(AntigravityLocalScanCache.CachedEvent(event: event))])
        }
        let retained = AntigravityLocalScanCache.RetainedCompleteReport(
            updatedAtUnixMs: 1_787_832_000_000,
            timeZoneIdentifier: Fixture.calendar.timeZone.identifier,
            estimateCost: false,
            report: CostUsageDailyReport(
                data: [.init(
                    date: "2026-08-27",
                    inputTokens: 400,
                    outputTokens: 148,
                    cacheReadTokens: 200,
                    cacheCreationTokens: 0,
                    reasoningTokens: 0,
                    totalTokens: 748,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: [])],
                summary: .init(
                    totalInputTokens: 400,
                    totalOutputTokens: 148,
                    cacheReadTokens: 200,
                    cacheCreationTokens: 0,
                    totalTokens: 748,
                    totalCostUSD: nil)))
        #expect(AntigravityLocalScanCacheIO.saveIncremental(
            scope: scope,
            activeKeys: Set(seededEntries.keys),
            updatedEntries: seededEntries,
            retainedComplete: retained,
            cacheRoot: cacheRoot))

        let bounded = try AntigravityLocalReader.makeIncrementalDailyReportWithStatus(
            AntigravityLocalReader.IncrementalScanRequest(
                context: fixture.context,
                calendar: Fixture.calendar,
                estimateCost: false,
                pricing: nil,
                scanCacheRoot: cacheRoot,
                now: Fixture.now,
                budget: AntigravityLocalReader.Budget(limits: .init(), cancellation: {}),
                maximumReplayBytes: 1024))
        #expect(bounded.coverage == .partial)
        #expect(bounded.catchUpPending)
        #expect(bounded.report.summary?.totalTokens == 748)

        // Streaming incremental reader still discovers and converges newly added conversations past that bound.
        try fixture.database("frag-new", blobs: [Fixture.blob(input: 50, output: 10, cacheRead: 0, reasoning: 0)])
        let updated = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(updated.coverage == .complete)
        #expect(!updated.catchUpPending)
        #expect(updated.report.summary?.totalTokens == 748 + 60)
    }

    @Test
    func `pending scan reserves duration budget after slow cache replay`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        try fixture.database("cached-a", blobs: [Fixture.blob(input: 100, output: 50, cacheRead: 0, reasoning: 0)])

        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)

        // Add a new pending database and simulate 30s elapsed during cache replay (after discovery,
        // before pending scan starts) so excluding replay time lets the pending DB finish within 25s.
        try fixture.database(
            "pending-after-replay",
            blobs: [Fixture.blob(input: 20, output: 5, cacheRead: 0, reasoning: 0)])
        var clockCallCount = 0
        var limits = AntigravityLocalReader.Limits()
        limits.duration = 25

        let result = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits,
            clock: {
                defer { clockCallCount += 1 }
                // Calls 0..7 cover Budget.init, discovery (3 roots + 2 files), and replayStarted;
                // call 8 (excludeElapsedSince) and all subsequent pending-scan checks see +30s.
                return clockCallCount <= 7 ? 0 : 30
            })
        #expect(result.coverage == .complete)
        #expect(!result.catchUpPending)
        #expect(result.batchMadeProgress)
        #expect(result.report.summary?.totalTokens == 150 + 25)
    }

    @Test
    func `label-only turns across cached fragments resolve inherited models via compact buckets`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)

        let b0 = Fixture.blob(model: nil, label: "Claude Sonnet 4.6", input: 40, output: 10, cacheRead: 0, reasoning: 0)
        let b1 = Fixture.blob(model: nil, label: "Claude Sonnet 4.6", input: 60, output: 15, cacheRead: 0, reasoning: 0)
        let b2 = Fixture.blob(
            model: "claude-sonnet-4-6",
            label: "Claude Sonnet 4.6",
            input: 20,
            output: 5,
            cacheRead: 0,
            reasoning: 0)

        // Two copies/batches of the same logical session: one has only label-only turns (model == nil),
        // the second adds row 2 introducing the model mapping for that label.
        try fixture.database("conv-label", rootIndex: 0, blobs: [b0, b1])
        try fixture.database("conv-label", rootIndex: 1, blobs: [b0, b1, b2])

        let first = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(first.coverage == .complete)
        #expect(first.report.summary?.totalTokens == 150)

        // Second pass replays both sharded fragments and must preserve the same token & model attribution.
        let replayed = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(replayed.coverage == .complete)
        #expect(replayed.statistics.files == 0)
        #expect(replayed.report.summary?.totalTokens == 150)
        #expect(replayed.report.data.first?.modelBreakdowns?.first?.modelName == "claude-sonnet-4-6")
    }

    @Test
    func `two 120k label-only turns on historical date price per-request below 200k threshold`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let feb20Seconds: UInt64 = 1_771_588_800 // 2026-02-20 12:00 UTC (< historical cutoff)

        try fixture.database(
            "conv-historical",
            blobs: [
                Fixture.blob(
                    model: nil,
                    label: "Claude Sonnet 4.6",
                    input: 120_000,
                    output: 0,
                    cacheRead: 0,
                    reasoning: 0,
                    seconds: feb20Seconds),
                Fixture.blob(
                    model: nil,
                    label: "Claude Sonnet 4.6",
                    input: 120_000,
                    output: 0,
                    cacheRead: 0,
                    reasoning: 0,
                    seconds: feb20Seconds),
                Fixture.blob(
                    model: "claude-sonnet-4-6",
                    label: "Claude Sonnet 4.6",
                    input: 0,
                    output: 0,
                    cacheRead: 0,
                    reasoning: 0,
                    seconds: feb20Seconds),
            ])

        let baseline = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            estimateCost: true,
            scanCacheRoot: nil,
            now: Fixture.now)
        let incremental = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            estimateCost: true,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        let replayed = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            estimateCost: true,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)

        let expectedCost = try #require(baseline.report.summary?.totalCostUSD)
        #expect(abs(expectedCost - 0.72) < 1e-6)
        #expect(abs((incremental.report.summary?.totalCostUSD ?? -1) - expectedCost) < 1e-6)
        #expect(abs((replayed.report.summary?.totalCostUSD ?? -1) - expectedCost) < 1e-6)
    }

    @Test
    func `jsonl fallback exhaustion returns retained complete report`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        try fixture.jsonl([Fixture.cacheUsage], session: "history")

        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)
        let expectedTokens = try #require(initial.report.summary?.totalTokens)

        var exhaustedLimits = AntigravityLocalReader.Limits()
        exhaustedLimits.duration = 0
        let exhausted = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: exhaustedLimits)
        #expect(exhausted.coverage == .partial)
        #expect(exhausted.report.summary?.totalTokens == expectedTokens)
    }

    @Test
    func `bounded fragment replay advances across passes to completion`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        for index in 0..<4 {
            try fixture.database(
                "adv-\(index)",
                blobs: [Fixture.blob(input: 100, output: 50, cacheRead: 0, reasoning: 0)])
        }
        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)
        #expect(initial.report.summary?.totalTokens == 600)

        var passes = 0
        var finalResult: AntigravityLocalReader.DailyReportResult?
        while passes < 10 {
            passes += 1
            let result = try AntigravityLocalReader.makeIncrementalDailyReportWithStatus(
                AntigravityLocalReader.IncrementalScanRequest(
                    context: fixture.context,
                    calendar: Fixture.calendar,
                    estimateCost: false,
                    pricing: nil,
                    scanCacheRoot: cacheRoot,
                    now: Fixture.now,
                    budget: AntigravityLocalReader.Budget(limits: .init(), cancellation: {}),
                    maximumReplayBytes: 1024))
            finalResult = result
            if result.coverage == .complete { break }
            #expect(result.batchMadeProgress)
            #expect(result.catchUpPending)
        }
        #expect(passes > 1)
        #expect(finalResult?.coverage == .complete)
        #expect(finalResult?.report.summary?.totalTokens == 600)
    }

    @Test
    func `stale fragments count toward replay byte limit`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        var dbURLs: [URL] = []
        for index in 0..<4 {
            try dbURLs.append(fixture.database(
                "stale-\(index)",
                blobs: [Fixture.blob(input: 100, output: 50, cacheRead: 0, reasoning: 0)]))
        }
        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)

        // Mutate all 4 databases so every cached fragment is stale.
        for (index, dbURL) in dbURLs.enumerated() {
            try FileManager.default.removeItem(at: dbURL)
            try fixture.database(
                "stale-\(index)",
                blobs: [
                    Fixture.blob(input: 100, output: 50, cacheRead: 0, reasoning: 0),
                    Fixture.blob(input: 10, output: 5, cacheRead: 0, reasoning: 0),
                ])
        }

        let bounded = try AntigravityLocalReader.makeIncrementalDailyReportWithStatus(
            AntigravityLocalReader.IncrementalScanRequest(
                context: fixture.context,
                calendar: Fixture.calendar,
                estimateCost: false,
                pricing: nil,
                scanCacheRoot: cacheRoot,
                now: Fixture.now,
                budget: AntigravityLocalReader.Budget(limits: .init(), cancellation: {}),
                maximumReplayBytes: 1024))
        #expect(bounded.coverage == .partial)
        #expect(bounded.catchUpPending)
        #expect(bounded.batchMadeProgress)
    }
}
