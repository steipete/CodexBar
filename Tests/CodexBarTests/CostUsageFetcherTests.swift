import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCostFetcherTests {
    static func summary(
        provider: UsageProvider = .codex,
        days: Int = 30,
        daily: [CostUsageDailyReport.Entry] = []) -> RemoteCostSummary
    {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.25,
            last30DaysTokens: 456,
            last30DaysCostUSD: 3.5,
            historyDays: days,
            historyCoverageIsEstablished: false,
            daily: daily,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return RemoteCostSummary(
            snapshot: snapshot,
            provider: provider,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"))
    }

    static func json(_ summaries: [RemoteCostSummary]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode(summaries), encoding: .utf8))
    }

    @Test
    func `summary transport excludes identity paths and conversation data`() throws {
        let daily = CostUsageDailyReport.Entry(
            date: "2026-09-10",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 456,
            costUSD: 3.5,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let json = try Self.json([Self.summary(daily: [daily])])
        let rows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let row = try #require(rows.first)
        let keys = row.keys.sorted()
        #expect(keys == [
            "bucketTimeZone", "coverage", "currencyCode", "daily", "historyCoverageIsEstablished", "historyDays",
            "last30DaysCostUSD", "last30DaysTokens", "provenance", "provider", "sessionCostUSD",
            "sessionTokens", "updatedAt",
        ])
        let dailyRows = try #require(row["daily"] as? [[String: Any]])
        #expect(try #require(dailyRows.first).keys.sorted() == ["costUSD", "date", "totalTokens"])
        #expect(!json.contains("modelsUsed"))
        #expect(!json.contains("modelBreakdowns"))
    }

    @Test
    func `SSH targets are explicit bounded and cannot introduce shell or SSH options`() throws {
        #expect(try RemoteCostFetcher.hosts(from: "") == [])
        #expect(try RemoteCostFetcher.hosts(from: "work, user@host, work") == ["work", "user@host"])
        #expect(try RemoteCostFetcher.hosts(from: "Alice@server, alice@server, Alice@SERVER") == [
            "Alice@server", "alice@server",
        ])
        for bad in ["-oProxyCommand=evil", "host;touch", "host$(id)", "host'", "host\nother", "user host"] {
            #expect(throws: RemoteCostError.self) {
                try RemoteCostFetcher.arguments(
                    host: bad,
                    providers: [.codex, .claude],
                    historyDays: 30,
                    force: false)
            }
        }
        #expect(throws: RemoteCostError.self) {
            try RemoteCostFetcher.hosts(from: (1...9).map { "host\($0)" }.joined(separator: ","))
        }
        let args = try RemoteCostFetcher.arguments(
            host: "user@host",
            providers: [.codex, .claude],
            historyDays: 7,
            force: true)
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("-T"))
        #expect(args.contains("user@host"))
        let command = try #require(args.last)
        #expect(command.contains("--provider both"))
        #expect(command.contains("--summary-only --provider-native-only --days 7 --refresh"))
        #expect(!command.contains("||"))
    }

    @Test
    func `remote reports retain calendar partial coverage and original host prices`() async throws {
        let summaries = [Self.summary(provider: .codex), Self.summary(provider: .claude)]
        let json = try Self.json(summaries)
        let fetcher = RemoteCostFetcher { _, environment in
            #expect(environment == ["PATH": "/usr/bin:/bin"])
            return json
        }
        let received = try await fetcher.fetch(
            host: "linux-host",
            providers: [.codex, .claude],
            historyDays: 30,
            environment: ["PATH": "/usr/bin:/bin"])
        #expect(received == summaries)
        #expect(received.allSatisfy { !$0.historyCoverageIsEstablished })
        #expect(received.allSatisfy { $0.bucketTimeZone == "GMT" })
        #expect(received.allSatisfy { $0.last30DaysCostUSD == 3.5 })
    }

    @Test
    func `remote rejects malformed wrong window negative and oversized summaries`() async throws {
        let valid = try Self.json([Self.summary()])
        for invalid in try [
            "not JSON", valid.replacingOccurrences(of: "123", with: "-1"),
            valid.replacingOccurrences(of: "\"codex\"", with: "\"claude\""),
            String(repeating: " ", count: 65537), Self.json([Self.summary(days: 7)]),
        ] {
            let fetcher = RemoteCostFetcher { _, _ in invalid }
            await #expect(throws: RemoteCostError.self) {
                try await fetcher.fetch(host: "host", providers: [.codex], historyDays: 30)
            }
        }
    }

    @Test
    func `remote preserves available providers when another provider has no history`() async throws {
        let codex = Self.summary(provider: .codex)
        let fetcher = RemoteCostFetcher { _, _ in try Self.json([codex]) }
        let received = try await fetcher.fetch(
            host: "host",
            providers: [.codex, .claude],
            historyDays: 30)
        #expect(received == [codex])
    }

    @Test
    func `remote rejects duplicate and unsupported provider summaries`() async throws {
        let codex = Self.summary(provider: .codex)
        let claude = Self.summary(provider: .claude)
        let invalidPayloads = try [
            Self.json([codex, codex]),
            Self.json([codex, claude]).replacingOccurrences(of: "\"claude\"", with: "\"cursor\""),
        ]
        for invalid in invalidPayloads {
            let fetcher = RemoteCostFetcher { _, _ in invalid }
            await #expect(throws: RemoteCostError.self) {
                try await fetcher.fetch(host: "host", providers: [.codex, .claude], historyDays: 30)
            }
        }
    }

    @Test
    func `remote subprocess errors do not expose remote stderr`() async {
        let fetcher = RemoteCostFetcher { _, _ in
            throw SubprocessRunnerError.nonZeroExit(code: 1, stderr: "private path or credential")
        }
        do {
            _ = try await fetcher.fetch(host: "host", providers: [.codex, .claude], historyDays: 30)
            Issue.record("Expected an unavailable-host error")
        } catch {
            #expect(!error.localizedDescription.contains("private path"))
            #expect(error.localizedDescription.contains("Check SSH"))
        }
    }
}

