import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCachedTokenDetailTests {
    @Test(arguments: [false, true], ["UTC", "Asia/Bangkok"])
    func `cached resumed rollouts preserve daily token details across local midnight`(
        forceRefresh: Bool,
        timeZone: String) async throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        let timestampA = timeZone == "UTC" ? "2026-08-29T12:00:00Z" : "2026-08-29T16:59:00Z"
        let timestampB = timeZone == "UTC" ? "2026-08-30T12:00:00Z" : "2026-08-29T17:01:00Z"
        let dateA = try #require(ISO8601DateFormatter().date(from: timestampA))
        let dateB = try #require(ISO8601DateFormatter().date(from: timestampB))
        let nowA = dateA.addingTimeInterval(10)
        let nowB = dateB.addingTimeInterval(10)
        let dayA = "2026-08-29"
        let dayB = "2026-08-30"
        let directory = env.codexSessionsRoot.appendingPathComponent("2026/08/29", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("synthetic-cross-day.jsonl")
        let initialLines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestampA,
                "payload": ["id": "synthetic-cross-day", "cwd": env.root.path],
            ],
            Self.turn(timestamp: timestampA, id: "day-a"),
            Self.event(timestamp: timestampA, total: [100, 20, 10, 4], last: [100, 20, 10, 4]),
        ]
        try env.jsonl(initialLines).write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: nowA], ofItemAtPath: file.path)
        let firstMetadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        #expect(options.forceRescan == false)
        #expect(options.refreshMinIntervalSeconds == 60)

        let first = try await Self.fetch(now: nowA, forceRefresh: forceRefresh, options: options)
        #expect(first.sessionTokens == 110)
        #expect(first.daily.map(\.date) == [dayA])
        let firstStore = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        let firstFile = try #require(firstStore.files.first)
        #expect(firstStore.files.count == 1)
        #expect(firstFile.parsedBytes == firstMetadata.size)
        #expect(firstFile.scanState.isComplete)
        #expect(firstFile.coverageSinceDay == dayA)
        #expect(firstFile.coverageUntilDay == dayA)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            Self.turn(timestamp: timestampB, id: "day-b"),
            Self.event(timestamp: timestampB, total: [160, 40, 16, 7], last: [60, 20, 6, 3]),
        ]).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: nowB], ofItemAtPath: file.path)
        let appendedMetadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        #expect(appendedMetadata.fileId == firstMetadata.fileId)
        #expect(appendedMetadata.size > firstMetadata.size)
        let second = try await Self.fetch(now: nowB, forceRefresh: forceRefresh, options: options)
        #expect(second.daily.map(\.date) == [dayA, dayB])
        #expect(second.daily.first == first.daily.first)
        #expect(second.sessionTokens == 66)
        #expect(try #require(second.sessionCostUSD) > 0)

        let reopened = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        let resumedFile = try #require(reopened.files.first)
        #expect(reopened.files.count == 1)
        #expect(resumedFile.path == firstFile.path)
        #expect(resumedFile.inode == firstFile.inode)
        #expect(resumedFile.parsedBytes == appendedMetadata.size)
        #expect(resumedFile.scanState.isComplete)
        #expect(resumedFile.scanState.tokenTimestampsMonotonic == true)
        #expect(resumedFile.coverageSinceDay == dayA)
        #expect(resumedFile.coverageUntilDay == dayB)
        let rows = try reopened.usageRows.map {
            try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: $0.payload)
        }
        #expect(rows.map(\.day) == [dayA, dayB])
        let rowB = try #require(rows.first { $0.day == dayB })
        #expect(rowB.input == 60)
        #expect(rowB.cached == 20)
        #expect(rowB.output == 6)
        #expect(rowB.reasoning == 3)
        #expect(reopened.dayAggregates.first { $0.day == dayA } == firstStore.dayAggregates.first)
        #expect(reopened.fileDayAggregates.map(\.aggregate.day) == [dayA, dayB])
        #expect(reopened.dayAggregates.map(\.day) == [dayA, dayB])
        for aggregates in [reopened.dayAggregates, reopened.fileDayAggregates.map(\.aggregate)] {
            let aggregateB = try #require(aggregates.first { $0.day == dayB })
            #expect(aggregateB.inputTokens == 60)
            #expect(aggregateB.cachedTokens == 20)
            #expect(aggregateB.outputTokens == 6)
            #expect(aggregateB.reasoningTokens == 3)
        }

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: nowB,
            historyDays: 30,
            includePiSessions: false,
            scannerOptions: options)
        #expect(cached?.sessionTokens == 66)
        #expect(cached?.sessionCostUSD == second.sessionCostUSD)
        let cachedSnapshot = try #require(cached)
        #expect(cachedSnapshot.daily.count == second.daily.count)
        for (actual, expected) in zip(cachedSnapshot.daily, second.daily) {
            #expect(actual.date == expected.date)
            #expect(actual.totalTokens == expected.totalTokens)
            #expect(actual.costUSD == expected.costUSD)
            #expect(CostUsageTokenMix.from(entry: actual) == CostUsageTokenMix.from(entry: expected))
            #expect(actual.modelBreakdowns == expected.modelBreakdowns)
            #expect(actual.requestCount == expected.requestCount)
            #expect(actual.coverageCounts == expected.coverageCounts)
        }
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: cachedSnapshot)],
            requestedDays: 30,
            now: nowB,
            calendar: calendar)
        let group = try #require(dashboard.groups.first)
        let expectedMix = CostUsageTokenMix(
            inputTokens: 160, outputTokens: 16, cacheReadTokens: 40, reasoningTokens: 7)
        #expect(group.tokenMix == expectedMix)
        #expect(group.displayedModels.first?.tokenMix == expectedMix)

        let stable = try await Self.fetch(
            now: nowB.addingTimeInterval(120), forceRefresh: forceRefresh, options: options)
        #expect(stable.daily == second.daily)
        #expect(stable.sessionTokens == 66)
        let stableStore = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        #expect(stableStore.usageRows == reopened.usageRows)
        #expect(stableStore.dayAggregates == reopened.dayAggregates)
        #expect(stableStore.fileDayAggregates == reopened.fileDayAggregates)
    }

    private static func fetch(
        now: Date,
        forceRefresh: Bool,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now,
            forceRefresh: forceRefresh,
            historyDays: 30,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
    }

    private static func turn(timestamp: String, id: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": "openai/gpt-5.4", "turn_id": id],
        ]
    }

    private static func event(timestamp: String, total: [Int], last: [Int]) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": self.tokens(total),
                    "last_token_usage": self.tokens(last),
                ],
            ],
        ]
    }

    private static func tokens(_ values: [Int]) -> [String: Int] {
        [
            "input_tokens": values[0],
            "cached_input_tokens": values[1],
            "output_tokens": values[2],
            "reasoning_output_tokens": values[3],
        ]
    }
}
