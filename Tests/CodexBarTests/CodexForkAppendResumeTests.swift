import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexForkAppendResumeTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    @Test
    func `ordinary fork with an unresolved parent keeps a bounded marker across append`() throws {
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
        #expect(firstUsage.codexDeferredForkScan == true)
        #expect(firstUsage.codexBufferedUnresolvedForkLines == nil)
        #expect(firstUsage.codexScanComplete == false)
        #expect(firstUsage.codexTokenSnapshots == nil)
        #expect(firstUsage.codexTokenSidecarState == nil)
        #expect(firstParsedBytes == 0)

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
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: appendedMetadata,
            cached: firstUsage) == appendedSize)
        var nilDependencyUsage = firstUsage
        nilDependencyUsage.forkBaselineDependencyKey = nil
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: appendedMetadata,
            cached: nilDependencyUsage) == appendedSize)

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
        #expect(secondUsage.parsedBytes == 0)
        #expect(secondUsage.size == appendedSize)
        #expect(secondUsage.codexScanComplete == false)
        #expect(secondUsage.codexDeferredForkScan == true)
        #expect(secondUsage.codexBufferedUnresolvedForkLines == nil)
        #expect(secondUsage.codexTokenSidecarState == nil)
    }

    @Test
    func `same-size subagent retry is free but an append forces a full rescan`() throws {
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
        #expect(firstUsage.codexTokenSnapshots == nil)
        #expect(firstUsage.codexTokenSidecarState?.eventCount == 1)

        var sameSizeRetryUsage = firstUsage
        sameSizeRetryUsage.forkBaselineDependencyKey = nil
        let sameSizeMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let sameSizePendingWork = CostUsageScanner.pendingCodexScanWorkBytes(
            metadata: sameSizeMetadata,
            cached: sameSizeRetryUsage)
        #expect(sameSizePendingWork == 0)
        let exhaustedBudget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 512,
            maxBytesPerRefresh: 512)
        exhaustedBudget.consume(workBytes: 512)
        switch exhaustedBudget.admit(workBytes: sameSizePendingWork) {
        case let .allow(allowance):
            #expect(allowance == 0)
        case .deferBudget:
            Issue.record("same-size in-memory retry must not be deferred by an exhausted byte budget")
        }

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

    @Test
    func `active append keeps a partial subagent buffered until stable EOF`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        var initialLines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": [
                    "id": "active-redacted-subagent",
                    "source": ["subagent": ["thread_spawn": [:]]],
                ],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.3",
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
            filename: "rollout-\(timestamp)-active-redacted-subagent.jsonl",
            contents: env.jsonl(initialLines))
        let appended = try env.jsonl([
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "active-redacted-parent"]],
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(2)),
                model: "openai/gpt-5.4"),
            [
                "type": "inter_agent_communication_metadata",
                "timestamp": env.isoString(for: day.addingTimeInterval(2)),
                "payload": ["trigger_turn": true],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(3)),
                model: "openai/gpt-5.4",
                total: (input: 1050, cached: 910, output: 105),
                last: (input: 50, cached: 10, output: 5)),
        ])

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: 512,
            maxCodexScanBytesPerRefresh: 512)
        options.refreshMinIntervalSeconds = 0
        var didAppend = false
        var mutationError: Error?
        let partialReport = CostUsageScanner.withCodexAfterFileParseHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fileURL.standardizedFileURL,
                  !didAppend
            else { return }
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(appended.utf8))
                try handle.close()
                didAppend = true
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
        }
        try #require(mutationError == nil)
        #expect(didAppend)

        let partialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let partialUsage = try #require(
            partialCache.files.values.first { $0.sessionId == "active-redacted-subagent" })
        let partialBytes = try #require(partialUsage.parsedBytes)
        let grownMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(partialBytes > 0)
        #expect(partialBytes < grownMetadata.size)
        #expect(partialUsage.size == grownMetadata.size)
        #expect(partialUsage.codexScanComplete == false)
        #expect(partialUsage.codexBufferedSubagentLines?.isEmpty == false)
        #expect(partialUsage.days.isEmpty)
        #expect(partialUsage.codexRows?.isEmpty != false)
        #expect(partialReport.data.isEmpty)

        options.maxCodexSessionFileBytes = 0
        options.maxCodexScanBytesPerRefresh = 0
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("active-subagent-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: controlOptions)
        let settled = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let settledUsage = try #require(
            settled.files.values.first { $0.sessionId == "active-redacted-subagent" })
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
        #expect(stable.data.first?.totalTokens == 55)
        #expect(settledUsage.codexScanComplete == true)
        #expect(settledUsage.codexBufferedSubagentLines == nil)
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
