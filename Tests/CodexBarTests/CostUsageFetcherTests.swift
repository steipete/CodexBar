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
    func `fetcher refreshes codex cache when history window expands`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: oldDay,
            filename: "old.jsonl",
            tokens: 15)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: newDay,
            filename: "new.jsonl",
            tokens: 30)

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        #expect(narrow.daily.map(\.date) == ["2026-04-08"])
        #expect(narrow.last30DaysTokens == 30)

        var legacyCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        legacyCache.scanSinceKey = nil
        legacyCache.scanUntilKey = nil
        CostUsageCacheIO.save(provider: .codex, cache: legacyCache, cacheRoot: env.cacheRoot)

        let expanded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            scannerOptions: options)
        #expect(expanded.daily.map(\.date) == ["2026-04-02", "2026-04-08"])
        #expect(expanded.last30DaysTokens == 45)
    }

    @Test
    func `fetcher resolves fork parent outside requested codex window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let childDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let model = "openai/gpt-5.4"
        let parentID = "parent-session"
        let parentTimestamp = env.isoString(for: parentDay.addingTimeInterval(1))
        let childTimestamp = env.isoString(for: childDay.addingTimeInterval(1))
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": ["session_id": parentID],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTimestamp,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": model,
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "session_id": "child-session",
                        "forked_from_id": parentID,
                        "timestamp": parentTimestamp,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTimestamp,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": model,
                            "total_token_usage": [
                                "input_tokens": 125,
                                "cached_input_tokens": 0,
                                "output_tokens": 5,
                            ],
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: childDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)

        #expect(snapshot.daily.map(\.date) == ["2026-04-08"])
        #expect(snapshot.last30DaysTokens == 30)
    }

    @Test
    func `force refresh only scans requested codex date window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let oldURL = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes([.modificationDate: oldDay], ofItemAtPath: oldURL.path)
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            forceRefresh: true,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let cacheFileExists = FileManager.default.fileExists(
            atPath: CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot).path)

        #expect(snapshot.daily.map(\.date) == ["2026-04-08"])
        #expect(snapshot.last30DaysTokens == 30)
        #expect(cacheFileExists)
        #expect(cache.files.keys.sorted().map(URL.init(fileURLWithPath:)).map(\.lastPathComponent) == ["new.jsonl"])
    }

    @Test
    func `narrow codex refresh preserves wider cache window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 15,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay,
            options: options)
        let wide = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(2),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(wide.last30DaysTokens == 45)
        #expect(narrow.last30DaysTokens == 30)
        #expect(cache.files.keys.map(URL.init(fileURLWithPath:)).map(\.lastPathComponent).sorted() == [
            "new.jsonl",
            "old.jsonl",
        ])
        #expect(cache.scanSinceKey == "2026-04-01")
        #expect(cache.scanUntilKey == "2026-04-09")
    }

    @Test
    func `force codex rescan narrows cache window to refreshed range`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 15,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)

        var rescanOptions = options
        rescanOptions.forceRescan = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: rescanOptions)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(cache.files.keys.map(URL.init(fileURLWithPath:)).map(\.lastPathComponent).sorted() == ["new.jsonl"])
        #expect(cache.scanSinceKey == "2026-04-07")
        #expect(cache.scanUntilKey == "2026-04-09")
    }

    @Test
    func `codex refresh drops stale cache entry when session moves to archive`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let contents = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day),
                "payload": ["session_id": "moved-session"],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "openai/gpt-5.4",
                        "last_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                    ],
                ],
            ],
        ])
        let originalURL = try env.writeCodexSessionFile(day: day, filename: "moved.jsonl", contents: contents)

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)

        let archivedURL = env.codexArchivedSessionsRoot.appendingPathComponent("moved.jsonl", isDirectory: false)
        try FileManager.default.moveItem(at: originalURL, to: archivedURL)

        let second = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(first.last30DaysTokens == 30)
        #expect(second.last30DaysTokens == 30)
        #expect(cache.files.count == 1)
        #expect(cache.files.keys.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ==
            archivedURL.resolvingSymlinksInPath().path)
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

extension CostUsageFetcherTests {
    @Test
    func `fetcher can hydrate codex snapshot from cache without scanning`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 100)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        try FileManager.default.removeItem(
            at: env.codexHomeRoot.appendingPathComponent("sessions", isDirectory: true))

        let cached = CostUsageFetcher.loadCachedTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(120),
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(cached?.sessionTokens == 100)
    }

    @Test
    func `fetcher does not hydrate codex snapshot from another home cache`() async throws {
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
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let cachedManaged = CostUsageFetcher.loadCachedTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(120),
            codexHomePath: managedHome.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(cachedManaged == nil)
    }
}
