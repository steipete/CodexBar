import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageStoreReadWorkTests {
    @Test(arguments: [2, 16])
    func `characterize valid store and caller reads`(fileCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: fileCount == 2 ? 4 : 64)
        defer { fixture.remove() }
        let persisted = await fixture.store.readSnapshot()
        let configuration = try #require(await fixture.store.configuration())
        let fileBytes = await fixture.store.fileSizeBytes()
        #expect(persisted.files.count == fileCount)
        #expect(persisted.usageRows.count == fixture.rowCount)
        #expect(persisted.tokenSnapshots.count == fixture.rowCount)
        #expect(persisted.fileDayAggregates.count == fileCount)
        #expect(persisted.dayAggregates.count == 1)
        print("[cost-store-read-proof] files=\(fileCount) rows=\(fixture.rowCount) " +
            "schema=\(configuration.userVersion) db_bytes=\(fileBytes)")

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let (sameStore, _) = await Self.measure("same-store-load", fixture: fixture, recorder: recorder) {
            fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        }
        #expect(sameStore == fixture.canonical)
        let (freshStore, _) = await Self.measure("fresh-access-read", fixture: fixture, recorder: recorder) {
            CostUsageStoreAccess.read(cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar)
        }
        #expect(freshStore == fixture.canonical)
        let (status, _) = await Self.measure("status-only", fixture: fixture, recorder: recorder) {
            await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        }
        fixture.expectStatus(status)
        let (cached, _) = await Self.measure("cached-totals", fixture: fixture, recorder: recorder) {
            await fixture.cachedSnapshot()
        }
        try fixture.expectSnapshot(cached)
        let (detailed, detailedWork) = await Self.measure(
            "cached-default-details",
            fixture: fixture,
            recorder: recorder)
        {
            await fixture.cachedSnapshot(details: true)
        }
        try fixture.expectSnapshot(detailed, details: true)
        #expect(detailedWork.usageRows == fixture.rowCount)
        #expect(detailedWork.usagePayloadBytes > 0)
        #expect(detailedWork.tokenSnapshotRows == 0)
        #expect(detailedWork.accumulatorRows == 0)
        let (fullDetailed, _) = await Self.measure(
            "full-load-details-baseline", fixture: fixture, recorder: recorder)
        {
            fixture.fullCachedSnapshot()
        }
        #expect(detailed?.snapshot == fullDetailed)

        var refreshed = fixture.canonical
        refreshed.lastScanUnixMs += 1000
        let before = await fixture.store.persistenceWriteMetricsForTesting()
        let (unchanged, unchangedWork) = await Self.measure(
            "unchanged-save-without-receipt",
            fixture: fixture,
            recorder: recorder)
        {
            fixture.save(refreshed)
        }
        let after = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(!unchanged.catchUpRequired)
        #expect(unchangedWork.fullSnapshotReads == 1)
        #expect(unchangedWork.usageRowDecodeAttempts == fixture.rowCount)
        #expect(unchangedWork.aggregateGroupingRowVisits == 0)
        #expect(unchanged.deletedRows == 0)
        #expect(after.rows - before.rows == 1)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == refreshed)

        var changed = refreshed
        changed.codexProjectMetadataVersion = (changed.codexProjectMetadataVersion ?? 0) + 1
        let (metadataSave, _) = await Self.measure("metadata-only-save", fixture: fixture, recorder: recorder) {
            fixture.save(changed)
        }
        let changedWrites = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(!metadataSave.catchUpRequired)
        #expect(metadataSave.deletedRows == 0)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == changed)
        print("[cost-store-read-proof] files=\(fileCount) unchanged_row_writes=\(after.rows - before.rows) " +
            "metadata_only_row_writes=\(changedWrites.rows - after.rows)")
    }

    @Test
    func `scanner load and unchanged save skip file histories`() throws {
        let rowsPerFile = 64
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: rowsPerFile)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let loaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let loadWork = recorder.snapshot()
        #expect(loadWork.scannerSnapshotReads == 1)
        #expect(loadWork.fullSnapshotReads == 0)
        #expect(loadWork.tokenSnapshotRows == 0)
        #expect(loadWork.usageRows == fixture.rowCount)
        #expect(loadWork.usageRowDecodeAttempts == fixture.rowCount)
        #expect(loaded.unloadedTokenSnapshotPaths.count == fixture.fileCount)
        #expect(loaded.cache.files.values.allSatisfy { $0.codexTokenSnapshots == nil })
        #expect(loaded.cache.files.values.allSatisfy { $0.codexTurnIDs?.count == rowsPerFile })

        let selectedPath = try #require(loaded.cache.files.keys.min())
        recorder.reset()
        let selected = try #require(loaded.store.syncLoadCodexTokenSnapshotsIfAvailable(
            paths: Set([selectedPath]), receipt: loaded.receipt))
        #expect(selected[selectedPath]?.count == rowsPerFile)
        #expect(recorder.snapshot().tokenSnapshotRows == rowsPerFile)
        #expect(loaded.cache.files[selectedPath]?.codexRows?.count == rowsPerFile)

        var refreshed = loaded.cache
        refreshed.lastScanUnixMs += 1000
        recorder.reset()
        let saved = try CostUsageStoreAccess.save(
            store: loaded.store,
            cache: refreshed,
            calendar: fixture.calendar,
            requestedScanWindow: (
                sinceKey: #require(refreshed.scanSinceKey),
                untilKey: #require(refreshed.scanUntilKey)),
            unloadedTokenSnapshotPaths: loaded.unloadedTokenSnapshotPaths,
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        let saveWork = recorder.snapshot()
        #expect(!saved.catchUpRequired)
        #expect(saveWork.scannerSnapshotReads == 0)
        #expect(saveWork.fullSnapshotReads == 0)
        #expect(saveWork.tokenSnapshotRows == 0)
        #expect(saveWork.usageRows == 0)
        #expect(saveWork.usageRowDecodeAttempts == 0)

        var expected = fixture.canonical
        expected.lastScanUnixMs = refreshed.lastScanUnixMs
        #expect(loaded.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)

        let reloaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        var partiallyHydrated = reloaded.cache
        var selectedUsage = try #require(partiallyHydrated.files[selectedPath])
        let selectedSnapshots = (selected[selectedPath] ?? []).map(CostUsageStore.tokenSnapshot(from:))
        selectedUsage.codexTokenSnapshots = selectedSnapshots
        selectedUsage.codexTokenCheckpoints = CostUsageScanner.codexTokenCheckpoints(for: selectedSnapshots)
        partiallyHydrated.files[selectedPath] = selectedUsage
        partiallyHydrated.lastScanUnixMs += 1000
        var remainingUnloadedPaths = reloaded.unloadedTokenSnapshotPaths
        remainingUnloadedPaths.remove(selectedPath)
        recorder.reset()
        _ = try CostUsageStoreAccess.save(
            store: reloaded.store,
            cache: partiallyHydrated,
            calendar: fixture.calendar,
            requestedScanWindow: (
                sinceKey: #require(partiallyHydrated.scanSinceKey),
                untilKey: #require(partiallyHydrated.scanUntilKey)),
            unloadedTokenSnapshotPaths: remainingUnloadedPaths,
            skipIdenticalContent: true,
            receipt: reloaded.receipt)
        let partialSaveWork = recorder.snapshot()
        #expect(partialSaveWork.scannerSnapshotReads == 0)
        #expect(partialSaveWork.fullSnapshotReads == 0)
        #expect(partialSaveWork.tokenSnapshotRows == 0)
        #expect(partialSaveWork.usageRows == 0)
        #expect(partialSaveWork.usageRowDecodeAttempts == 0)

        expected.lastScanUnixMs = partiallyHydrated.lastScanUnixMs
        #expect(reloaded.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
    }

    @Test
    func `pricing migration hydrates exact rows before accepting freshness`() throws {
        let rowsPerFile = 4
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: rowsPerFile)
        defer { fixture.remove() }
        let selectedPath = try #require(fixture.canonical.files.keys.min())
        var baseline = fixture.canonical
        var selectedUsage = try #require(baseline.files[selectedPath])
        selectedUsage.codexCostCacheComplete = false
        selectedUsage.codexRows = selectedUsage.codexRows?.map { row in
            CostUsageScanner.CodexUsageRow(
                day: row.day,
                model: row.model,
                rawModel: row.rawModel,
                turnID: row.turnID,
                eventIndex: row.eventIndex,
                timestampUnixMs: row.timestampUnixMs,
                input: row.input,
                cached: row.cached,
                output: row.output,
                reasoning: row.reasoning,
                knownCostNanos: row.knownCostNanos,
                unpricedTokens: row.unpricedTokens,
                pricingModel: nil,
                pricingMode: nil)
        }
        baseline.files[selectedPath] = selectedUsage
        #expect(!fixture.save(baseline).catchUpRequired)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        let work = recorder.snapshot()

        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows >= rowsPerFile)
        #expect(work.usageRowDecodeAttempts >= rowsPerFile)
        let migrated = fixture.store.syncLoadCodexCache(calendar: fixture.calendar).files[selectedPath]
        #expect(migrated?.codexCostCacheComplete == true)
        #expect(migrated?.codexRows?.allSatisfy { $0.pricingModel == $0.model && $0.pricingMode == "standard" } == true)
    }

    @Test
    func `history read failures retain unloaded markers and persisted rows`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let before = await fixture.store.readSnapshot()
        let loaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let selectedPath = try #require(loaded.cache.files.keys.min())
        let databaseURL = fixture.store.databaseURL
        CostUsageStore.codexTokenSnapshotReadFailureForTesting = { $0 == databaseURL && $1 == selectedPath }
        defer {
            CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil
        }

        let history = CostUsageScanner.CodexScanHistoryHydrator(load: loaded)
        var cache = loaded.cache
        let hydrated = history.hydrate(
            for: [URL(fileURLWithPath: selectedPath)],
            cache: &cache)
        #expect(hydrated.isEmpty)
        #expect(history.unloadedTokenPaths.contains(selectedPath))
        #expect(cache.files[selectedPath]?.codexTokenSnapshots == nil)

        cache.lastScanUnixMs += 1000
        let result = try CostUsageStoreAccess.save(
            store: loaded.store,
            cache: cache,
            calendar: fixture.calendar,
            requestedScanWindow: (
                sinceKey: #require(cache.scanSinceKey),
                untilKey: #require(cache.scanUntilKey)),
            unloadedTokenSnapshotPaths: history.unloadedTokenPaths,
            skipIdenticalContent: true)
        #expect(!result.catchUpRequired)

        CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil
        let after = await fixture.store.readSnapshot()
        #expect(after.tokenSnapshots == before.tokenSnapshots)
        #expect(after.usageRows == before.usageRows)
    }

    @Test
    func `scanner preserves failed history reads and retries changed files`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 4)
        defer { fixture.remove() }
        let selectedPath = try #require(fixture.canonical.files.keys.min())
        let originalUsage = try #require(fixture.canonical.files[selectedPath])
        let before = await fixture.store.readSnapshot()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: selectedPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let changedMetadata = CostUsageScanner.codexFileMetadata(fileURL: URL(fileURLWithPath: selectedPath))
        #expect(changedMetadata.size > originalUsage.size)

        let databaseURL = fixture.store.databaseURL
        CostUsageStore.codexTokenSnapshotReadFailureForTesting = {
            $0 == databaseURL && $1 == selectedPath
        }
        defer {
            CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil
        }
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil

        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        let deferred = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(deferred.files[selectedPath]?.size == originalUsage.size)
        #expect(deferred.files[selectedPath]?.mtimeUnixMs == originalUsage.mtimeUnixMs)
        #expect(deferred == fixture.canonical)
        let after = await fixture.store.readSnapshot()
        #expect(after.tokenSnapshots == before.tokenSnapshots)
        #expect(after.usageRows == before.usageRows)

        let retry = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(2),
            options: options)
        #expect(retry.summary?.totalTokens == report.summary?.totalTokens)
        let resumed = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(resumed.files[selectedPath]?.size == changedMetadata.size)
        #expect(resumed.codexScanCatchUpPending != true)
    }

    @Test
    func `alias migration defers on history failure then retries losslessly`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let oldPath = try #require(fixture.canonical.files.keys.min())
        let newURL = fixture.env.codexSessionsRoot.appendingPathComponent("renamed-after-failure.jsonl")
        let before = await fixture.store.readSnapshot()
        try FileManager.default.moveItem(at: URL(fileURLWithPath: oldPath), to: newURL)

        let databaseURL = fixture.store.databaseURL
        CostUsageStore.codexTokenSnapshotReadFailureForTesting = {
            $0 == databaseURL && $1 == oldPath
        }
        defer {
            CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil
        }
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0

        let deferredReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        CostUsageStore.codexTokenSnapshotReadFailureForTesting = nil

        #expect(deferredReport.summary?.totalTokens == fixture.rowCount * 13)
        let deferred = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(deferred.files[oldPath] != nil)
        #expect(deferred.files[newURL.path] == nil)
        let afterFailure = await fixture.store.readSnapshot()
        #expect(afterFailure.tokenSnapshots == before.tokenSnapshots)
        #expect(afterFailure.usageRows == before.usageRows)

        let retriedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(2),
            options: options)
        #expect(retriedReport.summary?.totalTokens == fixture.rowCount * 13)
        let migrated = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(migrated.files[oldPath] == nil)
        #expect(migrated.files[newURL.path]?.codexTokenSnapshots?.count == 4)
        #expect(migrated.files[newURL.path]?.codexRows?.count == 4)
    }

    #if canImport(SQLite3)
    @Test
    func `unrelated priority changes keep exact rows without token history loads`() throws {
        let rowsPerFile = 64
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: rowsPerFile)
        defer { fixture.remove() }
        let databaseURL = try #require(fixture.options.codexTraceDatabaseURL)
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: databaseURL)
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path) }

        var baseline = fixture.canonical
        baseline.codexPriorityMetadataKey = "sqlite:\(databaseURL.standardizedFileURL.path)"
        baseline.codexPriorityTurnKeys = [:]
        baseline.codexPriorityTurnIDsByDay = [:]
        #expect(!fixture.save(baseline).catchUpRequired)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: databaseURL,
            epochSeconds: Int64(fixture.now.timeIntervalSince1970),
            body: "thread_id=external turn.id=unrelated-priority-turn websocket request: " +
                #"{"type":"response.create","model":"gpt-5.4","service_tier":"priority"}"#)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let scanRecorder = CostUsageScanner.CodexScanWorkRecorder()
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0
        options.codexScanWorkRecorderForTesting = scanRecorder

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        let work = recorder.snapshot()
        CostUsageStore.readWorkRecorderForTesting = nil

        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
        let scanWork = scanRecorder.snapshot()
        #expect(scanWork.usageRowsProcessed == 0)
        #expect(scanWork.usageRowsRepriced == 0)
        let reloaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        #expect(reloaded.cache.files.values.allSatisfy { $0.codexTurnIDs?.count == rowsPerFile })
    }
    #endif

    @Test
    func `debounced scanner refresh skips file histories end to end`() throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: fixture.options)
        let work = recorder.snapshot()
        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        #expect(work.scannerSnapshotReads == 1)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
    }

    @Test
    func `routine scanner refresh skips unchanged file histories end to end`() throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        let work = recorder.snapshot()
        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        #expect(work.scannerSnapshotReads == 1)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
    }

    @Test
    func `renamed session preserves lazily loaded histories`() throws {
        let rowsPerFile = 4
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: rowsPerFile)
        defer { fixture.remove() }
        let oldPath = try #require(fixture.canonical.files.keys.min())
        let newURL = fixture.env.codexSessionsRoot.appendingPathComponent("renamed-session.jsonl")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: oldPath), to: newURL)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        var options = fixture.options
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now.addingTimeInterval(1),
            options: options)
        let work = recorder.snapshot()
        CostUsageStore.readWorkRecorderForTesting = nil

        #expect(report.summary?.totalTokens == fixture.rowCount * 13)
        #expect(work.tokenSnapshotRows == rowsPerFile)
        #expect(work.usageRows == fixture.rowCount)
        let persisted = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(persisted.files[oldPath] == nil)
        #expect(persisted.files[newURL.path]?.codexTokenSnapshots?.count == rowsPerFile)
        #expect(persisted.files[newURL.path]?.codexRows?.count == rowsPerFile)
        #expect(persisted.files[newURL.path]?.days == fixture.canonical.files[oldPath]?.days)
    }

    @Test
    func `new fork child hydrates only its cached parent history`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.2-codex"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "cached-parent.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"cached-parent"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
                #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                    + #""model":"\#(model)"}}}"#,
            ].joined(separator: "\n") + "\n")
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "unrelated.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"unrelated"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"last_token_usage":{"input_tokens":40,"cached_input_tokens":4,"output_tokens":2},"#
                    + #""model":"\#(model)"}}}"#,
            ].joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "new-child.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"new-child","#
                    + #""forked_from_id":"cached-parent"}}"#,
                #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"\#(model)"}}"#,
                #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                    + #""model":"\#(model)"}}}"#,
            ].joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: childURL.path)

        var baselineOptions = options
        baselineOptions.cacheRoot = env.root.appendingPathComponent("baseline-cache")
        let baselineReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: baselineOptions)
        let baselineCache = CostUsageStoreAccess.read(cacheRoot: baselineOptions.cacheRoot)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let incrementalReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: options)
        let work = recorder.snapshot()
        CostUsageStore.readWorkRecorderForTesting = nil
        let incrementalCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let baselineChild = try #require(baselineCache.files.values.first { $0.sessionId == "new-child" })
        let incrementalChild = try #require(incrementalCache.files.values.first { $0.sessionId == "new-child" })

        #expect(incrementalReport.summary?.totalTokens == baselineReport.summary?.totalTokens)
        #expect(incrementalCache.days == baselineCache.days)
        #expect(incrementalCache.files.mapValues(\.codexRows) == baselineCache.files.mapValues(\.codexRows))
        let incrementalCost = try #require(incrementalReport.summary?.totalCostUSD)
        let baselineCost = try #require(baselineReport.summary?.totalCostUSD)
        // Dictionary traversal can change the last floating-point bit when summing identical rows.
        #expect(abs(incrementalCost - baselineCost) < 1e-12)
        #expect(incrementalChild.days == baselineChild.days)
        #expect(incrementalChild.forkBaselineDependencyKey?.hasPrefix("file|cached-parent|") == true)
        #expect(work.tokenSnapshotRows == 1)
        #expect(work.usageRows == 2)
        #expect(work.usageRowDecodeAttempts == 2)
    }

    @Test
    func `metadata save preserves unloaded histories and aggregates`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let before = await fixture.store.readSnapshot()
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let loaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        var changed = loaded.cache
        changed.codexProjectMetadataVersion = (changed.codexProjectMetadataVersion ?? 0) + 1

        recorder.reset()
        let result = try CostUsageStoreAccess.save(
            store: loaded.store,
            cache: changed,
            calendar: fixture.calendar,
            requestedScanWindow: (
                sinceKey: #require(changed.scanSinceKey),
                untilKey: #require(changed.scanUntilKey)),
            unloadedTokenSnapshotPaths: loaded.unloadedTokenSnapshotPaths,
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        let work = recorder.snapshot()
        #expect(!result.catchUpRequired)
        #expect(work.scannerSnapshotReads == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == 0)
        #expect(work.usageRowDecodeAttempts == 0)

        let after = await fixture.store.readSnapshot()
        #expect(after.tokenSnapshots == before.tokenSnapshots)
        #expect(after.usageRows == before.usageRows)
        #expect(after.fileDayAggregates == before.fileDayAggregates)
        #expect(after.dayAggregates == before.dayAggregates)
        #expect(after.accumulators == before.accumulators)
        var expected = fixture.canonical
        expected.codexProjectMetadataVersion = changed.codexProjectMetadataVersion
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
    }

    @Test
    func `recorder excludes other database paths and preserves read results`() async throws {
        let observed = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { observed.remove() }
        let other = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { other.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: observed.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        #expect(CostUsageStoreAccess.read(cacheRoot: other.env.cacheRoot, calendar: other.calendar) == other.canonical)
        #expect(!other.save(other.canonical).catchUpRequired)
        #expect(recorder.snapshot() == CostUsageStoreReadWorkMetrics())

        let snapshot = await observed.store.readSnapshot()
        #expect(recorder.snapshot().fullSnapshotReads == 1)
        #expect(recorder.snapshot().usageRows == snapshot.usageRows.count)
        #expect(recorder.snapshot().usagePayloadBytes == snapshot.usageRows.reduce(0) { $0 + $1.payload.count })
        #expect(recorder.snapshot().cacheConversions == 0)
        recorder.reset()
        #expect(recorder.snapshot() == CostUsageStoreReadWorkMetrics())
        #expect(observed.store.syncLoadCodexCache(calendar: observed.calendar) == observed.canonical)
        recorder.reset()
        let path = try #require(observed.canonical.files.keys.min())
        let rows = await observed.store.fetchUsageRows(path: path)
        let tokens = await observed.store.fetchTokenSnapshots(path: path)
        #expect(recorder.snapshot().fullSnapshotReads == 0)
        #expect(recorder.snapshot().usageRows == rows.count)
        #expect(recorder.snapshot().usagePayloadBytes == rows.reduce(0) { $0 + $1.payload.count })
        #expect(recorder.snapshot().tokenSnapshotRows == tokens.count)
    }

    @Test(arguments: [false, true])
    func `complete and incomplete controls retain totals and reject other scopes`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let status = await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        fixture.expectStatus(status)
        try await fixture.expectSnapshot(fixture.cachedSnapshot())

        var otherScope = fixture.options
        otherScope.codexSessionsRoot = fixture.env.root.appendingPathComponent("other-home/sessions")
        let rejected = await CostUsageFetcher(scannerOptions: otherScope).codexScanCatchUpStatus()
        #expect(rejected == .init(pending: false, progressKey: "scope-mismatch"))
        #expect(await fixture.cachedSnapshot(options: otherScope) == nil)
        #expect(await fixture.cachedSnapshot(historyDays: 365) == nil)

        var otherCalendar = fixture.options
        otherCalendar.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(await fixture.cachedSnapshot(options: otherCalendar) == nil)
    }

    @Test(arguments: [false, true])
    func `status reads progress without historical usage payloads`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let (status, work) = await Self.measure("status-contract", fixture: fixture, recorder: recorder) {
            await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        }
        fixture.expectStatus(status)

        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.usageRowDecodeAttempts == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.bufferedPayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.fileRows == fixture.fileCount)
        #expect(work.retryPresenceRows == (incomplete ? 1 : 0))
        #expect(work.integrityChecks == 1)
        #expect(work.readViewConversions == 1)
        #expect(work.readViewConversionsInTransaction == 0)
    }

    @Test(arguments: [false, true])
    func `cached totals exclude raw token and replay details`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let (cached, work) = await Self.measure("report-contract", fixture: fixture, recorder: recorder) {
            await fixture.cachedSnapshot()
        }
        try fixture.expectSnapshot(cached)

        #expect(work.tokenSnapshotRows == 0)
        #expect(work.bufferedLines == 0)
        #expect(work.bufferedPayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
        #expect(work.usagePayloadBytes > 0)
        #expect(work.retryPresenceRows == (incomplete ? 1 : 0))
        #expect(work.readViewConversions == 1)
        #expect(work.readViewConversionsInTransaction == 0)
    }

    private static func measure<Value>(
        _ operation: String,
        fixture: ReadWorkFixture,
        recorder: CostUsageStoreReadWorkRecorder,
        work: () async -> Value) async -> (Value, CostUsageStoreReadWorkMetrics)
    {
        recorder.reset()
        let started = ContinuousClock.now
        let value = await work()
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let metrics = recorder.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(metrics)).flatMap { String(data: $0, encoding: .utf8) } ?? "encoding-failed"
        print("[cost-store-read-proof] files=\(fixture.fileCount) rows=\(fixture.rowCount) " +
            "incomplete=\(fixture.incomplete) op=\(operation) elapsed_ms=\(milliseconds) metrics=\(json)")
        return (value, metrics)
    }
}

