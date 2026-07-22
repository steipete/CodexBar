import Foundation
import Testing
@testable import CodexBarCore

struct CodexForkAttributionMigrationTests {
    private func options(_ env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func writeSession(
        _ env: CostUsageTestEnvironment,
        day: Date,
        events: [(Date, Int)],
        model: String? = nil) throws
    {
        let lines: [[String: Any]] = [[
            "type": "session_meta",
            "timestamp": env.isoString(for: day),
            "payload": ["id": "migration-session"],
        ]] + events.map { timestamp, input in
            var info: [String: Any] = [
                "last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0],
            ]
            if let model {
                info["model"] = model
            }
            return [
                "type": "event_msg",
                "timestamp": env.isoString(for: timestamp),
                "payload": [
                    "type": "token_count",
                    "info": info,
                ],
            ]
        }
        _ = try env.writeCodexSessionFile(day: day, filename: "migration.jsonl", contents: env.jsonl(lines))
    }

    private func markLegacyForkCandidate(_ env: CostUsageTestEnvironment) {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        for path in cache.files.keys {
            cache.files[path]?.forkedFromId = "missing-parent"
            cache.files[path]?.forkBaselineDependencyKey = "missing-parent|legacy-raw-boundary"
            cache.files[path]?.codexForkAttributionVersion = nil
        }
        cache.codexForkAttributionVersion = nil
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: env.cacheRoot,
            producerKey: "codex:cu:p48ac20dad61e9a7f")
    }

    @Test
    func `public cached snapshot quarantines known model legacy fork candidate`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        try self.writeSession(env, day: day, events: [(day, 408_650_005)], model: "gpt-5.6-sol")
        let options = self.options(env)
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        self.markLegacyForkCandidate(env)

        let legacy = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(legacy.producerKey == "codex:cu:p48ac20dad61e9a7f")
        #expect(legacy.files.values.contains { CostUsageScanner.isLegacyForkAttributionCandidate($0) })
        #expect(legacy.files.values
            .contains { $0.forkBaselineDependencyKey != CostUsageScanner.codexForkDependencyNotRequiredKey })

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day, historyDays: 1, scannerOptions: options)
        #expect(cached == nil)

        let migrated = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        #expect(migrated.data.first?.modelBreakdowns?.contains {
            $0.modelName == "gpt-5.6-sol" && $0.totalTokens == 408_650_005
        } == true)
        let refreshed = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(refreshed.files.values.allSatisfy {
            $0.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion
        })
    }

    @Test
    func `public cached snapshot preserves current legitimate unknown sentinel fork`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        try self.writeSession(env, day: day, events: [(day, 42)])
        let options = self.options(env)
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        for path in cache.files.keys {
            cache.files[path]?.forkedFromId = "current-fork"
            cache.files[path]?.forkBaselineDependencyKey = CostUsageScanner.codexForkDependencyNotRequiredKey
            cache.files[path]?.codexForkAttributionVersion = CostUsageScanner.codexForkAttributionVersion
        }
        cache.codexForkAttributionVersion = CostUsageScanner.codexForkAttributionVersion
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)
        #expect(first.data.first?.totalTokens == 42)
        #expect(cached?.last30DaysTokens == 42)
        #expect(cached?.daily.first?.modelBreakdowns?.contains {
            CostUsagePricing.isCodexUnattributedModel($0.modelName) && $0.totalTokens == 42
        } == true)
    }

    @Test
    func `legacy migration reparses touched file and drops unreparsed older day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let older = try env.makeLocalNoon(year: 2026, month: 5, day: 16)
        let current = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        try self.writeSession(env, day: current, events: [(older, 10), (current, 20)])
        let options = self.options(env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: older,
            until: current,
            now: current,
            options: options)
        self.markLegacyForkCandidate(env)
        let migrated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: current,
            until: current,
            now: current.addingTimeInterval(1),
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let oldKey = CostUsageScanner.CostUsageDayRange.dayKey(from: older)
        #expect(migrated.data.first?.totalTokens == 20)
        #expect(cache.files.values.allSatisfy { $0.days[oldKey] == nil })
        #expect(cache.scanSinceKey == CostUsageScanner.CostUsageDayRange(since: current, until: current).scanSinceKey)
        #expect(cache.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion)
        #expect(cache.files.values.allSatisfy {
            $0.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion
        })
    }

    @Test
    func `out of window legacy suspect is removed and later expansion reparses source`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let older = try env.makeLocalNoon(year: 2026, month: 5, day: 16)
        let current = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        try self.writeSession(env, day: older, events: [(older, 33)])
        let options = self.options(env)
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: older, until: older, now: older, options: options)
        self.markLegacyForkCandidate(env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: current,
            until: current,
            now: current,
            options: options)
        let narrowed = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let oldKey = CostUsageScanner.CostUsageDayRange.dayKey(from: older)
        #expect(narrowed.files.values.allSatisfy { $0.days[oldKey] == nil })
        #expect(narrowed.scanSinceKey == CostUsageScanner.CostUsageDayRange(since: current, until: current)
            .scanSinceKey)
        #expect(narrowed.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion)

        let expanded = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: older,
            until: current,
            now: current.addingTimeInterval(1),
            options: options)
        #expect(expanded.data.first?.totalTokens == 33)
        let expandedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(expandedCache.files.count == 1)
        #expect(expandedCache.files.values.allSatisfy {
            $0.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion
        })
    }
}
