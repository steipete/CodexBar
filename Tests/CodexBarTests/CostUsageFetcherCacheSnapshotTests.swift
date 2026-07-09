import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherCacheSnapshotTests {
    @Test
    func `cached codex token snapshot loads from existing cache without rescanning`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.sessionTokens == 42)
        #expect(cached?.last30DaysTokens == 42)
        #expect(cached?.daily.map(\.date) == ["2026-04-08"])
    }

    @Test
    func `cached codex token snapshot keeps the cache scan time as updatedAt`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(cache.lastScanUnixMs > 0)
        let scanTime = Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)

        let hydratedAt = day.addingTimeInterval(50 * 60)
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: hydratedAt,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.snapshot.updatedAt == scanTime)
        #expect(cached?.snapshot.updatedAt != hydratedAt)
        #expect(cached?.lastRefreshAt == scanTime)
    }

    @Test
    func `cached codex token snapshot keeps the oldest scan time when pi sessions merge`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let nativeCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        var piCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(nativeCache.lastScanUnixMs > 0)
        #expect(piCache.lastScanUnixMs > 0)
        piCache.lastScanUnixMs = nativeCache.lastScanUnixMs - 30 * 60 * 1000
        PiSessionCostCacheIO.save(cache: piCache, cacheRoot: env.cacheRoot)
        let oldestScanTime = Date(timeIntervalSince1970: TimeInterval(piCache.lastScanUnixMs) / 1000)

        let hydratedAt = day.addingTimeInterval(50 * 60)
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: hydratedAt,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.snapshot.sessionTokens == 207)
        #expect(cached?.snapshot.updatedAt == oldestScanTime)
        #expect(cached?.snapshot.updatedAt != hydratedAt)
        #expect(cached?.lastRefreshAt == nil)
    }

    @Test
    func `cached codex token snapshot keeps pi scan time when only pi sessions exist`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let piCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(piCache.lastScanUnixMs > 0)
        let piScanTime = Date(timeIntervalSince1970: TimeInterval(piCache.lastScanUnixMs) / 1000)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day.addingTimeInterval(50 * 60),
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.snapshot.sessionTokens == 165)
        #expect(cached?.snapshot.updatedAt == piScanTime)
        #expect(cached?.lastRefreshAt == nil)
    }

    @Test
    func `cached codex token snapshot keeps native scan time when pi cache lacks one`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        var piCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        piCache.lastScanUnixMs = 0
        PiSessionCostCacheIO.save(cache: piCache, cacheRoot: env.cacheRoot)

        let nativeCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(nativeCache.lastScanUnixMs > 0)
        let nativeScanTime = Date(
            timeIntervalSince1970: TimeInterval(nativeCache.lastScanUnixMs) / 1000)

        let hydratedAt = day.addingTimeInterval(50 * 60)
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: hydratedAt,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.sessionTokens == 207)
        #expect(cached?.updatedAt == nativeScanTime)
        #expect(cached?.updatedAt != hydratedAt)
    }

    @Test
    func `cached codex token snapshot refuses expanded or managed scopes`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let expanded = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 7,
            scannerOptions: options)
        let managed = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)

        #expect(expanded == nil)
        #expect(managed == nil)
    }

    @Test
    func `cached codex token snapshot omits projects until metadata migration`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let current = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)
        #expect(current?.projects.count == 1)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.codexProjectMetadataVersion = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let legacy = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)
        #expect(legacy?.sessionTokens == 42)
        #expect(legacy?.projects.isEmpty == true)
    }

    @Test
    func `cached codex token snapshot refuses mismatched roots fingerprint`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.roots = [env.root.appendingPathComponent("other/sessions", isDirectory: true).path: 0]
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached == nil)
    }

    @Test
    func `cached codex token snapshot merges cached pi sessions`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.sessionTokens == 207)
        #expect(cached?.last30DaysTokens == 207)
    }

    @Test
    func `cached codex token snapshot loads cached pi sessions without native codex cache`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: piOptions)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: env.cacheRoot))

        #expect(cached?.sessionTokens == 165)
        #expect(cached?.last30DaysTokens == 165)
    }

    @Test
    func `cached codex token snapshot still loads pi sessions when native cache roots mismatch`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)
        try Self.writePiCodexSessionFile(env: env, day: day, tokens: 165)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.roots = [env.root.appendingPathComponent("other/sessions", isDirectory: true).path: 0]
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)

        #expect(cached?.sessionTokens == 165)
        #expect(cached?.last30DaysTokens == 165)
    }

    private static func writeCodexSessionFile(
        homeRoot: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        tokens: Int) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = homeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = "openai/gpt-5.4"
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writePiCodexSessionFile(
        env: CostUsageTestEnvironment,
        day: Date,
        tokens: Int) throws
    {
        _ = try env.writePiSessionFile(
            relativePath: "nested/run-0/2026-04-08T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([
                [
                    "type": "message",
                    "timestamp": env.isoString(for: day),
                    "message": [
                        "role": "assistant",
                        "provider": "openai-codex",
                        "model": "openai/gpt-5.4",
                        "timestamp": Int(day.timeIntervalSince1970 * 1000),
                        "usage": [
                            "input": tokens,
                            "output": 0,
                            "cacheRead": 0,
                            "cacheWrite": 0,
                            "totalTokens": tokens,
                        ],
                    ],
                ],
            ]))
    }
}
