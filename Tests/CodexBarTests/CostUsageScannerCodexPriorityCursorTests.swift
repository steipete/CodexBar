import CryptoKit
import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

struct CostUsageScannerCodexPriorityCursorTests {
    @Test
    func `relaunch reuses persisted priority cursor and scans only appended rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = (0..<50).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.databasePath == dbURL.path)
        #expect(persisted.lastRowID == 51)
        let firstMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(firstMemo.lastRowID == 51)
        #expect(firstMemo.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.fileIdentity == firstMemo.fileIdentity)
        #expect(persisted.fileIdentity != nil)
        #expect(firstMemo.anchorRowID == firstMemo.lastRowID)
        #expect(!firstMemo.anchorDigest.isEmpty)
        #expect(persisted.anchorRowID == firstMemo.anchorRowID)
        #expect(persisted.anchorDigest == firstMemo.anchorDigest)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "mutated", turnID: "mutated-old"))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))])

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))

        let relaunched = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(relaunched.turns.keys.sorted() == ["turn-a", "turn-b"])
        #expect(relaunched.lastRowID == firstMemo.lastRowID + 1)
        #expect(relaunched.anchorRowID == relaunched.lastRowID)
        #expect(relaunched.anchorDigest != firstMemo.anchorDigest)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.lastRowID == firstMemo.lastRowID + 1)
        #expect(reloaded.databasePath == dbURL.path)
        #expect(reloaded.anchorRowID == relaunched.anchorRowID)
        #expect(reloaded.anchorDigest == relaunched.anchorDigest)
    }

    @Test
    func `persisted cursor still full scans after the database inode changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.fileIdentity != nil)
        #expect(persisted.turns.keys.sorted() == ["turn-a", "turn-b"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try FileManager.default.removeItem(at: dbURL)
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-c", turnID: "turn-c"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-d", turnID: "turn-d"))

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))
        let replaced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(replaced.turns.keys.sorted() == ["turn-c", "turn-d"])
        #expect(replaced.lastRowID == 2)
        #expect(replaced.fileIdentity != persisted.fileIdentity)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.turns.keys.sorted() == ["turn-c", "turn-d"])
        #expect(reloaded.fileIdentity == replaced.fileIdentity)
    }

    @Test
    func `replaced database with a reused inode still full scans when the content anchor mismatches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        let originalRowCount = 20
        var originalRows: [(epochSeconds: Int64, body: String)] = (0..<(originalRowCount - 1)).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        originalRows.append((
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: originalRows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.lastRowID == Int64(originalRowCount))
        #expect(persisted.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.anchorRowID == persisted.lastRowID)
        #expect(!persisted.anchorDigest.isEmpty)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try FileManager.default.removeItem(at: dbURL)
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        var replacementRows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x")),
        ]
        replacementRows.append(contentsOf: (1..<originalRowCount).map { index in
            (epochSeconds: epoch, body: "thread_id=r-\(index) turn.id=v-\(index) replacement filler")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: replacementRows)

        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let freshMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(freshTurns.keys.sorted() == ["turn-x"])
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)

        let replacementIdentity = try #require(
            CostUsageScanner._test_codexPriorityDatabaseFileIdentity(at: dbURL))
        var stale = persisted
        stale.fileIdentity = replacementIdentity
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: dbURL)

        let resumedTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let resumedMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(resumedTurns == freshTurns)
        #expect(resumedTurns.keys.sorted() == ["turn-x"])
        #expect(!resumedTurns.keys.contains("turn-a"))
        #expect(resumedMemo.lastRowID == freshMemo.lastRowID)
        #expect(resumedMemo.lastRowID == Int64(originalRowCount))

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(
            Self.persistedCursor(from: freshMemo, databasePath: dbURL.path),
            databaseURL: dbURL)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-y", turnID: "turn-y"))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-z", turnID: "turn-z"))])
        let incremental = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let incrementalMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(incremental.keys.sorted() == ["turn-x", "turn-z"])
        #expect(!incremental.keys.contains("turn-y"))
        #expect(incrementalMemo.lastRowID == freshMemo.lastRowID + 1)
        #expect(incrementalMemo.anchorRowID == incrementalMemo.lastRowID)
    }

    @Test
    func `deleted anchor row forces a full rescan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (1..<8).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.lastRowID == 8)
        #expect(persisted.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.anchorRowID == persisted.lastRowID)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        try Self.deleteTestLog(dbURL: dbURL, rowID: persisted.lastRowID)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let freshMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(turns == freshTurns)
        #expect(turns.keys.sorted() == ["turn-new", "turn-x"])
        #expect(!turns.keys.contains("turn-a"))
        #expect(memo.lastRowID == freshMemo.lastRowID)
        #expect(memo.lastRowID == persisted.lastRowID + 1)
    }

    @Test
    func `persisted cursor still full scans when the requested window expands earlier`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let today = Date()
        let thirtyDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -30, to: today))
        let fortyFiveDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -45, to: today))
        let sixtyDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -60, to: today))
        let formatter = ISO8601DateFormatter()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: fortyFiveDaysAgo),
            body: Self.priorityRequestBody(threadID: "thread-old", turnID: "turn-old"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: today),
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: thirtyDaysAgo,
            until: today,
            now: today)
        let narrowMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(narrowMemo.turns.keys.sorted() == ["turn-new"])
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.coverageSinceEpoch == narrowMemo.coverageSinceEpoch)
        #expect(persisted.turns.keys.sorted() == ["turn-new"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: sixtyDaysAgo,
            until: today,
            now: today.addingTimeInterval(1))
        let expanded = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(expanded.turns.keys.sorted() == ["turn-new", "turn-old"])
        #expect(expanded.coverageSinceEpoch < persisted.coverageSinceEpoch)
    }

    @Test
    func `old priority state payload without a cursor still cold scans`() async throws {
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
            body: Self.priorityRequestBody(threadID: "thread-cold", turnID: "turn-cold"))

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data(
            #"{"turnKeys":{"turn-a":"priority"},"turnIDsByDay":{"2026-05-10":["turn-a"]}}"#.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["turn-a": "priority"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(memo.turns.keys.sorted() == ["turn-cold"])
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let expectedKeys = try #require(Self.expectedPriorityTurnKeys(memo.turns))
        #expect(cache.codexPriorityTurnsCursor != nil)
        #expect(cache.codexPriorityTurnsCursor?.turns.keys.sorted() == ["turn-cold"])
        #expect(cache.codexPriorityTurnKeys == expectedKeys)
        let dayKey = try #require(expectedKeys.keys.first)
        #expect(cache.codexPriorityTurnKeys?[dayKey] != nil)
        #expect(cache.codexPriorityTurnIDsByDay?[dayKey] == ["turn-cold"])
    }

    @Test
    func `live priority memo wins over a stale persisted cursor seed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path) }

        var live = Self.emptyMemoState(observationID: 7)
        live.lastRowID = 99
        live.fileIdentity = 42
        live.turns = [
            "live": CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: "thread-live",
                turnID: "live",
                model: "gpt-5.5",
                timestamp: nil),
        ]
        CostUsageScanner.storeCodexPriorityTurnsMemoIfNewer(live, forPath: databaseURL.path)

        var stale = Self.emptyPersistedCursor(databasePath: databaseURL.path)
        stale.lastRowID = 1
        stale.fileIdentity = 1
        stale.turns = [
            "stale": CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: "thread-stale",
                turnID: "stale",
                model: "gpt-5.5",
                timestamp: nil),
        ]
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: databaseURL)

        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: databaseURL.path))
        #expect(memo.observationID == 7)
        #expect(memo.lastRowID == 99)
        #expect(memo.fileIdentity == 42)
        #expect(memo.turns.keys.sorted() == ["live"])
    }

    @Test
    func `stale seeded cursor reaccumulation is idempotent`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        let matchingRows: [(epochSeconds: Int64, body: String)] = [
            (epoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
            (epoch, Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b")),
            (epoch, Self.priorityRequestBody(threadID: "thread-c", turnID: "turn-c")),
            (epoch, Self.priorityRequestBody(threadID: "thread-d", turnID: "turn-d")),
            (epoch, Self.completedBody(turnID: "turn-a", model: "completed-a")),
            (epoch, Self.completedBody(turnID: "orphan-1", model: "pending-1")),
            (epoch, Self.completedBody(turnID: "orphan-2", model: "pending-2")),
        ]
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: matchingRows)

        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let freshMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(freshMemo.lastRowID == Int64(matchingRows.count))

        var stale = Self.persistedCursor(from: freshMemo, databasePath: dbURL.path)
        stale.lastRowID = 2
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: dbURL)

        let overlappingTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let overlappingMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let againTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let againMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        #expect(overlappingTurns == freshTurns)
        #expect(overlappingTurns == againTurns)
        #expect(overlappingMemo.turns == againMemo.turns)
        #expect(overlappingMemo.requestSourcesByTurnID == againMemo.requestSourcesByTurnID)
        #expect(overlappingMemo.priorityCompletedModelsByTurnID == againMemo.priorityCompletedModelsByTurnID)
        #expect(overlappingMemo.completedModelsByTurnID == againMemo.completedModelsByTurnID)
        #expect(overlappingMemo.completedTurnIDInsertionOrder == againMemo.completedTurnIDInsertionOrder)
        #expect(overlappingMemo.completedTurnIDInsertionOrderStartIndex
            == againMemo.completedTurnIDInsertionOrderStartIndex)
        let retained = Array(
            overlappingMemo.completedTurnIDInsertionOrder
                .dropFirst(overlappingMemo.completedTurnIDInsertionOrderStartIndex))
        #expect(Set(retained).count == retained.count)
        #expect(overlappingMemo.lastRowID == freshMemo.lastRowID)
    }

    @Test
    func `identical content skip still persists an advanced priority cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))])
        try Self.writeCodexSession(env: env, now: now)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now.addingTimeInterval(1))
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending != true)
        let firstCursor = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(firstCursor.lastRowID == 1)

        var persistedFileCount = 0
        CostUsageStore.saveCycleCheckpointForTesting = { _ in persistedFileCount += 1 }
        defer { CostUsageStore.saveCycleCheckpointForTesting = nil }

        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: (0..<3).map { index in
            (epochSeconds: epoch, body: "routine trace row \(index)")
        })
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now.addingTimeInterval(2))

        #expect(persistedFileCount == 0)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.lastRowID == firstCursor.lastRowID + 3)
        #expect(reloaded.turns.keys.sorted() == ["turn-a"])
    }

    @Test
    func `malformed priority turns cursor still loads turn keys`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data("""
        {
          "turnKeys": {"2026-05-10": "marker"},
          "turnIDsByDay": {"2026-05-10": ["turn-a"]},
          "turnsCursor": {"databasePath": 123}
        }
        """.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["2026-05-10": "marker"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)
    }

    @Test
    func `persisted payload without content anchor fields still cold scans`() async throws {
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
            body: Self.priorityRequestBody(threadID: "thread-cold", turnID: "turn-cold"))

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data("""
        {
          "turnKeys": {"2026-05-10": "marker"},
          "turnIDsByDay": {"2026-05-10": ["turn-a"]},
          "turnsCursor": {
            "databasePath": "/tmp/logs_2.sqlite",
            "coverageSinceEpoch": 0,
            "lastRowID": 51,
            "fileIdentity": 1,
            "turns": {"turn-a": {"threadID": "thread-a", "turnID": "turn-a"}},
            "requestSourcesByTurnID": {},
            "priorityCompletedModelsByTurnID": {},
            "completedModelsByTurnID": {},
            "completedTurnIDInsertionOrder": [],
            "completedTurnIDInsertionOrderStartIndex": 0
          }
        }
        """.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["2026-05-10": "marker"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(memo.turns.keys.sorted() == ["turn-cold"])
        #expect(memo.anchorRowID == memo.lastRowID)
        #expect(!memo.anchorDigest.isEmpty)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let expectedKeys = try #require(Self.expectedPriorityTurnKeys(memo.turns))
        let persisted = try #require(cache.codexPriorityTurnsCursor)
        #expect(persisted.turns.keys.sorted() == ["turn-cold"])
        #expect(persisted.anchorRowID == memo.anchorRowID)
        #expect(persisted.anchorDigest == memo.anchorDigest)
        #expect(cache.codexPriorityTurnKeys == expectedKeys)
        let dayKey = try #require(expectedKeys.keys.first)
        #expect(cache.codexPriorityTurnIDsByDay?[dayKey] == ["turn-cold"])
    }

    @Test
    func `force rescan drops a persisted priority cursor and cold scans`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.lastRowID == 2)
        #expect(persisted.turns.keys.sorted() == ["turn-a", "turn-b"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-mutated", turnID: "turn-mutated"))
        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1),
            forceRescan: true)

        let rebuilt = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(rebuilt.turns.keys.sorted() == ["turn-b", "turn-mutated"])
        #expect(rebuilt.lastRowID == 2)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.turns.keys.sorted() == ["turn-b", "turn-mutated"])
        #expect(reloaded.lastRowID == 2)
    }

    private static func loadCodexDailyReport(
        env: CostUsageTestEnvironment,
        databaseURL: URL,
        since: Date? = nil,
        until: Date? = nil,
        now: Date,
        forceRescan: Bool = false)
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: databaseURL)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = forceRescan
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since ?? now,
            until: until ?? now,
            now: now,
            options: options)
    }

    private static func priorityRequestBody(threadID: String, turnID: String) -> String {
        "thread_id=\(threadID) turn.id=\(turnID) websocket request: "
            + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#
    }

    private static func completedBody(turnID: String, model: String) -> String {
        "thread_id=thread turn.id=\(turnID) websocket event: "
            + #"{"type":"response.completed","response":{"model":"\#(model)"}}"#
    }

    private static func writeCodexSession(env: CostUsageTestEnvironment, now: Date) throws {
        let iso = env.isoString(for: now)
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"cursor-skip"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                + #""model":"gpt-5.2-codex"}}}"#,
        ]
        _ = try env.writeCodexSessionFile(
            day: now,
            filename: "cursor-skip.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
    }

    private static func expectedPriorityTurnKeys(
        _ turns: [String: CostUsageScanner.CodexPriorityTurnMetadata],
        calendar: Calendar = .current) -> [String: String]?
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in turns {
            guard let timestamp = turn.timestamp, let seconds = Int64(timestamp) else { continue }
            let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(seconds)),
                calendar: calendar)
            partsByDay[dayKey, default: []].append(
                [turnID, turn.model ?? "", turn.timestamp ?? "", turn.threadID ?? ""]
                    .joined(separator: "|"))
        }
        guard !partsByDay.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            let digest = SHA256.hash(data: Data(parts.sorted().joined(separator: "\n").utf8))
            out[dayKey] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private static func persistedCursor(
        from memo: CostUsageScanner.CodexPriorityTurnsMemoState,
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: memo.coverageSinceEpoch,
            lastRowID: memo.lastRowID,
            fileIdentity: memo.fileIdentity,
            anchorRowID: memo.anchorRowID,
            anchorDigest: memo.anchorDigest,
            turns: memo.turns,
            requestSourcesByTurnID: memo.requestSourcesByTurnID,
            priorityCompletedModelsByTurnID: memo.priorityCompletedModelsByTurnID,
            completedModelsByTurnID: memo.completedModelsByTurnID,
            completedTurnIDInsertionOrder: memo.completedTurnIDInsertionOrder,
            completedTurnIDInsertionOrderStartIndex: memo.completedTurnIDInsertionOrderStartIndex)
    }

    private static func emptyMemoState(observationID: UInt64) -> CostUsageScanner.CodexPriorityTurnsMemoState {
        CostUsageScanner.CodexPriorityTurnsMemoState(
            observationID: observationID,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    private static func emptyPersistedCursor(
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    private static func updateTestLog(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func deleteTestLog(dbURL: URL, rowID: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from logs where id = ?", -1, &statement, nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
    }
}
#endif