struct ReadWorkFixture {
    static let day = "2026-08-01"
    static let model = "gpt-5.4"
    let env: CostUsageTestEnvironment
    let calendar: Calendar
    let now: Date
    let options: CostUsageScanner.Options
    let store: CostUsageStore
    let canonical: CostUsageCache
    let fileCount: Int
    let rowCount: Int
    let incomplete: Bool

    init(fileCount: Int, rowsPerFile: Int, incomplete: Bool = false) throws {
        let env = try CostUsageTestEnvironment()
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)))
            let trace = env.root.appendingPathComponent("missing-trace.sqlite")
            let options = CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                claudeProjectsRoots: [env.claudeProjectsRoot],
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: trace,
                calendar: calendar)
            let range = CostUsageScanner.CostUsageDayRange(since: now, until: now, calendar: calendar)
            var cache = CostUsageCache()
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.timeZoneIdentifier = calendar.timeZone.identifier
            cache.lastScanUnixMs = Int64(now.timeIntervalSince1970 * 1000)
            cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
            cache.codexPricingKey = CostUsageScanner.codexPricingKey(modelsDevArtifact: nil)
            cache.codexPriorityMetadataKey = "missing:\(trace.standardizedFileURL.path)"
            cache.codexProjectMetadataVersion = CostUsageScanner.codexProjectMetadataVersion
            for index in 0..<fileCount {
                let url = env.codexSessionsRoot.appendingPathComponent("fixture-\(index).jsonl")
                cache.files[url.path] = try Self.usage(
                    url: url, index: index, rowCount: rowsPerFile, incomplete: incomplete && index == 0)
            }
            cache.days = [Self.day: [Self.model: [
                fileCount * rowsPerFile * 10,
                fileCount * rowsPerFile * 2,
                fileCount * rowsPerFile * 3,
            ]]]
            cache.codexScanCatchUpPending = incomplete
            cache.codexScanCompletedFiles = fileCount - (incomplete ? 1 : 0)
            cache.codexScanTotalFiles = fileCount
            cache.codexScanProcessedBytes = cache.files.values.reduce(0) { $0 + ($1.parsedBytes ?? 0) }
            cache.codexScanTotalBytes = cache.files.values.reduce(0) { $0 + $1.size }
            cache.codexScanInventoryPaths = cache.files.keys.sorted()
            let store = CostUsageStore(cacheRoot: env.cacheRoot)
            let saved = store.syncSaveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: (sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey))
            try #require(!saved.catchUpRequired)
            self.env = env
            self.calendar = calendar
            self.now = now
            self.options = options
            self.store = store
            self.canonical = store.syncLoadCodexCache(calendar: calendar)
            self.fileCount = fileCount
            self.rowCount = fileCount * rowsPerFile
            self.incomplete = incomplete
            #expect(self.canonical.files.count == fileCount)
            #expect(self.canonical.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) } == self.rowCount)
            #expect(self.canonical.files.values.allSatisfy { !CostUsageScanner.needsCodexPricingMetadata($0) })
        } catch {
            env.cleanup()
            throw error
        }
    }

    func save(_ cache: CostUsageCache) -> CostUsageStoreBudgetResult {
        self.store.syncSaveCodexCache(
            cache,
            calendar: self.calendar,
            requestedScanWindow: (sinceKey: self.canonical.scanSinceKey!, untilKey: self.canonical.scanUntilKey!),
            skipIdenticalContent: true)
    }

    func cachedSnapshot(
        options: CostUsageScanner.Options? = nil,
        historyDays: Int = 1,
        details: Bool = false) async -> CostUsageFetcher.CachedCodexTokenSnapshotResult?
    {
        if details {
            return await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
                now: self.now,
                historyDays: historyDays,
                includePiSessions: false,
                scannerOptions: options ?? self.options)
        }
        return await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: self.now,
            historyDays: historyDays,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            scannerOptions: options ?? self.options)
    }

    func expectStatus(_ status: CostUsageFetcher.CodexScanCatchUpStatus) {
        #expect(status.pending == self.incomplete)
        #expect(status.totalFiles == self.fileCount)
        #expect(status.completedFiles == self.fileCount - (self.incomplete ? 1 : 0))
        #expect(status.processedBytes == self.canonical.codexScanProcessedBytes)
        #expect(status.totalBytes == self.canonical.codexScanTotalBytes)
        #expect(status.progressKey == CostUsageFetcher.codexScanProgressKey(
            cache: self.canonical, scopedFiles: self.canonical.files))
    }

    func expectSnapshot(_ result: CostUsageFetcher.CachedCodexTokenSnapshotResult?, details: Bool = false) throws {
        let result = try #require(result)
        #expect(result.snapshot.historyCoverageIsEstablished == !self.incomplete)
        #expect(result.snapshot.last30DaysTokens == self.rowCount * 13)
        #expect(result.snapshot.sessionTokens == self.rowCount * 13)
        #expect(result.snapshot.daily.count == 1)
        let cost = try #require(result.snapshot.last30DaysCostUSD)
        #expect(abs(cost - Double(self.rowCount) * 0.001) < 0.000000001)
        if details {
            let range = CostUsageScanner.CostUsageDayRange(since: self.now, until: self.now, calendar: self.calendar)
            #expect(result.snapshot.projects == self.fullCachedSnapshot(cache: self.canonical).projects)
            #expect(result.snapshot.sessions == CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                cache: self.canonical,
                range: range,
                modelsDevCacheRoot: self.env.cacheRoot,
                sessionRoots: CostUsageScanner.codexSessionsRoots(options: self.options)))
            #expect(result.snapshot.projects.count == 1)
            #expect(result.snapshot.sessions.count == self.fileCount)
            #expect(result.snapshot.projects.first?.totalTokens == self.rowCount * 13)
            #expect(result.snapshot.sessions.allSatisfy { $0.totalTokens == self.rowCount / self.fileCount * 13 })
        } else {
            #expect(result.snapshot.projects.isEmpty)
            #expect(result.snapshot.sessions.isEmpty)
        }
        #expect(result.lastRefreshAt == self.now)
        #expect(result.snapshot.updatedAt == self.now)
    }

    func remove() {
        self.env.cleanup()
    }

    private static func usage(
        url: URL,
        index: Int,
        rowCount: Int,
        incomplete: Bool) throws -> CostUsageFileUsage
    {
        let timestamp = "2026-08-01T12:00:00Z"
        let tokenLine = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
        """
        let contents = Array(repeating: tokenLine, count: rowCount).joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
        var usage = CostUsageFileUsage(
            mtimeUnixMs: metadata.mtimeUnixMs,
            size: metadata.size,
            days: [Self.day: [Self.model: [rowCount * 10, rowCount * 2, rowCount * 3]]])
        usage.parsedBytes = metadata.size
        usage.codexScanFileId = metadata.fileId
        usage.codexScanTargetSize = metadata.size
        usage.codexScanComplete = !incomplete
        usage.sessionId = "fixture-session-\(index)"
        usage.projectPath = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("owned-project").path
        usage.canonicalProjectPath = usage.projectPath
        usage.codexSession = .init(sessionId: usage.sessionId, cwd: usage.projectPath, title: "Fixture \(index)")
        usage.lastCountedTotals = .init(input: rowCount * 10, cached: rowCount * 2, output: rowCount * 3)
        usage.codexCostCacheComplete = true
        usage.codexStandardTokens = [Self.day: [Self.model: rowCount * 13]]
        usage.codexTokenTimestampsMonotonic = true
        usage.codexRows = (0..<rowCount).map { event in
            CostUsageScanner.CodexUsageRow(
                day: Self.day,
                model: Self.model,
                turnID: "fixture-\(index)-\(event)",
                eventIndex: event,
                input: 10,
                cached: 2,
                output: 3,
                knownCostNanos: 1_000_000,
                pricingModel: Self.model,
                pricingMode: "standard")
        }
        usage.codexTurnIDs = CostUsageScanner.codexTurnIDs(rows: usage.codexRows ?? [])
        usage.codexTokenSnapshots = (0..<rowCount).map { event in
            CostUsageCodexTokenSnapshot(
                timestamp: timestamp,
                last: CostUsageCodexTotals(input: 10, cached: 2, output: 3),
                total: nil,
                endOffset: Int64((event + 1) * (tokenLine.utf8.count + 1)))
        }
        if incomplete {
            usage.codexBufferedUnresolvedForkLines = [CostUsageScanner.CodexBufferedFastLine(
                lineIndex: rowCount,
                ordinal: rowCount,
                endOffset: metadata.size,
                line: .taskStarted(turnID: "fixture-replay"))]
        }
        return usage
    }
}
