import Foundation
import Testing
@testable import CodexBarCore

/// Corpus-scale probes for the SQLite store foundation (#2760 phase 1). The shapes mirror
/// the #2637 incident corpora (~1.5k session files, large per-file payloads, 30-day window)
/// with SQL work and storage bounds that do not depend on host scheduling or disk latency.
@Suite(.serialized)
struct CostUsageStoreScaleProofTests {
    private static let windowDays = 30

    @Test
    func `incident shaped corpus stays within linear work and storage bounds`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = Calendar(identifier: .gregorian)
        // Freeze the reference date so a run spanning midnight cannot push age-zero data
        // past the window bounds and make the zero-prune assertion flaky.
        let reference = Date()
        guard let windowSince = Self.dayString(
            daysAgo: Self.windowDays - 1,
            calendar: calendar,
            reference: reference),
            let windowUntil = Self.dayString(daysAgo: 0, calendar: calendar, reference: reference)
        else {
            Issue.record("failed to build window bounds")
            return
        }

        let bulkStarted = ContinuousClock.now
        var bulkWork = CostUsageStoreSQLWork()
        for fileIndex in 0..<1500 {
            let age = fileIndex % Self.windowDays
            guard let day = Self.dayString(daysAgo: age, calendar: calendar, reference: reference) else {
                Issue.record("failed to build day string")
                return
            }
            let path = "/rollouts/session-\(fileIndex).jsonl"
            let (_, fileWork) = try await store.measureSQLWork { store in
                let fileWritten = store.upsertFile(Self.file(path: path, day: day, ordinal: fileIndex))
                #expect(fileWritten)
                let snapshots = (0..<100).map { eventIndex in
                    Self.snapshot(path: path, eventIndex: eventIndex, day: day)
                }
                let snapshotsWritten = store.appendTokenSnapshots(snapshots)
                #expect(snapshotsWritten)
                // Spread models independently of the day (fileIndex % 30 correlates with % 3).
                let aggregate = Self.aggregate(day: day, model: "model-\((fileIndex / 30) % 3)")
                let fileAggregatesWritten = store.replaceFileDayAggregates(path: path, aggregates: [aggregate])
                #expect(fileAggregatesWritten)
                let aggregatesWritten = store.mergeDayAggregates([aggregate])
                #expect(aggregatesWritten)
            }
            bulkWork.statements += fileWork.statements
            bulkWork.virtualMachineSteps += fileWork.virtualMachineSteps
        }
        let bulkElapsed = ContinuousClock.now - bulkStarted

        let bulkFileBytes = await store.fileSizeBytes()

        // A corpus spanning exactly the active window leaves the out-of-window prune no work.
        let pruneStarted = ContinuousClock.now
        let (pruned, pruneWork) = try await store.measureSQLWork {
            $0.retainDayWindow(sinceDay: windowSince, untilDay: windowUntil)
        }
        let pruneElapsed = ContinuousClock.now - pruneStarted
        #expect(pruned.deletedFiles == 0)
        #expect(pruned.deletedTokenSnapshots == 0)
        #expect(pruned.deletedDayAggregates == 0)

        let reportStarted = ContinuousClock.now
        let (report, reportWork) = try await store.measureSQLWork {
            $0.readReport(sinceDay: windowSince, untilDay: windowUntil)
        }
        let reportElapsed = ContinuousClock.now - reportStarted
        #expect(report.aggregates.count == Self.windowDays * 3)

        let snapshotStarted = ContinuousClock.now
        let (snapshot, snapshotWork) = try await store.measureSQLWork { $0.readSnapshot() }
        let snapshotElapsed = ContinuousClock.now - snapshotStarted
        #expect(snapshot.files.count == 1500)
        #expect(snapshot.tokenSnapshots.count == 150_000)

        print("[scale-proof] bulk load 1.5k files/150k snapshots: \(Self.milliseconds(bulkElapsed)) ms")
        print("[scale-proof] db file after bulk load: \(bulkFileBytes / 1_048_576) MiB")
        print("[scale-proof] no-op out-of-window prune: \(Self.milliseconds(pruneElapsed)) ms")
        print("[scale-proof] readReport(30 days): \(Self.milliseconds(reportElapsed)) ms")
        print("[scale-proof] readSnapshot(150k rows): \(Self.milliseconds(snapshotElapsed)) ms")

