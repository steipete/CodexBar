import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `warm activity reads recover compatible metadata changes without losing rows`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let initial = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        let persisted = await fixture.store.readSnapshot()
        let predecessorHash = "4a593b5d59c7bcf3"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion, parserHash: predecessorHash)
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        try writer.execute("BEGIN IMMEDIATE")
        try writer.execute("UPDATE meta SET value = '\(predecessorHash)' WHERE key = 'parser_hash'")
        try writer.execute("PRAGMA user_version = \(predecessorVersion)")
        try writer.execute("COMMIT")

        _ = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        let recovered = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        #expect(recovered.days == initial.days)
        #expect(recovered.lastScanUnixMs == initial.lastScanUnixMs)
        #expect(await fixture.store.readSnapshot() == persisted)
        #expect(await fixture.store.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
    }

    @Test
    func `incompatible warm schemas defer repair until the next access`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
        _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        try writer.execute("BEGIN IMMEDIATE")
        try writer.execute("PRAGMA user_version = \(CostUsageStore.schemaVersion &+ 1)")
        try writer.execute("ALTER TABLE scan_metadata RENAME TO future_scan_metadata")
        try writer.execute("COMMIT")

        let raced = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        #expect(raced.days.isEmpty)
        #expect(await reader.rebuildCount == 0)
        _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        #expect(await reader.rebuildCount == 1)
        #expect(await reader.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
    }

    @Test
    func `detailed reports stay transient between warm activity reads`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let first = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        for _ in 0..<2 {
            let report = CostUsageStoreAccess.readView(
                cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .report)
            let daily = report.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot)
            let full = fixture.fullReport(fixture.canonical)
            #expect(daily.data == full.data)
            #expect(daily.summary.map(CostUsageCodexPreviousReport.Summary.init)
                == full.summary.map(CostUsageCodexPreviousReport.Summary.init))
            #expect(report.sessions(
                range: fixture.range,
                cacheRoot: fixture.env.cacheRoot,
                roots: [fixture.env.codexSessionsRoot]).count == fixture.fileCount)
            let activity = CostUsageStoreAccess.readView(
                cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
            #expect(activity.days == first.days)
        }
        #expect(recorder.snapshot().usageRowDecodeAttempts == fixture.rowCount * 2)
        #expect(recorder.snapshot().cacheConversions == 3)
        #expect(recorder.snapshot().integrityChecks == 1)
    }

    @Test
    func `warm activity revalidates reconciled catch up after source replacement`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var metadata = await fixture.store.fetchMetadata()
        metadata.catchUpPending = true
        #expect(await fixture.store.setMetadata(metadata))
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let first = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        #expect(!first.hasPendingScan)
        let path = try #require(fixture.canonical.files.keys.min())
        try Data("changed fixture\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        let second = CostUsageStoreAccess.readView(
            cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
        #expect(second.hasPendingScan)
        #expect(recorder.snapshot().cacheConversions == 1)
        #expect(recorder.snapshot().readViewConversions == 2)
    }

    @Test
    func `read store eviction preserves recent roots and isolates totals`() throws {
        var fixtures: [ReadWorkFixture] = []
        defer { fixtures.forEach { $0.remove() } }
        for count in 1...5 {
            try fixtures.append(ReadWorkFixture(fileCount: count, rowsPerFile: 1))
        }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixtures[1].store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        for index in [0, 1, 2, 3, 0, 4, 0, 1] {
            let fixture = fixtures[index]
            let view = CostUsageStoreAccess.readView(
                cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .activity)
            #expect(view.days == fixture.canonical.days)
        }
        #expect(recorder.snapshot().integrityChecks == 2)
        #expect(recorder.snapshot().cacheConversions == 2)
    }

    @Test
    func `external commit during an activity read cannot make stale data authoritative`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        var metadata = await fixture.store.readSnapshot().metadata
        metadata.lastScanUnixMs += 1000
        let encodedMetadata = try JSONEncoder().encode(metadata).map { String(format: "%02x", $0) }.joined()
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        CostUsageStore.codexBaselineReadCheckpointForTesting = (fixture.store.databaseURL, {
            try writer.execute("UPDATE scan_metadata SET payload = X'\(encodedMetadata)' WHERE id = 1")
        })
        defer { CostUsageStore.codexBaselineReadCheckpointForTesting = nil }
        let raced = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        #expect(raced.lastScanUnixMs == 0)
        #expect(await reader.rebuildCount == 0)
        #expect(await fixture.store.readSnapshot().metadata == metadata)
        CostUsageStore.codexBaselineReadCheckpointForTesting = nil
        let retried = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        let fresh = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        #expect(retried.days == fresh.days)
        #expect(retried.hasPendingScan == fresh.hasPendingScan)
        #expect(retried.lastScanUnixMs == metadata.lastScanUnixMs)
        #expect(recorder.snapshot().integrityChecks == 1)
        #expect(await reader.rebuildCount == 0)
    }

    @Test
    func `unchanged activity refreshes reuse validated decoded store state`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        var totals: [[Int?]] = []
        for _ in 0..<3 {
            let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
                now: fixture.now,
                maximumDays: 365,
                scannerOptions: fixture.options))
            totals.append(activity.daily.map(\.totalTokens))
        }

        #expect(totals == Array(repeating: [fixture.rowCount * 13], count: 3))
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 1)
        #expect(work.cacheConversions == 1)
        #expect(work.fileRows == fixture.fileCount)
        #expect(work.readViewConversions == 3)
    }

    @Test
    func `activity read state also serves later status refreshes`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())
        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())
        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())

        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 1)
        #expect(work.cacheConversions == 2)
        #expect(work.fileRows == fixture.fileCount * 2)
        #expect(work.readViewConversions == 4)
    }

    @Test
    func `activity refresh invalidates decoded state after an external store commit`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let initial = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        var reduced = fixture.canonical
        try reduced.files.removeValue(forKey: #require(reduced.files.keys.min()))
        #expect(!fixture.save(reduced).catchUpRequired)
        recorder.reset()
        let refreshed = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))

        #expect(initial.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(refreshed.daily.map(\.totalTokens) == [(fixture.rowCount - 8) * 13])
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 0)
        #expect(work.cacheConversions == 1)
        #expect(work.fileRows == fixture.fileCount - 1)
        #expect(work.readViewConversions == 1)
    }

    @Test
    func `activity refresh reopens and validates a replacement database`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let initial = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        let replacementRoot = fixture.env.root.appendingPathComponent("replacement")
        let replacement = CostUsageStore(cacheRoot: replacementRoot)
        var reduced = fixture.canonical
        try reduced.files.removeValue(forKey: #require(reduced.files.keys.min()))
        #expect(!replacement.syncSaveCodexCache(
            reduced,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day)).catchUpRequired)
        #expect(await replacement.truncateWALForTesting())
        await replacement.closeConnectionForTesting()
        #expect(await fixture.store.truncateWALForTesting())
        let originalDirectory = fixture.store.databaseURL.deletingLastPathComponent()
        try FileManager.default.moveItem(
            at: originalDirectory,
            to: fixture.env.root.appendingPathComponent("retired-store"))
        try FileManager.default.moveItem(
            at: replacement.databaseURL.deletingLastPathComponent(),
            to: originalDirectory)

        let refreshed = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        #expect(initial.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(refreshed.daily.map(\.totalTokens) == [(fixture.rowCount - 8) * 13])
        #expect(recorder.snapshot().integrityChecks == 2)
    }

    @Test
    func `cached token activity skips event payloads while preserving totals`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(activity.coverageSinceKey == fixture.canonical.scanSinceKey)
        #expect(activity.coverageUntilKey == fixture.canonical.scanUntilKey)
        let work = recorder.snapshot()
        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.usageRowDecodeAttempts == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.fullSnapshotReads == 0)
    }

    @Test
    func `cached token activity preserves scope timezone and incomplete guards`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var otherScope = fixture.options
        otherScope.codexSessionsRoot = fixture.env.root.appendingPathComponent("other-account/sessions")
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: otherScope) == nil)
        var otherCalendar = fixture.options
        otherCalendar.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: otherCalendar) == nil)

        let path = try #require(fixture.canonical.files.keys.min())
        let malformed = CostUsageStoreBufferedLine(
            path: path, kind: .unresolvedFork, lineIndex: 0, payload: Data("invalid replay JSON".utf8))
        #expect(await fixture.store.replaceBufferedLines(path: path, kind: .unresolvedFork, lines: [malformed]))
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options) == nil)
        #expect(recorder.snapshot().retryPresenceRows == 1)
        #expect(recorder.snapshot().bufferedPayloadBytes == 0)
        #expect(recorder.snapshot().usageRows == 0)
    }

    @Test
    func `cached token activity excludes foreign file aggregates`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let path = try #require(cache.files.keys.min())
        cache.files[fixture.env.root.appendingPathComponent("other-account/foreign.jsonl").path] = cache.files[path]
        #expect(!fixture.save(cache).catchUpRequired)
        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options))
        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
    }

    @Test
    func `cached token activity rejects unfinished file scan`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options) == nil)
    }
}
