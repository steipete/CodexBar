import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// Store invariants share one fixture/helper vocabulary across focused extensions.
// swiftlint:disable file_length

struct CostUsageStoreTests {
    /// The store actor runs on a custom DispatchQueue-backed `SerialExecutor`, and its
    /// `sync*` bridges hand work to the actor from inside `queue.sync`. Getting that handoff
    /// wrong takes the app down on launch with "Incorrect actor executor assumption", so the
    /// bridges have to stay callable from an ordinary non-actor thread.
    ///
    /// The subprocess coverage in `CostUsageStoreExecutorIsolationTests` exercises the legacy
    /// runtime path that an in-process test cannot select.
    @Test
    func `sync bridges are callable from a plain thread`() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)

        final class Outcome: @unchecked Sendable {
            var loadedScanStamp: Int64?
            var savedRowCount: Int?
        }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)

        let thread = Thread {
            let loaded = store.syncLoadCodexCache(calendar: .current)
            outcome.loadedScanStamp = loaded.lastScanUnixMs
            let saved = store.syncSaveCodexCache(
                loaded,
                calendar: .current,
                requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-03"))
            outcome.savedRowCount = saved.rowCount
            finished.signal()
        }
        thread.start()

        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(outcome.loadedScanStamp == 0)
        #expect((outcome.savedRowCount ?? -1) >= 0)
    }

    @Test
    func `database lives beside the legacy artifact directory`() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)

        #expect(store.databaseURL.lastPathComponent == "cost-usage.sqlite")
        #expect(store.databaseURL.deletingLastPathComponent().lastPathComponent == "cost-usage")
    }

    @Test
    func `new database uses WAL`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let configuration = await CostUsageStore(cacheRoot: fixture.root).configuration()

        #expect(configuration?.journalMode.lowercased() == "wal")
    }

    @Test
    func `new database configures busy timeout`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let configuration = await CostUsageStore(cacheRoot: fixture.root).configuration()

        #expect(configuration?.busyTimeoutMilliseconds == 5000)
    }

    @Test
    func `new database enables foreign keys`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let configuration = await CostUsageStore(cacheRoot: fixture.root).configuration()

        #expect(configuration?.foreignKeysEnabled == true)
    }

    @Test
    func `new database uses incremental auto vacuum`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let configuration = await CostUsageStore(cacheRoot: fixture.root).configuration()

        #expect(configuration?.autoVacuumMode == 2)
    }

    @Test
    func `user version combines schema and parser hash`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let configuration = await CostUsageStore(cacheRoot: fixture.root).configuration()

        #expect(configuration?.userVersion == Int(CostUsageStore.schemaVersion))
        #expect(CostUsageStore.combinedSchemaVersion(base: 1, parserHash: "a") !=
            CostUsageStore.combinedSchemaVersion(base: 1, parserHash: "b"))
    }

    @Test
    func `schema contains phase two query indexes`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        _ = await store.configuration()

        let indexes = try SQLiteTestConnection.indexNames(at: store.databaseURL)
        #expect(indexes.contains("files_path_idx"))
        #expect(indexes.contains("file_day_aggregates_day_idx"))
        #expect(indexes.contains("file_day_aggregates_model_day_idx"))
        #expect(indexes.contains("day_aggregates_day_idx"))
        #expect(indexes.contains("day_aggregates_model_idx"))
        #expect(indexes.contains("day_aggregates_model_day_idx"))
    }
}

extension CostUsageStoreTests {
    @Test
    func `file state round trips all validation fields`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")

        #expect(await store.upsertFile(file))
        #expect(await store.fetchFile(path: file.path) == file)
    }

    @Test
    func `file upsert replaces mutable state`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        file.size = 999
        file.parsedBytes = 800
        file.scanState.isComplete = false
        file.updatedAtUnixMs = 20

        #expect(await store.upsertFile(file))
        #expect(await store.fetchFile(path: file.path) == file)
    }

    @Test
    func `missing file returns nil`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }

        #expect(await CostUsageStore(cacheRoot: fixture.root).fetchFile(path: "/missing") == nil)
    }

    @Test
    func `deleting file cascades dependent tables`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        #expect(await store.appendTokenSnapshots([Self.snapshot(path: file.path, eventIndex: 0)]))
        #expect(await store.replaceFileDayAggregates(
            path: file.path,
            aggregates: [Self.aggregate(day: "2026-08-01", model: "model-a", scale: 1)]))
        #expect(await store.upsertForkLineage(Self.lineage(path: file.path)))
        #expect(await store.upsertAccumulator(Self.accumulator(path: file.path)))

        #expect(await store.deleteFile(path: file.path))
        let snapshot = await store.readSnapshot()
        #expect(snapshot.files.isEmpty)
        #expect(snapshot.tokenSnapshots.isEmpty)
        #expect(snapshot.fileDayAggregates.isEmpty)
        #expect(snapshot.forkLineage.isEmpty)
        #expect(snapshot.accumulators.isEmpty)
    }
}

extension CostUsageStoreTests {
    @Test
    func `token snapshot deltas round trip`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        let snapshots = [
            Self.snapshot(path: file.path, eventIndex: 0),
            Self.snapshot(path: file.path, eventIndex: 1, day: "2026-08-02"),
        ]

