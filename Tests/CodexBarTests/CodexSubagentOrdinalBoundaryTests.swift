import Foundation
import Testing
@testable import CodexBarCore

struct CodexSubagentOrdinalBoundaryTests {
    @Test
    func `explicit boundary excludes a prefix ending before child history`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 15)
        let file = try self.writePrefix(env: env, day: day)
        var consultedParent = false
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: file,
            range: .init(since: day, until: day),
            inheritedTotalsResolver: { _, _ in
                consultedParent = true
                return .unresolved
            })
        #expect(parsed.days.isEmpty)
        #expect(parsed.rows.isEmpty)
        #expect(!parsed.dependsOnParentTotals)
        #expect(!consultedParent)
    }

    @Test(arguments: [false, true])
    func `explicit boundary preserves first owned usage across cached and bounded appends`(bounded: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 15)
        let file = try self.writePrefix(env: env, day: day)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        if bounded {
            options.maxCodexSessionFileBytes = 4096
            options.maxCodexScanBytesPerRefresh = 4096
        }
        options.refreshMinIntervalSeconds = 0
        var clock = day
        let cold = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(cold) == 0)
        let warm = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(warm) == 0)

        let appended = try env.jsonl([
            self.context(ordinal: 210, timestamp: env.isoString(for: day.addingTimeInterval(5))),
            self.tokens(
                ordinal: 211,
                timestamp: env.isoString(for: day.addingTimeInterval(6)),
                total: [1100, 930, 115],
                last: [30, 15, 5]),
        ])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + appended).utf8))
        try handle.close()
        let grown = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(grown) == 35)
        let cached = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(cached) == 35)
        options.forceRescan = true
        let forced = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(forced) == 35)
    }

    @Test
    func `legacy whitespace marker does not qualify as the current parser`() throws {
        let json = #"{"mtimeUnixMs":1,"size":1,"days":{},"codexEventWhitespaceParsed":true}"#
        let legacy = try JSONDecoder().decode(CostUsageFileUsage.self, from: Data(json.utf8))
        #expect(legacy.codexParserRevision == nil)
        #expect(!legacy.hasCurrentCodexParser)
    }

    @Test(arguments: [false, true], [nil, 1] as [Int?])
    func `older parser revisions replace unchanged inherited rows without rebuilding`(
        bounded: Bool,
        revision: Int?) async throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 15)
        let file = try self.writePrefix(env: env, day: day)
        let contents = try Data(contentsOf: file)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        var clock = day
        _ = try self.scan(env: env, day: day, options: options, clock: &clock)
        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(legacy.files.keys.first)
        var usage = try #require(legacy.files[path])
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        usage.days = [dayKey: ["gpt-5.4": [70, 15, 10]]]
        usage.codexRows = [.init(
            day: dayKey,
            model: "gpt-5.4",
            rawModel: "gpt-5.4",
            turnID: nil,
            eventIndex: 0,
            timestampUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            input: 70,
            cached: 15,
            output: 10)]
        usage.codexParserRevision = revision
        legacy.files[path] = usage
        legacy.days = usage.days
        let report = CostUsageDailyReport(
            data: [.init(
                date: dayKey,
                inputTokens: 70,
                outputTokens: 10,
                totalTokens: 80,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            summary: nil)
        legacy.codexPreviousReport = CostUsageCodexPreviousReport(
            report: report, cache: legacy, reportSinceKey: dayKey, reportUntilKey: dayKey)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path]?.codexRows?.first?.input == 70)
        if bounded { options.maxCodexScanBytesPerRefresh = 512 }
        let repaired = try self.scan(env: env, day: day, options: options, clock: &clock)
        #expect(self.totalTokens(repaired) == 0)
        let reopened = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(reopened.files[path]?.hasCurrentCodexParser == true)
        #expect((reopened.files[path]?.codexRows ?? []).isEmpty)
        #expect(try Data(contentsOf: file) == contents)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let persisted = await store.readSnapshot()
        #expect(persisted.usageRows.isEmpty)
        #expect(persisted.files.contains { $0.path == path })
        #expect(await store.rebuildCount == 0)
    }

    private func writePrefix(env: CostUsageTestEnvironment, day: Date) throws -> URL {
        let timestamp = env.isoString(for: day)
        return try env.writeCodexSessionFile(
            day: day, filename: "ordinal-child.jsonl", contents: env.jsonl([
                ["type": "session_meta", "ordinal": 0, "timestamp": timestamp, "payload": [
                    "id": "ordinal-child", "forked_from_id": "ordinal-parent", "timestamp": timestamp,
                    "subagent_history_start_ordinal": 210,
                    "source": ["subagent": ["thread_spawn": ["parent_thread_id": "ordinal-parent"]]],
                ]],
                self.tokens(ordinal: 2, timestamp: timestamp, total: [1000, 900, 100], last: [0, 0, 0]),
                self.context(ordinal: 10, timestamp: timestamp),
                [
                    "type": "inter_agent_communication_metadata",
                    "ordinal": 11,
                    "timestamp": timestamp,
                    "payload": ["trigger_turn": true],
                ],
                self.tokens(ordinal: 19, timestamp: timestamp, total: [1050, 910, 105], last: [50, 10, 5]),
                self.tokens(ordinal: 208, timestamp: timestamp, total: [1070, 915, 110], last: [20, 5, 5]),
            ]))
    }

    private func context(ordinal: Int, timestamp: String) -> [String: Any] {
        ["type": "turn_context", "ordinal": ordinal, "timestamp": timestamp, "payload": ["model": "gpt-5.4"]]
    }

    private func totalTokens(_ report: CostUsageDailyReport) -> Int {
        report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) }
    }

    private func tokens(ordinal: Int, timestamp: String, total: [Int], last: [Int]) -> [String: Any] {
        func usage(_ values: [Int]) -> [String: Int] {
            ["input_tokens": values[0], "cached_input_tokens": values[1], "output_tokens": values[2]]
        }
        return ["type": "event_msg", "ordinal": ordinal, "timestamp": timestamp, "payload": [
            "type": "token_count", "info": ["total_token_usage": usage(total), "last_token_usage": usage(last)],
        ]]
    }

    private func scan(
        env: CostUsageTestEnvironment,
        day: Date,
        options: CostUsageScanner.Options,
        clock: inout Date) throws -> CostUsageDailyReport
    {
        for _ in 0..<20 {
            clock.addTimeInterval(1)
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: clock,
                options: options)
            let files = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files.values
            if !files.isEmpty, files.allSatisfy({ $0.codexScanComplete == true && $0.hasCurrentCodexParser }) {
                return report
            }
        }
        throw NSError(domain: "OrdinalBoundaryTests", code: 1)
    }
}
