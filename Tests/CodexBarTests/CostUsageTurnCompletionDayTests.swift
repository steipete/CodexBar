import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTurnCompletionDayTests {
    @Test
    func `completion day retains a turn whose usage was before midnight`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let start = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T23:59:55Z"))
        let end = start.addingTimeInterval(10)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let prefix = try env.jsonl([[
            "type": "session_meta",
            "timestamp": env.isoString(for: start),
            "payload": ["id": "synthetic-midnight"],
        ]])
        let turn = try CostUsageTurnPerformanceFixture.turn(
            env: env, day: start, session: "synthetic-midnight", turn: 0, requests: 2)
        _ = try env.writeCodexSessionFile(day: start, filename: "synthetic-midnight.jsonl", contents: prefix + turn)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            calendar: calendar,
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: start,
            until: end,
            now: end.addingTimeInterval(10),
            options: options)
        let cache = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar)
        let range = CostUsageScanner.CostUsageDayRange(since: end, until: end, calendar: calendar)
        let direct = cache.files.values
            .flatMap { CostUsageScanner.codexTurnPerformanceSamples(usage: $0, range: range) }
        #expect(direct.count == 1)
        let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: cache, range: range, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(sessions.flatMap(\.turnPerformanceSamples).count == 1)
        #expect(sessions.first?.totalTokens == nil)
        #expect(sessions.first?.costUSD == nil)
        let previousRange = CostUsageScanner.CostUsageDayRange(since: start, until: start, calendar: calendar)
        let previousSessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: cache, range: previousRange, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(previousSessions.flatMap(\.turnPerformanceSamples).isEmpty)
        #expect((previousSessions.first?.totalTokens ?? 0) > 0)
    }
}