        #expect(await store.appendTokenSnapshots(snapshots))
        #expect(await store.fetchTokenSnapshots(path: file.path) == snapshots)
    }

    @Test
    func `token snapshot append is idempotent by event index`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        var snapshot = Self.snapshot(path: file.path, eventIndex: 0)
        #expect(await store.appendTokenSnapshots([snapshot]))
        snapshot.endOffset = 222

        #expect(await store.appendTokenSnapshots([snapshot]))
        #expect(await store.fetchTokenSnapshots(path: file.path) == [snapshot])
    }

    @Test
    func `persistence planner materializes only the delta and store preserves absolute indexes`() async throws {
        var transformedIndexes: [Int] = []

        func materialize(
            _ action: CostUsagePersistenceAction,
            source: [Int]) -> [Int]
        {
            transformedIndexes = []
            return action.materialize(source) { index, value in
                transformedIndexes.append(index)
                return value
            }
        }

        let initialAction = CostUsagePersistencePlanner.action(
            canReuse: false,
            stableCursor: false,
            appendSafe: false,
            persistedCount: 0,
            sourceCount: 2)
        #expect(initialAction == .replace)
        #expect(materialize(initialAction, source: [10, 20]) == [10, 20])
        #expect(transformedIndexes == [0, 1])

        let stableAction = CostUsagePersistencePlanner.action(
            canReuse: true,
            stableCursor: true,
            appendSafe: false,
            persistedCount: 2,
            sourceCount: 2)
        #expect(stableAction == .reuse)
        #expect(materialize(stableAction, source: [10, 20]).isEmpty)
        #expect(transformedIndexes.isEmpty)

        let appendAction = CostUsagePersistencePlanner.action(
            canReuse: true,
            stableCursor: false,
            appendSafe: true,
            persistedCount: 2,
            sourceCount: 3)
        #expect(appendAction == .append(startingAt: 2))
        #expect(materialize(appendAction, source: [10, 20, 30]) == [30])
        #expect(transformedIndexes == [2])

        let replacementAction = CostUsagePersistencePlanner.action(
            canReuse: true,
            stableCursor: false,
            appendSafe: false,
            persistedCount: 3,
            sourceCount: 2)
        #expect(replacementAction == .replace)
        #expect(materialize(replacementAction, source: [40, 50]) == [40, 50])
        #expect(transformedIndexes == [0, 1])

        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let path = "/rollouts/delta.jsonl"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        func token(_ index: Int) -> CostUsageCodexTokenSnapshot {
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-08-01T12:00:0\(index)Z",
                last: CostUsageCodexTotals(input: index + 1, cached: 0, output: 1),
                total: CostUsageCodexTotals(input: (index + 1) * 10, cached: 0, output: index + 1),
                endOffset: Int64(100 + index))
        }

        func row(_ index: Int) -> CostUsageScanner.CodexUsageRow {
            CostUsageScanner.CodexUsageRow(
                day: "2026-08-01",
                model: "model-\(index)",
                turnID: "turn-\(index)",
                eventIndex: index,
                timestampUnixMs: Int64(1_754_046_000_000 + index),
                input: index + 1,
                cached: 0,
                output: 1)
        }

        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 200,
            days: ["2026-08-01": ["model-0": [1, 0, 1]]])
        usage.parsedBytes = 200
        usage.codexScanFileId = "1:42"
        usage.codexScanComplete = true
        usage.codexTokenTimestampsMonotonic = true
        usage.codexTokenSnapshots = [token(0), token(1)]
        usage.codexRows = [row(0), row(1)]

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-08-01"
        cache.scanUntilKey = "2026-08-01"
        cache.files = [path: usage]
        cache.days = usage.days

        func save() {
            _ = store.syncSaveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"))
        }

        save()
        save()

        usage.parsedBytes = 300
        usage.size = 300
        usage.codexTokenSnapshots = [token(0), token(1), token(2)]
        usage.codexRows = [row(0), row(1), row(2)]
        cache.files[path] = usage
        save()

        #expect(await store.fetchTokenSnapshots(path: path).map(\.eventIndex) == [0, 1, 2])
        let appendedRows = await store.fetchUsageRows(path: path)
        #expect(appendedRows.map(\.rowIndex) == [0, 1, 2])
        #expect(try appendedRows.map {
            try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: $0.payload)
        } == usage.codexRows)

        usage.parsedBytes = 400
        usage.size = 400
        usage.codexScanFileId = "2:99"
        usage.codexTokenSnapshots = [token(3), token(4)]
        usage.codexRows = [row(3), row(4)]
        cache.files[path] = usage
        save()

        let replacedSnapshots = await store.fetchTokenSnapshots(path: path)
        #expect(replacedSnapshots.map(\.eventIndex) == [0, 1])
        #expect(replacedSnapshots.map(\.timestamp) == usage.codexTokenSnapshots?.map(\.timestamp))
        let replacedRows = await store.fetchUsageRows(path: path)
        #expect(replacedRows.map(\.rowIndex) == [0, 1])
        #expect(try replacedRows.map {
            try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: $0.payload)
        } == usage.codexRows)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `identical codex cache save skips content rewrites but advances the scan timestamp`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let path = "/rollouts/stable.jsonl"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        func token(_ index: Int) -> CostUsageCodexTokenSnapshot {
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-08-01T12:00:0\(index)Z",
                last: CostUsageCodexTotals(input: index + 1, cached: 0, output: 1),
                total: CostUsageCodexTotals(input: (index + 1) * 10, cached: 0, output: index + 1),
                endOffset: Int64(100 + index))
        }

        func row(_ index: Int) -> CostUsageScanner.CodexUsageRow {
            CostUsageScanner.CodexUsageRow(
                day: "2026-08-01",
                model: "model-\(index)",
                turnID: "turn-\(index)",
                eventIndex: index,
                timestampUnixMs: Int64(1_754_046_000_000 + index),
                input: index + 1,
                cached: 0,
                output: 1)
        }

        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 200,
            days: ["2026-08-01": ["model-0": [1, 0, 1]]])
        usage.parsedBytes = 200
        usage.codexScanFileId = "1:42"
        usage.codexScanComplete = true
        usage.codexTokenTimestampsMonotonic = true
        usage.codexTokenSnapshots = [token(0), token(1)]
        usage.codexRows = [row(0), row(1)]

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-08-01"
        cache.scanUntilKey = "2026-08-01"
        cache.files = [path: usage]
        cache.days = usage.days
        cache.lastScanUnixMs = 1000
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        cache.codexPricingKey = "pricing-v1"
        cache.codexPriorityMetadataKey = "priority-v1"
        cache.codexProjectMetadataVersion = 7
        cache.codexPriorityTurnKeys = ["turn-0": "priority"]
        cache.codexPriorityTurnIDsByDay = ["2026-08-01": ["turn-0"]]
        cache.codexScanCatchUpPending = false
        cache.codexScanProcessedBytes = 200
        cache.codexScanTotalBytes = 200
        cache.codexScanCompletedFiles = 1
        cache.codexScanTotalFiles = 1
        cache.roots = ["/synthetic/root": 123]
        cache.codexSessionDiscovery = CostUsageCodexSessionDiscovery(
            roots: ["/synthetic/root"],
            generation: "generation-v1",
            directoryStamps: [:],
            directoryPaths: [],
            nextDirectoryIndex: 0,
            filePaths: [path],
            nextFileIndex: 1,
            fileStamps: [:],
            headScan: nil,
            filePathBySessionId: ["session-1": path],
            missingSessionIds: [],
            pendingSessionIds: [],
            validationDirectoryIndex: 0,
            isComplete: true)
        cache.codexActiveLookbackState = CostUsageCodexActiveLookbackState(
            scanSinceKey: "2026-08-01",
            rootPaths: ["/synthetic/root"],
            nextDayKeyByRoot: ["/synthetic/root": "2026-08-02"])
        cache.codexPreviousReport = CostUsageCodexPreviousReport(
            report: CostUsageDailyReport(data: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-01",
                    inputTokens: 1,
                    outputTokens: 1,
                    totalTokens: 2,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ], summary: nil),
            cache: cache)

        func save(_ cache: CostUsageCache) {
            _ = store.syncSaveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"),
                skipIdenticalContent: true)
        }

        save(cache)

        #expect(await store.setWALAutoCheckpointForTesting(0))
        #expect(await store.truncateWALForTesting())
        let dbURL = store.databaseURL
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        struct Footprint: Equatable {
            var size: Int64
            var mtime: Date?
        }

        func footprint() -> [URL: Footprint] {
            var out: [URL: Footprint] = [:]
            for url in [dbURL, walURL] {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    out[url] = Footprint(
                        size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                        mtime: attributes[.modificationDate] as? Date)
                }
            }
            return out
        }

        let before = footprint()
        let snapshotBefore = await store.readSnapshot()
        _ = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        let countersBefore = await store.persistenceWriteMetricsForTesting()

        // A later scan pass over unchanged files stamps a new timestamp: the content tables
        // stay untouched, but the durable timestamp advances so refresh debounce survives
        // cache reloads and app restarts.
        var reread = CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar)
        #expect(reread.files[path] != nil)
        reread.lastScanUnixMs = 2000
        let noOpResult = store.syncSaveCodexCache(
            reread,
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"),
            skipIdenticalContent: true)

        let after = footprint()
        let countersAfter = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        var expectedSnapshot = snapshotBefore
        expectedSnapshot.metadata.lastScanUnixMs = 2000
        #expect(await store.readSnapshot() == expectedSnapshot)
        #expect(countersAfter.rows - countersBefore.rows == 1)
        #expect(countersAfter.pages <= 2)
        #expect(noOpResult.deletedRows == 0)
        #expect(after[dbURL]?.size == before[dbURL]?.size)
        #expect(after[walURL]?.size ?? 0 > 0)
        #expect(after[walURL]?.mtime != before[walURL]?.mtime)
        #expect(await store.fetchTokenSnapshots(path: path).map(\.eventIndex) == [0, 1])
        #expect(await store.fetchUsageRows(path: path).count == 2)
        let reloaded = CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar)
        #expect(reloaded.lastScanUnixMs == 2000)

        // Repeating the unchanged scan checkpoints at most the prior metadata frame, then emits
        // exactly one new metadata-row change. Both files are measured using SQLite's real `-wal`
        // path; no claim of zero physical writes is made.
        var repeated = reloaded
        repeated.lastScanUnixMs = 2500
        let repeatBefore = footprint()
        let repeatCountersBefore = await store.persistenceWriteMetricsForTesting()
        save(repeated)
        let repeatAfter = footprint()
        let repeatCountersAfter = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        #expect(repeatCountersAfter.rows - repeatCountersBefore.rows == 1)
        #expect(repeatCountersAfter.pages <= 2)
        #expect(repeatAfter[dbURL]?.size == repeatBefore[dbURL]?.size)
        #expect(repeatAfter[walURL]?.size == after[walURL]?.size)
        #expect(repeatAfter[dbURL]?.mtime != nil)
        #expect(repeatAfter[walURL]?.mtime != repeatBefore[walURL]?.mtime)
        print("[no-op-write-proof] first before=\(before) after=\(after)")
        print("[no-op-write-proof] repeat before=\(repeatBefore) after=\(repeatAfter)")

        // A real content change still uses the full all-or-nothing save.
        var changed = repeated
        changed.lastScanUnixMs = 3000
        changed.files[path]?.parsedBytes = 201
        changed.files[path]?.codexTokenSnapshots = [token(0), token(1), token(2)]
        changed.files[path]?.codexRows = [row(0), row(1), row(2)]
        let changedCountersBefore = await store.persistenceWriteMetricsForTesting()
        save(changed)
        let changedCountersAfter = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)

        #expect(changedCountersAfter.rows - changedCountersBefore.rows > 1)
        #expect(await store.fetchTokenSnapshots(path: path).map(\.eventIndex) == [0, 1, 2])

        // Tightening the byte budget still runs enforcement before any identical-content
        // return, but requested-window content is protected, so the cap becomes best-effort
        // and the unchanged save completes without requesting a rescan.
        let tightenedBudget = store.syncSaveCodexCache(
            CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar),
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"),
            fileBudgetBytes: 1,
            skipIdenticalContent: true)
        #expect(tightenedBudget.catchUpRequired == false)
        #expect(tightenedBudget.fileBytes > 1)
        #expect(await store.fetchUsageRows(path: path).count == 3)
    }

    @Test
    func `identical scanner save preserves content committed before the writer lock`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let path = "/rollouts/recheck.jsonl"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 100,
            days: ["2026-08-01": ["gpt-5.6-sol": [10, 2, 1]]])
        usage.parsedBytes = 100
        usage.codexScanFileId = "1:42"
        usage.codexScanComplete = true
        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-08-01"
        cache.scanUntilKey = "2026-08-01"
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        cache.files = [path: usage]
        cache.days = usage.days
        cache.lastScanUnixMs = 1000

        func save(_ value: CostUsageCache) -> CostUsageStoreBudgetResult {
            store.syncSaveCodexCache(
                value,
                calendar: calendar,
                requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"),
                skipIdenticalContent: true)
        }

        _ = save(cache)
        var reread = CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar)
        reread.lastScanUnixMs = 2000
        let interloper = try SQLiteTestConnection(url: store.databaseURL)
        var checkpointError: Error?
        CostUsageStore.identicalContentPreLockCheckpointForTesting = {
            do {
                try interloper.execute("UPDATE files SET parsed_bytes = 999 WHERE path = '\(path)'")
            } catch {
                checkpointError = error
            }
        }
        defer { CostUsageStore.identicalContentPreLockCheckpointForTesting = nil }

        let result = save(reread)

        #expect(checkpointError == nil)
        #expect(result.catchUpRequired)
        #expect(await store.rebuildCount == 0)
        #expect(await store.fetchFile(path: path)?.parsedBytes == 999)
        #expect(CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar).lastScanUnixMs == 1000)

        CostUsageStore.identicalContentPreLockCheckpointForTesting = nil
        var refreshed = CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar)
        refreshed.lastScanUnixMs = 3000
        let retried = save(refreshed)
        #expect(!retried.catchUpRequired)
        #expect(await store.fetchFile(path: path)?.parsedBytes == 999)
        #expect(CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar).lastScanUnixMs == 3000)
    }

    @Test(.timeLimit(.minutes(1)))
    func `identical scanner save reports retry while the writer lock is unavailable`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let path = "/rollouts/locked-save.jsonl"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 100,
            days: ["2026-08-01": ["gpt-5.6-sol": [10, 2, 1]]])
        usage.parsedBytes = 100
        usage.codexScanFileId = "1:42"
        usage.codexScanComplete = true
        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-08-01"
        cache.scanUntilKey = "2026-08-01"
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        cache.files = [path: usage]
        cache.days = usage.days
        cache.lastScanUnixMs = 1000

        func save(_ value: CostUsageCache) -> CostUsageStoreBudgetResult {
            store.syncSaveCodexCache(
                value,
                calendar: calendar,
                requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"),
                skipIdenticalContent: true)
        }

        _ = save(cache)
        var reread = CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar)
        reread.lastScanUnixMs = 2000
        let holder = try SQLiteTestConnection(url: store.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        try holder.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('save-holder', '1')")

        let blocked = save(reread)

        #expect(blocked.catchUpRequired)
        #expect(await store.rebuildCount == 0)
        #expect(CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar).lastScanUnixMs == 1000)

        var changed = reread
        changed.files[path]?.parsedBytes = 200
        changed.lastScanUnixMs = 2500
        let blockedFullSave = store.syncSaveCodexCache(
            changed,
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-01"))
        #expect(blockedFullSave.catchUpRequired)
        #expect(await store.fetchFile(path: path)?.parsedBytes == 100)
        #expect(CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar).lastScanUnixMs == 1000)

        try holder.execute("COMMIT")
        let retried = save(reread)
        #expect(!retried.catchUpRequired)
        #expect(CostUsageStoreAccess.read(cacheRoot: fixture.root, calendar: calendar).lastScanUnixMs == 2000)
    }

    @Test
    func `day aggregate inserts and reads by model`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let aggregate = Self.aggregate(day: "2026-08-01", model: "gpt-5.6-sol", scale: 1)

        #expect(await store.mergeDayAggregates([aggregate]))
        #expect(await store.fetchDayAggregates(sinceDay: "2026-08-01", untilDay: "2026-08-01") == [aggregate])
    }

    @Test
    func `per file aggregates replace and round trip`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        let first = Self.aggregate(day: "2026-08-01", model: "model-a", scale: 1)
        let replacement = Self.aggregate(day: "2026-08-02", model: "model-b", scale: 2)
        #expect(await store.upsertFile(file))
        #expect(await store.replaceFileDayAggregates(path: file.path, aggregates: [first]))
        #expect(await store.replaceFileDayAggregates(path: file.path, aggregates: [replacement]))

        #expect(await store.fetchFileDayAggregates(path: file.path) == [replacement])
    }

    @Test
    func `day aggregate merge adds every metric`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let first = Self.aggregate(day: "2026-08-01", model: "gpt-5.6-sol", scale: 1)
        let second = Self.aggregate(day: "2026-08-01", model: "gpt-5.6-sol", scale: 2)

        #expect(await store.mergeDayAggregates([first, second]))
        #expect(await store.fetchDayAggregates(sinceDay: "2026-08-01", untilDay: "2026-08-01") == [
            Self.aggregate(day: "2026-08-01", model: "gpt-5.6-sol", scale: 3),
        ])
    }

    @Test
    func `day aggregate range is inclusive and sorted`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let values = [
            Self.aggregate(day: "2026-08-03", model: "model-b", scale: 1),
            Self.aggregate(day: "2026-08-01", model: "model-a", scale: 1),
            Self.aggregate(day: "2026-08-02", model: "model-a", scale: 1),
        ]
        #expect(await store.mergeDayAggregates(values))

        let fetched = await store.fetchDayAggregates(sinceDay: "2026-08-01", untilDay: "2026-08-02")
        #expect(fetched.map(\.day) == ["2026-08-01", "2026-08-02"])
    }

    @Test
    func `negative aggregate delta subtracts prior contribution`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let first = Self.aggregate(day: "2026-08-01", model: "model-a", scale: 3)
        let delta = Self.aggregate(day: "2026-08-01", model: "model-a", scale: -1)
        #expect(await store.mergeDayAggregates([first, delta]))

        #expect(await store.fetchDayAggregates(sinceDay: "2026-08-01", untilDay: "2026-08-01") == [
            Self.aggregate(day: "2026-08-01", model: "model-a", scale: 2),
        ])
    }
}

