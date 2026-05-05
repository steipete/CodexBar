import Foundation
import Testing
@testable import CodexBarCore

// swiftlint:disable file_length
// swiftlint:disable type_body_length
struct CostUsageScannerBreakdownTests {
    @Test
    func `codex daily report parses token counts and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let firstTokenCount: [String: Any] = [
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
                    "model": model,
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(first.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.2-codex",
                costUSD: first.data[0].costUSD,
                totalTokens: 110),
        ])
        #expect(first.data[0].totalTokens == 110)
        #expect((first.data[0].costUSD ?? 0) > 0)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(second.data[0].totalTokens == 176)
        #expect((second.data[0].costUSD ?? 0) > (first.data[0].costUSD ?? 0))
    }

    @Test
    func `codex daily report includes archived sessions and dedupes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 22)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.2-codex"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-archived-1",
            ],
        ]
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let tokenCount: [String: Any] = [
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
                    "model": model,
                ],
            ],
        ]

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let archivedName = "rollout-\(dayKey)T12-00-00-archived.jsonl"
        let contents = try env.jsonl([sessionMeta, turnContext, tokenCount])
        _ = try env.writeCodexArchivedSessionFile(filename: archivedName, contents: contents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].totalTokens == 110)

        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: contents)
        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].totalTokens == 110)
    }

    @Test
    func `codex daily report includes long lived sessions stored under older date partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: fileDay,
            filename: "rollout-2026-02-27T11-29-28-cross-day.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": "cross-day-session",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 110)
    }

    @Test
    func `codex forked child subtracts parent totals at fork timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let parentTs3 = env.isoString(for: parentDay.addingTimeInterval(3))
        let childForkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent"
        let childSessionId = "sess-child"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": childForkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child subtracts inherited replay from last token usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))
        let childTs3 = env.isoString(for: childDay.addingTimeInterval(3))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-last"
        let childSessionId = "sess-child-last"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 3,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child ignores replayed parent prefix sequence`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-prefix"
        let childSessionId = "sess-child-prefix"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(6)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child subtracts inherited replay even when session meta appears late`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-late-meta"
        let childSessionId = "sess-child-late-meta"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child resolves parent when parent session file is a symlink`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-symlink"
        let childSessionId = "sess-child-symlink"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        let parentContents = try env.jsonl([
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ])

        let parentTarget = env.root.appendingPathComponent("parent-target.jsonl", isDirectory: false)
        try parentContents.write(to: parentTarget, atomically: true, encoding: .utf8)

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parentDay)
        let parentDir = env.codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let parentLink = parentDir.appendingPathComponent(
            "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            isDirectory: false)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parentTarget)

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child resolves parent by exact session meta id`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let wantedParentSessionId = "sess-parent-exact"
        let wrongParentSessionId = "sess-parent-exact-extra"
        let childSessionId = "sess-child-exact"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(wrongParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wrongParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 1000,
                                "cached_input_tokens": 100,
                                "output_tokens": 100,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-29-\(wantedParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wantedParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": wantedParentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 35,
                                "cached_input_tokens": 9,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 42,
                                "cached_input_tokens": 11,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child compares parent snapshots by parsed timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-timestamp"
        let childSessionId = "sess-child-timestamp"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": "2026-02-27T23:59:58Z",
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-27T23:59:59Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-28T00:00:01Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": "2026-02-28T08:00:00+08:00",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 25,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 10,
                                "output_tokens": 6,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 10,
            cachedInputTokens: 5,
            outputTokens: 4)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 4)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex first refresh keeps unrelated archived sessions out of cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let archivedDay = try env.makeLocalNoon(year: 2025, month: 1, day: 1)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-recent.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        let archivedURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-2025-01-01T12-00-00-session-archived.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: archivedDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: archivedDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 10,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(report.data.count == 1)
        #expect(cache.files.keys.contains { $0.hasSuffix("session-recent.jsonl") })
        #expect(!cache.files.keys.contains(archivedURL.path))
    }

    @Test
    func `codex root switch reloads long lived sessions from older partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        func writeSessionFile(
            root: URL,
            day: Date,
            filename: String,
            contents: String) throws -> URL
        {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let dir = root
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename, isDirectory: false)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let otherSessionsRoot = env.root
            .appendingPathComponent("other-codex-home", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSessionsRoot, withIntermediateDirectories: true)

        let oldRootURL = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-old-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try writeSessionFile(
            root: otherSessionsRoot,
            day: fileDay,
            filename: "rollout-2026-02-27T11-30-27-session-new-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 5,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var firstOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        firstOptions.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: firstOptions)

        var secondOptions = CostUsageScanner.Options(
            codexSessionsRoot: otherSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        secondOptions.refreshMinIntervalSeconds = 0

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: secondOptions)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(secondReport.data.count == 1)
        #expect(secondReport.data[0].inputTokens == 10)
        #expect(secondReport.data[0].outputTokens == 4)
        #expect(secondReport.data[0].totalTokens == 14)
        #expect(!cache.files.keys.contains(oldRootURL.path))
    }

    @Test
    func `claude daily report parses usage and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([assistant]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-20250514"])
        #expect(report.data[0].inputTokens == 200)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 80)
        #expect(report.data[0].totalTokens == 355)
        #expect(report.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-20250514",
                costUSD: report.data[0].costUSD,
                totalTokens: 355),
        ])
        #expect((report.data[0].costUSD ?? 0) > 0)
    }

    @Test
    func `codex daily report preserves full sorted model breakdowns`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let iso4 = env.isoString(for: day.addingTimeInterval(4))
        let iso5 = env.isoString(for: day.addingTimeInterval(5))
        let iso6 = env.isoString(for: day.addingTimeInterval(6))
        let iso7 = env.isoString(for: day.addingTimeInterval(7))

        let events: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": iso0,
                "payload": ["model": "openai/gpt-5.2-pro"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso1,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 100,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso2,
                "payload": ["model": "openai/gpt-5.3-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso3,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso4,
                "payload": ["model": "openai/gpt-5.2-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso5,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso6,
                "payload": ["model": "openai/gpt-5.3-codex-spark"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso7,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 0,
                            "output_tokens": 5,
                        ],
                    ],
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl(events))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].modelBreakdowns?.map(\.modelName) == [
            "gpt-5.2-pro",
            "gpt-5.3-codex",
            "gpt-5.2-codex",
            "gpt-5.3-codex-spark",
        ])
        #expect(report.data[0].modelBreakdowns?.map(\.totalTokens) == [110, 40, 30, 15])
    }
}

// swiftlint:enable type_body_length
