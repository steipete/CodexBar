import Foundation
import Testing
@testable import CodexBarCore

struct GrokTurnUsageScannerTests {
    @Test
    func `parses turn_completed matching headless usage fields`() throws {
        // Use a released public model ID (not internal -build suffixes) per repo test-model policy.
        let usage = """
        "inputTokens":12845,"outputTokens":32,"totalTokens":12877,"cachedReadTokens":10752,\
        "reasoningTokens":27,"modelCalls":1,"apiDurationMs":1772,"costUsdTicks":76036000,\
        "modelUsage":{"grok-4":{"inputTokens":12845,"outputTokens":32,"totalTokens":12877,\
        "cachedReadTokens":10752,"reasoningTokens":27,"modelCalls":1,"apiDurationMs":1772,\
        "costUsdTicks":76036000}},"numTurns":1
        """
        let line = """
        {"timestamp":1784626073,"method":"_x.ai/session/update","params":{"sessionId":\
        "session-fixture-1","update":{"sessionUpdate":"turn_completed","prompt_id":\
        "prompt-fixture-1","stop_reason":"end_turn","usage":{\(usage)}}},"_meta":{"eventId":\
        "session-fixture-1-29","agentTimestampMs":1784626073119}}
        """

        let record = try #require(GrokTurnUsageScanner.parseTurnLine(
            line,
            sessionID: "session-fixture-1",
            cwd: "/tmp/demo-project"))

        #expect(record.eventID == "session-fixture-1-29")
        #expect(record.sessionID == "session-fixture-1")
        #expect(record.inputTokens == 2093) // uncached = 12845 - 10752
        #expect(record.cacheReadTokens == 10752)
        #expect(record.outputTokens == 32)
        #expect(record.reasoningTokens == 27)
        #expect(record.totalTokens == 12877)
        #expect(record.modelCalls == 1)
        #expect(record.models == ["grok-4"])
        #expect(record.modelUsages.count == 1)
        #expect(record.modelUsages[0].modelName == "grok-4")
        #expect(record.modelUsages[0].totalTokens == 12877)
        let cost = try #require(record.costUSD)
        #expect(abs(cost - 0.0076036) < 0.0000001)
        let modelCost = try #require(record.modelUsages[0].costUSD)
        #expect(abs(modelCost - 0.0076036) < 0.0000001)
    }

    @Test
    func `preserves nested multi-model usage totals`() throws {
        let modelUsage = """
        "grok-4":{"inputTokens":100,"cachedReadTokens":20,"outputTokens":10,"totalTokens":110,\
        "modelCalls":1,"costUsdTicks":1000000000},"test-grok-model":{"inputTokens":200,\
        "cachedReadTokens":30,"outputTokens":30,"totalTokens":230,"modelCalls":2,\
        "costUsdTicks":2000000000}
        """
        let usage = """
        "inputTokens":300,"cachedReadTokens":50,"outputTokens":40,"totalTokens":340,\
        "modelCalls":3,"costUsdTicks":3000000000,"modelUsage":{\(modelUsage)}
        """
        let line = """
        {"timestamp":1784626073,"params":{"sessionId":"session-multi","update":{\
        "sessionUpdate":"turn_completed","prompt_id":"p-multi","usage":{\(usage)}}},\
        "_meta":{"eventId":"e-multi","agentTimestampMs":1784626073000}}
        """

        let record = try #require(GrokTurnUsageScanner.parseTurnLine(
            line,
            sessionID: "session-multi",
            cwd: "/tmp/multi"))

        #expect(record.models == ["grok-4", "test-grok-model"])
        #expect(record.modelUsages.count == 2)
        #expect(record.modelUsages[0].modelName == "grok-4")
        #expect(record.modelUsages[0].totalTokens == 110)
        #expect(record.modelUsages[0].modelCalls == 1)
        #expect(abs((record.modelUsages[0].costUSD ?? -1) - 0.1) < 0.0000001)
        #expect(record.modelUsages[1].modelName == "test-grok-model")
        #expect(record.modelUsages[1].totalTokens == 230)
        #expect(record.modelUsages[1].modelCalls == 2)
        #expect(abs((record.modelUsages[1].costUSD ?? -1) - 0.2) < 0.0000001)

        let report = GrokTurnUsageScanner.dailyReport(from: [record])
        let entry = try #require(report.data.first)
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        #expect(breakdowns[0].modelName == "grok-4")
        #expect(breakdowns[0].totalTokens == 110)
        #expect(abs((breakdowns[0].costUSD ?? -1) - 0.1) < 0.0000001)
        #expect(breakdowns[0].requestCount == 1)
        #expect(breakdowns[1].modelName == "test-grok-model")
        #expect(breakdowns[1].totalTokens == 230)
        #expect(abs((breakdowns[1].costUSD ?? -1) - 0.2) < 0.0000001)
        #expect(breakdowns[1].requestCount == 2)
        // Turn-level totals still reflect the outer usage object.
        #expect(entry.totalTokens == 340)
        #expect(abs((entry.costUSD ?? -1) - 0.3) < 0.0000001)
    }

    @Test
    func `ignores non turn_completed lines`() {
        let line = #"{"timestamp":1,"params":{"update":{"sessionUpdate":"agent_message_chunk"}}}"#
        #expect(GrokTurnUsageScanner.parseTurnLine(line, sessionID: "s", cwd: nil) == nil)
    }

    @Test
    func `reads nested params meta when root meta is absent`() throws {
        let line = """
        {"timestamp":1784626073,"params":{"sessionId":"session-nested","update":{\
        "sessionUpdate":"turn_completed","prompt_id":"p-nested","usage":{"inputTokens":10,\
        "cachedReadTokens":0,"outputTokens":1,"totalTokens":11,"modelCalls":1}},\
        "_meta":{"eventId":"nested-event-1","agentTimestampMs":1784626073000}}}
        """

        let record = try #require(GrokTurnUsageScanner.parseTurnLine(
            line,
            sessionID: "session-nested",
            cwd: nil))

        #expect(record.eventID == "nested-event-1")
        #expect(record.inputTokens == 10)
        #expect(record.outputTokens == 1)
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
        let turn1Usage = """
        "inputTokens":100,"cachedReadTokens":40,"outputTokens":10,"totalTokens":110,\
        "modelCalls":1,"costUsdTicks":1000000000,"modelUsage":{"grok-4":{"inputTokens":100,\
        "outputTokens":10,"totalTokens":110,"modelCalls":1,"costUsdTicks":1000000000}}
        """
        let turn2Usage = """
        "inputTokens":200,"cachedReadTokens":50,"outputTokens":20,"totalTokens":220,\
        "modelCalls":2,"modelUsage":{"grok-4":{"inputTokens":200,"outputTokens":20,\
        "totalTokens":220,"modelCalls":2}}
        """
        let updates = """
        {"timestamp":1784626073,"params":{"sessionId":"session-a","update":{"sessionUpdate":\
        "turn_completed","prompt_id":"p1","usage":{\(turn1Usage)}}},"_meta":{"eventId":"e1",\
        "agentTimestampMs":1784626073000}}
        {"timestamp":1784627000,"params":{"sessionId":"session-a","update":{"sessionUpdate":\
        "turn_completed","prompt_id":"p2","usage":{\(turn2Usage)}}},"_meta":{"eventId":"e2",\
        "agentTimestampMs":1784627000000}}
        """
        try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cost-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let options = GrokTurnUsageScanner.Options(sessionsRoot: root, cacheRoot: cacheRoot)
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
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 1)
        #expect(breakdowns[0].modelName == "grok-4")
        #expect(breakdowns[0].totalTokens == 330)

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
        let usage = """
        "inputTokens":50,"cachedReadTokens":10,"outputTokens":5,"totalTokens":55,"modelCalls":1,\
        "costUsdTicks":500000000,"modelUsage":{"grok-4":{"inputTokens":50,"cachedReadTokens":10,\
        "outputTokens":5,"totalTokens":55,"modelCalls":1,"costUsdTicks":500000000}}
        """
        let updates = """
        {"timestamp":\(ts),"params":{"sessionId":"sid","update":{"sessionUpdate":\
        "turn_completed","prompt_id":"p","usage":{\(usage)}}},"_meta":{"eventId":"e-now",\
        "agentTimestampMs":\(ts)000}}
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

    @Test
    func `partially scans oversized session logs and marks history incomplete`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-oversized-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-oversized-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let sessionDir = root
            .appendingPathComponent("cwd", isDirectory: true)
            .appendingPathComponent("big-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)
        // Root-level `_meta` (real Grok log shape); keep JSON fully closed.
        let line = """
        {"timestamp":\(ts),"params":{"sessionId":"big-session","update":{"sessionUpdate":\
        "turn_completed","prompt_id":"p","usage":{"inputTokens":10,"cachedReadTokens":0,\
        "outputTokens":1,"totalTokens":11,"modelCalls":1,"costUsdTicks":100000000}}},"_meta":{\
        "eventId":"e-big","agentTimestampMs":\(ts)000}}
        """
        let lineData = Data((line + "\n").utf8)
        // Prefix padding makes the file oversized; the full trailing turn still fits in the tail slice.
        var payload = Data(repeating: UInt8(ascii: "x"), count: 800)
        payload.append(Data("\n".utf8))
        payload.append(lineData)
        try payload.write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let fileSize = Int64(payload.count)
        let maxFileBytes = Int64(lineData.count + 50)
        #expect(fileSize > maxFileBytes)

        let budget = GrokTurnUsageScanner.ScanBudget(
            maxFileBytes: maxFileBytes,
            maxBytesPerRefresh: 10_000)
        let options = GrokTurnUsageScanner.Options(
            sessionsRoot: root,
            cacheRoot: cacheRoot,
            maxSessionFileBytes: maxFileBytes,
            maxScanBytesPerRefresh: 10_000)
        let result = try GrokTurnUsageScanner.scanTurns(
            since: now.addingTimeInterval(-86_400),
            until: now.addingTimeInterval(60),
            options: options,
            checkCancellation: nil,
            budget: budget)

        #expect(result.turns.count == 1)
        #expect(result.turns[0].eventID == "e-big")
        #expect(result.historyIsIncomplete)
        #expect(budget.partialOversizedFileCount == 1)
        #expect(budget.bytesConsumed > 0)
        #expect(budget.bytesConsumed <= maxFileBytes)
    }

    @Test
    func `refresh budget prefers newest session and defers older files`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-budget-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-budget-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)

        func writeSession(id: String, eventID: String, tokens: Int, modifiedAt: Date) throws {
            let sessionDir = root
                .appendingPathComponent("cwd", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let line = """
            {"timestamp":\(ts),"params":{"sessionId":"\(id)","update":{"sessionUpdate":\
            "turn_completed","prompt_id":"p","usage":{"inputTokens":\(tokens),"cachedReadTokens":0,\
            "outputTokens":1,"totalTokens":\(tokens + 1),"modelCalls":1,"costUsdTicks":100000000}}},\
            "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts)000}}
            """
            let url = sessionDir.appendingPathComponent("updates.jsonl")
            try Data((line + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: url.path)
        }

        try writeSession(
            id: "old-session",
            eventID: "e-old",
            tokens: 100,
            modifiedAt: now.addingTimeInterval(-3_600))
        try writeSession(
            id: "new-session",
            eventID: "e-new",
            tokens: 50,
            modifiedAt: now)

        // Budget fits only one of the two ~similar-size session files.
        let sampleURL = root
            .appendingPathComponent("cwd", isDirectory: true)
            .appendingPathComponent("new-session", isDirectory: true)
            .appendingPathComponent("updates.jsonl")
        let sampleSize = Int64(
            (try FileManager.default.attributesOfItem(atPath: sampleURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0)
        #expect(sampleSize > 0)

        let budget = GrokTurnUsageScanner.ScanBudget(
            maxFileBytes: sampleSize * 4,
            maxBytesPerRefresh: sampleSize)
        let options = GrokTurnUsageScanner.Options(
            sessionsRoot: root,
            cacheRoot: cacheRoot,
            maxSessionFileBytes: sampleSize * 4,
            maxScanBytesPerRefresh: sampleSize,
            preferNewestSessionsFirst: true)
        let result = try GrokTurnUsageScanner.scanTurns(
            since: now.addingTimeInterval(-86_400),
            until: now.addingTimeInterval(60),
            options: options,
            checkCancellation: nil,
            budget: budget)

        #expect(result.turns.count == 1)
        #expect(result.turns[0].eventID == "e-new")
        #expect(result.turns[0].totalTokens == 51)
        #expect(result.historyIsIncomplete) // first-seen older file deferred
        #expect(budget.deferredByBudgetFileCount == 1)
        #expect(budget.bytesConsumed == sampleSize)
    }

    @Test
    func `later refresh catches up budget-deferred files via cache`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cache-catchup-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cache-root-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)

        func writeSession(id: String, eventID: String, tokens: Int, modifiedAt: Date) throws -> Int64 {
            let sessionDir = root
                .appendingPathComponent("cwd", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let line = """
            {"timestamp":\(ts),"params":{"sessionId":"\(id)","update":{"sessionUpdate":\
            "turn_completed","prompt_id":"p","usage":{"inputTokens":\(tokens),"cachedReadTokens":0,\
            "outputTokens":1,"totalTokens":\(tokens + 1),"modelCalls":1,"costUsdTicks":100000000}}},\
            "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts)000}}
            """
            let url = sessionDir.appendingPathComponent("updates.jsonl")
            try Data((line + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: url.path)
            return Int64(
                (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                    .int64Value ?? 0)
        }

        let newSize = try writeSession(
            id: "new-session",
            eventID: "e-new",
            tokens: 50,
            modifiedAt: now)
        let oldSize = try writeSession(
            id: "old-session",
            eventID: "e-old",
            tokens: 100,
            modifiedAt: now.addingTimeInterval(-3_600))
        #expect(newSize > 0)
        #expect(oldSize > 0)

        // Budget fits only one file per refresh.
        let perRefresh = max(newSize, oldSize)
        let options = GrokTurnUsageScanner.Options(
            sessionsRoot: root,
            cacheRoot: cacheRoot,
            maxSessionFileBytes: perRefresh * 4,
            maxScanBytesPerRefresh: perRefresh,
            preferNewestSessionsFirst: true)

        let budget1 = GrokTurnUsageScanner.ScanBudget(
            maxFileBytes: perRefresh * 4,
            maxBytesPerRefresh: perRefresh)
        let firstResult = try GrokTurnUsageScanner.scanTurns(
            since: now.addingTimeInterval(-86_400),
            until: now.addingTimeInterval(60),
            options: options,
            checkCancellation: nil,
            budget: budget1)
        #expect(firstResult.turns.map(\.eventID).sorted() == ["e-new"])
        #expect(firstResult.historyIsIncomplete)
        #expect(budget1.deferredByBudgetFileCount == 1)
        #expect(budget1.freshlyScannedFileCount == 1)

        // Second refresh: newest is a cache hit (free), so budget scans the deferred older file.
        let budget2 = GrokTurnUsageScanner.ScanBudget(
            maxFileBytes: perRefresh * 4,
            maxBytesPerRefresh: perRefresh)
        let secondResult = try GrokTurnUsageScanner.scanTurns(
            since: now.addingTimeInterval(-86_400),
            until: now.addingTimeInterval(60),
            options: options,
            checkCancellation: nil,
            budget: budget2)
        #expect(Set(secondResult.turns.map(\.eventID)) == Set(["e-new", "e-old"]))
        #expect(!secondResult.historyIsIncomplete)
        #expect(budget2.cacheHitFileCount == 1)
        #expect(budget2.freshlyScannedFileCount == 1)
        #expect(budget2.deferredByBudgetFileCount == 0)
    }

    @Test
    func `skips stale session files outside the since window`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-stale-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-stale-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let now = Date()
        let sessionDir = root
            .appendingPathComponent("cwd", isDirectory: true)
            .appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = Int(now.addingTimeInterval(-10 * 86_400).timeIntervalSince1970)
        let line = """
        {"timestamp":\(ts),"params":{"sessionId":"stale","update":{"sessionUpdate":\
        "turn_completed","prompt_id":"p","usage":{"inputTokens":10,"cachedReadTokens":0,\
        "outputTokens":1,"totalTokens":11,"modelCalls":1}}},"_meta":{"eventId":"e-stale",\
        "agentTimestampMs":\(ts)000}}
        """
        let url = sessionDir.appendingPathComponent("updates.jsonl")
        try Data((line + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: url.path)

        let budget = GrokTurnUsageScanner.ScanBudget(
            maxFileBytes: 1024 * 1024,
            maxBytesPerRefresh: 1024 * 1024)
        let options = GrokTurnUsageScanner.Options(sessionsRoot: root, cacheRoot: cacheRoot)
        let result = try GrokTurnUsageScanner.scanTurns(
            since: now.addingTimeInterval(-86_400),
            until: now.addingTimeInterval(60),
            options: options,
            checkCancellation: nil,
            budget: budget)

        #expect(result.turns.isEmpty)
        #expect(!result.historyIsIncomplete)
        #expect(budget.skippedStaleFileCount == 1)
        #expect(budget.bytesConsumed == 0)
    }
}

