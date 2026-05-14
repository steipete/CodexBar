import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherTests {
    @Test
    func `fetcher scopes codex history to selected codex home`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let otherHome = env.root.appendingPathComponent("other-codex-home", isDirectory: true)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "ambient.jsonl",
            tokens: 100)
        try Self.writeCodexSessionFile(homeRoot: otherHome, env: env, day: day, filename: "managed.jsonl", tokens: 10)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options)
        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: otherHome.path,
            scannerOptions: options)

        #expect(ambient.sessionTokens == 100)
        #expect(managed.sessionTokens == 10)
    }

    @Test
    func `fetcher refreshes codex cache when legacy roots metadata is missing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let managedHome = env.root.appendingPathComponent("managed-codex-home", isDirectory: true)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "ambient.jsonl",
            tokens: 100)
        try Self.writeCodexSessionFile(homeRoot: managedHome, env: env, day: day, filename: "managed.jsonl", tokens: 10)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)
        #expect(ambient.sessionTokens == 100)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.roots = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: managedHome.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(managed.sessionTokens == 10)
    }

    @Test
    func `fetcher merges native and pi codex history with normalized model names`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeTurnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": "openai/gpt-5.4",
            ],
        ]
        let nativeTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                    "model": "openai/gpt-5.4",
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([nativeTurnContext, nativeTokenCount]))

        let piAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 50,
                    "cacheRead": 5,
                    "output": 5,
                    "totalTokens": 60,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([piAssistant]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10) ?? 0
        let piCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 55,
            cachedInputTokens: 5,
            outputTokens: 5) ?? 0

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.date == "2026-04-08")
        #expect(snapshot.daily.first?.totalTokens == 170)
        #expect(abs((snapshot.daily.first?.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        #expect(snapshot.daily.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.4",
                costUSD: nativeCost + piCost,
                totalTokens: 170),
        ])
    }

    @Test
    func `fetcher merges native and pi claude history and ignores unsupported pi providers`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 9)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeAssistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "anthropic.foo.claude-sonnet-4-6-v1:0",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([nativeAssistant]))

        let supportedPiAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.addingTimeInterval(60).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 50,
                    "cacheRead": 4,
                    "cacheWrite": 6,
                    "output": 10,
                    "totalTokens": 70,
                ],
            ],
        ]
        let unsupportedPiAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "openrouter",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.addingTimeInterval(120).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 999,
                    "output": 1,
                    "totalTokens": 1000,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-09T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([supportedPiAssistant, unsupportedPiAssistant]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 100,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 10,
            outputTokens: 20) ?? 0
        let piCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 50,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 10) ?? 0

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.date == "2026-04-09")
        #expect(snapshot.daily.first?.totalTokens == 205)
        #expect(abs((snapshot.daily.first?.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        #expect(snapshot.daily.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-6",
                costUSD: nativeCost + piCost,
                totalTokens: 205),
        ])
    }

    @Test
    func `fetcher prefers turn context model over token count fallback`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeTurnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": "openai/gpt-5.4",
            ],
        ]
        let nativeTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "gpt-5",
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([nativeTurnContext, nativeTokenCount]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10) ?? 0

        #expect(snapshot.daily.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.4",
                costUSD: cost,
                totalTokens: 110),
        ])
    }

    @Test
    func `force refresh keeps incremental cost cache`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 11)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.4"

        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": ["model": model],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": model,
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot)

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        #expect(first.daily.first?.totalTokens == 110)

        let appendedTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": model,
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, appendedTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            forceRefresh: true,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        #expect(refreshed.daily.first?.totalTokens == 176)
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
