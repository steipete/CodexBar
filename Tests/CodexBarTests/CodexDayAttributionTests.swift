import Foundation
import Testing
@testable import CodexBarCore

struct CodexDayAttributionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_DAY_BENCHMARK"] == "1"))
    func `large synthetic history scan timing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let stamp = env.isoString(for: day)
        let context = #"{"type":"turn_context","timestamp":"\#(stamp)","payload":{"model":"gpt-5.4"}}"#
        let events = (1...100).map { index in
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":\#(index * 100),"output_tokens":\#(index * 10)}}}}"#
        }.joined(separator: "\n")
        for index in 0..<1500 {
            _ = try env.writeCodexSessionFile(
                day: day, filename: "synthetic-\(index).jsonl", contents: context + "\n" + events + "\n")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        for label in ["cold", "warm"] {
            let start = ContinuousClock.now
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: day, options: options)
            print("[day-attribution-benchmark] \(label): \(start.duration(to: .now)); 1500 files, 150000 events")
            #expect(report.summary?.totalTokens == 16_500_000)
        }
    }

    @Test
    func `completed directory discovery releases the retained token snapshot`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        var cache = CostUsageStoreAccess.read(
            cacheRoot: fixture.base.env.cacheRoot, calendar: fixture.base.calendar)
        let roots = try #require(cache.codexActiveLookbackState).rootPaths
        cache.codexActiveLookbackState?.completedCurrentWindowRootPaths = []
        cache.codexActiveLookbackState?.completedCurrentWindowFlatRootPaths = []
        CostUsageStoreAccess.replace(
            cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
        #expect(await fixture.strictSnapshot() == nil)
        let retained = try #require(await fixture.base.cachedSnapshot())
        #expect(retained.snapshot.last30DaysTokens == 13)
        #expect(retained.snapshot.updatedAt == fixture.previousTime)

        cache.codexActiveLookbackState?.completedCurrentWindowRootPaths = roots
        cache.codexActiveLookbackState?.completedCurrentWindowFlatRootPaths = roots
        CostUsageStoreAccess.replace(
            cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
        let completed = try #require(await fixture.strictSnapshot())
        #expect(completed.snapshot.last30DaysTokens == 52)
        #expect(completed.snapshot.updatedAt == fixture.base.now)
        #expect(completed.staleSnapshotUpdatedAt == nil)
        #expect(await CostUsageFetcher(scannerOptions: fixture.base.options).codexScanCatchUpStatus().pending)
    }

    @Test(arguments: [false, true])
    func `resumed sessions keep event days through archive copies and parser migration`(force: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let firstStamp = "2026-08-29T15:59:00Z"
        let nextStamp = "2026-08-29T16:01:00Z"
        let firstDate = try #require(ISO8601DateFormatter().date(from: firstStamp))
        let nextDate = try #require(ISO8601DateFormatter().date(from: nextStamp))
        func event(_ timestamp: String, _ total: [Int], _ last: [Int]) -> [String: Any] {
            func tokens(_ values: [Int]) -> [String: Int] {
                [
                    "input_tokens": values[0],
                    "cached_input_tokens": values[1],
                    "output_tokens": values[2],
                    "reasoning_output_tokens": values[3],
                ]
            }
            return [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": ["type": "token_count", "info": [
                    "total_token_usage": tokens(total), "last_token_usage": tokens(last),
                ]],
            ]
        }
        let file = try env.writeCodexSessionFile(
            day: firstDate,
            filename: "synthetic-resume.jsonl",
            contents: env.jsonl([
                ["type": "session_meta", "timestamp": firstStamp, "payload": ["id": "synthetic-resume"]],
                ["type": "turn_context", "timestamp": firstStamp, "payload": ["model": "gpt-5.4"]],
                event(firstStamp, [1000, 200, 100, 40], [1000, 200, 100, 40]),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex, since: firstDate, until: firstDate, now: firstDate, options: options)
        #expect(first.summary?.totalTokens == 1100)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            event(nextStamp, [1060, 220, 106, 43], [60, 20, 6, 3]),
            event("2026-08-29T16:01:05Z", [1120, 240, 112, 46], [60, 20, 6, 3]),
        ]).utf8))
        try handle.close()
        options.forceRescan = force
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: firstDate, until: nextDate, now: nextDate, options: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        let saved = try #require(cache.files.values.first)
        #expect(saved.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: file).size)
        #expect(saved.codexScanComplete == true)
        let today = report.data.first { $0.date == "2026-08-30" }?.totalTokens ?? 0
        #expect(today == 132)
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: nextDate, calendar: calendar)
        #expect(snapshot.sessionTokens == 132)
        #expect(try #require(snapshot.sessionCostUSD) > 0)
        #expect(saved.days.keys.sorted() == ["2026-08-29", "2026-08-30"])
        let repeated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstDate,
            until: nextDate,
            now: nextDate.addingTimeInterval(120),
            options: options)
        #expect(repeated.data == report.data)
        let thirdStamp = "2026-08-31T02:00:00Z"
        let thirdDate = try #require(ISO8601DateFormatter().date(from: thirdStamp))
        let nextHandle = try FileHandle(forWritingTo: file)
        try nextHandle.seekToEnd()
        try nextHandle.write(contentsOf: Data(env.jsonl([
            event(thirdStamp, [1180, 260, 118, 49], [60, 20, 6, 3]),
        ]).utf8))
        try nextHandle.close()
        let archived = env.codexArchivedSessionsRoot.appendingPathComponent("rotated.jsonl")
        try FileManager.default.copyItem(at: file, to: archived)
        options.forceRescan = false
        let rotated = CostUsageScanner.loadDailyReport(
            provider: .codex, since: firstDate, until: thirdDate, now: thirdDate, options: options)
        #expect(rotated.data.map(\.totalTokens) == [1100, 132, 66])
        #expect(rotated.summary?.totalTokens == 1298)
        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        for path in Array(legacy.files.keys) {
            legacy.files[path]?.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
        }
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy, calendar: calendar)
        let migrated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstDate,
            until: thirdDate,
            now: thirdDate.addingTimeInterval(1),
            options: options)
        #expect(migrated.data == rotated.data)
        let upgraded = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        let allFilesUpgraded = upgraded.files.values.allSatisfy(\.hasCurrentCodexParser)
        #expect(allFilesUpgraded)
    }
}
