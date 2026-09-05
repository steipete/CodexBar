import Foundation
import Testing
@testable import CodexBarCore

struct CodexSubagentFrozenTargetTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    @Test
    func `bounded growing subagent retains its prefix until appended lineage is complete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-bounded-growing-subagent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "bounded-growing-child",
                        "source": ["subagent": ["thread_spawn": [:]]],
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: "openai/gpt-5.3"),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: "openai/gpt-5.3",
                    total: (input: 1000, cached: 900, output: 100)),
            ]))
        let initialSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size
        let slice = max(1, initialSize / 2)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: 1_000_000)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(cache.files.values.first)
        #expect(usage.codexScanComplete == false)
        #expect(usage.codexScanTargetSize == initialSize)
        #expect(usage.codexBufferedSubagentLines?.isEmpty == false)

        let appended = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "bounded-growing-parent"],
            ],
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
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        var frozenReport: CostUsageDailyReport?
        for pass in 1...8 {
            frozenReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            usage = try #require(cache.files.values.first)
            if usage.parsedBytes == initialSize {
                break
            }
        }

        #expect(usage.parsedBytes == initialSize)
        #expect(usage.codexScanTargetSize == initialSize)
        #expect(usage.codexScanComplete == true)
        #expect(usage.codexBufferedSubagentLines?.isEmpty == false)
        #expect(cache.codexScanCatchUpPending == true)
        #expect(frozenReport?.data.isEmpty == true)

        var finalReport: CostUsageDailyReport?
        for pass in 9...24 {
            finalReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            usage = try #require(cache.files.values.first)
            if cache.codexScanCatchUpPending == false {
                break
            }
        }

        #expect(finalReport?.data.first?.totalTokens == 55)
        #expect(usage.forkedFromId == "bounded-growing-parent")
        #expect(usage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey)
        #expect(usage.codexScanComplete == true)
        #expect(usage.codexBufferedSubagentLines == nil)
        #expect(cache.codexScanCatchUpPending == false)
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
