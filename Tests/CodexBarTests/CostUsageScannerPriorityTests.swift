import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerPriorityTests {
    @Test
    func `codex daily report applies gpt55 priority rates`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": iso0, "payload": ["model": "gpt-5.5"]],
            ["type": "event_msg", "timestamp": iso1, "payload": ["type": "task_started", "turn_id": "standard-turn"]],
            self.tokenCount(timestamp: iso2, input: 100, cached: 20, output: 10),
            ["type": "event_msg", "timestamp": iso3, "payload": ["type": "task_started", "turn_id": "priority-turn"]],
            self.tokenCount(timestamp: iso3, input: 100, cached: 20, output: 10),
        ]
        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: env.jsonl(entries))

        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CodexPriorityTraceScannerTests.createTestLogsDatabase(at: dbURL)
        try self.insertPriorityTrace(dbURL: dbURL, timestamp: iso3)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let standardCost = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)
        let priorityCost = (80.0 * 1.25e-5) + (20.0 * 1.25e-6) + (10.0 * 7.5e-5)

        #expect(report.summary?.totalCostUSD == standardCost + priorityCost)
    }

    @Test
    func `codex daily report applies gpt54 priority rates`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": iso0, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": iso1, "payload": ["type": "task_started", "turn_id": "standard-turn"]],
            self.tokenCount(timestamp: iso2, input: 100, cached: 20, output: 10),
            ["type": "event_msg", "timestamp": iso3, "payload": ["type": "task_started", "turn_id": "priority-turn"]],
            self.tokenCount(timestamp: iso3, input: 100, cached: 20, output: 10),
        ]
        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: env.jsonl(entries))

        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CodexPriorityTraceScannerTests.createTestLogsDatabase(at: dbURL)
        try self.insertPriorityTrace(dbURL: dbURL, timestamp: iso3, model: "gpt-5.4")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let standardCost = (80.0 * 2.5e-6) + (20.0 * 2.5e-7) + (10.0 * 1.5e-5)
        let priorityCost = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)

        #expect(report.summary?.totalCostUSD == standardCost + priorityCost)
    }

    @Test
    func `codex daily report keeps base cost when sqlite metadata is missing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": iso0, "payload": ["model": "gpt-5.5"]],
            ["type": "event_msg", "timestamp": iso1, "payload": ["type": "task_started", "turn_id": "priority-turn"]],
            self.tokenCount(timestamp: iso1, input: 100, cached: 20, output: 10),
        ]
        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: env.jsonl(entries))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let expected = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)

        #expect(report.summary?.totalCostUSD == expected)
    }

    @Test
    func `codex pricing applies long context tiers per turn`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": iso0, "payload": ["model": "gpt-5.5"]],
            ["type": "event_msg", "timestamp": iso1, "payload": ["type": "task_started", "turn_id": "standard-turn"]],
            self.tokenCount(timestamp: iso1, input: 272_001, cached: 0, output: 10),
            ["type": "event_msg", "timestamp": iso2, "payload": ["type": "task_started", "turn_id": "priority-turn"]],
            self.tokenCount(timestamp: iso2, input: 300_000, cached: 0, output: 5),
            self.tokenCount(timestamp: iso3, input: 100_001, cached: 0, output: 5),
        ]
        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: env.jsonl(entries))

        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CodexPriorityTraceScannerTests.createTestLogsDatabase(at: dbURL)
        try self.insertPriorityTrace(dbURL: dbURL, timestamp: iso2)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let standardTurnBase = (272_001.0 * 1e-5) + (10.0 * 4.5e-5)
        let priorityTurnCost = (400_001.0 * 1e-5) + (10.0 * 4.5e-5)

        #expect(report.summary?.totalCostUSD == standardTurnBase + priorityTurnCost)
    }

    private func tokenCount(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }

    private func insertPriorityTrace(dbURL: URL, timestamp: String, model: String = "gpt-5.5") throws {
        try CodexPriorityTraceScannerTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":""# + model + #"","service_tier":"priority"}"#)
    }
}