extension CostUsageStoreTests {
    @Test
    func `fork lineage round trips typed and opaque state`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-01")
        let lineage = Self.lineage(path: file.path)
        #expect(await store.upsertFile(file))

        #expect(await store.upsertForkLineage(lineage))
        #expect(await store.fetchForkLineage(path: file.path) == lineage)
    }

    @Test
    func `buffered lines round trip every retry kind`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        var expected: [CostUsageStoreBufferedLine] = []
        for (index, kind) in CostUsageStoreBufferedLineKind.allCases.enumerated() {
            let line = Self.bufferedLine(path: file.path, kind: kind, index: index)
            expected.append(line)
            #expect(await store.replaceBufferedLines(path: file.path, kind: kind, lines: [line]))
        }

        #expect(await store.fetchBufferedLines(path: file.path) == expected.sorted {
            $0.kind.rawValue < $1.kind.rawValue
        })
    }

    @Test
    func `buffer replacement is scoped by retry kind`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-01")
        #expect(await store.upsertFile(file))
        let subagent = Self.bufferedLine(path: file.path, kind: .subagent, index: 1)
        let fork = Self.bufferedLine(path: file.path, kind: .unresolvedFork, index: 2)
        #expect(await store.replaceBufferedLines(path: file.path, kind: .subagent, lines: [subagent]))
        #expect(await store.replaceBufferedLines(path: file.path, kind: .unresolvedFork, lines: [fork]))

        #expect(await store.replaceBufferedLines(path: file.path, kind: .subagent, lines: []))
        #expect(await store.fetchBufferedLines(path: file.path) == [fork])
    }

    @Test
    func `discovery state round trips and clears`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let state = Self.discoveryState(paths: ["/a", "/b"])

        #expect(await store.setDiscoveryState(state))
        #expect(await store.fetchDiscoveryState() == state)
        #expect(await store.setDiscoveryState(nil))
        #expect(await store.fetchDiscoveryState() == nil)
    }

    @Test
    func `active lookback state round trips`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let state = CostUsageStoreLookbackState(
            scanSinceDay: "2026-07-01",
            rootPaths: ["/root"],
            nextDayByRoot: ["/root": "2026-07-10"],
            completedRootPaths: [],
            pendingFilePaths: ["/pending"],
            legacyRecursivePendingRootPaths: ["/legacy"])

        #expect(await store.setLookbackState(state))
        #expect(await store.fetchLookbackState() == state)
    }

    @Test
    func `scan metadata round trips`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let metadata = Self.metadata()

        #expect(await store.setMetadata(metadata))
        #expect(await store.fetchMetadata() == metadata)
    }

    @Test
    func `two stores advance freshness monotonically without losing current metadata`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = CostUsageStore(cacheRoot: fixture.root)
        let second = CostUsageStore(cacheRoot: fixture.root)
        var stale = Self.metadata()
        stale.lastScanUnixMs = 100
        #expect(await first.setMetadata(stale))

        // Simulate a second owner committing richer metadata after the first owner obtained
        // its stale input. The freshness operation must re-read this whole payload under its
        // writer lock rather than writing fields copied from the stale caller.
        var current = stale
        current.lastScanUnixMs = 250
        current.scanSinceDay = "2026-07-01"
        current.scanUntilDay = "2026-08-11"
        current.pricingKey = "pricing-v2"
        current.priorityMetadataKey = "priority-v2"
        current.catchUpPending = false
        current.rootMtimes = ["/current/root": 999]
        current.previousReportPayload = Data([9, 8, 7])
        current.priorityTurnStatePayload = Data([6, 5, 4])
        current.projectMetadataVersion = 9
        #expect(await second.setMetadata(current))

        #expect(await first.advanceLastScanUnixMs(200))
        #expect(await first.fetchMetadata() == current)
        #expect(await second.advanceLastScanUnixMs(300))
        var expected = current
        expected.lastScanUnixMs = 300
        #expect(await first.fetchMetadata() == expected)

        var catchUp = expected
        catchUp.catchUpPending = true
        catchUp.lastScanUnixMs = 0
        #expect(await second.setMetadata(catchUp))
        #expect(await first.advanceLastScanUnixMs(400))
        #expect(await first.fetchMetadata() == catchUp)
    }

    @Test(.timeLimit(.minutes(1)))
    func `held writer lock makes freshness advance fail soft without rebuilding`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var metadata = Self.metadata()
        metadata.catchUpPending = false
        #expect(await store.setMetadata(metadata))

        let holder = try SQLiteTestConnection(url: store.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        try holder.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('freshness-holder', '1')")

        #expect(await store.advanceLastScanUnixMs(500) == false)
        #expect(await store.rebuildCount == 0)
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))

        try holder.execute("COMMIT")
        #expect(await store.fetchMetadata() == metadata)
        #expect(await store.advanceLastScanUnixMs(500))
        var expected = metadata
        expected.lastScanUnixMs = 500
        #expect(await store.fetchMetadata() == expected)
        #expect(await store.rebuildCount == 0)
    }

    @Test
    func `terminal accumulator round trips all state`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        let accumulator = Self.accumulator(path: file.path)
        #expect(await store.upsertFile(file))

        #expect(await store.upsertAccumulator(accumulator))
        #expect(await store.fetchAccumulator(path: file.path) == accumulator)
    }
}

