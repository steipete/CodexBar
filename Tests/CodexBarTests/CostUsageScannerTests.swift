import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageScannerTests {
    @Test
    func codexDailyReportParsesTokenCountsAndCaches() throws {
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
        #expect(first.data[0].modelsUsed == ["gpt-5.2"])
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
        #expect(second.data[0].totalTokens == 176)
        #expect((second.data[0].costUSD ?? 0) > (first.data[0].costUSD ?? 0))
    }

    @Test
    func codexDailyReportIncludesArchivedSessionsAndDedupes() throws {
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
    func claudeDailyReportParsesUsageAndCaches() throws {
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
        #expect((report.data[0].costUSD ?? 0) > 0)
    }

    @Test
    func vertexDailyReportFiltersClaudeLogs() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)

        let vertexEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "metadata": [
                "provider": "vertexai",
                "projectId": "vertex-project",
                "location": "us-central1",
            ],
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]
        let claudeEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "metadata": [
                "provider": "anthropic",
            ],
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([vertexEntry, claudeEntry]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .vertexai,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 5)
        #expect(report.data[0].totalTokens == 15)
    }

    @Test
    func vertexDailyReportDetectsByVrtxIdPrefix() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        // Vertex AI entries have "_vrtx_" in message.id and requestId
        let vertexEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_vrtx_011CWjK86SWeFuXqZKUtgB1H",
            "message": [
                "id": "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo",
                "model": "claude-opus-4-5-20251101",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ],
        ]
        // Anthropic API entries have regular IDs without "_vrtx_"
        let claudeEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": "req_011CW7BFSFkbK9qJrV8kiptH",
            "message": [
                "id": "msg_0152zX6DsQYcwH1qiXi4B3y2",
                "model": "claude-opus-4-5-20251101",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([vertexEntry, claudeEntry]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // Vertex AI report should only include entries with _vrtx_ prefix
        let vertexReport = CostUsageScanner.loadDailyReport(
            provider: .vertexai,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(vertexReport.data.count == 1)
        #expect(vertexReport.data[0].inputTokens == 100)
        #expect(vertexReport.data[0].outputTokens == 50)
        #expect(vertexReport.data[0].totalTokens == 150)

        // Claude report with excludeVertexAI should only include non-vrtx entries
        var claudeOptions = options
        claudeOptions.claudeLogProviderFilter = .excludeVertexAI
        let claudeReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: claudeOptions)

        #expect(claudeReport.data.count == 1)
        #expect(claudeReport.data[0].inputTokens == 200)
        #expect(claudeReport.data[0].outputTokens == 100)
        #expect(claudeReport.data[0].totalTokens == 300)
    }

    @Test
    func claudeParsesLargeLinesWithUsageAtTail() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 28)
        let iso0 = env.isoString(for: day)
        let largeText = String(repeating: "a", count: 70000)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "content": [
                    ["type": "text", "text": largeText],
                ],
                "usage": [
                    "input_tokens": 3714,
                    "output_tokens": 1,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/large-line.jsonl",
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
        #expect(report.data[0].inputTokens == 3714)
        #expect(report.data[0].outputTokens == 1)
        #expect(report.data[0].totalTokens == 3715)
    }

    @Test
    func claudeDailyReportRefreshesWhenFileChanges() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

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
        #expect(firstReport.data.first?.totalTokens == 355)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(secondReport.data.first?.totalTokens == 430)
    }

    @Test
    func codexIncrementalParsingUsesPreviousTotals() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let normalized = CostUsagePricing.normalizeCodexModel(model)
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

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        #expect(first.parsedBytes > 0)
        #expect(first.lastTotals?.input == 100)
        #expect(first.lastTotals?.cached == 20)
        #expect(first.lastTotals?.output == 10)

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

        let delta = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            startOffset: first.parsedBytes,
            initialModel: first.lastModel,
            initialTotals: first.lastTotals)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = delta.days[dayKey]?[normalized] ?? []
        #expect(packed.count >= 3)
        #expect(packed[0] == 60)
        #expect(packed[1] == 20)
        #expect(packed[2] == 6)
    }

    @Test
    func claudeIncrementalParsingReadsAppendedLinesOnly() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let normalized = CostUsagePricing.normalizeClaudeModel(model)
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let firstParse = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all)
        #expect(firstParse.parsedBytes > 0)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let delta = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all,
            startOffset: firstParse.parsedBytes)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = delta.days[dayKey]?[normalized] ?? []
        #expect(packed.count >= 4)
        #expect(packed[0] == 40)
        #expect(packed[1] == 5)
        #expect(packed[2] == 10)
        #expect(packed[3] == 20)
    }

    @Test
    func dayKeyFromTimestampMatchesISOParsing() {
        let timestamps = [
            "2025-12-20T23:59:59Z",
            "2025-12-20T23:59:59+02:00",
        ]

        for ts in timestamps {
            let expected = CostUsageScanner.dayKeyFromParsedISO(ts)
            let fast = CostUsageScanner.dayKeyFromTimestamp(ts)
            #expect(fast == expected)
        }
    }

    @Test
    func claudeDeduplicatesStreamingChunks() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"
        let requestId = "req_01XYZ789"

        // Streaming emits multiple chunks with same message.id + requestId.
        // Each chunk has cumulative usage, not delta.
        let chunk1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk3: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
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

        // Should only count once, not 3x.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 185)
    }

    @Test
    func claudeCountsEntriesWithoutIdsAsSeparate() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"

        // Entries without message.id or requestId should still be counted
        // (fallback for older log formats).
        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

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

        // Both entries should be counted since no IDs to dedupe.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 300)
        #expect(report.data[0].outputTokens == 150)
        #expect(report.data[0].totalTokens == 450)
    }

    @Test
    func claudeCountsDifferentRequestIdsSeparately() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"

        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_01AAA",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": "req_01BBB",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 20,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

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
        #expect(report.data[0].outputTokens == 15)
        #expect(report.data[0].totalTokens == 45)
    }

    @Test
    func jsonlScannerHandlesLinesAcrossReadChunks() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileURL = env.root.appendingPathComponent("large-lines.jsonl", isDirectory: false)
        let largeLine = String(repeating: "x", count: 300_000)
        let contents = "\(largeLine)\nsmall\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [(count: Int, truncated: Bool)] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 400_000,
            prefixBytes: 400_000)
        { line in
            scanned.append((line.bytes.count, line.wasTruncated))
        }

        #expect(endOffset == Int64(Data(contents.utf8).count))
        #expect(scanned.count == 2)
        #expect(scanned[0].count == 300_000)
        #expect(scanned[0].truncated == false)
        #expect(scanned[1].count == 5)
        #expect(scanned[1].truncated == false)
    }

    @Test
    func jsonlScannerMarksPrefixLimitedLinesAsTruncated() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileURL = env.root.appendingPathComponent("truncated-lines.jsonl", isDirectory: false)
        let shortLine = "ok"
        let longLine = String(repeating: "a", count: 2000)
        let contents = "\(shortLine)\n\(longLine)\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        _ = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 10000,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 2)
        #expect(String(data: scanned[0].bytes, encoding: .utf8) == "ok")
        #expect(scanned[0].wasTruncated == false)
        #expect(scanned[1].bytes.isEmpty)
        #expect(scanned[1].wasTruncated == true)
    }
}

