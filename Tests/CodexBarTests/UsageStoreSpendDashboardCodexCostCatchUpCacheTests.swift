import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreSpendDashboardCodexCostCatchUpCacheTests {
    @Test
    func `a refresh completing the real SQLite cache retires a sleeping dashboard worker`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "sleep-completion-real-cache")
        let sleep = SpendDashboardPendingLoads<Void>()
        defer { store.stopSharedSpendDashboardPublication(); sleep.close() }
        let now = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        let iso = env.isoString(for: now)
        let header = """
        {"type":"session_meta","timestamp":"\(iso)","payload":{"session_id":"synthetic-completion"}}
        {"type":"turn_context","timestamp":"\(iso)","payload":{"model":"synthetic-evidence-model"}}

        """
        let row = "{\"type\":\"event_msg\",\"timestamp\":\"\(iso)\",\"payload\":{\"type\":\"token_count\","
            + "\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":3}}}}\n"
        let file = try env.writeCodexSessionFile(
            day: now, filename: "rollout-synthetic-completion.jsonl", contents: header + String(
                repeating: row,
                count: 4000))
        let calendar = store.settings.costUsageBucketCalendar
        var partialOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"),
            calendar: calendar,
            maxCodexSessionFileBytes: 65536,
            maxCodexScanBytesPerRefresh: 65536)
        partialOptions.refreshMinIntervalSeconds = 0
        let since = CostReportingPeriod.rolling(days: 365).bounds(now: now, calendar: calendar).lowerBound
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex, since: since, until: now, now: now, options: partialOptions)
        let partialFetcher = CostUsageFetcher(scannerOptions: partialOptions)
        let initial = await partialFetcher.codexScanCatchUpStatus(historyDays: 365, now: now)
        #expect(initial.pending)
        #expect(!initial.completionIsConfirmed)
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "synthetic-completion", cacheIdentity: "synthetic-completion")]
        var scanPasses = 0
        var scheduledDelay: TimeInterval?
        store.settings.backgroundWorkLowPowerModePreference = .off
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_spendDashboardCodexCostCatchUpActiveDuration = 2
        // Only the roots, initial byte budget and scheduling are controlled; statuses and cache writes are real.
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await partialFetcher.codexScanCatchUpStatus(historyDays: 365, now: now)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, days in
            scanPasses += 1
            return try await partialFetcher.advanceCodexScanCatchUp(now: now, historyDays: days).value
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { delay in
            guard delay > 0 else { return }
            scheduledDelay = delay
            try await sleep.load()
        }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
        let original = try #require(store.spendDashboardCodexCostCatchUpTask)
        try await sleep.waitForPendingCount(1)
        #expect(scheduledDelay == 1998)
        #expect(scanPasses == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)

        var fullOptions = partialOptions
        fullOptions.maxCodexSessionFileBytes = 0
        fullOptions.maxCodexScanBytesPerRefresh = 0
        let fullFetcher = CostUsageFetcher(scannerOptions: fullOptions)
        for _ in 0..<8 {
            let status = try await fullFetcher.advanceCodexScanCatchUp(
                now: now, historyDays: 365, scanDurationPerRefresh: 10).value
            if !status.pending { break }
        }
        let completed = await partialFetcher.codexScanCatchUpStatus(historyDays: 365, now: now)
        #expect(!completed.pending)
        #expect(completed.completionIsConfirmed)
        #expect(completed.completedFiles == 1)
        #expect(completed.processedBytes == completed.totalBytes)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
            .files[file.path]?.codexScanComplete == true)
        let revision = store.spendDashboardCodexCostCatchUpRevision
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        await store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value

        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(store.spendDashboardCodexCostCatchUpRevision == revision + 1)
        #expect(original.isCancelled)
        #expect(scanPasses == 1)
        #expect(!store.spendDashboardCodexCostCatchUpRestartRequested)
        sleep.close()
        await original.value
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
    }
}
