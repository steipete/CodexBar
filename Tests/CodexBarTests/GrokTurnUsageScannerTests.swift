import Foundation
import Testing
@testable import CodexBarCore

struct GrokTurnUsageScannerTests {
    @Test
    func `parses turn_completed matching headless usage fields`() throws {
        let line = #"""
        {"timestamp":1784626073,"method":"_x.ai/session/update","params":{"sessionId":"019f8400-c020-7941-bf9f-3b424b755104","update":{"sessionUpdate":"turn_completed","prompt_id":"c0c89ae6-c50e-41a6-8169-a2f3124eb4d8","stop_reason":"end_turn","usage":{"inputTokens":12845,"outputTokens":32,"totalTokens":12877,"cachedReadTokens":10752,"reasoningTokens":27,"modelCalls":1,"apiDurationMs":1772,"costUsdTicks":76036000,"modelUsage":{"grok-4.5-build":{"inputTokens":12845,"outputTokens":32,"totalTokens":12877,"cachedReadTokens":10752,"reasoningTokens":27,"modelCalls":1,"apiDurationMs":1772,"costUsdTicks":76036000}},"numTurns":1}},"_meta":{"eventId":"019f8400-c020-7941-bf9f-3b424b755104-29","agentTimestampMs":1784626073119}}}
        """#

        let record = try #require(GrokTurnUsageScanner.parseTurnLine(
            line,
            sessionID: "019f8400-c020-7941-bf9f-3b424b755104",
            cwd: "/Users/chen/Documents/llm"))

        #expect(record.eventID == "019f8400-c020-7941-bf9f-3b424b755104-29")
        #expect(record.sessionID == "019f8400-c020-7941-bf9f-3b424b755104")
        #expect(record.inputTokens == 2093) // uncached = 12845 - 10752
        #expect(record.cacheReadTokens == 10752)
        #expect(record.outputTokens == 32)
        #expect(record.reasoningTokens == 27)
        #expect(record.totalTokens == 12877)
        #expect(record.modelCalls == 1)
        #expect(record.models == ["grok-4.5-build"])
        let cost = try #require(record.costUSD)
        #expect(abs(cost - 0.0076036) < 0.0000001)
    }

    @Test
    func `ignores non turn_completed lines`() {
        let line = #"{"timestamp":1,"params":{"update":{"sessionUpdate":"agent_message_chunk"}}}"#
        #expect(GrokTurnUsageScanner.parseTurnLine(line, sessionID: "s", cwd: nil) == nil)
    }

    @Test
    func `daily report aggregates tokens and partial costs`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cost-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root
            .appendingPathComponent("%2Ftmp%2Fdemo", isDirectory: true)
            .appendingPathComponent("session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = #"""
        {"info":{"id":"session-a","cwd":"/tmp/demo"},"created_at":"2026-07-21T00:00:00Z"}
        """#
        try Data(summary.utf8).write(to: sessionDir.appendingPathComponent("summary.json"))

        // Two turns same day: one with cost, one without.
        let updates = #"""
        {"timestamp":1784626073,"params":{"sessionId":"session-a","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":100,"cachedReadTokens":40,"outputTokens":10,"totalTokens":110,"modelCalls":1,"costUsdTicks":1000000000,"modelUsage":{"grok-4.5":{"inputTokens":100,"outputTokens":10,"totalTokens":110}}}},"_meta":{"eventId":"e1","agentTimestampMs":1784626073000}}}
        {"timestamp":1784627000,"params":{"sessionId":"session-a","update":{"sessionUpdate":"turn_completed","prompt_id":"p2","usage":{"inputTokens":200,"cachedReadTokens":50,"outputTokens":20,"totalTokens":220,"modelCalls":2,"modelUsage":{"grok-4.5":{"inputTokens":200,"outputTokens":20,"totalTokens":220}}}},"_meta":{"eventId":"e2","agentTimestampMs":1784627000000}}}
        """#
        try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let options = GrokTurnUsageScanner.Options(sessionsRoot: root)
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = Date(timeIntervalSince1970: 1_900_000_000)
        let report = try GrokTurnUsageScanner.loadDailyReport(
            since: since,
            until: until,
            options: options)

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.totalTokens == 330)
        #expect(entry.inputTokens == 210) // (100-40) + (200-50)
        #expect(entry.cacheReadTokens == 90)
        #expect(entry.outputTokens == 30)
        #expect(entry.requestCount == 3)
        let cost = try #require(entry.costUSD)
        #expect(abs(cost - 0.1) < 0.0000001) // 1e9 ticks
        #expect(report.summary?.totalTokens == 330)

        let sessions = try GrokTurnUsageScanner.loadSessionBreakdowns(
            since: since,
            until: until,
            options: options)
        #expect(sessions.count == 1)
        #expect(sessions[0].sessionID == "session-a")
        #expect(sessions[0].totalTokens == 330)

        let projects = try GrokTurnUsageScanner.loadProjectBreakdowns(
            since: since,
            until: until,
            options: options)
        #expect(projects.count == 1)
        #expect(projects[0].path == "/tmp/demo")
        #expect(projects[0].totalTokens == 330)
    }

    @Test
    func `cost fetcher supports grok token snapshots`() async throws {
        #expect(CostUsageFetcher.supportsTokenSnapshot(.grok))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-fetcher-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root
            .appendingPathComponent("cwd", isDirectory: true)
            .appendingPathComponent("sid", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)
        let updates = """
        {"timestamp":\(ts),"params":{"sessionId":"sid","update":{"sessionUpdate":"turn_completed","prompt_id":"p","usage":{"inputTokens":50,"cachedReadTokens":10,"outputTokens":5,"totalTokens":55,"modelCalls":1,"costUsdTicks":500000000,"modelUsage":{"grok-4.5":{}}}},"_meta":{"eventId":"e-now","agentTimestampMs":\(ts)000}}}
        """
        try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        var options = CostUsageScanner.Options()
        options.grokSessionsRoot = root
        options.refreshMinIntervalSeconds = 0

        let fetcher = CostUsageFetcher(scannerOptions: options)
        let snapshot = try await fetcher.loadTokenSnapshot(
            provider: .grok,
            forceRefresh: true,
            historyDays: 7,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            bypassScannerDebounce: true)

        #expect(snapshot.sessionTokens == 55)
        #expect(snapshot.last30DaysTokens == 55)
        let cost = try #require(snapshot.sessionCostUSD)
        #expect(abs(cost - 0.05) < 0.0000001)
    }

    @Test
    func `descriptor enables token cost`() {
        #expect(GrokProviderDescriptor.descriptor.tokenCost.supportsTokenCost)
    }
}
