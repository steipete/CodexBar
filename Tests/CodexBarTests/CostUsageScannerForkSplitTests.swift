import Foundation
#if canImport(SQLite3)
import Testing
@testable import CodexBarCore

struct CostUsageScannerForkSplitTests {
    @Test
    func `codex report rejects fork inflated row split and its fast uplift`() throws {
        let fixture = try self.makeFixture()
        defer { fixture.environment.cleanup() }

        var cache = fixture.cache
        let parent = try #require(cache.files.first { $0.value.sessionId == "parent-session" })
        let child = try #require(cache.files.first { $0.value.sessionId == "child-session" })
        let copiedParentRows = try #require(parent.value.codexRows)
        var inflatedChild = child.value
        inflatedChild.codexRows = (inflatedChild.codexRows ?? []) + copiedParentRows
        cache.files[child.key] = inflatedChild

        let canonical = try #require(cache.days[fixture.dayKey]?[fixture.model])
        #expect(canonical == [150, 60, 15])
        let canonicalTokens = canonical[0] + canonical[2]
        let rowTokens = cache.files.values
            .flatMap { $0.codexRows ?? [] }
            .reduce(0) { $0 + $1.input + $1.output }
        #expect(rowTokens > canonicalTokens)

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: fixture.range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        let canonicalCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: canonical[0],
            cachedInputTokens: canonical[1],
            outputTokens: canonical[2]))

        #expect(abs((breakdown.costUSD ?? 0) - canonicalCost) < 1e-12)
        #expect(breakdown.standardCostUSD == nil)
        #expect(breakdown.priorityCostUSD == nil)
        #expect(breakdown.standardTokens == nil)
        #expect(breakdown.priorityTokens == nil)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - canonicalCost) < 1e-12)
    }

    @Test
    func `codex report keeps trusted fork deduplicated row split`() throws {
        let fixture = try self.makeFixture()
        defer { fixture.environment.cleanup() }

        let canonical = try #require(fixture.cache.days[fixture.dayKey]?[fixture.model])
        #expect(canonical == [150, 60, 15])
        let child = try #require(fixture.cache.files.first { $0.value.sessionId == "child-session" }?.value)
        #expect(child.days[fixture.dayKey]?[fixture.model] == [50, 20, 5])

        let report = CostUsageScanner.buildCodexReportFromCache(cache: fixture.cache, range: fixture.range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        let standardCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 50,
            cachedInputTokens: 20,
            outputTokens: 5))
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: fixture.model,
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 10))

        #expect(abs((breakdown.costUSD ?? 0) - (standardCost + priorityCost)) < 1e-12)
        #expect(abs((breakdown.standardCostUSD ?? 0) - standardCost) < 1e-12)
        #expect(abs((breakdown.priorityCostUSD ?? 0) - priorityCost) < 1e-12)
        #expect(breakdown.standardTokens == 55)
        #expect(breakdown.priorityTokens == 110)
    }

    @Test
    func `window expansion replaces stale fork rows before pricing combined short requests`() throws {
        let fixture = try self.makePricingFixture(
            parent: (input: 200_000, cached: 20000, output: 1000),
            child: (input: 200_000, cached: 20000, output: 1000))
        defer { fixture.environment.cleanup() }

        let inflatedCache = try self.cacheByCopyingParentRowsIntoChild(fixture.cache)
        let canonicalBeforeRescan = try #require(inflatedCache.days[fixture.dayKey]?[fixture.model])
        let inflatedRowTokens = inflatedCache.files.values
            .flatMap { $0.codexRows ?? [] }
            .reduce(0) { $0 + $1.input + $1.output }
        #expect(inflatedRowTokens > canonicalBeforeRescan[0] + canonicalBeforeRescan[2])
        CostUsageStoreAccess.replace(cacheRoot: fixture.environment.cacheRoot, cache: inflatedCache)

        let earlierDay = try #require(fixture.range.calendar.date(byAdding: .day, value: -3, to: fixture.day))
        let expandedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: earlierDay,
            until: fixture.day,
            now: fixture.day.addingTimeInterval(10),
            options: fixture.options)
        let expandedRange = CostUsageScanner.CostUsageDayRange(
            since: earlierDay,
            until: fixture.day,
            calendar: fixture.range.calendar)
        let repairedCache = CostUsageStoreAccess.read(
            cacheRoot: fixture.environment.cacheRoot,
            calendar: fixture.range.calendar)

        let canonical = try #require(repairedCache.days[fixture.dayKey]?[fixture.model])
        #expect(canonical == [400_000, 40000, 2000])
        let repairedRows = repairedCache.files.values.flatMap { $0.codexRows ?? [] }
        #expect(repairedRows.reduce(0) { $0 + $1.input } == canonical[0])
        #expect(repairedRows.reduce(0) { $0 + $1.cached } == canonical[1])
        #expect(repairedRows.reduce(0) { $0 + $1.output } == canonical[2])
        let repairedChild = try #require(repairedCache.files.first {
            $0.value.sessionId == "child-session"
        }?.value)
        #expect(repairedChild.codexTurnIDs == ["child-turn"])
        #expect(repairedChild.codexRows?.map(\.turnID) == ["child-turn"])

        let parentCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 200_000,
            cachedInputTokens: 20000,
            outputTokens: 1000))
        let childCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 200_000,
            cachedInputTokens: 20000,
            outputTokens: 1000))
        let expectedCost = parentCost + childCost
        let incorrectAggregateCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: canonical[0],
            cachedInputTokens: canonical[1],
            outputTokens: canonical[2]))
        #expect(abs(expectedCost - incorrectAggregateCost) > 1e-12)
        #expect(abs((expandedReport.summary?.totalCostUSD ?? 0) - expectedCost) < 1e-12)

        let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: repairedCache,
            range: expandedRange)
        #expect(sessions.count == 2)
        #expect(abs((sessions.first { $0.sessionID == "parent-session" }?.costUSD ?? 0) - parentCost) < 1e-12)
        #expect(abs((sessions.first { $0.sessionID == "child-session" }?.costUSD ?? 0) - childCost) < 1e-12)
        let sessionCost = sessions.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(sessionCost - expectedCost) < 1e-12)

        let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: repairedCache,
            range: expandedRange)
        #expect(projects.count == 1)
        #expect(abs((projects.first?.totalCostUSD ?? 0) - expectedCost) < 1e-12)
    }

    @Test
    func `trusted fork rows tier only the genuine long context request`() throws {
        let fixture = try self.makePricingFixture(
            parent: (input: 300_000, cached: 30000, output: 1000),
            child: (input: 100_000, cached: 10000, output: 1000))
        defer { fixture.environment.cleanup() }

        let report = CostUsageScanner.buildCodexReportFromCache(cache: fixture.cache, range: fixture.range)
        let longRequestCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 300_000,
            cachedInputTokens: 30000,
            outputTokens: 1000))
        let shortRequestCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 100_000,
            cachedInputTokens: 10000,
            outputTokens: 1000))
        let canonical = try #require(fixture.cache.days[fixture.dayKey]?[fixture.model])
        let incorrectlyTieredAggregate = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: canonical[0],
            cachedInputTokens: canonical[1],
            outputTokens: canonical[2]))
        let expectedCost = longRequestCost + shortRequestCost

        #expect(abs((report.summary?.totalCostUSD ?? 0) - expectedCost) < 1e-12)
        #expect(abs(expectedCost - incorrectlyTieredAggregate) > 1e-12)
        let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: fixture.cache,
            range: fixture.range)
        #expect(abs((sessions.first { $0.sessionID == "parent-session" }?.costUSD ?? 0) - longRequestCost) < 1e-12)
        #expect(abs((sessions.first { $0.sessionID == "child-session" }?.costUSD ?? 0) - shortRequestCost) < 1e-12)
    }

    @Test
    func `codex report omits an ambiguous long context aggregate fallback`() throws {
        let fixture = try self.makePricingFixture(
            parent: (input: 200_000, cached: 20000, output: 1000),
            child: (input: 200_000, cached: 20000, output: 1000))
        defer { fixture.environment.cleanup() }

        let inflatedCache = try self.cacheByCopyingParentRowsIntoChild(fixture.cache)
        let canonical = try #require(inflatedCache.days[fixture.dayKey]?[fixture.model])
        #expect(CostUsagePricing.codexAggregateCostUSD(
            model: fixture.model,
            inputTokens: canonical[0],
            cachedInputTokens: canonical[1],
            outputTokens: canonical[2]) == nil)
        #expect(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: canonical[0],
            cachedInputTokens: canonical[1],
            outputTokens: canonical[2]) != nil)

        let report = CostUsageScanner.buildCodexReportFromCache(cache: inflatedCache, range: fixture.range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        #expect(breakdown.costUSD == nil)
        #expect(breakdown.standardCostUSD == nil)
        #expect(breakdown.priorityCostUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
    }

    private struct Fixture {
        let environment: CostUsageTestEnvironment
        let range: CostUsageScanner.CostUsageDayRange
        let dayKey: String
        let model: String
        let cache: CostUsageCache
    }

    private struct PricingFixture {
        let environment: CostUsageTestEnvironment
        let day: Date
        let range: CostUsageScanner.CostUsageDayRange
        let dayKey: String
        let model: String
        let options: CostUsageScanner.Options
        let cache: CostUsageCache
    }

    private func makeFixture() throws -> Fixture {
        let env = try CostUsageTestEnvironment()
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 6)
        let parentTimestamp = env.isoString(for: day)
        let parentUsageTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childUsageTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let model = "gpt-5.5"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "a-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": parentTimestamp,
                    "payload": ["id": "parent-session", "timestamp": parentTimestamp],
                ],
                ["type": "turn_context", "timestamp": parentTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": parentUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "priority-turn"],
                ],
                self.totalTokenCount(timestamp: parentUsageTimestamp, input: 100, cached: 40, output: 10),
            ]))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "z-child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                ["type": "turn_context", "timestamp": forkTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": childUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "standard-turn"],
                ],
                self.totalTokenCount(timestamp: childUsageTimestamp, input: 150, cached: 60, output: 15),
            ]))

        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: parentUsageTimestamp,
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL,
            forceRescan: true,
            preferNewestCodexSessionsFirst: false)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        return Fixture(
            environment: env,
            range: range,
            dayKey: range.sinceKey,
            model: model,
            cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: range.calendar))
    }

    private func makePricingFixture(
        parent: (input: Int, cached: Int, output: Int),
        child: (input: Int, cached: Int, output: Int)) throws -> PricingFixture
    {
        let env = try CostUsageTestEnvironment()
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 6)
        let parentTimestamp = env.isoString(for: day)
        let parentUsageTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childUsageTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let model = "gpt-5.5"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "a-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": parentTimestamp,
                    "payload": ["id": "parent-session", "timestamp": parentTimestamp],
                ],
                ["type": "turn_context", "timestamp": parentTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": parentUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "parent-turn"],
                ],
                self.totalTokenCount(
                    timestamp: parentUsageTimestamp,
                    input: parent.input,
                    cached: parent.cached,
                    output: parent.output),
            ]))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "z-child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                ["type": "turn_context", "timestamp": forkTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": childUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "child-turn"],
                ],
                self.totalTokenCount(
                    timestamp: childUsageTimestamp,
                    input: parent.input + child.input,
                    cached: parent.cached + child.cached,
                    output: parent.output + child.output),
            ]))

        var initialOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            forceRescan: true,
            preferNewestCodexSessionsFirst: false)
        initialOptions.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: initialOptions)

        var rescanOptions = initialOptions
        rescanOptions.forceRescan = false
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        return PricingFixture(
            environment: env,
            day: day,
            range: range,
            dayKey: range.sinceKey,
            model: model,
            options: rescanOptions,
            cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: range.calendar))
    }

    private func cacheByCopyingParentRowsIntoChild(_ original: CostUsageCache) throws -> CostUsageCache {
        var cache = original
        let parent = try #require(cache.files.first { $0.value.sessionId == "parent-session" })
        let child = try #require(cache.files.first { $0.value.sessionId == "child-session" })
        let copiedParentRows = try #require(parent.value.codexRows)
        var inflatedChild = child.value
        inflatedChild.codexRows = (inflatedChild.codexRows ?? []) + copiedParentRows
        inflatedChild.codexTurnIDs = Array(Set((inflatedChild.codexTurnIDs ?? []) + (parent.value.codexTurnIDs ?? [])))
            .sorted()
        cache.files[child.key] = inflatedChild
        return cache
    }

    private func totalTokenCount(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }
}
#endif
