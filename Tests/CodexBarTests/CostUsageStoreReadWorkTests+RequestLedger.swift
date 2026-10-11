import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `status and activity read views omit the request ledger while reports and scans keep it`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 2)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.min())
        let nowMs = Int64(fixture.now.timeIntervalSince1970 * 1000)
        var cache = fixture.canonical
        var usage = try #require(cache.files[path])
        usage.codexRows = (usage.codexRows ?? []).enumerated().map { index, row in
            CostUsageScanner.CodexUsageRow(
                day: row.day,
                model: row.model,
                turnID: row.turnID,
                eventIndex: row.eventIndex,
                timestampUnixMs: nowMs - 1000,
                input: row.input,
                cached: row.cached,
                output: row.output,
                knownCostNanos: row.knownCostNanos,
                pricingModel: row.pricingModel,
                pricingMode: row.pricingMode,
                responseID: "fixture-response-\(index)")
        }
        let turnID = try #require(usage.codexRows?.first?.turnID)
        var ledger = CostUsageScanner.CodexRequestLedgerState()
        ledger.responseIDs = ["fixture-response-0", "fixture-response-1"]
        ledger.mirroredResponses = ["fixture-snapshot-0": "fixture-response-0"]
        ledger.legacyRowIndices = ["fixture-legacy-0": 0]
        ledger.turnModels = [turnID: ReadWorkFixture.model]
        var performance = CostUsageScanner.CodexTurnPerformanceState()
        performance.reportedOutputTokens = 3
        performance.completion = .init(
            turnID: turnID,
            timestamp: "2026-08-01T12:00:00Z",
            completedAtUnixMs: nowMs,
            durationMilliseconds: 2000,
            firstTokenMilliseconds: 100,
            startedAtUnixMs: nowMs - 5000)
        ledger.turnPerformance = [turnID: performance]
        usage.codexRequestLedgerState = ledger
        cache.files[path] = usage
        _ = fixture.save(cache)
        let persisted = await fixture.store.readSnapshot()
        let scanned = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(scanned.files[path]?.codexRequestLedgerState == ledger)

        let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
        _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .status)
        let retainedStatus = try #require(await reader.retainedCodexRead)
        #expect(retainedStatus.purpose == .status)
        #expect(retainedStatus.decoded.files.count == fixture.fileCount)
        #expect(retainedStatus.decoded.files.values.allSatisfy { $0.codexRequestLedgerState == nil })

        _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
        let retainedActivity = try #require(await reader.retainedCodexRead)
        #expect(retainedActivity.purpose == .activity)
        #expect(retainedActivity.decoded.files.values.allSatisfy { $0.codexRequestLedgerState == nil })

        // A ledger-stripped warm view must never satisfy a report request.
        #expect(!CostUsageStoreReadPurpose.status.includes(.report))
        #expect(!CostUsageStoreReadPurpose.activity.includes(.report))
        let roots = CostUsageScanner.codexSessionsRoots(options: fixture.options)
        let report = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report).scoped(to: roots)
        let projections = report.reports(range: fixture.range, cacheRoot: fixture.env.cacheRoot, roots: roots)
        let expected = CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: CostUsageScanner.codexCache(scanned, scopedTo: roots),
            range: fixture.range,
            modelsDevCacheRoot: fixture.env.cacheRoot,
            sessionRoots: roots)
        #expect(projections.daily.data == expected.daily.data)
        #expect(projections.sessions == expected.sessions)
        #expect(projections.sessions.contains { !$0.turnPerformanceSamples.isEmpty })
        #expect(await reader.retainedCodexRead?.purpose == .activity)

        #expect(reader.syncLoadCodexCache(calendar: fixture.calendar).files[path]?.codexRequestLedgerState == ledger)
        #expect(await fixture.store.readSnapshot() == persisted)
    }
}
