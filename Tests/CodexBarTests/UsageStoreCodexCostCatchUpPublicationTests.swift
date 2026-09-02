import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCodexCostCatchUpPublicationTests {
    @Test
    func `completed catch-up publishes its cached report without scanning later growth`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date()
        let iso = env.isoString(for: now)
        let url = try env.writeCodexSessionFile(
            day: now,
            filename: "rollout-publication.jsonl",
            contents: """
            {"type":"session_meta","timestamp":"\(iso)","payload":{"session_id":"publication-test"}}
            {"type":"turn_context","timestamp":"\(iso)","payload":{"model":"openai/gpt-5.2-codex"}}
            \(Self.tokenRecord(iso: iso, input: 100))

            """)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(initial.last30DaysTokens == 100)
        #expect(initial.historyCoverageIsEstablished)

        let store = try Self.makeStore(suite: "real-cache")
        defer { store.cancelCodexCostCatchUp() }
        store.publishTokenSnapshot(initial, for: .codex)
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: nil, updatedAt: now), provider: .codex)
        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        var scanLoads = 0
        let scannerOptions = options
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            scanLoads += 1
            return try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: now.addingTimeInterval(2),
                allowPricingRefresh: false,
                includePiSessions: false,
                scannerOptions: scannerOptions)
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, days in
            await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
                now: now.addingTimeInterval(2),
                historyDays: days,
                includePiSessions: false,
                requireCompleteHistory: true,
                scannerOptions: scannerOptions)
                .map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt) }
        }
        var didAdvance = false
        var completedOffset: Int64?
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: !didAdvance, progressKey: "status")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            try Self.append(Self.tokenRecord(iso: iso, input: 200), to: url)
            let completed = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: now.addingTimeInterval(1),
                allowPricingRefresh: false,
                includePiSessions: false,
                scannerOptions: scannerOptions)
            #expect(completed.last30DaysTokens == 200)
            #expect(completed.historyCoverageIsEstablished)
            completedOffset = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[url.path]?
                .parsedBytes)
            didAdvance = true
            // Growth after completion belongs to the next refresh, not the publication handoff.
            try Self.append(Self.tokenRecord(iso: iso, input: 300), to: url)
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: false, progressKey: "completed")
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await store.codexCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(scanLoads == 0)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 200)
        let tokenUpdatedAt = try #require(store.tokenSnapshot(for: .codex)?.updatedAt)
        #expect(abs(tokenUpdatedAt.timeIntervalSince(now.addingTimeInterval(1))) < 0.002)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 2)
        let widget = try #require(widgetSnapshots.last?.entries.first { $0.provider == .codex })
        #expect(widget.tokenUsage?.last30DaysTokens == 200)
        #expect(widget.tokenUsage?.updatedAt == tokenUpdatedAt)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[url.path]?.parsedBytes == completedOffset)

        let next = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now.addingTimeInterval(3),
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: scannerOptions)
        #expect(next.last30DaysTokens == 300)
        #expect(next.historyCoverageIsEstablished)
    }

    @Test(arguments: ["missing", "pending", "incomplete"])
    func `unavailable completed history preserves prior publication and freshness`(kind: String) async throws {
        let store = try Self.makeStore(suite: "unavailable-\(kind)")
        let oldTime = Date().addingTimeInterval(-3600)
        let initial = Self.snapshot(tokens: 100, now: oldTime)
        store.publishTokenSnapshot(initial, for: .codex)
        store.lastTokenFetchAt[.codex] = oldTime
        store.tokenErrors[.codex] = "existing error"
        Self.stubCompletion(on: store)
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            if kind == "missing" {
                return nil
            }
            return (
                Self.snapshot(tokens: 200, now: oldTime, complete: kind != "incomplete"),
                nil,
                kind == "pending" ? oldTime : nil)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await store.codexCostCatchUpTask?.value

        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 1)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 100)
        #expect(store.lastTokenFetchAt[.codex] == oldTime)
        #expect(store.tokenErrors[.codex] == "existing error")
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        guard case .error = store.codexCostCatchUpActivity?.pauseReason else {
            Issue.record("Expected unavailable-history pause")
            return
        }
    }

    @Test(arguments: [false, true])
    func `foreground publication supersedes both successful and unavailable cached reads`(
        unavailable: Bool) async throws
    {
        let store = try Self.makeStore(suite: "foreground-\(unavailable)")
        let now = Date()
        store.publishTokenSnapshot(Self.snapshot(tokens: 100, now: now), for: .codex)
        Self.stubCompletion(on: store)
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            store.publishTokenSnapshot(Self.snapshot(tokens: 300, now: now), for: .codex)
            store.tokenErrors[.codex] = "foreground error"
            if unavailable {
                return nil
            }
            return (Self.snapshot(tokens: 200, now: now), now, nil)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await store.codexCostCatchUpTask?.value

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 300)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 2)
        #expect(store.tokenErrors[.codex] == "foreground error")
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test(arguments: ["stop", "window", "disabled"])
    func `obsolete completion cannot publish after its context changes`(change: String) async throws {
        let store = try Self.makeStore(suite: "context-\(change)")
        let now = Date()
        store.publishTokenSnapshot(Self.snapshot(tokens: 100, now: now), for: .codex)
        Self.stubCompletion(on: store)
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            switch change {
            case "stop": store.stopCodexCostCatchUp()
            case "window": store.settings.costUsageHistoryDays = 7
            default: store.settings.costUsageEnabled = false
            }
            return (Self.snapshot(tokens: 200, now: now), now, nil)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await store.codexCostCatchUpTask?.value

        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 1)
        #expect(store.tokenErrors[.codex] == nil)
    }

    @Test(arguments: [0, 50])
    func `completed history permits downward reconciliation without inventing refresh time`(tokens: Int) async throws {
        let store = try Self.makeStore(suite: "reconcile-\(tokens)")
        let oldTime = Date().addingTimeInterval(-3600)
        store.publishTokenSnapshot(Self.snapshot(tokens: 100, now: oldTime), for: .codex)
        store.lastTokenFetchAt[.codex] = oldTime
        Self.stubCompletion(on: store)
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            (Self.snapshot(tokens: tokens, now: oldTime), nil, nil)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await store.codexCostCatchUpTask?.value

        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 2)
        #expect(store.lastTokenFetchAt[.codex] == oldTime)
        if tokens == 0 {
            #expect(store.tokenSnapshot(for: .codex) == nil)
        } else {
            #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == tokens)
            #expect(store.tokenSnapshot(for: .codex)?.updatedAt == oldTime)
        }
    }

    private static func stubCompletion(on store: UsageStore) {
        var advanced = false
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: !advanced, progressKey: "status")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanced = true
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: false, progressKey: "done")
        }
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Issue.record("Final publication must not invoke the scanning loader")
            return Self.snapshot(tokens: 999, now: now)
        }
    }

    private static func snapshot(tokens: Int, now: Date, complete: Bool = true) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: 0,
            last30DaysTokens: tokens,
            last30DaysCostUSD: 0,
            historyCoverageIsEstablished: complete,
            daily: tokens == 0 ? [] : [CostUsageDailyReport.Entry(
                date: CostUsageLocalDay.key(from: now),
                inputTokens: tokens,
                outputTokens: 0,
                totalTokens: tokens,
                costUSD: 0,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }

    private static func makeStore(suite: String) throws -> UsageStore {
        let settings = testSettingsStore(suiteName: "UsageStoreCodexCostCatchUpPublicationTests-\(suite)")
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_codexCostCatchUpSleepOverride = { _ in await Task.yield() }
        return store
    }

    private static func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func tokenRecord(iso: String, input: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0},"#
            + #""model":"openai/gpt-5.2-codex"}}}"#
    }
}