private struct CostUsageTestEnvironment {
    let root: URL
    let cacheRoot: URL
    let codexHomeRoot: URL
    let codexSessionsRoot: URL
    let codexArchivedSessionsRoot: URL
    let claudeProjectsRoot: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.codexHomeRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        self.codexSessionsRoot = self.codexHomeRoot.appendingPathComponent("sessions", isDirectory: true)
        self.codexArchivedSessionsRoot = self.codexHomeRoot
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexArchivedSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.claudeProjectsRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func makeLocalNoon(year: Int, month: Int, day: Int) throws -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        guard let date = comps.date else { throw NSError(domain: "CostUsageTestEnvironment", code: 1) }
        return date
    }

    func isoString(for date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    func writeCodexSessionFile(day: Date, filename: String, contents: String) throws -> URL {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let y = String(format: "%04d", comps.year ?? 1970)
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)

        let dir = self.codexSessionsRoot
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent(d, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeClaudeProjectFile(relativePath: String, contents: String) throws -> URL {
        let url = self.claudeProjectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeCodexArchivedSessionFile(filename: String, contents: String) throws -> URL {
        let url = self.codexArchivedSessionsRoot.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func jsonl(_ objects: [Any]) throws -> String {
        let lines = try objects.map { obj in
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw NSError(domain: "CostUsageTestEnvironment", code: 2)
            }
            return text
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