        // Bound database work per input row, not time spent waiting for the shared host.
        Self.expectWork(bulkWork, statements: 180_000, steps: 150_000 * 200, operation: "bulk load")
        Self.expectWork(pruneWork, statements: 30, steps: 1500 * 100, operation: "no-op prune")
        // A report reads the 90 aggregate rows, never the 150k token snapshots.
        Self.expectWork(reportWork, statements: 10, steps: 90 * 100, operation: "report")
        Self.expectWork(snapshotWork, statements: 30, steps: 150_000 * 100, operation: "snapshot")
        #expect(bulkFileBytes < 300 * 1_048_576)
    }

    @Test
    func `window prune shrinks corpus and reclaims file bytes`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = Calendar(identifier: .gregorian)
        // Same frozen reference as the incident-shaped test: deterministic day keys.
        let reference = Date()
        guard let sinceDay = Self.dayString(daysAgo: 7, calendar: calendar, reference: reference),
              let untilDay = Self.dayString(daysAgo: 0, calendar: calendar, reference: reference)
        else {
            Issue.record("failed to build window bounds")
            return
        }

        for fileIndex in 0..<500 {
            let age = fileIndex % 30
            guard let day = Self.dayString(daysAgo: age, calendar: calendar, reference: reference) else {
                Issue.record("failed to build day string")
                return
            }
            let path = "/rollouts/window-\(fileIndex).jsonl"
            #expect(await store.upsertFile(Self.file(path: path, day: day, ordinal: fileIndex)))
            let snapshots = (0..<50).map { eventIndex in
                Self.snapshot(path: path, eventIndex: eventIndex, day: day)
            }
            #expect(await store.appendTokenSnapshots(snapshots))
            let aggregate = Self.aggregate(day: day, model: "model-\(fileIndex % 3)")
            #expect(await store.replaceFileDayAggregates(path: path, aggregates: [aggregate]))
            #expect(await store.mergeDayAggregates([aggregate]))
        }
        let beforeBytes = await store.fileSizeBytes()

        let pruneStarted = ContinuousClock.now
        let (result, pruneWork) = try await store.measureSQLWork {
            $0.retainDayWindow(sinceDay: sinceDay, untilDay: untilDay)
        }
        let pruneElapsed = ContinuousClock.now - pruneStarted
        let afterBytes = await store.fileSizeBytes()
        let snapshot = await store.readSnapshot()

        // Ages 0...7 survive: 16 full 30-day cycles contribute 128 files and the remaining
        // 20 indices contribute 8 more, so the retained corpus is deterministically 136.
        let survivors = snapshot.files.count
        #expect(survivors == 136)
        #expect(snapshot.files.allSatisfy { file in
            guard let coverage = file.coverageUntilDay else { return false }
            return coverage >= sinceDay && coverage <= untilDay
        })
        #expect(snapshot.dayAggregates.allSatisfy { $0.day >= sinceDay && $0.day <= untilDay })
        #expect(result.deletedFiles == 500 - survivors)
        #expect(result.deletedFiles > 0)
        #expect(afterBytes < beforeBytes)

        print("[scale-proof] window prune 500 -> \(survivors) files: \(Self.milliseconds(pruneElapsed)) ms, ")
        print("[scale-proof] db file \(beforeBytes / 1_048_576) -> \(afterBytes / 1_048_576) MiB")
        Self.expectWork(pruneWork, statements: 500 * 20, steps: 25000 * 200, operation: "window prune")
    }

    @Test
    func `legacy sized payload round trips without whole artifact blowup`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        // Mirror the ~100 MiB legacy artifact as one worst-case deferred-replay payload.
        let path = "/rollouts/blob.jsonl"
        #expect(await store.upsertFile(Self.file(path: path, day: "2026-08-01", ordinal: 0)))
        let payload = Data(repeating: 0x61, count: 100 * 1_048_576)
        let line = CostUsageStoreBufferedLine(
            path: path,
            kind: .deferredReplay,
            lineIndex: 0,
            ordinal: nil,
            endOffset: Int64(payload.count),
            payload: payload)

        let writeStarted = ContinuousClock.now
        let (written, writeWork) = try await store.measureSQLWork {
            $0.replaceBufferedLines(path: path, kind: .deferredReplay, lines: [line])
        }
        #expect(written)
        let writeElapsed = ContinuousClock.now - writeStarted
        let persistedBytes = await store.fileSizeBytes()

        let readStarted = ContinuousClock.now
        let (fetched, readWork) = try await store.measureSQLWork {
            $0.fetchBufferedLines(path: path, kind: .deferredReplay)
        }
        let readElapsed = ContinuousClock.now - readStarted
        #expect(fetched == [line])

        print("[scale-proof] 100 MiB blob write: \(Self.milliseconds(writeElapsed)) ms, ")
        print("[scale-proof] db file after 100 MiB blob: \(persistedBytes / 1_048_576) MiB")
        print("[scale-proof] 100 MiB blob read: \(Self.milliseconds(readElapsed)) ms")
        Self.expectWork(writeWork, statements: 10, steps: 1000, operation: "blob write")
        Self.expectWork(readWork, statements: 10, steps: 1000, operation: "blob read")
        // Keep the persisted representation bounded so a second whole-artifact copy cannot
        // hide behind a successful round trip.
        #expect(persistedBytes < 256 * 1_048_576)
    }
}