extension CostUsageStoreTests {
    @Test
    func `full snapshot reads every table from one transaction`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        let token = Self.snapshot(path: file.path, eventIndex: 0)
        let aggregate = Self.aggregate(day: "2026-08-01", model: "model-a", scale: 1)
        let lineage = Self.lineage(path: file.path)
        let line = Self.bufferedLine(path: file.path, kind: .subagent, index: 0)
        let discovery = Self.discoveryState(paths: [file.path])
        let lookback = CostUsageStoreLookbackState(
            scanSinceDay: "2026-08-01",
            rootPaths: ["/root"],
            nextDayByRoot: [:],
            completedRootPaths: [],
            pendingFilePaths: [],
            legacyRecursivePendingRootPaths: [])
        let accumulator = Self.accumulator(path: file.path)
        let metadata = Self.metadata()
        #expect(await store.upsertFile(file))
        #expect(await store.appendTokenSnapshots([token]))
        #expect(await store.replaceFileDayAggregates(path: file.path, aggregates: [aggregate]))
        #expect(await store.mergeDayAggregates([aggregate]))
        #expect(await store.upsertForkLineage(lineage))
        #expect(await store.replaceBufferedLines(path: file.path, kind: .subagent, lines: [line]))
        #expect(await store.setDiscoveryState(discovery))
        #expect(await store.setLookbackState(lookback))
        #expect(await store.upsertAccumulator(accumulator))
        #expect(await store.setMetadata(metadata))

        let snapshot = await store.readSnapshot()
        #expect(snapshot == CostUsageStoreSnapshot(
            metadata: metadata,
            files: [file],
            tokenSnapshots: [token],
            fileDayAggregates: [CostUsageStoreFileDayAggregate(path: file.path, aggregate: aggregate)],
            dayAggregates: [aggregate],
            forkLineage: [lineage],
            bufferedLines: [line],
            discoveryState: discovery,
            lookbackState: lookback,
            accumulators: [accumulator]))
    }

    @Test
    func `report readback includes metadata and bounded aggregates`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let metadata = Self.metadata()
        let inside = Self.aggregate(day: "2026-08-02", model: "model-a", scale: 1)
        let outside = Self.aggregate(day: "2026-07-31", model: "model-a", scale: 1)
        #expect(await store.setMetadata(metadata))
        #expect(await store.mergeDayAggregates([inside, outside]))

        #expect(await store.readReport(sinceDay: "2026-08-01", untilDay: "2026-08-03") ==
            CostUsageStoreReport(metadata: metadata, aggregates: [inside]))
    }

    @Test
    func `database persists across store instances`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl", day: "2026-08-01")
        #expect(await first.upsertFile(file))
        let second = CostUsageStore(cacheRoot: fixture.root)

        #expect(await second.fetchFile(path: file.path) == file)
        #expect(await second.rebuildCount == 0)
    }
}

extension CostUsageStoreTests {
    @Test
    func `compatible predecessor parser hash adopts without rebuilding`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        #expect(CostUsageStore.compatiblePredecessorParserHashes == [
            "3c984b655688593f",
            "98da5914d2f6a9cd",
            "43609cc56f76a003",
            "b975eb705f905b9a",
            "47144baa8daccf52",
            "2d17f4981b78d07f",
        ])
        let predecessorHash = "3c984b655688593f"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        let predecessor = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: predecessorVersion,
            parserHash: predecessorHash)
        let file = Self.file(path: "/rollouts/compatible.jsonl", day: "2026-08-01")
        let token = Self.snapshot(path: file.path, eventIndex: 0)
        let usageRow = CostUsageStoreUsageRow(path: file.path, rowIndex: 0, payload: Data([8, 9, 10]))
        let aggregate = Self.aggregate(day: "2026-08-01", model: "gpt-5.6-sol", scale: 1)
        let lineage = Self.lineage(path: file.path)
        let line = Self.bufferedLine(path: file.path, kind: .subagent, index: 0)
        let discovery = Self.discoveryState(paths: [file.path])
        let lookback = CostUsageStoreLookbackState(
            scanSinceDay: "2026-08-01",
            rootPaths: ["/root"],
            nextDayByRoot: ["/root": "2026-08-02"],
            completedRootPaths: [],
            pendingFilePaths: [file.path],
            legacyRecursivePendingRootPaths: [])
        let accumulator = Self.accumulator(path: file.path)
        let metadata = Self.metadata()
        #expect(await predecessor.upsertFile(file))
        #expect(await predecessor.appendTokenSnapshots([token]))
        #expect(await predecessor.replaceUsageRows(path: file.path, rows: [usageRow]))
        #expect(await predecessor.replaceFileDayAggregates(path: file.path, aggregates: [aggregate]))
        #expect(await predecessor.mergeDayAggregates([aggregate]))
        #expect(await predecessor.upsertForkLineage(lineage))
        #expect(await predecessor.replaceBufferedLines(path: file.path, kind: .subagent, lines: [line]))
        #expect(await predecessor.setDiscoveryState(discovery))
        #expect(await predecessor.setLookbackState(lookback))
        #expect(await predecessor.upsertAccumulator(accumulator))
        #expect(await predecessor.setMetadata(metadata))
        let before = await predecessor.readSnapshot()

        let current = CostUsageStore(cacheRoot: fixture.root)
        let after = await current.readSnapshot()
        #expect(after == before)
        #expect(await current.rebuildCount == 0)
        #expect(await current.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        let connection = try SQLiteTestConnection(url: fixture.databaseURL, readOnly: true)
        #expect(try connection.scalarInt(
            "SELECT COUNT(*) FROM meta WHERE key = 'parser_hash' AND value = '\(CodexParserHash.value)'") == 1)
    }

    @Test
    func `compatible predecessor parser hash adopts cursorless priority payload without rebuilding`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let predecessorHash = "2d17f4981b78d07f"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        let predecessor = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: predecessorVersion,
            parserHash: predecessorHash)
        let file = Self.file(path: "/rollouts/compatible.jsonl", day: "2026-08-01")
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data(
            #"{"turnKeys":{"turn-a":"priority"},"turnIDsByDay":{"2026-05-10":["turn-a"]}}"#.utf8)
        #expect(await predecessor.upsertFile(file))
        #expect(await predecessor.setMetadata(metadata))

        let current = CostUsageStore(cacheRoot: fixture.root)
        let loaded = current.syncLoadCodexCache(calendar: .current)
        #expect(await current.fetchFile(path: file.path) == file)
        #expect(await current.fetchMetadata() == metadata)
        #expect(await current.rebuildCount == 0)
        #expect(await current.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        #expect(loaded.codexPriorityTurnKeys == ["turn-a": "priority"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)
        let connection = try SQLiteTestConnection(url: fixture.databaseURL, readOnly: true)
        #expect(try connection.scalarInt(
            "SELECT COUNT(*) FROM meta WHERE key = 'parser_hash' AND value = '\(CodexParserHash.value)'") == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `concurrent predecessor adoption never rebuilds a valid store`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let predecessorHash = "b975eb705f905b9a"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        let predecessor = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: predecessorVersion,
            parserHash: predecessorHash)
        let metadata = Self.metadata()
        #expect(await predecessor.setMetadata(metadata))

        let stores = (0..<16).map { _ in CostUsageStore(cacheRoot: fixture.root) }
        await withTaskGroup(of: Void.self) { group in
            for store in stores {
                group.addTask {
                    #expect(await store.fetchMetadata() == metadata)
                    #expect(await store.rebuildCount == 0)
                }
            }
        }
        let connection = try SQLiteTestConnection(url: fixture.databaseURL, readOnly: true)
        #expect(try connection.scalarInt("PRAGMA user_version") == Int64(CostUsageStore.schemaVersion))
        #expect(try connection.scalarInt(
            "SELECT COUNT(*) FROM meta WHERE key = 'parser_hash' AND value = '\(CodexParserHash.value)'") == 1)
    }

    @Test
    func `version mismatch drops and recreates`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let url = fixture.databaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SQLiteTestConnection.execute(at: url, sql: "PRAGMA user_version = 7")
        let store = CostUsageStore(cacheRoot: fixture.root)

        #expect(await store.fetchMetadata() == .empty)
        #expect(await store.rebuildCount == 1)
        #expect(await store.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
    }

    @Test
    func `parser hash mismatch drops and recreates`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let url = fixture.databaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SQLiteTestConnection.execute(at: url, sql: """
        PRAGMA auto_vacuum=INCREMENTAL;
        VACUUM;
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta(key, value) VALUES ('parser_hash', 'old-parser');
        PRAGMA user_version = \(CostUsageStore.schemaVersion);
        """)
        let store = CostUsageStore(cacheRoot: fixture.root)

        #expect(await store.fetchMetadata() == .empty)
        #expect(await store.rebuildCount == 1)
    }

    @Test
    func `v0_49_2 parser hash upgrades without rebuilding completed files`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let previousParserHash = "b975eb705f905b9a"
        let previousSchemaVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: previousParserHash)
        let previousStore = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: previousSchemaVersion,
            parserHash: previousParserHash)
        let file = Self.file(path: "/rollouts/completed.jsonl", day: "2026-08-01")
        #expect(await previousStore.upsertFile(file))

        let upgradedStore = CostUsageStore(cacheRoot: fixture.root)

        #expect(await upgradedStore.fetchFile(path: file.path) == file)
        #expect(await upgradedStore.rebuildCount == 0)
        #expect(await upgradedStore.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        let connection = try SQLiteTestConnection(url: fixture.databaseURL, readOnly: true)
        #expect(try connection.scalarInt(
            "SELECT COUNT(*) FROM meta WHERE key = 'parser_hash' AND value = '\(CodexParserHash.value)'") == 1)
    }

    @Test
    func `compatible predecessor hash with mismatched version still rebuilds`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let predecessorHash = "b975eb705f905b9a"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        let predecessor = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: predecessorVersion,
            parserHash: predecessorHash)
        #expect(await predecessor.setMetadata(Self.metadata()))
        try SQLiteTestConnection.execute(
            at: fixture.databaseURL,
            sql: "PRAGMA user_version = \(predecessorVersion + 1)")

        let current = CostUsageStore(cacheRoot: fixture.root)
        #expect(await current.fetchMetadata() == .empty)
        #expect(await current.rebuildCount == 1)
    }

    @Test
    func `compatible predecessor hash without incremental auto vacuum still rebuilds`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let predecessorHash = "b975eb705f905b9a"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        try FileManager.default.createDirectory(
            at: fixture.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try SQLiteTestConnection.execute(at: fixture.databaseURL, sql: """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta(key, value) VALUES ('parser_hash', '\(predecessorHash)');
        PRAGMA user_version = \(predecessorVersion);
        """)

        let current = CostUsageStore(cacheRoot: fixture.root)
        #expect(await current.fetchMetadata() == .empty)
        #expect(await current.rebuildCount == 1)
        #expect(await current.configuration()?.autoVacuumMode == 2)
    }

    @Test
    func `garbage database recovers by rebuild`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let url = fixture.databaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: url)
        let store = CostUsageStore(cacheRoot: fixture.root)

        #expect(await store.fetchMetadata() == .empty)
        #expect(await store.rebuildCount == 1)
        #expect(await store.configuration()?.journalMode.lowercased() == "wal")
    }

    @Test
    func `runtime sqlite error degrades to a fresh store`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.mergeDayAggregates([Self.aggregate(day: "2026-08-01", model: "model-a", scale: 1)]))
        try SQLiteTestConnection.execute(at: store.databaseURL, sql: "DROP TABLE day_aggregates")

        #expect(await store.fetchDayAggregates(sinceDay: "2026-08-01", untilDay: "2026-08-01").isEmpty)
        #expect(await store.rebuildCount == 1)
    }
}

