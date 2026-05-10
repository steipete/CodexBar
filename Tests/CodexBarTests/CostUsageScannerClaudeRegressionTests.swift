import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerClaudeRegressionTests {
    @Test
    func `parseClaudeFile snapshots keep the last streaming chunk`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/parse-stream-last.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": iso0,
                    "sessionId": "parse-session",
                    "requestId": "req_parse_stream",
                    "isSidechain": false,
                    "message": [
                        "id": "msg_parse_stream",
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 50,
                            "cache_creation_input_tokens": 5,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 7,
                        ],
                    ],
                ],
                [
                    "type": "assistant",
                    "timestamp": iso1,
                    "sessionId": "parse-session",
                    "requestId": "req_parse_stream",
                    "isSidechain": false,
                    "message": [
                        "id": "msg_parse_stream",
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 50,
                            "cache_creation_input_tokens": 5,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 19,
                        ],
                    ],
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].sessionId == "parse-session")
        #expect(parsed.rows[0].messageId == "msg_parse_stream")
        #expect(parsed.rows[0].requestId == "req_parse_stream")
        #expect(parsed.rows[0].output == 19)
    }

    @Test
    func `parseClaudeFile snapshots keep missing id rows distinct`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/parse-missing-ids.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": iso0,
                    "message": [
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 11,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 3,
                        ],
                    ],
                ],
                [
                    "type": "assistant",
                    "timestamp": iso1,
                    "message": [
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 13,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 5,
                        ],
                    ],
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [11, 13])
        #expect(parsed.rows.allSatisfy { $0.messageId == nil && $0.requestId == nil })
    }

    @Test
    func `claude opus 4 7 issue row gets priced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 23)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/opus-47.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-opus-4-7",
                        "id": "msg_01NrvWoSMk2Eig6vkCgyRZqc",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 6,
                            "cache_creation_input_tokens": 1389,
                            "cache_read_input_tokens": 50352,
                            "output_tokens": 3922,
                        ],
                    ],
                    "requestId": "req_011CaLLcFQD712ZnCTxHFk71",
                    "type": "assistant",
                    "timestamp": "2026-04-23T07:51:34.428Z",
                    "sessionId": "39d4b923-8273-4c35-ad9c-e098395286f1",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].model == "claude-opus-4-7")
        #expect(parsed.rows[0].input == 6)
        #expect(parsed.rows[0].cacheCreate == 1389)
        #expect(parsed.rows[0].cacheRead == 50352)
        #expect(parsed.rows[0].output == 3922)

        let expected = 0.13193725
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
    }

    @Test
    func `claude streaming keeps the last cumulative chunk`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "claude-sonnet-4-20250514"
        let sessionId = "session-stream-last-wins"
        let messageId = "msg_stream_last_wins"
        let requestId = "req_stream_last_wins"

        let chunk1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": sessionId,
            "requestId": requestId,
            "isSidechain": false,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 12,
                ],
            ],
        ]
        let chunk2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": sessionId,
            "requestId": requestId,
            "isSidechain": false,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 48,
                ],
            ],
        ]
        let chunk3: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "sessionId": sessionId,
            "requestId": requestId,
            "isSidechain": false,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 90,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/stream-last-wins.jsonl",
            contents: env.jsonl([chunk1, chunk2, chunk3]))

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
        #expect(report.data[0].inputTokens == 120)
        #expect(report.data[0].cacheCreationTokens == 10)
        #expect(report.data[0].cacheReadTokens == 5)
        #expect(report.data[0].outputTokens == 90)
        #expect(report.data[0].totalTokens == 225)
    }

    @Test
    func `claude cross file dedup prefers parent and keeps unique sidechain rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 22)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

        let model = "claude-sonnet-4-20250514"
        let sessionId = "session-cross-file"

        let parentOverlap: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": sessionId,
            "requestId": "req_overlap",
            "isSidechain": false,
            "message": [
                "id": "msg_overlap",
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 30,
                ],
            ],
        ]
        let compactOverlap: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": sessionId,
            "requestId": "req_overlap",
            "isSidechain": true,
            "message": [
                "id": "msg_overlap",
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 30,
                ],
            ],
        ]
        let nonCompactOverlap: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "sessionId": sessionId,
            "requestId": "req_overlap",
            "isSidechain": true,
            "message": [
                "id": "msg_overlap",
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 30,
                ],
            ],
        ]
        let uniqueSidechain: [String: Any] = [
            "type": "assistant",
            "timestamp": iso3,
            "sessionId": sessionId,
            "requestId": "req_unique_sidechain",
            "isSidechain": true,
            "message": [
                "id": "msg_unique_sidechain",
                "model": model,
                "usage": [
                    "input_tokens": 70,
                    "cache_creation_input_tokens": 5,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 20,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId).jsonl",
            contents: env.jsonl([parentOverlap]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId)/subagents/agent-acompact-overlap.jsonl",
            contents: env.jsonl([compactOverlap]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId)/subagents/agent-aside_question-overlap.jsonl",
            contents: env.jsonl([nonCompactOverlap, uniqueSidechain]))

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
        #expect(report.data[0].inputTokens == 170)
        #expect(report.data[0].cacheCreationTokens == 25)
        #expect(report.data[0].cacheReadTokens == 10)
        #expect(report.data[0].outputTokens == 50)
        #expect(report.data[0].totalTokens == 255)
    }

    @Test
    func `claude cross file dedup uses stable path order for same rank sidechains`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let sessionId = "session-sidechain-path-order"

        let firstSidechain: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": sessionId,
            "requestId": "req_path_order",
            "isSidechain": true,
            "message": [
                "id": "msg_path_order",
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]
        let secondSidechain: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": sessionId,
            "requestId": "req_path_order",
            "isSidechain": true,
            "message": [
                "id": "msg_path_order",
                "model": model,
                "usage": [
                    "input_tokens": 999,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 999,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId)/subagents/agent-a-first.jsonl",
            contents: env.jsonl([firstSidechain]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId)/subagents/agent-b-second.jsonl",
            contents: env.jsonl([secondSidechain]))

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
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 1)
        #expect(report.data[0].totalTokens == 11)
    }

    @Test
    func `claude cross file dedup does not merge rows without session ids`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"

        let missingSession: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_shared",
            "isSidechain": false,
            "message": [
                "id": "msg_shared",
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]
        let sessionScoped: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": "session-has-id",
            "requestId": "req_shared",
            "isSidechain": true,
            "message": [
                "id": "msg_shared",
                "model": model,
                "usage": [
                    "input_tokens": 20,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 2,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/missing-session-parent.jsonl",
            contents: env.jsonl([missingSession]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-has-id/subagents/agent-a-sidechain.jsonl",
            contents: env.jsonl([sessionScoped]))

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
        #expect(report.data[0].inputTokens == 30)
        #expect(report.data[0].outputTokens == 3)
        #expect(report.data[0].totalTokens == 33)
    }

    @Test
    func `claude rescans sessions when a new parent file overlaps cached sidechain data`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 24)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let sessionId = "session-cache-recompute"

        let sidechainOverlap: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": sessionId,
            "requestId": "req_overlap",
            "isSidechain": true,
            "message": [
                "id": "msg_overlap",
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        let uniqueSidechain: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": sessionId,
            "requestId": "req_unique",
            "isSidechain": true,
            "message": [
                "id": "msg_unique",
                "model": model,
                "usage": [
                    "input_tokens": 5,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId)/subagents/agent-acompact-cached.jsonl",
            contents: env.jsonl([sidechainOverlap, uniqueSidechain]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let firstReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(firstReport.data.count == 1)
        #expect(firstReport.data[0].inputTokens == 45)
        #expect(firstReport.data[0].outputTokens == 11)
        #expect(firstReport.data[0].totalTokens == 56)

        let parentOverlap: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": sessionId,
            "requestId": "req_overlap",
            "isSidechain": false,
            "message": [
                "id": "msg_overlap",
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/\(sessionId).jsonl",
            contents: env.jsonl([parentOverlap]))

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(10),
            options: options)

        #expect(secondReport.data.count == 1)
        #expect(secondReport.data[0].inputTokens == 45)
        #expect(secondReport.data[0].outputTokens == 11)
        #expect(secondReport.data[0].totalTokens == 56)
    }

    @Test
    func `claude sonnet 4 6 pricing is available for base and dated models`() {
        let baseCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            cacheReadInputTokens: 100,
            cacheCreationInputTokens: 50,
            outputTokens: 25)
        let datedCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6-20260219",
            inputTokens: 1000,
            cacheReadInputTokens: 100,
            cacheCreationInputTokens: 50,
            outputTokens: 25)

        #expect(baseCost != nil)
        #expect(datedCost != nil)
        #expect(baseCost == datedCost)
    }
}