// MARK: - Helpers

extension CostUsageStoreScaleProofTests {
    private static func expectWork(
        _ work: CostUsageStoreSQLWork,
        statements: Int,
        steps: Int,
        operation: String)
    {
        print("[scale-proof] \(operation): \(work.statements) statements, \(work.virtualMachineSteps) VM steps")
        #expect(work.statements > 0 && work.statements <= statements)
        #expect(work.virtualMachineSteps > 0 && work.virtualMachineSteps <= steps)
    }

    private static func dayString(
        daysAgo: Int,
        calendar: Calendar,
        reference: Date) -> String?
    {
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: reference) else { return nil }
        return self.dayString(for: date, calendar: calendar)
    }

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    private static func file(path: String, day: String, ordinal: Int) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            inode: Int64(ordinal),
            mtimeUnixMs: 1000 + Int64(ordinal),
            size: 5000 + Int64(ordinal),
            parsedBytes: 4000,
            anchor: CostUsageStoreValidationAnchor(indexedBytes: 4000, windowStart: 144, sha256: "abc123"),
            scanState: CostUsageStoreScanState(
                targetSize: 5000,
                isComplete: true,
                resumePayload: nil,
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 100,
                lastModel: "gpt-5.6-sol",
                lastTurnID: "turn-\(ordinal)"),
            sessionID: "session-\(path)",
            coverageSinceDay: day,
            coverageUntilDay: day,
            updatedAtUnixMs: 1000 + Int64(ordinal))
    }

    private static func snapshot(path: String, eventIndex: Int, day: String) -> CostUsageStoreTokenSnapshot {
        CostUsageStoreTokenSnapshot(
            path: path,
            eventIndex: eventIndex,
            timestamp: "\(day)T12:00:00Z",
            timestampUnixMs: 1_754_046_000_000 + Int64(eventIndex),
            day: day,
            last: CostUsageStoreTotals(input: 2, cached: 1, output: 3, reasoning: 1),
            total: CostUsageStoreTotals(input: 20, cached: 10, output: 30, reasoning: 5),
            endOffset: 100 + Int64(eventIndex))
    }

    private static func aggregate(day: String, model: String) -> CostUsageStoreDayAggregate {
        CostUsageStoreDayAggregate(
            day: day,
            model: model,
            inputTokens: 10,
            cachedTokens: 2,
            outputTokens: 3,
            reasoningTokens: 1,
            requestCount: 1,
            authoritativeCostNanos: 1000,
            standardInputTokens: 6,
            standardCachedTokens: 1,
            standardOutputTokens: 2,
            priorityInputTokens: 4,
            priorityCachedTokens: 1,
            priorityOutputTokens: 1,
            standardTokens: 9,
            priorityTokens: 6)
    }
}

private struct ScaleFixture: Sendable {
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreScaleProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
