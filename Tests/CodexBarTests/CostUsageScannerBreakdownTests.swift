import Foundation
import Testing
@testable import CodexBarCore

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