extension CostUsageStoreTests {
    @Test
    func `retention keeps inclusive window edges`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let days = ["2026-07-31", "2026-08-01", "2026-08-03", "2026-08-04"]
        for (index, day) in days.enumerated() {
            let file = Self.file(path: "/rollouts/\(index).jsonl", day: day)
            #expect(await store.upsertFile(file))
            #expect(await store.appendTokenSnapshots([Self.snapshot(path: file.path, eventIndex: 0, day: day)]))
            let aggregate = Self.aggregate(day: day, model: "model-a", scale: 1)
            #expect(await store.replaceFileDayAggregates(path: file.path, aggregates: [aggregate]))
            #expect(await store.mergeDayAggregates([aggregate]))
        }

        let result = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")
        #expect(result.deletedFiles == 2)
        #expect(result.deletedFileDayAggregates == 2)
        #expect(await (store.readSnapshot()).files.map(\.coverageSinceDay) == ["2026-08-01", "2026-08-03"])
        #expect(await (store.readSnapshot()).dayAggregates.map(\.day) == ["2026-08-01", "2026-08-03"])
    }

    @Test
    func `retention preserves incomplete out of window file`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var file = Self.file(path: "/rollouts/incomplete.jsonl", day: "2026-07-01")
        file.scanState.isComplete = false
        #expect(await store.upsertFile(file))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")
        #expect(await store.fetchFile(path: file.path) != nil)
    }

    @Test
    func `retention preserves file with buffered retry lines`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/buffered.jsonl", day: "2026-07-01")
        let line = Self.bufferedLine(path: file.path, kind: .unresolvedFork, index: 0)
        #expect(await store.upsertFile(file))
        #expect(await store.replaceBufferedLines(path: file.path, kind: .unresolvedFork, lines: [line]))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")
        #expect(await store.fetchFile(path: file.path) != nil)
    }

    @Test
    func `retention preserves parent referenced by surviving child`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var parent = Self.file(path: "/rollouts/parent.jsonl", day: "2026-07-01")
        parent.sessionID = "parent-session"
        let child = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-02")
        var lineage = Self.lineage(path: child.path)
        lineage.forkedFromID = "parent-session"
        #expect(await store.upsertFile(parent))
        #expect(await store.upsertFile(child))
        #expect(await store.upsertForkLineage(lineage))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")
        #expect(await store.fetchFile(path: parent.path) != nil)
    }

    @Test
    func `retention keeps recently modified file with stale coverage`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var file = Self.file(path: "/rollouts/stale-but-active.jsonl", day: "2026-07-01")
        let recentMtime = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 1,
            hour: 6)))
        file.mtimeUnixMs = Int64(recentMtime.timeIntervalSince1970 * 1000)
        #expect(await store.upsertFile(file))

        _ = await store.retainDayWindow(
            sinceDay: "2026-08-01",
            untilDay: "2026-08-03",
            calendar: calendar)
        #expect(await store.fetchFile(path: file.path) != nil)
    }

    @Test
    func `retention prunes stale file modified before the window`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var file = Self.file(path: "/rollouts/stale-and-idle.jsonl", day: "2026-07-01")
        let oldMtime = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 1,
            hour: 12)))
        file.mtimeUnixMs = Int64(oldMtime.timeIntervalSince1970 * 1000)
        #expect(await store.upsertFile(file))

        _ = await store.retainDayWindow(
            sinceDay: "2026-08-01",
            untilDay: "2026-08-03",
            calendar: calendar)
        #expect(await store.fetchFile(path: file.path) == nil)
    }

    @Test
    func `retention prunes stale file modified after the window`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var file = Self.file(path: "/rollouts/stale-after-window.jsonl", day: "2026-07-01")
        let lateMtime = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4,
            hour: 12)))
        file.mtimeUnixMs = Int64(lateMtime.timeIntervalSince1970 * 1000)
        #expect(await store.upsertFile(file))

        _ = await store.retainDayWindow(
            sinceDay: "2026-08-01",
            untilDay: "2026-08-03",
            calendar: calendar)
        #expect(await store.fetchFile(path: file.path) == nil)
    }

    @Test
    func `retention keeps stale file modified at the window edges`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let startMtime = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 1,
            hour: 0)))
        let endMtime = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 23,
            minute: 59,
            second: 59)))
        for (index, mtime) in [startMtime, endMtime].enumerated() {
            var file = Self.file(
                path: "/rollouts/edge-\(index).jsonl",
                day: "2026-07-01")
            file.mtimeUnixMs = Int64(mtime.timeIntervalSince1970 * 1000)
            #expect(await store.upsertFile(file))
        }

        _ = await store.retainDayWindow(
            sinceDay: "2026-08-01",
            untilDay: "2026-08-03",
            calendar: calendar)
        #expect(await store.fetchFile(path: "/rollouts/edge-0.jsonl") != nil)
        #expect(await store.fetchFile(path: "/rollouts/edge-1.jsonl") != nil)
    }

    @Test
    func `retention prunes discovery references for removed files`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var old = Self.file(path: "/rollouts/old.jsonl", day: "2026-07-01")
        old.sessionID = "old-session"
        #expect(await store.upsertFile(old))
        #expect(await store.setDiscoveryState(Self.discoveryState(paths: [old.path])))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")
        let discovery = try #require(await store.fetchDiscoveryState())
        #expect(discovery.filePaths.isEmpty)
        #expect(discovery.pendingSessionIDs.isEmpty)
        #expect(discovery.filePathBySessionID.isEmpty)
    }

    @Test
    func `retention prunes the discovery payload in sync with typed state`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var old = Self.file(path: "/rollouts/old.jsonl", day: "2026-07-01")
        old.sessionID = "old-session"
        var kept = Self.file(path: "/rollouts/kept.jsonl", day: "2026-08-02")
        kept.sessionID = "kept-session"
        #expect(await store.upsertFile(old))
        #expect(await store.upsertFile(kept))
        let discovery = CostUsageCodexSessionDiscovery(
            roots: ["/rollouts"],
            generation: nil,
            directoryStamps: [:],
            directoryPaths: [],
            nextDirectoryIndex: 3,
            filePaths: [old.path, kept.path],
            nextFileIndex: 2,
            fileStamps: [
                old.path: .init(mtimeUnixMs: 1, size: 100, fileId: nil),
                kept.path: .init(mtimeUnixMs: 1, size: 100, fileId: nil),
            ],
            headScan: nil,
            filePathBySessionId: [
                "old-session": old.path,
                "kept-session": kept.path,
            ],
            missingSessionIds: ["old-session"],
            pendingSessionIds: [],
            validationDirectoryIndex: 1,
            isComplete: true)
        var state = Self.discoveryState(paths: [old.path, kept.path])
        state.payload = try JSONEncoder().encode(discovery)
        #expect(await store.setDiscoveryState(state))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")

        // The scanner round-trips discovery through the opaque payload, so pruning must
        // reach it or deleted files resurface on the next load.
        let cache = store.syncLoadCodexCache(calendar: .current)
        let pruned = try #require(cache.codexSessionDiscovery)
        #expect(pruned.filePaths == [kept.path])
        #expect(pruned.fileStamps[old.path] == nil)
        #expect(pruned.fileStamps[kept.path] != nil)
        #expect(pruned.filePathBySessionId["old-session"] == nil)
        #expect(pruned.filePathBySessionId["kept-session"] != nil)
        #expect(pruned.missingSessionIds.isEmpty)
        #expect(pruned.isComplete == false)
        #expect(pruned.nextFileIndex == 0)
        #expect(pruned.nextDirectoryIndex == 0)
    }

    @Test
    func `retention does not protect a parent referenced only by a lineage only child`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var parent = Self.file(path: "/rollouts/parent.jsonl", day: "2026-07-01")
        parent.sessionID = "parent-session"
        let child = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-02")
        var lineage = Self.lineage(path: child.path)
        lineage.forkedFromID = "parent-session"
        lineage.dependencyKey = CostUsageScanner.codexForkDependencyNotRequiredKey
        #expect(await store.upsertFile(parent))
        #expect(await store.upsertFile(child))
        #expect(await store.upsertForkLineage(lineage))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")

        // Lineage-only children never resolve inherited totals, so they do not keep a
        // stale out-of-window parent alive.
        #expect(await store.fetchFile(path: parent.path) == nil)
        #expect(await store.fetchFile(path: child.path) != nil)
    }

    @Test
    func `retention drops a stale parent referenced only by a stale child`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var parent = Self.file(path: "/rollouts/parent.jsonl", day: "2026-07-01", updatedAt: 1)
        parent.sessionID = "parent-session"
        var child = Self.file(path: "/rollouts/child.jsonl", day: "2026-07-02", updatedAt: 2)
        child.sessionID = "child-session"
        var lineage = Self.lineage(path: child.path)
        lineage.forkedFromID = "parent-session"
        #expect(await store.upsertFile(parent))
        #expect(await store.upsertFile(child))
        #expect(await store.upsertForkLineage(lineage))

        let result = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03")

        // One pass: deleting the stale child releases the parent's fork protection, and the
        // parent must not linger as an unreferenced out-of-window row.
        #expect(result.deletedFiles == 2)
        #expect(await store.fetchFile(path: parent.path) == nil)
        #expect(await store.fetchFile(path: child.path) == nil)
    }

    @Test
    func `retention preserves an out of window file modified inside the window`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()
        let activeDate = try #require(CostUsageScanner.parseDayKey("2026-08-02", calendar: calendar))
        var active = Self.file(path: "/rollouts/active.jsonl", day: "2026-07-01")
        active.mtimeUnixMs = Int64(activeDate.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        var stale = Self.file(path: "/rollouts/stale.jsonl", day: "2026-07-01")
        stale.mtimeUnixMs = 1
        #expect(await store.upsertFile(active))
        #expect(await store.upsertFile(stale))

        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-03", calendar: calendar)

        // A recent mtime means the file may hold unscanned in-window rows; dropping it would
        // force a rediscovery and full reparse on every refresh.
        #expect(await store.fetchFile(path: active.path) != nil)
        #expect(await store.fetchFile(path: stale.path) == nil)
    }
}

