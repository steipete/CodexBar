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
}
