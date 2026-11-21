import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `large decode preserves every persisted field with one decoder`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        let expected = try Self.decodeGoldenCache(fixture: fixture, fileCount: 2048)
        #expect(!fixture.save(expected).catchUpRequired)
        let snapshot = await fixture.store.readSnapshot()
        var constructions = 0
        let decoded = CostUsageStore.decodeCodexCache(from: snapshot, recorder: nil, makeDecoder: {
            constructions += 1
            return JSONDecoder()
        })
        #expect(decoded == expected)
        #expect(snapshot.files.count == 2048)
        #expect(snapshot.usageRows.count == 8192)
        #expect(snapshot.tokenSnapshots.count == 8192)
        #expect(snapshot.accumulators.count == 2048)
        #expect(snapshot.forkLineage.count == 2048)
        #expect(snapshot.bufferedLines.count == 10240)
        #expect(snapshot.discoveryState != nil)
        #expect(snapshot.lookbackState != nil)
        #expect(constructions == 1)
        print("[store-decode] files=\(snapshot.files.count) rows=\(snapshot.usageRows.count) " +
            "decoders=\(constructions) golden_equal=\(decoded == expected)")
    }

    @Test
    func `malformed payloads do not affect subsequent decodes or row order`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        var snapshot = await fixture.store.readSnapshot()
        let path = try #require(snapshot.files.first?.path)
        let invalid = Data("invalid JSON".utf8)
        var unreadable = try #require(snapshot.files.first)
        unreadable.path += ".invalid"
        unreadable.scanState.detailsPayload = invalid
        snapshot.files.insert(unreadable, at: 0)
        snapshot.usageRows.insert(.init(path: path, rowIndex: -1, payload: invalid), at: 0)
        snapshot.bufferedLines.insert(.init(path: path, kind: .unresolvedFork, lineIndex: -1, payload: invalid), at: 0)
        snapshot.bufferedLines.append(.init(path: path, kind: .sourcePricingEvidence, lineIndex: 0, payload: invalid))
        snapshot.metadata.priorityTurnStatePayload = invalid
        snapshot.metadata.previousReportPayload = invalid
        var expected = fixture.canonical
        expected.files[path]?.codexPendingSourcePricing = [:]
        let decoded = CostUsageStore.decodeCodexCache(from: snapshot, recorder: nil)
        #expect(decoded == expected)
    }

    @Test
    func `streamed codex baseline matches the full snapshot decode`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 3, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.min())
        var rows = await fixture.store.readSnapshot().usageRows.filter { $0.path == path }
        rows.append(.init(path: path, rowIndex: rows.count, payload: Data("invalid JSON".utf8)))
        #expect(await fixture.store.replaceUsageRows(path: path, rows: rows))

        var unreadable = try #require(await fixture.store.readSnapshot().files.first { $0.path != path })
        unreadable.scanState.detailsPayload = Data("invalid JSON".utf8)
        #expect(await fixture.store.upsertFile(unreadable))

        let snapshot = await fixture.store.readSnapshot(loadTokenSnapshots: false)
        let expected = CostUsageStore.decodeCodexCache(from: snapshot, recorder: nil, tokenSnapshotsLoaded: false)
        let baseline = try #require(await fixture.store.codexBaselineProjectionForTesting())
        #expect(baseline.decoded == expected)
        #expect(baseline.rowCounts == snapshot.usageRows.reduce(into: [:]) { $0[$1.path, default: 0] += 1 })
        #expect(baseline.rowCounts[path] == 5)
    }

    static func decodeGoldenCache(fixture: ReadWorkFixture, fileCount: Int) throws -> CostUsageCache {
        var expected = fixture.canonical
        let path = try #require(expected.files.keys.first)
        var usage = try #require(expected.files[path])
        usage.lastTotals = .init(input: 40, cached: 8, output: 12)
        usage.lastRawTotalsBaseline = .init(input: 10, cached: 2, output: 3)
        usage.lastRawTotalsWatermark = usage.lastTotals
        usage.seenRawTotals = [usage.lastRawTotalsBaseline!, usage.lastTotals!]
        usage.hasDivergentTotals = true
        usage.hasInterleavedTotals = true
        usage.forkedFromId = "fixture-parent"
        usage.forkBaselineDependencyKey = "fixture-dependency"
        usage.codexWorkspaceContentFingerprint = "fixture-workspace"
        usage.codexNextUsageRowIndex = 4
        usage.codexPendingPricing = ["fixture-turn": .init(pricingModel: "gpt-5.4", pricingMode: "priority")]
        let source = CostUsageScanner.CodexUsageRow(
            day: ReadWorkFixture.day,
            model: ReadWorkFixture.model,
            turnID: "fixture-source",
            eventIndex: 0,
            timestampUnixMs: 1_785_585_600_000,
            input: 10,
            cached: 2,
            output: 3)
        usage.codexPendingSourcePricing = try [#require(CostUsageScanner.CodexSourcePricingKey(source)):
            .init(pricingModel: "gpt-5.4", pricingMode: "standard")]
        usage.codexPendingSourcePricingAnchor = .init(indexedBytes: 40, windowStart: 10, sha256: "fixture-anchor")
        usage.codexBufferedSubagentLines = usage.codexBufferedUnresolvedForkLines
        let partial = fixture.env.root.appendingPathComponent("partial.jsonl")
        try Data(("{\"message\":\"" + String(repeating: "x", count: 128)).utf8).write(to: partial)
        let progress = try CostUsageJsonl.scanBounded(
            fileURL: partial,
            maxLineBytes: 256,
            prefixBytes: 256,
            maxBytesToRead: 64,
            resumeState: nil,
            onLine: { _ in })
        let resume = try #require(progress.resumeState)
        usage.codexJSONLResumeState = resume
        expected.files = Dictionary(uniqueKeysWithValues: (0..<fileCount).map { index in
            (fixture.env.codexSessionsRoot.appendingPathComponent("golden-\(index).jsonl").path, usage)
        })
        expected.codexScanInventoryPaths = expected.files.keys.sorted()
        expected.codexScanTotalFiles = fileCount
        expected.codexScanCompletedFiles = 0
        expected.codexScanProcessedBytes = Int64(fileCount) * (usage.parsedBytes ?? 0)
        expected.codexScanTotalBytes = Int64(fileCount) * usage.size
        expected.days = [ReadWorkFixture.day: [ReadWorkFixture.model: [fileCount * 40, fileCount * 8, fileCount * 12]]]
        expected.codexPriorityTurnKeys = [ReadWorkFixture.day: "fixture-priority-key"]
        expected.codexPriorityTurnIDsByDay = [ReadWorkFixture.day: ["fixture-turn"]]
        let turn = CostUsageScanner.CodexPriorityTurnMetadata(
            threadID: "fixture-thread", turnID: "fixture-turn", model: "gpt-5.4", timestamp: "2026-08-01T12:00:00Z")
        expected.codexResolvedPriorityTurns = ["fixture-turn": turn]
        expected.codexPriorityTurnsCursor = .init(
            databasePath: fixture.env.root.appendingPathComponent("synthetic-trace.sqlite").path,
            coverageSinceEpoch: 1_785_542_400,
            lastRowID: 7,
            fileIdentity: 42,
            anchorRowID: 7,
            anchorDigest: "fixture-digest",
            anchors: [.init(rowID: 7, digest: "fixture-digest")],
            turns: ["fixture-turn": turn],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: ["fixture-turn"],
            completedTurnIDInsertionOrderStartIndex: 0)
        let root = fixture.env.codexSessionsRoot.path
        expected.codexSessionDiscovery = .init(
            roots: [root],
            generation: "fixture-generation",
            directoryStamps: [root: .init(
                mtimeUnixMs: 1,
                jsonlFileCount: 1)],
            directoryPaths: [root],
            nextDirectoryIndex: 1,
            filePaths: [path],
            nextFileIndex: 0,
            fileStamps: [path: .init(mtimeUnixMs: usage.mtimeUnixMs, size: usage.size, fileId: usage.codexScanFileId)],
            headScan: .init(path: path, offset: 12),
            filePathBySessionId: ["fixture-session": path],
            missingSessionIds: ["missing"],
            pendingSessionIds: ["pending"],
            validationDirectoryIndex: 0,
            isComplete: false)
        expected.codexActiveLookbackState = .init(
            scanSinceKey: ReadWorkFixture.day,
            rootPaths: [root],
            nextDayKeyByRoot: [root: ReadWorkFixture.day],
            nextDirectoryOffsetByRoot: [root: 7],
            pendingFilePaths: [path],
            legacyRecursivePendingRootPaths: [root],
            currentWindowNextDayKeyByRoot: [root: ReadWorkFixture.day],
            currentWindowDirectoryOffsetByRoot: [root: 3],
            completedCurrentWindowRootPaths: [],
            currentWindowFlatDirectoryOffsetByRoot: [root: 4],
            completedCurrentWindowFlatRootPaths: [],
            cacheWideMigrationQueueActive: true)
        expected.codexPreviousReport = .init(
            report: fixture.fullReport(fixture.canonical),
            cache: fixture.canonical,
            reportSinceKey: ReadWorkFixture.day,
            reportUntilKey: ReadWorkFixture.day)
        return expected
    }
}

extension CostUsageStore {
    fileprivate func codexBaselineProjectionForTesting() -> (decoded: CostUsageCache, rowCounts: [String: Int])? {
        self.readCodexBaseline().map { ($0.decoded, $0.persistence.rowCounts) }
    }
}

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [false, true])
    func `report and baseline stream encoded usage rows`(baseline: Bool) throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var hooks = CostUsageStoreTestHooks.current
        hooks.readWorkRecorder = recorder
        CostUsageStoreTestHooks.$current.withValue(hooks) {
            if baseline {
                let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
                defer { loaded.release() }
                #expect(loaded.cache.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) } == fixture.rowCount)
            } else {
                let view = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
                #expect(view.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot).data
                    == fixture.fullReport(fixture.canonical).data)
            }
        }
        let work = recorder.snapshot()
        print("[stream-work] baseline=\(baseline) decoded=\(work.usageRowDecodeAttempts) "
            + "materialized=\(work.materializedUsageRows) payloadBytes=\(work.usagePayloadBytes)")
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
        #expect(work.fileDetailsDecodeAttempts == fixture.fileCount)
        #expect(work.materializedUsageRows == 0)
    }
}