extension CostUsageStoreTests {
    @Test
    func `save preserves an existing previous report when protected data exceeds the byte cap`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var older = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        older.sessionId = "older-session"
        var recent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        recent.sessionId = "recent-session"
        cache.files = [
            "/sessions/older.jsonl": older,
            "/sessions/recent.jsonl": recent,
        ]
        cache.days = [
            "2026-06-05": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]
        // Simulate an already pending catch-up pass with a complete previous report.
        cache.codexScanCatchUpPending = true
        cache.codexPreviousReport = CostUsageCodexPreviousReport(
            report: CostUsageDailyReport(data: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-05",
                    inputTokens: 1,
                    outputTokens: 0,
                    totalTokens: 1,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ], summary: nil),
            cache: cache)

        let result = store.syncSaveCodexCache(
            cache,
            calendar: .current,
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            reportWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            fileBudgetBytes: 1)

        #expect(result.catchUpRequired == false)
        let metadata = await store.fetchMetadata()
        let payload = try #require(metadata.previousReportPayload)
        let preserved = try JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: payload)
        #expect(preserved.data.count == 1)
        #expect(preserved.data.first?.date == "2026-06-05")
        #expect(preserved.data.contains { $0.date == "2026-06-28" } == false)
    }

    @Test
    func `save over byte cap keeps non-gregorian in window report intact`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var entry = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        entry.sessionId = "in-window-session"
        cache.files = ["/sessions/in-window.jsonl": entry]
        cache.days = ["2026-06-05": ["gpt-5.5": [1, 0, 0]]]

        let result = store.syncSaveCodexCache(
            cache,
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            reportWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            fileBudgetBytes: 1)
        let report = await store.readReport(sinceDay: "2026-06-01", untilDay: "2026-07-01")

        #expect(result.catchUpRequired == false)
        #expect(await store.fetchMetadata().previousReportPayload == nil)
        #expect(report.aggregates.map(\.day) == ["2026-06-05"])
        #expect(report.aggregates.contains { $0.day == "1483-06-05" } == false)
    }
}

extension CostUsageStoreTests {
    @Test
    func `narrow dashboard windows preserve wider retained cache under byte pressure`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()
        let retainedWindow = (sinceKey: "2025-08-15", untilKey: "2026-08-14")
        let olderDay = "2026-01-15"
        let recentDay = "2026-08-14"
        let model = "gpt-5.5"
        let olderPath = "/rollouts/older.jsonl"
        let recentPath = "/rollouts/recent.jsonl"

        func usage(day: String, mtimeUnixMs: Int64) -> CostUsageFileUsage {
            var value = CostUsageFileUsage(
                mtimeUnixMs: mtimeUnixMs,
                size: 500,
                days: [day: [model: [1, 0, 0]]])
            value.parsedBytes = 500
            value.codexScanComplete = true
            return value
        }

        let olderUsage = usage(day: olderDay, mtimeUnixMs: 1)
        let recentUsage = usage(day: recentDay, mtimeUnixMs: 2)
        var cache = CostUsageCache()
        cache.scanSinceKey = retainedWindow.sinceKey
        cache.scanUntilKey = retainedWindow.untilKey
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        cache.files = [olderPath: olderUsage, recentPath: recentUsage]
        cache.days = olderUsage.days.merging(recentUsage.days) { _, recent in recent }

        let seeded = store.syncSaveCodexCache(
            cache,
            calendar: calendar,
            requestedScanWindow: retainedWindow,
            fileBudgetBytes: 1)
        #expect(seeded.deletedRows == 0)
        #expect(seeded.rowCount == 2)

