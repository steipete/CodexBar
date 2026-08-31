import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: ["anchor", "replacement", "retry"])
    func `save comparisons reconcile live anchors identities and retry presence`(change: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 4)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.first)
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        var file = try #require(await fixture.store.fetchFile(path: path))
        let inode = try #require(file.scanState.fileIdentity?.split(separator: ":").last)
        file.scanState.fileIdentity = "0:\(inode)"
        let anchor = try #require(CostUsageScanner.codexTokenIndexAnchor(fileURL: url, indexedBytes: file.size))
        file.anchor = .init(indexedBytes: anchor.indexedBytes, windowStart: anchor.windowStart, sha256: anchor.sha256)
        #expect(await fixture.store.upsertFile(file))
        var metadata = await fixture.store.fetchMetadata()
        metadata.catchUpPending = true
        // No root-device shortcut: completion must revalidate the persisted inode and anchor.
        metadata.rootMtimes = [:]
        #expect(await fixture.store.setMetadata(metadata))
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.codexScanCatchUpPending == false)
        var incoming = loaded.cache
        incoming.lastScanUnixMs += 1000
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.identicalContentPreLockCheckpointForTesting = (fixture.store.databaseURL, {
            do {
                if change == "retry" {
                    try writer.execute("""
                    INSERT INTO buffered_lines(file_id, kind, line_index, ordinal, end_offset, payload)
                    SELECT id, 'unresolvedFork', 0, 0, size, X'00' FROM files
                    """)
                } else {
                    let bytes = Data(repeating: 32, count: Int(file.size))
                    if change == "replacement" {
                        try bytes.write(to: url, options: .atomic)
                    } else {
                        try bytes.write(to: url)
                    }
                    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: path)
                }
            } catch { Issue.record(error) }
        })
        defer { CostUsageStore.identicalContentPreLockCheckpointForTesting = nil }
        #expect(fixture.save(incoming, receipt: loaded.receipt).catchUpRequired)
        #expect(await fixture.store.fetchMetadata().catchUpPending == true)
        #expect(await fixture.store.fetchMetadata().lastScanUnixMs == fixture.canonical.lastScanUnixMs)
        let fresh = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .status)
        #expect(fresh.hasPendingScan)
        if change == "retry" {
            #expect(await fixture.store.fetchBufferedLines(path: path, kind: .unresolvedFork).count == 1)
        }
    }

    @Test
    func `receipt persists cursor-only changes without grouping or decoding again`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let before = await fixture.store.persistenceWriteMetricsForTesting()
        var incoming = loaded.cache
        incoming.codexPriorityTurnsCursor = .init(
            databasePath: fixture.env.root.appendingPathComponent("synthetic-trace.sqlite").path,
            coverageSinceEpoch: 0,
            lastRowID: 7,
            fileIdentity: 1,
            anchorRowID: 7,
            anchorDigest: "synthetic",
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
        incoming.lastScanUnixMs += 1000
        #expect(!fixture.save(incoming, receipt: loaded.receipt).catchUpRequired)
        #expect(await fixture.store.persistenceWriteMetricsForTesting().rows - before.rows == 2)
        #expect(recorder.snapshot().fullSnapshotReads == 1)
        #expect(recorder.snapshot().usageRowDecodeAttempts == fixture.rowCount)
        #expect(recorder.snapshot().aggregateGroupingRowVisits == 0)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == incoming)
    }

    @Test
    func `native scanner bridge reuses decoded baseline across an unchanged scan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let timestamp = env.isoString(for: day)
        _ = try env.writeCodexSessionFile(day: day, filename: "baseline.jsonl", contents: """
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"synthetic-baseline"}}
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.4"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}

        """)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func scan(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: now, options: options)
        }
        let original = scan(day)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: CostUsageStore(cacheRoot: env.cacheRoot).databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let unchanged = scan(day.addingTimeInterval(1))
        #expect(unchanged.data == original.data)
        #expect(unchanged.summary == original.summary)
        #expect(recorder.snapshot().fullSnapshotReads == 1)
        #expect(recorder.snapshot().cacheConversions == 1)
        #expect(recorder.snapshot().usageRowDecodeAttempts == 1)
        #expect(recorder.snapshot().aggregateGroupingRowVisits == 0)
    }
}
