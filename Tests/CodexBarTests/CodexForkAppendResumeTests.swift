import Foundation
import Testing
@testable import CodexBarCore

struct CodexForkAppendResumeTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    @Test
    func `bounded append resumes a complete fork with an unresolved parent`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        var initialLines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": [
                    "id": "redacted-child",
                    "forked_from_id": "redacted-missing-parent",
                    "timestamp": timestamp,
                ],
            ],
            self.turnContext(timestamp: timestamp, model: "openai/gpt-5.4"),
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.4",
                total: (input: 1000, cached: 900, output: 100)),
        ]
        for index in 0..<80 {
            initialLines.append([
                "type": "response_item",
                "timestamp": timestamp,
                "payload": [
                    "sequence": index,
                    "text": String(repeating: "x", count: 128),
                ],
            ])
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-redacted-child.jsonl",
            contents: env.jsonl(initialLines))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: 64 * 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstUsage = try #require(firstCache.files.values.first { $0.sessionId == "redacted-child" })
        let firstParsedBytes = try #require(firstUsage.parsedBytes)
        #expect(firstUsage.forkedFromId == "redacted-missing-parent")
        #expect(firstUsage.forkBaselineDependencyKey != nil)
        #expect(firstUsage.codexBufferedUnresolvedForkLines?.isEmpty == false)
        #expect(firstUsage.codexScanComplete == true)
        #expect(firstUsage.codexTokenSnapshots?.count == 1)
        #expect(firstParsedBytes == CostUsageScanner.codexFileMetadata(fileURL: fileURL).size)
        #expect(firstParsedBytes > 512)

        let appended = try env.jsonl([
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(2)),
                model: "openai/gpt-5.4"),
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(3)),
                model: "openai/gpt-5.4",
                total: (input: 1050, cached: 910, output: 105),
                last: (input: 50, cached: 10, output: 5)),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let appendedMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let appendedSize = appendedMetadata.size
        #expect(appendedSize > firstParsedBytes)
        #expect(appendedSize - firstParsedBytes <= 512)
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: appendedMetadata,
            cached: firstUsage) == appendedSize - firstParsedBytes)
        var nilDependencyUsage = firstUsage
        nilDependencyUsage.forkBaselineDependencyKey = nil
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: appendedMetadata,
            cached: nilDependencyUsage) == appendedSize - firstParsedBytes)

        options.maxCodexSessionFileBytes = 512
        options.maxCodexScanBytesPerRefresh = 512
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let secondCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let secondUsage = try #require(secondCache.files.values.first { $0.sessionId == "redacted-child" })
        #expect(secondUsage.parsedBytes == appendedSize)
        #expect((secondUsage.parsedBytes ?? 0) >= firstParsedBytes)
        #expect(secondUsage.codexScanComplete == true)
        #expect(secondUsage.codexTokenSnapshots?.count == 2)
    }

    @Test
    func `bounded append keeps an unresolved subagent on the full rescan path`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        var initialLines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": [
                    "id": "redacted-subagent",
                    "forked_from_id": "redacted-missing-parent",
                    "source": ["subagent": ["thread_spawn": [:]]],
                ],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.3",
                total: (input: 1000, cached: 900, output: 100)),
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "redacted-missing-parent"],
            ],
        ]
        for index in 0..<80 {
            initialLines.append([
                "type": "response_item",
                "timestamp": timestamp,
                "payload": [
                    "sequence": index,
                    "text": String(repeating: "x", count: 128),
                ],
            ])
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-redacted-subagent.jsonl",
            contents: env.jsonl(initialLines))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: 64 * 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstUsage = try #require(firstCache.files.values.first { $0.sessionId == "redacted-subagent" })
        let firstParsedBytes = try #require(firstUsage.parsedBytes)
        #expect(firstUsage.forkedFromId == "redacted-missing-parent")
        #expect(firstUsage.codexBufferedSubagentLines?.isEmpty == false)
        #expect(firstUsage.codexBufferedUnresolvedForkLines?.isEmpty != false)
        #expect(firstUsage.codexScanComplete == true)
        #expect(firstParsedBytes == CostUsageScanner.codexFileMetadata(fileURL: fileURL).size)
        #expect(firstParsedBytes > 512)

        let appended = try env.jsonl([
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(4)),
                model: "openai/gpt-5.4"),
            [
                "type": "inter_agent_communication_metadata",
                "timestamp": env.isoString(for: day.addingTimeInterval(4)),
                "payload": ["trigger_turn": true],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(5)),
                model: "openai/gpt-5.4",
                total: (input: 1050, cached: 910, output: 105),
                last: (input: 50, cached: 10, output: 5)),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let appendedMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(appendedMetadata.size > firstParsedBytes)
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: appendedMetadata,
            cached: firstUsage) == appendedMetadata.size)

        options.maxCodexSessionFileBytes = 512
        options.maxCodexScanBytesPerRefresh = 512
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let secondCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let secondUsage = try #require(secondCache.files.values.first { $0.sessionId == "redacted-subagent" })
        #expect((secondUsage.parsedBytes ?? 0) <= 512)
        #expect(secondUsage.codexScanComplete == false)
    }

    private func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": model],
        ]
    }

    private func tokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = ["model": model]
        if let total {
            info["total_token_usage"] = [
                "input_tokens": total.input,
                "cached_input_tokens": total.cached,
                "output_tokens": total.output,
            ]
        }
        if let last {
            info["last_token_usage"] = [
                "input_tokens": last.input,
                "cached_input_tokens": last.cached,
                "output_tokens": last.output,
            ]
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }
}