        let dashboardWindows = [
            (sinceKey: "2026-07-16", skipIdenticalContent: true),
            (sinceKey: "2026-08-08", skipIdenticalContent: false),
        ]
        for dashboardWindow in dashboardWindows {
            let result = store.syncSaveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: (sinceKey: dashboardWindow.sinceKey, untilKey: recentDay),
                fileBudgetBytes: 1,
                skipIdenticalContent: dashboardWindow.skipIdenticalContent)
            let report = await store.readReport(
                sinceDay: retainedWindow.sinceKey,
                untilDay: retainedWindow.untilKey)
            let metadata = await store.fetchMetadata()

            #expect(result.catchUpRequired == false)
            #expect(result.deletedRows == 0)
            #expect(result.rowCount == 2)
            #expect(result.fileBytes > 1)
            #expect(await store.fetchFile(path: olderPath) != nil)
            #expect(await store.fetchFile(path: recentPath) != nil)
            #expect(report.aggregates.map(\.day) == [olderDay, recentDay])
            #expect(metadata.scanSinceDay == retainedWindow.sinceKey)
            #expect(metadata.scanUntilDay == retainedWindow.untilKey)
        }
    }

    @Test
    func `row budget deletes oldest rows to cap`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        for index in 0..<10 {
            let file = Self.file(path: "/rollouts/\(index).jsonl", day: "2026-08-01", updatedAt: Int64(index))
            #expect(await store.upsertFile(file))
        }

        let result = await store.enforceBudgets(maxRows: 3, maxFileBytes: Int64.max)
        #expect(result.rowCount <= 3)
        #expect(result.deletedRows >= 7)
    }

    @Test
    func `file size budget reclaims bytes after incremental vacuum`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        for index in 0..<8 {
            let file = Self.file(path: "/rollouts/\(index).jsonl", day: "2026-08-01", updatedAt: Int64(index))
            #expect(await store.upsertFile(file))
            let row = CostUsageStoreUsageRow(
                path: file.path,
                rowIndex: 0,
                payload: Data(repeating: UInt8(index), count: 256 * 1024))
            #expect(await store.replaceUsageRows(path: file.path, rows: [row]))
        }
        let before = await store.fileSizeBytes()
        let limit = max(1, before / 2)

        let result = await store.enforceBudgets(maxRows: .max, maxFileBytes: limit)
        #expect(result.fileBytes < before)
        #expect(result.deletedRows > 0)
    }

    @Test
    func `empty append and merge are no ops`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)

        #expect(await store.appendTokenSnapshots([]))
        #expect(await store.mergeDayAggregates([]))
        #expect(await (store.readSnapshot()).files.isEmpty)
    }

    @Test
    func `budget pruning uses the requested window and narrows retained coverage`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.upsertFile(Self.file(path: "/rollouts/stale.jsonl", day: "2026-06-01", updatedAt: 1)))
        #expect(await store.upsertFile(Self.file(path: "/rollouts/current.jsonl", day: "2026-08-01", updatedAt: 2)))

        let result = await store.enforceBudgets(
            maxRows: 1,
            maxFileBytes: .max,
            requestedSinceDay: "2026-07-31",
            requestedUntilDay: "2026-08-02")

        #expect(result.rowCount == 1)
        #expect(await store.fetchFile(path: "/rollouts/stale.jsonl") == nil)
        #expect(await store.fetchFile(path: "/rollouts/current.jsonl") != nil)
        let metadata = await store.fetchMetadata()
        #expect(metadata.scanSinceDay == "2026-07-31")
        #expect(metadata.scanUntilDay == "2026-08-02")
    }

    @Test
    func `budget keeps a recently active zero day entry`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()
        let activeDate = try #require(CostUsageScanner.parseDayKey("2026-08-01", calendar: calendar))
        var active = Self.file(path: "/rollouts/active.jsonl", day: "2026-08-01", updatedAt: 1)
        active.coverageSinceDay = nil
        active.coverageUntilDay = nil
        active.mtimeUnixMs = Int64(activeDate.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        var stale = Self.file(path: "/rollouts/stale-zero.jsonl", day: "2026-08-01", updatedAt: 0)
        stale.coverageSinceDay = nil
        stale.coverageUntilDay = nil
        stale.mtimeUnixMs = 1
        #expect(await store.upsertFile(active))
        #expect(await store.upsertFile(stale))

        _ = await store.enforceBudgets(
            maxRows: 1,
            maxFileBytes: .max,
            requestedSinceDay: "2026-08-01",
            requestedUntilDay: "2026-08-02",
            calendar: calendar)

        #expect(await store.fetchFile(path: active.path) != nil)
        #expect(await store.fetchFile(path: stale.path) == nil)
    }

    @Test
    func `byte budget preserves in window data across repeated enforcement`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let day = "2026-08-01"
        let model = "gpt-5.5"
        for (index, path) in ["/rollouts/one.jsonl", "/rollouts/two.jsonl"].enumerated() {
            let file = Self.file(path: path, day: day, updatedAt: Int64(index))
            #expect(await store.upsertFile(file))
            #expect(await store.replaceUsageRows(path: path, rows: [CostUsageStoreUsageRow(
                path: path,
                rowIndex: 0,
                payload: Data(repeating: UInt8(index), count: 256 * 1024))]))
            #expect(await store.replaceFileDayAggregates(
                path: path,
                aggregates: [Self.aggregate(day: day, model: model, scale: 1)]))
        }
        #expect(await store.mergeDayAggregates([Self.aggregate(day: day, model: model, scale: 2)]))

        let first = await store.enforceBudgets(
            maxRows: .max,
            maxFileBytes: 1,
            requestedSinceDay: day,
            requestedUntilDay: day)
        let second = await store.enforceBudgets(
            maxRows: .max,
            maxFileBytes: 1,
            requestedSinceDay: day,
            requestedUntilDay: day)
        let report = await store.readReport(sinceDay: day, untilDay: day)

        #expect(first.catchUpRequired == false)
        #expect(second.catchUpRequired == false)
        #expect(first.deletedRows == 0)
        #expect(second.deletedRows == 0)
        #expect(first.rowCount == 2)
        #expect(second.rowCount == 2)
        #expect(first.fileBytes > 1)
        #expect(second.fileBytes > 1)
        #expect(await store.fetchUsageRows(path: "/rollouts/one.jsonl").count == 1)
        #expect(await store.fetchUsageRows(path: "/rollouts/two.jsonl").count == 1)
        #expect(report.aggregates == [Self.aggregate(day: day, model: model, scale: 2)])
        #expect(await store.fetchMetadata().catchUpPending == false)
    }

    @Test
    func `row budget never deletes files touching the requested window`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.upsertFile(Self.file(path: "/rollouts/stale.jsonl", day: "2026-06-01", updatedAt: 0)))
        #expect(await store.upsertFile(Self.file(path: "/rollouts/one.jsonl", day: "2026-08-01", updatedAt: 1)))
        #expect(await store.upsertFile(Self.file(path: "/rollouts/two.jsonl", day: "2026-08-02", updatedAt: 2)))

        let result = await store.enforceBudgets(
            maxRows: 1,
            maxFileBytes: .max,
            requestedSinceDay: "2026-08-01",
            requestedUntilDay: "2026-08-02")

        // The out-of-window file is pruned, but in-window files stay even though the row
        // count remains above the cap: the former entry budget never dropped in-window data.
        #expect(result.rowCount == 2)
        #expect(await store.fetchFile(path: "/rollouts/stale.jsonl") == nil)
        #expect(await store.fetchFile(path: "/rollouts/one.jsonl") != nil)
        #expect(await store.fetchFile(path: "/rollouts/two.jsonl") != nil)
        #expect(await store.fetchMetadata().catchUpPending == false)
    }

    @Test
    func `byte budget removes only data outside the requested window`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let stale = Self.file(path: "/rollouts/stale.jsonl", day: "2026-06-01", updatedAt: 0)
        let current = Self.file(path: "/rollouts/current.jsonl", day: "2026-08-01", updatedAt: 1)
        for file in [stale, current] {
            #expect(await store.upsertFile(file))
            #expect(await store.replaceUsageRows(path: file.path, rows: [CostUsageStoreUsageRow(
                path: file.path,
                rowIndex: 0,
                payload: Data(repeating: 7, count: 256 * 1024))]))
        }

        let result = await store.enforceBudgets(
            maxRows: .max,
            maxFileBytes: 1,
            requestedSinceDay: "2026-08-01",
            requestedUntilDay: "2026-08-02")

        #expect(result.deletedRows == 1)
        #expect(result.rowCount == 1)
        #expect(result.fileBytes > 1)
        #expect(await store.fetchFile(path: stale.path) == nil)
        #expect(await store.fetchFile(path: current.path) != nil)
        #expect(await store.fetchUsageRows(path: current.path).count == 1)
        #expect(await store.fetchMetadata().catchUpPending == false)
    }

    @Test
    func `byte budget preserves fork parent detail required by a surviving child`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        var parent = Self.file(path: "/rollouts/parent.jsonl", day: "2026-06-01", updatedAt: 1)
        parent.sessionID = "parent-session"
        #expect(await store.upsertFile(parent))
        #expect(await store.upsertForkLineage(CostUsageStoreForkLineage(
            path: parent.path,
            sessionID: "parent-session",
            forkedFromID: nil,
            forkTimestamp: nil,
            dependencyKey: nil,
            subagentState: nil,
            accountingState: nil)))
        #expect(await store.replaceUsageRows(path: parent.path, rows: [CostUsageStoreUsageRow(
            path: parent.path,
            rowIndex: 0,
            payload: Data(repeating: 5, count: 256 * 1024))]))
        var child = Self.file(path: "/rollouts/child.jsonl", day: "2026-08-01", updatedAt: 2)
        child.sessionID = "child-session"
        child.scanState.isComplete = false
        var lineage = Self.lineage(path: child.path)
        lineage.forkedFromID = "parent-session"
        #expect(await store.upsertFile(child))
        #expect(await store.upsertForkLineage(lineage))

        let result = await store.enforceBudgets(
            maxRows: .max,
            maxFileBytes: 1,
            requestedSinceDay: "2026-08-01",
            requestedUntilDay: "2026-08-02")

        let retained = try #require(await store.fetchFile(path: parent.path))
        #expect(result.catchUpRequired == false)
        #expect(retained.parsedBytes == parent.parsedBytes)
        #expect(retained.scanState.isComplete)
        #expect(await store.fetchUsageRows(path: parent.path).count == 1)
        #expect(await store.fetchFile(path: child.path) != nil)
        #expect(await store.fetchMetadata().catchUpPending == false)
    }

    @Test
    func `read only WAL reader keeps a consistent snapshot during write`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.upsertFile(Self.file(path: "/rollouts/one.jsonl", day: "2026-08-01")))
        let reader = try SQLiteTestConnection(url: store.databaseURL, readOnly: true)
        try reader.execute("BEGIN")
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM files") == 1)

        #expect(await store.upsertFile(Self.file(path: "/rollouts/two.jsonl", day: "2026-08-01")))
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM files") == 1)
        try reader.execute("COMMIT")
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM files") == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func `write lock held by another process skips the write instead of deleting the store`() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.upsertFile(Self.file(path: "/rollouts/one.jsonl", day: "2026-08-01")))

        // The CLI cost command scans through CostUsageFetcher and therefore opens its own
        // writable store connection. Hold that cross-process lock past the 5s busy timeout.
        let holder = try SQLiteTestConnection(url: store.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        try holder.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('holder', '1')")

        let blocked = await store.upsertFile(Self.file(path: "/rollouts/two.jsonl", day: "2026-08-02"))
        #expect(blocked == false)
        #expect(await store.rebuildCount == 0)
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))

        try holder.execute("COMMIT")
        #expect(await store.upsertFile(Self.file(path: "/rollouts/two.jsonl", day: "2026-08-02")))
        let reader = try SQLiteTestConnection(url: store.databaseURL, readOnly: true)
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM files") == 2)
        #expect(await store.rebuildCount == 0)
    }
}

