import Foundation
import Testing
@testable import CodexBarCore

struct CodexSubagentForkBaselineTests {
    @Test(arguments: [false, true], [false, true])
    func `explicit suffix excludes inherited totals even when components drift`(
        mismatched: Bool,
        parentPresent: Bool) throws
    {
        try self.verifyForks(explicit: true, trigger: true, mismatched: mismatched, parentPresent: parentPresent)
    }

    @Test(arguments: [false, true], [false, true])
    func `legacy suffix excludes inherited totals without a parent snapshot`(
        mismatched: Bool,
        trigger: Bool) throws
    {
        try self.verifyForks(explicit: false, trigger: trigger, mismatched: mismatched, parentPresent: false)
    }

    @Test(arguments: [false, true])
    func `legacy first owned token identifies its boundary without turn metadata`(mismatched: Bool) throws {
        try self.verifyForks(
            explicit: false, trigger: false, mismatched: mismatched, parentPresent: false, contextPresent: false)
    }

    @Test(arguments: [false, true], [false, true])
    func `nested forks count each owned suffix once`(explicit: Bool, parentPresent: Bool) throws {
        try self.verifyForks(
            explicit: explicit, trigger: true, mismatched: true, parentPresent: parentPresent, depth: 2)
    }

    @Test(arguments: [false, true])
    func `zero inherited counters preserve fresh child usage`(explicit: Bool) throws {
        try self.verifyForks(
            explicit: explicit, trigger: true, mismatched: false, parentPresent: false, opening: [0, 0, 0])
    }

    @Test(arguments: [false, true], [false, true])
    func `terminal inherited-only suffixes contribute no child usage`(explicit: Bool, parentPresent: Bool) throws {
        try self.verifyForks(
            explicit: explicit, trigger: true, mismatched: true, parentPresent: parentPresent, owned: false)
    }

    private func verifyForks(
        explicit: Bool,
        trigger: Bool,
        mismatched: Bool,
        parentPresent: Bool,
        depth: Int = 1,
        contextPresent: Bool = true,
        opening: [Int] = [1000, 900, 100],
        owned: Bool = true) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 15)
        let timestamp = env.isoString(for: day)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        var prefix = opening
        let ownedUsage: [Int]? = owned ? [70, 15, 10] : nil
        let ownedTokens = owned ? 80 : 0
        if parentPresent {
            _ = try env.writeCodexSessionFile(day: day, filename: "parent.jsonl", contents: env.jsonl([
                ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "fork-0"]],
                self.context(timestamp: timestamp),
                self.tokens(ordinal: 2, timestamp: timestamp, total: prefix, last: prefix),
            ]))
        }
        for level in 1...depth {
            let baseline = mismatched ? [prefix[0] + 4000, prefix[1] + 3000, prefix[2] + 400] : prefix
            var metadata: [String: Any] = [
                "id": "fork-\(level)", "forked_from_id": "fork-\(level - 1)", "timestamp": timestamp,
                "thread_source": "subagent",
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": "fork-\(level - 1)", "depth": level]]],
            ]
            if explicit { metadata["subagent_history_start_ordinal"] = 10 }
            var lines: [[String: Any]] = [
                ["type": "session_meta", "ordinal": 0, "timestamp": timestamp, "payload": metadata],
                ["type": "compacted", "ordinal": 1, "timestamp": timestamp, "payload": [:]],
                self.tokens(ordinal: 2, timestamp: timestamp, total: prefix, last: [0, 0, 0]),
            ]
            if contextPresent { lines.append(self.context(timestamp: timestamp)) }
            if trigger {
                lines.append([
                    "type": "inter_agent_communication_metadata", "ordinal": 11, "timestamp": timestamp,
                    "payload": ["trigger_turn": true],
                ])
            }
            // Even total == last can be a copied snapshot; equality alone cannot prove a reset.
            lines.append(self.tokens(ordinal: 12, timestamp: timestamp, total: prefix, last: prefix))
            lines.append(self.tokens(ordinal: 13, timestamp: timestamp, total: baseline, last: baseline))
            let ownedStart = lines.count
            lines.append(self.tokens(
                ordinal: 19,
                timestamp: timestamp,
                total: [baseline[0] + 50, baseline[1] + 10, baseline[2] + 5],
                last: [50, 10, 5]))
            let final = [baseline[0] + 70, baseline[1] + 15, baseline[2] + 10]
            lines.append(self.tokens(
                ordinal: 20,
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                total: final,
                last: [20, 5, 5]))
            // A fresh timestamp with the same cumulative payload must remain a replay.
            lines.append(self.tokens(
                ordinal: 21,
                timestamp: env.isoString(for: day.addingTimeInterval(2)),
                total: final,
                last: [20, 5, 5]))
            if !owned { lines.removeSubrange(ownedStart...) }
            let file = try env.writeCodexSessionFile(
                day: day, filename: "child-\(level).jsonl", contents: env.jsonl(lines))
            var consultedParent = false
            let parsed = CostUsageScanner.parseCodexFile(
                fileURL: file,
                range: .init(since: day, until: day),
                inheritedTotalsResolver: { _, _ in
                    consultedParent = true
                    return .unresolved
                })
            #expect(parsed.days[dayKey]?["gpt-5.4"] == ownedUsage)
            #expect(parsed.rows.reduce(0) { $0 + $1.input + $1.output } == ownedTokens)
            #expect(!parsed.dependsOnParentTotals)
            #expect(!consultedParent)
            prefix = final
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh = 1024
        var clock = day
        let expected = (parentPresent ? opening[0] + opening[2] : 0) + ownedTokens * depth
        for forced in [false, false, true] {
            options.forceRescan = forced
            let report = try self.completedScan(env: env, day: day, options: options, clock: &clock)
            #expect(report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == expected)
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            for level in 1...depth {
                let child = try #require(cache.files.values.first { $0.sessionId == "fork-\(level)" })
                #expect(child.days[dayKey]?["gpt-5.4"] == ownedUsage)
                #expect(child.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey)
            }
        }
    }

    private func completedScan(
        env: CostUsageTestEnvironment,
        day: Date,
        options: CostUsageScanner.Options,
        clock: inout Date) throws -> CostUsageDailyReport
    {
        var options = options
        for _ in 0..<40 {
            clock.addTimeInterval(1)
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: clock, options: options)
            options.forceRescan = false
            let files = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files.values
            if !files.isEmpty, files.allSatisfy({ $0.codexScanComplete == true && $0.hasCurrentCodexParser }) {
                return report
            }
        }
        throw NSError(domain: "ForkBaselineTests", code: 1)
    }

    private func context(timestamp: String) -> [String: Any] {
        ["type": "turn_context", "ordinal": 10, "timestamp": timestamp, "payload": ["model": "gpt-5.4"]]
    }

    private func tokens(ordinal: Int, timestamp: String, total: [Int], last: [Int]) -> [String: Any] {
        func usage(_ values: [Int]) -> [String: Int] {
            [
                "input_tokens": values[0],
                "cached_input_tokens": values[1],
                "output_tokens": values[2],
                "total_tokens": values[0] + values[2],
            ]
        }
        var lastUsage = usage(last)
        if last == [0, 0, 0] { lastUsage["total_tokens"] = 9035 }
        return ["type": "event_msg", "ordinal": ordinal, "timestamp": timestamp, "payload": [
            "type": "token_count", "info": [
                "model": "gpt-5.4",
                "total_token_usage": usage(total),
                "last_token_usage": lastUsage,
            ],
        ]]
    }
}
