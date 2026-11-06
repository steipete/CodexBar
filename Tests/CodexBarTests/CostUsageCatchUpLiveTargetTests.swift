import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct CostUsageCatchUpLiveTargetTests {
    @Test
    func `completed live appends cannot keep a stalled dashboard worker running`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 1)
        let timestamp = env.isoString(for: day)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "child.jsonl",
            contents: env.jsonl([
                ["type": "session_meta", "timestamp": timestamp, "payload": [
                    "id": "child", "forked_from_id": "pending-parent", "timestamp": timestamp,
                ]],
                ["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "token_count", "info": [
                        "model": "gpt-5.4",
                        "total_token_usage": ["input_tokens": 1000, "cached_input_tokens": 0, "output_tokens": 100],
                        "last_token_usage": ["input_tokens": 1000, "cached_input_tokens": 0, "output_tokens": 100],
                    ],
                ]],
            ]))
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let append = Data(
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"still waiting\"}}\n"
                .utf8)
        var cache = CostUsageCache()
        let trustedRow = CostUsageScanner.CodexUsageRow(
            day: range.sinceKey,
            model: "gpt-5.4",
            turnID: nil,
            eventIndex: 0,
            input: 10,
            cached: 2,
            output: 3,
            pricingModel: "gpt-5.4",
            pricingMode: "standard")
        cache.days = [range.sinceKey: ["gpt-5.4": [10, 2, 3]]]
        cache.files["/synthetic/trusted.jsonl"] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: cache.days,
            parsedBytes: 1,
            codexRows: [trustedRow],
            codexScanTargetSize: 1,
            codexScanComplete: true)
        func status() -> CostUsageFetcher.CodexScanCatchUpStatus {
            let parsed = CostUsageScanner.parseCodexFile(
                fileURL: file, range: range, inheritedTotalsResolver: { _, _ in .unresolved })
            let usage = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: parsed.scanTargetSize,
                days: parsed.days,
                parsedBytes: parsed.parsedBytes,
                sessionId: parsed.sessionId,
                forkedFromId: parsed.forkedFromId,
                codexRows: parsed.rows,
                codexScanFileId: "synthetic-child",
                codexScanTargetSize: parsed.scanTargetSize,
                codexScanComplete: parsed.parsedBytes == parsed.scanTargetSize,
                codexBufferedUnresolvedForkLines: parsed.bufferedUnresolvedForkLines)
            #expect(usage.codexScanComplete == true)
            #expect(usage.hasPendingCodexForkRetry)
            cache.files[file.path] = usage
            return .init(
                pending: usage.hasPendingCodexScanWork,
                progressKey: CostUsageFetcher.codexScanProgressKey(cache: cache, scopedFiles: cache.files))
        }
        func reportBytes() throws -> Data {
            let report = CostUsageScanner.buildCodexReportFromCache(
                cache: cache, range: range, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
            #expect(report.summary?.totalTokens == 13)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(report)
        }
        let initial = status()
        let initialReport = try reportBytes()
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completed-live-target")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        var advances = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in initial }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            // A finite stream bounds a broken worker without a timeout or blocked thread.
            if advances <= 64 { try writer.write(contentsOf: append) }
            let next = status()
            let report = try reportBytes()
            #expect(report == initialReport)
            return next
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in await Task.yield() }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "fixture", cacheIdentity: "fixture")],
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        #expect(advances == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
    }
}
