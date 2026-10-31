import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexSessionTierTests {
    @Test(arguments: ["legacy", "ledger", "bare"])
    func `session log priority tier prices the turn at the fast rate`(usageKind: String) throws {
        let standard = try Self.cost(serviceTier: "default", usageKind: usageKind)
        let priority = try Self.cost(serviceTier: "priority", usageKind: usageKind)
        #expect(abs(priority - standard * 2) < 1e-9)
    }

    @Test
    func `priority tier does not leak to an older explicit turn`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-leak"]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "turn-a"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-a",
                "info": ["last_token_usage": ["input_tokens": 100, "output_tokens": 10]],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": "priority"],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "turn-b"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-a",
                "info": ["last_token_usage": ["input_tokens": 200, "output_tokens": 20]],
            ]],
        ]
        let file = try env.writeCodexSessionFile(day: day, filename: "tier-leak.jsonl", contents: env.jsonl(records))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let result = CostUsageScanner.parseCodexFile(fileURL: file, range: range)
        #expect(result.rows.count == 2)
        #expect(result.rows.last?.pricingMode == nil)
    }

    @Test
    func `priority tier survives an incremental scan checkpoint`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        let prefix = try env.jsonl([
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-checkpoint"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": "priority"],
            ]],
        ])
        let suffix = try env.jsonl([
            [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": "turn-checkpoint"],
            ],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-checkpoint",
                "info": ["last_token_usage": ["input_tokens": 200_000, "output_tokens": 10000]],
            ]],
        ])
        let file = env.root.appendingPathComponent("tier-checkpoint.jsonl")
        try prefix.write(to: file, atomically: true, encoding: .utf8)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        #expect(first.requestLedgerState?.threadPriority == true)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        let second = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: first.parsedBytes,
            initialRequestLedgerState: first.requestLedgerState)
        #expect(second.rows.last?.pricingMode == "priority")
    }

    @Test(arguments: [2, 3, 5, 7])
    func `session tiers survive SQLite reopening between settings turns and usage`(prefixCount: Int) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        func event(_ payload: [String: Any]) -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp, "payload": payload]
        }
        func usage(_ turn: String) -> [String: Any] {
            event(["type": "token_count", "turn_id": turn, "info": ["last_token_usage": [
                "input_tokens": 200_000, "output_tokens": 10000,
            ]]])
        }
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "synthetic-tier-reopen"]],
            event(["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]]),
            event(["type": "task_started", "turn_id": "priority-turn"]),
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            usage("priority-turn"),
            event(["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]]),
            event(["type": "task_started", "turn_id": "default-turn"]),
            usage("priority-turn"),
            usage("default-turn"),
            event(["type": "task_started", "turn_id": "missing-tier-turn"]),
            usage("missing-tier-turn"),
            event(["type": "thread_settings_applied", "thread_settings": ["service_tier": "synthetic-unknown"]]),
            event(["type": "task_started", "turn_id": "unknown-tier-turn"]),
            usage("unknown-tier-turn"),
        ]
        let file = try env.writeCodexSessionFile(
            day: day, filename: "tier-reopen.jsonl", contents: env.jsonl(Array(records.prefix(prefixCount))))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        let stored = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let before = try #require(await stored.fetchFile(path: file.path))
        #expect(before.parsedBytes == before.size)
        await stored.closeConnectionForTesting()
        #expect(await stored.fetchFile(path: file.path) == before)
        let checkpoint = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: .current)
        let tierState = try #require(checkpoint.files[file.path]?.codexRequestLedgerState)
        #expect(tierState.threadPriority == (prefixCount != 7))
        #expect(tierState.priorityTurnIDs == (prefixCount == 2 ? nil : ["priority-turn"]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl(Array(records.dropFirst(prefixCount))).utf8))
        try handle.close()
        let resumed = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: .current)
        let rows = try #require(reopened.files[file.path]?.codexRows)
        #expect(rows.map(\.pricingMode) == ["priority", "priority", "standard", "standard", "standard"])
        #expect(resumed.summary?.totalTokens == 1_050_000)
        #expect(try abs(#require(resumed.summary?.totalCostUSD) - 4.55) < 1e-9)
        options.cacheRoot = env.root.appendingPathComponent("fresh-cache")
        let fresh = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        #expect(fresh.data == resumed.data)
    }

    @Test(arguments: [false, true])
    func `thread priority remains effective across later turns`(resume: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        func event(_ payload: [String: Any]) -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp, "payload": payload]
        }
        func usage(_ turn: String) -> [String: Any] {
            event(["type": "token_count", "turn_id": turn, "info": ["last_token_usage": [
                "input_tokens": 100, "output_tokens": 10,
            ]]])
        }
        let prefix: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "persistent-tier"]],
            event(["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]]),
            event(["type": "task_started", "turn_id": "first-turn"]),
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            usage("first-turn"),
        ]
        let file = env.root.appendingPathComponent("persistent-tier.jsonl")
        try env.jsonl(prefix).write(to: file, atomically: true, encoding: .utf8)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = resume ? try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range) : nil
        let checkpoint = try first?.requestLedgerState.map {
            try JSONDecoder().decode(
                CostUsageScanner.CodexRequestLedgerState.self, from: JSONEncoder().encode($0))
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            event(["type": "task_started", "turn_id": "second-turn"]), usage("second-turn"),
        ]).utf8))
        try handle.close()
        let parsed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: first?.parsedBytes ?? 0,
            initialModel: first?.lastModel,
            initialSessionID: first?.sessionId,
            initialTotals: first?.lastTotals,
            initialCodexTurnID: first?.lastCodexTurnID,
            initialCodexUsageRowIndex: first?.nextUsageRowIndex ?? 0,
            initialRequestLedgerState: checkpoint)
        #expect(parsed.rows.count == (resume ? 1 : 2))
        #expect(parsed.rows.allSatisfy { $0.pricingMode == "priority" })
    }

    @Test(arguments: [0, 6, 10])
    func `resumed turn contexts refresh the tier without repricing earlier requests`(prefixCount: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 1)
        func record(_ type: String, _ payload: [String: Any], second: Int) -> [String: Any] {
            ["type": type, "timestamp": env.isoString(for: day.addingTimeInterval(Double(second))), "payload": payload]
        }
        func settings(_ tier: String, second: Int) -> [String: Any] {
            record(
                "event_msg",
                ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier]],
                second: second)
        }
        func context(second: Int) -> [String: Any] {
            record("turn_context", ["model": "gpt-6.1-sol", "turn_id": "resumed-turn"], second: second)
        }
        func usage(second: Int) -> [String: Any] {
            record(
                "event_msg",
                ["type": "token_count", "turn_id": "resumed-turn", "info": ["last_token_usage": [
                    "input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 100,
                ]]],
                second: second)
        }
        let records = [
            record("session_meta", ["id": "synthetic-resumed-tier"], second: 0),
            settings("default", second: 1),
            record("event_msg", ["type": "task_started", "turn_id": "resumed-turn"], second: 2),
            context(second: 3), usage(second: 4), settings("priority", second: 5),
            context(second: 6), usage(second: 7), settings("default", second: 8),
            context(second: 9), usage(second: 10),
        ]
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "resumed-tier.jsonl",
            contents: env.jsonl(prefixCount > 0 ? Array(records.prefix(prefixCount)) : records))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        if prefixCount > 0 {
            _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl(Array(records.dropFirst(prefixCount))).utf8))
            try handle.close()
        }
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(20), options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        #expect(cache.files[file.path]?.codexRows?.map(\.pricingMode) == ["standard", "priority", "standard"])
        #expect(report.summary?.totalTokens == 3300)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.00592) < 1e-12)

        // Older parsers pinned each row to the tier observed at task_started.
        cache.files[file.path]?.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
        for (index, mode) in ["standard", "standard", "priority"].enumerated() {
            cache.files[file.path]?.codexRows?[index].pricingMode = mode
        }
        _ = CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, home: env.codexStoreHome, cache: cache)
        let migrated = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(40), options: options)
        let restored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        #expect(restored.files[file.path]?.codexRows?.map(\.pricingMode) == ["standard", "priority", "standard"])
        #expect(migrated.summary?.totalTokens == 3300)
        #expect(try abs(#require(migrated.summary?.totalCostUSD) - 0.00592) < 1e-12)
    }

    private static func cost(serviceTier: String, usageKind: String) throws -> Double {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-\(serviceTier)"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_id": "tier-\(serviceTier)",
                "thread_settings": ["model": "gpt-5.4", "service_tier": serviceTier],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "tier-turn"]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4", "turn_id": "tier-turn"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "tier-turn",
                "info": ["last_token_usage": [
                    "input_tokens": 200_000,
                    "cached_input_tokens": 0,
                    "output_tokens": 10000,
                ]],
            ]],
        ]
        let usage = ["input_tokens": 200_000, "output_tokens": 10000]
        if usageKind == "ledger" {
            records[records.count - 1] = ["type": "token_usage_record", "timestamp": timestamp, "payload": [
                "thread_id": "tier-\(serviceTier)", "response_id": "synthetic-response", "turn_id": "tier-turn",
                "model": "gpt-5.4", "usage": usage, "thread_token_usage": usage,
            ]]
        } else if usageKind == "bare" {
            records[records.count - 1] = ["timestamp": timestamp, "model": "gpt-5.4", "usage": usage]
        }
        _ = try env.writeCodexSessionFile(day: day, filename: "tier.jsonl", contents: env.jsonl(records))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        return try #require(report.summary?.totalCostUSD)
    }
}
