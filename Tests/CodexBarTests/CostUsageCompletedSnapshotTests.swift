import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCompletedSnapshotTests {
    @Test(arguments: ["missing", "pending", "timezone", "window", "roots"])
    func `completed cache reads reject unavailable native history`(invalidity: String) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.options(env: env)
        if invalidity != "missing" {
            let url = try await Self.seedNative(env: env, day: day, options: options)
            var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            var storedCalendar = options.calendar
            switch invalidity {
            case "pending":
                cache.codexScanCatchUpPending = true
                cache.files[url.path]?.codexScanComplete = false
            case "timezone":
                storedCalendar.timeZone = try #require(TimeZone(
                    secondsFromGMT: options.calendar.timeZone.secondsFromGMT() == 0 ? 3600 : 0))
            case "window": cache.scanSinceKey = "2026-04-08"
            default: cache.roots = [:]
            }
            CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache, calendar: storedCalendar)
        }

        let result = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            includePiSessions: false,
            requireCompleteHistory: true,
            scannerOptions: options)

        #expect(result == nil)
    }

    @Test
    func `completed reads reject the established report held during pending catch-up`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        var options = Self.options(env: env)
        let url = try await Self.seedNative(env: env, day: day, options: options)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.nativeRecord(env: env, day: day, tokens: 200) + "\n").utf8))
        try handle.close()
        options.maxCodexScanBytesPerRefresh = 1
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day.addingTimeInterval(1),
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        let hydrated = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day.addingTimeInterval(2),
            includePiSessions: false,
            scannerOptions: options)
        #expect(hydrated?.snapshot.historyCoverageIsEstablished == true)
        #expect(hydrated?.snapshot.last30DaysTokens == 100)
        #expect(hydrated?.staleSnapshotUpdatedAt != nil)

        let completed = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day.addingTimeInterval(2),
            includePiSessions: false,
            requireCompleteHistory: true,
            scannerOptions: options)
        #expect(completed == nil)
    }

    @Test
    func `completed scoped reads exclude ambient mirrors and reject other homes`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.options(env: env)
        _ = try await Self.seedNative(env: env, day: day, options: options)
        let fetcher = CostUsageFetcher(scannerOptions: options)

        let scoped = await fetcher.loadCompletedCodexTokenSnapshotResult(
            now: day,
            codexHomePath: env.codexHomeRoot.path)
        #expect(scoped?.snapshot.last30DaysTokens == 100)
        #expect(scoped?.lastRefreshAt == day)
        let other = await fetcher.loadCompletedCodexTokenSnapshotResult(
            now: day,
            codexHomePath: env.root.appendingPathComponent("other-home").path)
        #expect(other == nil)
    }

    @Test(arguments: [0, 165])
    func `completed ambient reads require valid mirror history including confirmed empty`(piTokens: Int) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.options(env: env)
        _ = try await Self.seedNative(env: env, day: day, options: options)
        let fetcher = CostUsageFetcher(scannerOptions: options)
        #expect(await fetcher.loadCompletedCodexTokenSnapshotResult(now: day) == nil)
        if piTokens > 0 {
            _ = try env.writePiSessionFile(
                relativePath: "2026-04-08T10-00-00-000Z_mirror.jsonl",
                contents: env.jsonl([[
                    "type": "message",
                    "timestamp": env.isoString(for: day),
                    "message": [
                        "role": "assistant",
                        "provider": "openai-codex",
                        "model": "openai/gpt-5.4",
                        "timestamp": Int(day.timeIntervalSince1970 * 1000),
                        "usage": ["input": piTokens, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    ],
                ]]))
        }
        let since = try #require(options.calendar.date(byAdding: .day, value: -29, to: day))
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: day,
            now: day.addingTimeInterval(-60),
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                ompSessionsRoot: env.root.appendingPathComponent("empty-omp"),
                cacheRoot: env.cacheRoot,
                calendar: options.calendar,
                refreshMinIntervalSeconds: 0))

        let completed = await fetcher.loadCompletedCodexTokenSnapshotResult(now: day)
        #expect(completed?.snapshot.last30DaysTokens == 100 + piTokens)
        #expect(completed?.snapshot.updatedAt == day.addingTimeInterval(-60))
        #expect(completed?.lastRefreshAt == nil)

        let validPiCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        for invalidity in ["pricing", "timestamp", "timezone", "window"] {
            var cache = validPiCache
            var storedCalendar = options.calendar
            switch invalidity {
            case "pricing": cache.pricingKey = "obsolete-pricing"
            case "timestamp": cache.lastScanUnixMs = 0
            case "timezone":
                storedCalendar.timeZone = try #require(TimeZone(
                    secondsFromGMT: options.calendar.timeZone.secondsFromGMT() == 0 ? 3600 : 0))
            default: cache.scanSinceKey = "2026-04-08"
            }
            PiSessionCostCacheIO.save(cache: cache, cacheRoot: env.cacheRoot, calendar: storedCalendar)
            #expect(await fetcher.loadCompletedCodexTokenSnapshotResult(now: day) == nil)
        }
        try Data("invalid JSON".utf8).write(to: PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot))
        #expect(await fetcher.loadCompletedCodexTokenSnapshotResult(now: day) == nil)
    }

    @Test
    func `completed scoped reads preserve legitimately empty history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.options(env: env)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        let result = await CostUsageFetcher(scannerOptions: options).loadCompletedCodexTokenSnapshotResult(
            now: day.addingTimeInterval(60),
            codexHomePath: env.codexHomeRoot.path)
        #expect(result?.snapshot.historyCoverageIsEstablished == true)
        #expect(result?.snapshot.last30DaysTokens == 0)
        #expect(result?.snapshot.updatedAt == day)
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func seedNative(
        env: CostUsageTestEnvironment,
        day: Date,
        options: CostUsageScanner.Options) async throws -> URL
    {
        let iso = env.isoString(for: day)
        let url = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-completed.jsonl",
            contents: """
            {"type":"session_meta","timestamp":"\(iso)","payload":{"session_id":"completed"}}
            {"type":"turn_context","timestamp":"\(iso)","payload":{"model":"openai/gpt-5.2-codex"}}
            \(Self.nativeRecord(env: env, day: day, tokens: 100))

            """)
        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(initial.historyCoverageIsEstablished)
        #expect(initial.last30DaysTokens == 100)
        return url
    }

    private static func nativeRecord(env: CostUsageTestEnvironment, day: Date, tokens: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(env.isoString(for: day))","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":\#(tokens),"cached_input_tokens":0,"output_tokens":0},"#
            + #""model":"openai/gpt-5.2-codex"}}}"#
    }
}
