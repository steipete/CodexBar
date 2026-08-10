import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCodexCostCatchUpTests {
    @Test
    func `bounded catch-up automatically publishes only the final stable snapshot`() async throws {
        let store = try Self.makeStore(suite: "publishes-final")
        var snapshotLoadCount = 0
        var statusLoadCount = 0
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            return Self.tokenSnapshot(cost: Double(snapshotLoadCount), now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: "status-\(statusLoadCount)")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: "advance-\(advanceCount)")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        await store.refreshTokenUsage(.codex, force: true)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && snapshotLoadCount == 2
        }

        #expect(advanceCount == 2)
        #expect(statusLoadCount == 2)
        #expect(snapshotLoadCount == 2)
        #expect(sleepDurations.first == 8)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 2)
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `catch-up stops after one bounded pass that makes no progress`() async throws {
        let store = try Self.makeStore(suite: "no-progress")
        var snapshotLoadCount = 0
        var advanceCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            return Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unchanged")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unchanged")
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        await store.refreshTokenUsage(.codex, force: true)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && advanceCount == 1
        }

        #expect(advanceCount == 1)
        #expect(snapshotLoadCount == 1)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `catch-up stops when bounded progress revisits an earlier semantic state`() async throws {
        let store = try Self.makeStore(suite: "cyclic-progress")
        let progressKeys = ["validation-1", "validation-2", "validation-0"]
        var advanceCount = 0
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: "validation-0")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: progressKeys[min(advanceCount - 1, progressKeys.count - 1)])
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 3)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `catch-up continues when existing complete file backlog advances`() async throws {
        let store = try Self.makeStore(suite: "existing-complete-backlog")
        let first = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 125,
            days: [:],
            parsedBytes: 125,
            codexScanFileId: "1:1",
            codexScanComplete: true)
        let second = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 125,
            days: [:],
            parsedBytes: 125,
            codexScanFileId: "2:2",
            codexScanComplete: true)
        let files = [
            "/sessions/first.jsonl": first,
            "/sessions/second.jsonl": second,
        ]
        var caches = [CostUsageCache(), CostUsageCache(), CostUsageCache()]
        caches[0].codexScanCompletedFiles = 0
        caches[1].codexScanCompletedFiles = 1
        caches[2].codexScanCompletedFiles = 2
        let keys = caches.map {
            CostUsageFetcher.codexScanProgressKey(cache: $0, scopedFiles: files)
        }
        var statusLoadCount = 0
        var advanceCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: statusLoadCount == 1 ? keys[0] : keys[2])
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: keys[advanceCount])
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(Set(keys).count == 3)
        #expect(advanceCount == 2)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `accelerated catch-up runs without an inter-pass delay and publishes progress`() async throws {
        let store = try Self.makeStore(suite: "accelerated")
        var statusLoadCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: "status-\(statusLoadCount)",
                processedBytes: statusLoadCount == 1 ? 25 : 100,
                totalBytes: 100,
                completedFiles: statusLoadCount == 1 ? 0 : 1,
                totalFiles: 1)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete",
                processedBytes: 100,
                totalBytes: 100,
                completedFiles: 1,
                totalFiles: 1)
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(sleepDurations.first == 0)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.mode == .accelerated)
        #expect(store.codexCostCatchUpActivity?.fractionCompleted == 1)
    }

    @Test
    func `stop during an idle delay preserves progress without starting a pass`() async throws {
        let store = try Self.makeStore(suite: "stop-idle")
        var advanceCount = 0
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: "partial",
                processedBytes: 50,
                totalBytes: 100)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: false, progressKey: "unexpected")
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            store.stopCodexCostCatchUp()
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded()
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 0)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .user)
        #expect(store.codexCostCatchUpActivity?.fractionCompleted == 0.5)
    }

    private static func makeStore(suite: String) throws -> UsageStore {
        let settings = testSettingsStore(suiteName: "UsageStoreCodexCostCatchUpTests-\(suite)")
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func tokenSnapshot(cost: Double, now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-07-30",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool) async
    {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Codex cost catch-up task")
    }
}