@Suite(.serialized)
struct CostUsageFetcherTests {
    @Test
    func `native codex sessions survive when pi usage is present but pi merge is disabled`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "native.jsonl",
            tokens: 100)
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_mixed.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 50, "output": 5, "totalTokens": 55],
                ],
            ]]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let merged = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: piOptions)
        let nativeOnly = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(merged.sessions.isEmpty)
        #expect(nativeOnly.sessionTokens == 100)
        #expect(nativeOnly.sessions.count == 1)
    }

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
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_ambient.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 50, "output": 5, "totalTokens": 55],
                ],
            ]]))

        let options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root
                .appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            allowPricingRefresh: false,
            scannerOptions: options,
            piScannerOptions: piOptions)
        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: otherHome.path,
            allowPricingRefresh: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(ambient.sessionTokens == 100)
        #expect(managed.sessionTokens == 10)
    }
}

extension CostUsageFetcherTests {
    @Test
    func `completed empty codex scan publishes known zero totals`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.sessionCostUSD == 0)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.last30DaysCostUSD == 0)
    }

    @Test
    func `codex history coverage follows pending catch up`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "bounded.jsonl",
            tokens: 42)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1,
            maxCodexScanBytesPerRefresh: 1)
        options.refreshMinIntervalSeconds = 0

        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(!pending.historyCoverageIsEstablished)

        options.maxCodexSessionFileBytes = 0
        options.maxCodexScanBytesPerRefresh = 0
        let covered = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(covered.historyCoverageIsEstablished)
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

        let options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root
                .appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options,
            piScannerOptions: piOptions)
        #expect(ambient.sessionTokens == 100)

        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        cache.roots = nil
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)

        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: managedHome.path,
            allowPricingRefresh: false,
            includePiSessions: false,
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

        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root
                .appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 3600

        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(narrow.daily.map(\.date) == ["2026-04-08"])
        #expect(narrow.last30DaysTokens == 30)

        var legacyCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        legacyCache.scanSinceKey = nil
        legacyCache.scanUntilKey = nil
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacyCache)

        let expanded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            allowPricingRefresh: false,
            includePiSessions: false,
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

        let options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root
                .appendingPathComponent("missing-traces.sqlite"))
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: childDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
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
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let cacheFileExists = FileManager.default.fileExists(
            atPath: CostUsageStore(cacheRoot: env.cacheRoot).databaseURL.path)

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
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)
        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(2),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)

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
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)

        var rescanOptions = options
        rescanOptions.forceRescan = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: rescanOptions)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)

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

        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root
                .appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        let archivedURL = env.codexArchivedSessionsRoot.appendingPathComponent("moved.jsonl", isDirectory: false)
        try FileManager.default.moveItem(at: originalURL, to: archivedURL)

        let second = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)

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
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        let withoutPi = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let piCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 55,
            cachedInputTokens: 5,
            outputTokens: 5,
            modelsDevCacheRoot: env.cacheRoot) ?? 0

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.date == "2026-04-08")
        #expect(snapshot.daily.first?.totalTokens == 170)
        #expect(withoutPi.daily.first?.totalTokens == 110)
        #expect(abs((snapshot.daily.first?.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-5.4")
        #expect(abs((breakdown.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        #expect(breakdown.totalTokens == 170)
        #expect(snapshot.sessions.isEmpty)
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
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            allowPricingRefresh: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 100,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 10,
            outputTokens: 20,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let piCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 50,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 10,
            modelsDevCacheRoot: env.cacheRoot) ?? 0

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
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10,
            modelsDevCacheRoot: env.cacheRoot) ?? 0

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-5.4")
        #expect(abs((breakdown.costUSD ?? 0) - cost) < 0.000001)
        #expect(breakdown.totalTokens == 110)
    }

    @Test
    func `app refresh bypasses scanner debounce without changing direct callers`() async throws {
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
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot)

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
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

        let debounced = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        #expect(debounced.daily.first?.totalTokens == 110)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            bypassScannerDebounce: true,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        #expect(refreshed.daily.first?.totalTokens == 176)
    }

    @Test
    func `app codex refresh bounds its initial scan before background catch up`() {
        #expect(CostUsageFetcher.resolvedCodexScanDurationPerRefresh(
            provider: .codex,
            bypassScannerDebounce: true,
            configuredDuration: nil) == 2)
        #expect(CostUsageFetcher.resolvedCodexScanDurationPerRefresh(
            provider: .codex,
            bypassScannerDebounce: false,
            configuredDuration: nil) == nil)
        #expect(CostUsageFetcher.resolvedCodexScanDurationPerRefresh(
            provider: .claude,
            bypassScannerDebounce: true,
            configuredDuration: nil) == nil)
        #expect(CostUsageFetcher.resolvedCodexScanDurationPerRefresh(
            provider: .codex,
            bypassScannerDebounce: true,
            configuredDuration: 7) == 7)
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
    func `fetcher returns individual codex conversations for the selected history window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let firstURL = try env.writeCodexSessionFile(
            day: day,
            filename: "first.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["session_id": "first-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                        ],
                    ],
                ],
            ]))
        let secondURL = try env.writeCodexSessionFile(
            day: day,
            filename: "second.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["session_id": "second-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 40,
                                "cached_input_tokens": 5,
                                "output_tokens": 5,
                            ],
                        ],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(10)],
            ofItemAtPath: firstURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(20)],
            ofItemAtPath: secondURL.path)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(snapshot.sessions.map(\.sessionID) == ["second-session", "first-session"])
        let first = try #require(snapshot.sessions.first(where: { $0.sessionID == "first-session" }))
        #expect(first.inputTokens == 100)
        #expect(first.cachedInputTokens == 20)
        #expect(first.outputTokens == 10)
        #expect(first.totalTokens == 110)
        #expect(first.requestCount == nil)
        #expect(first.modelBreakdowns.map(\.modelName) == ["gpt-5.4"])
        #expect(first.costUSD != nil)

        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let unrelatedRoot = env.root.appendingPathComponent("unrelated/sessions", isDirectory: true)
        let filtered = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: env.cacheRoot,
            sessionRoots: [unrelatedRoot])
        #expect(filtered.isEmpty)
        let scopedCache = CostUsageScanner.codexCache(cache, scopedTo: [unrelatedRoot])
        #expect(scopedCache.files.isEmpty)
        #expect(scopedCache.days.isEmpty)
    }
}