// MARK: - Fixtures

extension CostUsageStoreTests {
    private static func file(
        path: String,
        day: String,
        updatedAt: Int64 = 10) -> CostUsageStoreFile
    {
        CostUsageStoreFile(
            path: path,
            inode: 42,
            mtimeUnixMs: 1000,
            size: 500,
            parsedBytes: 400,
            anchor: CostUsageStoreValidationAnchor(indexedBytes: 400, windowStart: 144, sha256: "abc123"),
            scanState: CostUsageStoreScanState(
                targetSize: 500,
                isComplete: true,
                resumePayload: Data([1, 2, 3]),
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 7,
                lastModel: "gpt-5.6-sol",
                lastTurnID: "turn-1",
                fileIdentity: "1:42",
                detailsPayload: Data([4, 5, 6])),
            sessionID: "session-\(path)",
            coverageSinceDay: day,
            coverageUntilDay: day,
            updatedAtUnixMs: updatedAt)
    }

    private static func snapshot(
        path: String,
        eventIndex: Int,
        day: String = "2026-08-01") -> CostUsageStoreTokenSnapshot
    {
        CostUsageStoreTokenSnapshot(
            path: path,
            eventIndex: eventIndex,
            timestamp: "2026-08-01T12:00:00Z",
            timestampUnixMs: 1_754_046_000_000 + Int64(eventIndex),
            day: day,
            last: CostUsageStoreTotals(input: 2, cached: 1, output: 3, reasoning: 1),
            total: CostUsageStoreTotals(input: 20, cached: 10, output: 30, reasoning: 5),
            endOffset: 100 + Int64(eventIndex))
    }

    private static func aggregate(
        day: String,
        model: String,
        scale: Int64) -> CostUsageStoreDayAggregate
    {
        CostUsageStoreDayAggregate(
            day: day,
            model: model,
            inputTokens: 10 * scale,
            cachedTokens: 2 * scale,
            outputTokens: 3 * scale,
            reasoningTokens: 1 * scale,
            requestCount: 1 * scale,
            authoritativeCostNanos: 1000 * scale,
            standardInputTokens: 6 * scale,
            standardCachedTokens: 1 * scale,
            standardOutputTokens: 2 * scale,
            priorityInputTokens: 4 * scale,
            priorityCachedTokens: 1 * scale,
            priorityOutputTokens: 1 * scale,
            standardTokens: 9 * scale,
            priorityTokens: 6 * scale)
    }

    private static func lineage(path: String) -> CostUsageStoreForkLineage {
        CostUsageStoreForkLineage(
            path: path,
            sessionID: "child-session",
            forkedFromID: "parent-session",
            forkTimestamp: "2026-08-01T11:00:00Z",
            dependencyKey: "parent-key",
            subagentState: Data([4, 5]),
            accountingState: Data([6, 7]))
    }

    private static func bufferedLine(
        path: String,
        kind: CostUsageStoreBufferedLineKind,
        index: Int) -> CostUsageStoreBufferedLine
    {
        CostUsageStoreBufferedLine(
            path: path,
            kind: kind,
            lineIndex: index,
            ordinal: index + 10,
            endOffset: Int64(index + 100),
            payload: Data([UInt8(index), 9, 8]))
    }

    private static func discoveryState(paths: [String]) -> CostUsageStoreDiscoveryState {
        CostUsageStoreDiscoveryState(
            roots: ["/root"],
            generation: "generation-1",
            directoryPaths: ["/root/2026/08/01"],
            nextDirectoryIndex: 1,
            filePaths: paths,
            nextFileIndex: paths.count,
            filePathBySessionID: paths.isEmpty ? [:] : ["old-session": paths[0]],
            missingSessionIDs: ["old-session"],
            pendingSessionIDs: ["old-session"],
            validationDirectoryIndex: 2,
            isComplete: false,
            payload: Data([1, 3, 5]))
    }

    private static func accumulator(path: String) -> CostUsageStoreAccumulator {
        CostUsageStoreAccumulator(
            path: path,
            eventCount: 12,
            nextUsageRowIndex: 9,
            countedTotals: CostUsageStoreTotals(input: 10, cached: 2, output: 3, reasoning: 1),
            rawTotalsBaseline: CostUsageStoreTotals(input: 8, cached: 1, output: 2, reasoning: nil),
            rawTotalsWatermark: CostUsageStoreTotals(input: 12, cached: 3, output: 4, reasoning: 1),
            sawDivergentTotals: true,
            sawInterleavedTotals: true,
            seenRawTotals: [CostUsageStoreTotals(input: 9, cached: 1, output: 2, reasoning: nil)],
            updatedAtUnixMs: 99)
    }

    private static func metadata() -> CostUsageStoreMetadata {
        CostUsageStoreMetadata(
            lastScanUnixMs: 100,
            scanSinceDay: "2026-08-01",
            scanUntilDay: "2026-08-03",
            timeZoneIdentifier: "UTC",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            catchUpPending: true,
            processedBytes: 100,
            totalBytes: 200,
            completedFiles: 2,
            totalFiles: 4,
            scanInventoryPaths: ["/root/2026/08/01/session.jsonl"],
            rootMtimes: ["/root": 123],
            previousReportPayload: Data([2, 4, 6]),
            priorityTurnStatePayload: Data([1, 3, 5]),
            projectMetadataVersion: 2)
    }
}

private struct StoreFixture: Sendable {
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    var databaseURL: URL {
        self.root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("cost-usage.sqlite", isDirectory: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private final class SQLiteTestConnection: @unchecked Sendable {
    enum TestError: Error {
        case sqlite(Int32)
    }

    private var database: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(url.path, &self.database, flags, nil)
        guard result == SQLITE_OK else { throw TestError.sqlite(result) }
        sqlite3_busy_timeout(self.database, 5000)
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(self.database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw TestError.sqlite(result) }
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(self.database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw TestError.sqlite(prepare) }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw TestError.sqlite(result) }
        return sqlite3_column_int64(statement, 0)
    }

    static func execute(at url: URL, sql: String) throws {
        try Self(url: url).execute(sql)
    }

    static func indexNames(at url: URL) throws -> Set<String> {
        let connection = try Self(url: url, readOnly: true)
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            connection.database,
            "SELECT name FROM sqlite_master WHERE type = 'index'",
            -1,
            &statement,
            nil)
        guard result == SQLITE_OK, let statement else { throw TestError.sqlite(result) }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: value))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw TestError.sqlite(step) }
        return names
    }
}
