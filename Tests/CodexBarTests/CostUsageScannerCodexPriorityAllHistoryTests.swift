import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerCodexPriorityAllHistoryTests {
    /// Parser hash shipped in CodexBar 0.68.0; its caches must adopt in place instead of rebuilding.
    private static let releasedPredecessorHash = "98de5f52231e524e"

    @Test
    func `all-history scan window records priority state only for days that have turns`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: CostUsageScannerCodexPriorityCursorTests.priorityRequestBody(
                threadID: "thread-all",
                turnID: "turn-all"))

        // The spend dashboard scans from `Date.distantPast`; per-day bookkeeping must stay proportional to the
        // days that actually hold turns, not to the ~740k calendar days in that window.
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, since: .distantPast, now: now)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let turnIDsByDay = try #require(cache.codexPriorityTurnIDsByDay)
        #expect(turnIDsByDay.count == 1)
        #expect(turnIDsByDay.values.first == ["turn-all"])
        #expect(cache.codexPriorityTurnKeys?.count == 1)

        // A second pass over the same window must see no change and keep the compact state.
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, since: .distantPast, now: now.addingTimeInterval(1))
        let second = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        #expect(second.codexPriorityTurnIDsByDay == turnIDsByDay)
        #expect(second.codexPriorityTurnKeys == cache.codexPriorityTurnKeys)
    }

    @Test
    func `released dense all-history priority cache adopts without rebuild and compacts on refresh`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let oldEpoch: Int64 = 1_556_712_000 // 2019-05-01T12:00:00Z
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            epochSeconds: oldEpoch,
            body: CostUsageScannerCodexPriorityCursorTests.priorityRequestBody(
                threadID: "thread-old",
                turnID: "turn-old"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: CostUsageScannerCodexPriorityCursorTests.priorityRequestBody(
                threadID: "thread-new",
                turnID: "turn-new"))
        let oldDay = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(oldEpoch)))
        let newDay = CostUsageScanner.CostUsageDayRange.dayKey(from: now)

        // 0.68.0 wrote one entry per calendar day of the all-history window (~740k in the field).
        // A few thousand synthetic empty days are enough to prove the shape survives adoption and is compacted.
        var denseIDs: [String: [String]] = [oldDay: ["turn-old"]]
        var denseKeys: [String: String] = [oldDay: "stale-marker"]
        for index in 0..<5000 {
            let key = String(format: "%04d-%02d-%02d", 1 + index / 372, 1 + (index / 31) % 12, 1 + index % 31)
            denseIDs[key] = []
            denseKeys[key] = "empty"
        }
        let densePayload = try JSONEncoder().encode(DensePriorityState(turnKeys: denseKeys, turnIDsByDay: denseIDs))

        let predecessor = CostUsageStore(
            cacheRoot: env.cacheRoot,
            home: env.codexStoreHome,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion,
                parserHash: Self.releasedPredecessorHash),
            parserHash: Self.releasedPredecessorHash)
        var metadata = await predecessor.fetchMetadata()
        metadata.priorityTurnStatePayload = densePayload
        #expect(await predecessor.setMetadata(metadata))

        // Opening with the current producer must adopt the released database in place.
        let current = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let adopted = current.syncLoadCodexCache(calendar: .current)
        #expect(await current.rebuildCount == 0)
        #expect(adopted.codexPriorityTurnIDsByDay?.count == denseIDs.count)
        #expect(adopted.codexPriorityTurnIDsByDay?[oldDay] == ["turn-old"])

        // One all-history refresh drops the empty days and keeps only days that hold recorded turns.
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, since: .distantPast, now: now)
        let refreshed = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let turnIDsByDay = try #require(refreshed.codexPriorityTurnIDsByDay)
        #expect(turnIDsByDay.count == 2)
        #expect(turnIDsByDay[oldDay] == ["turn-old"])
        #expect(turnIDsByDay[newDay] == ["turn-new"])
        let turnKeys = try #require(refreshed.codexPriorityTurnKeys)
        #expect(Set(turnKeys.keys) == [oldDay, newDay])
        #expect(turnKeys[oldDay] != "stale-marker")
        #expect(refreshed.codexPriorityTurnsCursor?.turns.keys.sorted() == ["turn-new", "turn-old"])
    }

    private struct DensePriorityState: Encodable {
        var turnKeys: [String: String]
        var turnIDsByDay: [String: [String]]
    }

    private static func loadCodexDailyReport(
        env: CostUsageTestEnvironment,
        databaseURL: URL,
        since: Date,
        now: Date)
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: databaseURL)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options)
    }
}
#endif
