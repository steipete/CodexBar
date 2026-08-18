import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodexUsageParserTests {
    @Test
    func `parses persisted usage rows without reading the developer home`() throws {
        let line = """
        {"requestId":"req-1","timestamp":1784179200000,"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported","accountLogLabel":"p2","surface":"claude",\
        "usage":{"inputTokens":100,"outputTokens":20,"cacheReadInputTokens":10,\
        "reasoningOutputTokens":5,"totalTokens":135},"totalTokens":135}
        """
        let entry = try #require(OpenCodexUsageParser.parseLine(line))
        #expect(entry.requestID == "req-1")
        #expect(entry.provider == "openai")
        #expect(entry.model == "gpt-5.4")
        #expect(entry.usageStatus == .reported)
        #expect(entry.accountLogLabel == "p2")
        #expect(entry.surface == "claude")
        #expect(entry.usage?.inputTokens == 100)
        #expect(entry.usage?.reasoningOutputTokens == 5)
        #expect(entry.resolvedTotalTokens == 135)
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_784_179_200))
    }

    @Test
    func `skips malformed lines and keeps nil usage classes unset`() {
        let text = """
        not-json
        {"requestId":"req-2","timestamp":1784179200,"provider":"anthropic",\
        "model":"claude-sonnet-4","usageStatus":"unreported"}
        """
        let entries = OpenCodexUsageParser.parseLines(text)
        #expect(entries.count == 1)
        #expect(entries[0].usage == nil)
        #expect(entries[0].usageStatus == .unreported)
        #expect(entries[0].accountLogLabel == nil)
    }

    @Test
    func `does not resolve a default home while tests are running`() {
        #expect(OpenCodexUsageLog.usageLogURL(environment: ["TESTING_LIBRARY_VERSION": "1"]) == nil)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodexUsageParserTests-\(UUID().uuidString)", isDirectory: true)
        let url = OpenCodexUsageLog.usageLogURL(environment: ["OPENCODEX_HOME": home.path])
        #expect(url == home.appendingPathComponent("usage.jsonl"))
    }

    @Test
    func `cache path stays outside the OpenCodex usage root`() throws {
        let openCodexRoot = URL(fileURLWithPath: "/tmp/test-home/.opencodex", isDirectory: true)
        let codexBarRoot = URL(
            fileURLWithPath: "/tmp/test-home/Library/Caches/CodexBar",
            isDirectory: true)
        let logURL = try #require(OpenCodexUsageLog.usageLogURL(
            environment: ["OPENCODEX_HOME": openCodexRoot.path]))
        let cacheRoot = OpenCodexUsageLog.cacheRoot(codexBarCachesDirectory: codexBarRoot)
        let databaseURL = cacheRoot.appendingPathComponent(OpenCodexUsageStore.databaseFilename)

        #expect(logURL.deletingLastPathComponent() == openCodexRoot)
        #expect(cacheRoot.path == codexBarRoot.appendingPathComponent("opencodex-usage").path)
        #expect(!databaseURL.path.hasPrefix(openCodexRoot.path + "/"))
    }

    @Test
    func `aggregates a fixture log into an independent snapshot`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodexUsageAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("usage.jsonl")
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let millis = Int(now.timeIntervalSince1970 * 1000)
        try """
        {"requestId":"a","timestamp":\(millis),"provider":"openai","model":"gpt-5.4","usageStatus":"reported",\
        "accountLogLabel":"main","conversationId":"chat-1",\
        "usage":{"inputTokens":10,"outputTokens":2,"totalTokens":12},"totalTokens":12}
        {"requestId":"b","timestamp":\(millis),"provider":"openai","model":"gpt-5.4","usageStatus":"estimated",\
        "accountLogLabel":"p1","conversationId":"chat-1",\
        "usage":{"inputTokens":5,"outputTokens":1,"reasoningOutputTokens":3,"totalTokens":9},"totalTokens":9}
        """.write(to: log, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let snapshot = try OpenCodexUsageStore(cacheRoot: root).loadSnapshot(
            logURL: log,
            now: now,
            historyDays: 7,
            calendar: calendar)
        #expect(snapshot.historyLabel == "OpenCodex usage.jsonl")
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily[0].inputTokens == 15)
        #expect(snapshot.daily[0].reasoningTokens == 3)
        #expect(snapshot.daily[0].estimatedRequestCount == 1)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].sessionID == "chat-1")
        #expect(snapshot.sessions[0].reasoningTokens == 3)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(OpenCodexUsageStore.databaseFilename == "opencodex-usage.sqlite")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("opencodex-usage.sqlite").path))
    }

    @Test
    func `unreported rows without usage stay unpriced instead of zero spend`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: [
                OpenCodexUsageEntry(
                    requestID: "empty",
                    timestamp: now,
                    provider: "openai",
                    model: "gpt-5.4",
                    usageStatus: .unreported),
            ],
            now: now,
            historyDays: 7,
            calendar: calendar)
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily[0].costUSD == nil)
        #expect(snapshot.daily[0].unpricedRequestCount == 1)
        #expect(snapshot.daily[0].requestCount == 1)
        #expect(snapshot.costProvenance == .listPriceEstimate)
    }

    @Test
    func `session totals use the current day instead of the latest historical day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let yesterday = now.addingTimeInterval(-86400)
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: [
                OpenCodexUsageEntry(
                    requestID: "old",
                    timestamp: yesterday,
                    provider: "openai",
                    model: "gpt-5.4",
                    usageStatus: .reported,
                    usage: OpenCodexTokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12),
                    totalTokens: 12),
            ],
            now: now,
            historyDays: 7,
            calendar: calendar)
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.sessionCostUSD == 0)
        #expect(snapshot.last30DaysTokens == 12)
    }

    @Test
    func `unpriced estimated requests count once`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: [
                OpenCodexUsageEntry(
                    requestID: "est",
                    timestamp: now,
                    provider: "openai",
                    model: "not-a-priced-model-xyz",
                    usageStatus: .estimated,
                    usage: OpenCodexTokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12),
                    totalTokens: 12),
            ],
            now: now,
            historyDays: 7,
            calendar: calendar)
        #expect(snapshot.daily[0].requestCount == 1)
        #expect(snapshot.daily[0].estimatedRequestCount == 0)
        #expect(snapshot.daily[0].unpricedRequestCount == 1)
        #expect(snapshot.daily[0].costUSD == nil)
    }

    @Test
    func `duplicate request ids replace instead of aborting the cache write`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodexUsageStoreDedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("usage.jsonl")
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let millis = Int(now.timeIntervalSince1970 * 1000)
        try """
        {"requestId":"dup","timestamp":\(millis),"provider":"openai","model":"gpt-5.4","usageStatus":"reported",\
        "usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2},"totalTokens":2}
        {"requestId":"dup","timestamp":\(millis),"provider":"openai","model":"gpt-5.4","usageStatus":"reported",\
        "usage":{"inputTokens":9,"outputTokens":1,"totalTokens":10},"totalTokens":10}
        """.write(to: log, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let snapshot = try OpenCodexUsageStore(cacheRoot: root).loadSnapshot(
            logURL: log,
            now: now,
            historyDays: 7,
            calendar: calendar)
        #expect(snapshot.daily[0].inputTokens == 9)
        #expect(snapshot.daily[0].requestCount == 1)
    }
}
