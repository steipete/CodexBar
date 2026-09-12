import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct AntigravityLocalPublicationTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test(
        arguments: ["absent", "corrupt", "empty", "out-of-window", "partial", "over-budget"],
        ["none", "history", "confirmed-empty"])
    func `actual publication distinguishes unavailable from confirmed empty after replacing history`(
        source: String, initialState: String) async throws
    {
        let hasHistory = initialState == "history"
        let initial = try Fixture()
        try initial.database(blobs: hasHistory ? [Fixture.blob()] : [])
        let next = try Fixture()
        switch source {
        case "corrupt":
            let url = try next.database()
            try Data("broken".utf8).write(to: url)
        case "empty":
            try next.database()
        case "out-of-window":
            try next.database(blobs: [Fixture.blob(seconds: 1_600_000_000)])
        case "partial":
            try next.database(blobs: [Fixture.blob(), Fixture.blob(seconds: nil)])
            try next.jsonl([Fixture.cacheUsage])
        case "over-budget":
            let url = try next.jsonl([Fixture.cacheUsage])
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 129 * 1024 * 1024)
            try handle.close()
        default: break
        }
        let store = try Self.store(root: initial.root)
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in try await initial.snapshot() }
        if initialState != "none" {
            await store.refreshTokenUsageNow(for: .antigravity, force: true)
            await store.refreshSpendDashboardTokenUsageNow(for: .antigravity, force: true)
            #expect(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .antigravity)?
                .snapshot?.last30DaysTokens == (hasHistory ? 198 : nil))
            // A new regular publication must not be acknowledged by a failing independent refresh.
            await store.refreshTokenUsageNow(for: .antigravity, force: true)
        }
        let revision = store.spendDashboardTokenSnapshotPublicationRevision(for: .antigravity)
        let regularRevision = store.tokenSnapshotPublicationRevision(for: .antigravity)
        let acknowledged = store.spendDashboardTokenIncorporatedTriggers[.antigravity]

        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in try await next.snapshot() }
        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.refreshSpendDashboardTokenUsageNow(for: .antigravity, force: true)
        let publication = store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .antigravity)
        let regular = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .antigravity)
        if source == "empty" || source == "out-of-window" {
            #expect(publication != nil)
            #expect(publication?.snapshot == nil)
            #expect(publication?.publicationRevision == revision + 1)
            #expect(store.spendDashboardTokenFailedTriggers[.antigravity] == nil)
            #expect(regular != nil)
            #expect(regular?.snapshot == nil)
            #expect(regular?.publicationRevision == regularRevision + 1)
            #expect(store.tokenFailureGates[.antigravity]?.streak == 0)
            #expect(store.spendDashboardTokenIncorporatedTriggers[.antigravity] ==
                store.spendDashboardTokenRefreshTrigger(for: .antigravity))
        } else {
            #expect(publication == nil)
            #expect(store.spendDashboardTokenSnapshotPublicationRevision(for: .antigravity) == revision)
            #expect(store.spendDashboardTokenFailedTriggers[.antigravity] != nil)
            #expect(store.spendDashboardTokenIncorporatedTriggers[.antigravity] == acknowledged)
            #expect(store.tokenSnapshotPublicationRevision(for: .antigravity) == regularRevision)
            #expect(regular?.snapshot?.last30DaysTokens == (hasHistory ? 198 : nil))
            #expect((regular != nil) == hasHistory)
            #expect(store.tokenFailureGates[.antigravity]?.streak == 1)
            #expect((store.tokenError(for: .antigravity) != nil) == !hasHistory)
        }
        store._test_tokenUsageSnapshotLoaderOverride = nil
        await store.widgetSnapshotPersistTask?.value
    }

    @Test(arguments: [UsageProvider.claude, .codex, .cursor])
    func `regular unavailable handling preserves failure gating and Codex catchup retention`(
        provider: UsageProvider) async throws
    {
        let healthy = try Fixture()
        try healthy.database(blobs: [Fixture.blob()])
        let absent = try Fixture()
        let store = try Self.store(root: healthy.root, provider: provider)
        // Real reader/fetcher snapshots exercise publication; other-provider transport is deliberately stubbed.
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in try await healthy.snapshot() }
        await store.refreshTokenUsageNow(for: provider, force: true)
        let revision = store.tokenSnapshotPublicationRevision(for: provider)
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in try await absent.snapshot() }
        await store.refreshTokenUsageNow(for: provider, force: true)
        #expect(store.tokenSnapshotPublicationRevision(for: provider) == revision)
        #expect(store.tokenSnapshot(for: provider)?.last30DaysTokens == 198)
        #expect(store.tokenError(for: provider) == nil)
        #expect(store.tokenFailureGates[provider.instanceID]?.streak == (provider == .codex ? 0 : 1))
        await store.codexCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageSnapshotLoaderOverride = nil
    }

    @Test
    func `accepted two and three day totals remain unknown through fetcher dashboard menu widget and CLI`()
        async throws
    {
        let fixture = try Fixture()
        for (index, tokens) in [Int.max - 1, 2, 7].enumerated() {
            try fixture.database("day-\(index)", blobs: [Fixture.blob(
                system: 0,
                input: UInt64(tokens),
                output: 0,
                cacheRead: 0,
                reasoning: 0,
                seconds: UInt64(Fixture.now.timeIntervalSince1970) - UInt64(2 - index) * 86400)])
            guard index >= 1 else { continue }
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.historyCoverageIsEstablished)
            #expect(snapshot.daily.count == index + 1)
            #expect(snapshot.last30DaysTokens == nil)
            let summary = snapshot.summary(forLastDays: 30, calendar: Fixture.calendar)
            #expect(summary.totalTokens == nil)
            #expect(summary.tokenMix.inputTokens == nil)
            #expect(summary.totalRequests == index + 1)
            let menu = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                UsageMenuCardView.Model.tokenUsageSection(
                    provider: .antigravity,
                    enabled: true,
                    comparisonPeriodsEnabled: false,
                    snapshot: snapshot,
                    error: nil)
            }
            #expect(menu?.monthLine == "Last 30 days: —")
            #expect(UsageStore.widgetTokenUsageSummary(from: snapshot, provider: .antigravity)?.last30DaysTokens == nil)
            let payload = CodexBarCLI.makeCostPayload(
                provider: .antigravity, snapshot: snapshot, error: nil, calendar: Fixture.calendar)
            #expect(payload.last30DaysTokens == nil)
            #expect(payload.totals?.totalInputTokens == nil)
            #expect(payload.totals?.totalTokens == nil)
            #expect(payload.totals?.totalCostUSD == nil)
            let model = SpendDashboardModel.build(
                inputs: [.init(id: "fixture", provider: .antigravity, displayName: "Fixture", snapshot: snapshot)],
                requestedDays: 30,
                now: Fixture.now,
                calendar: Fixture.calendar)
            let group = try #require(model.groups.first)
            #expect(group.tokenMix.inputTokens == nil)
            #expect(group.totalTokens == nil)
            #expect(group.tokenMix.outputTokens == 0)
        }
    }

    @Test(arguments: [UsageProvider.claude, .codex, .cursor])
    func `shared overflow repair preserves missing buckets and other providers`(provider: UsageProvider) {
        let rows = zip(["2026-08-25", "2026-08-26", "2026-08-27"], [Int.max - 1, 2, 7]).map { day, count in
            CostUsageDailyReport.Entry(
                date: day,
                inputTokens: count,
                outputTokens: 1,
                totalTokens: count,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: .init(data: rows, summary: nil), now: Fixture.now, calendar: Fixture.calendar)
        let summary = snapshot.summary(forLastDays: 30, calendar: Fixture.calendar)
        #expect(summary.tokenMix.inputTokens == nil)
        #expect(summary.tokenMix.outputTokens == 3)
        #expect(summary.tokenMix.cacheReadTokens == nil)
        let payload = CodexBarCLI.makeCostPayload(
            provider: provider, snapshot: snapshot, error: nil, calendar: Fixture.calendar)
        #expect(payload.totals?.totalInputTokens == nil)
        #expect(payload.totals?.totalOutputTokens == 3)
    }

    private static func store(root: URL, provider selectedProvider: UsageProvider = .antigravity) throws -> UsageStore {
        let suite = "AntigravityLocalPublicationTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json")),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            antigravityOAuthCredentialsStore: .init(fileURL: root.appendingPathComponent("no-credentials.json")),
            performInitialProviderDetection: false)
        settings._test_managedCodexAccountStoreURL = root.appendingPathComponent("accounts.json")
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        settings._test_codexReconciliationEnvironment = environment
        settings.cursorCookieSource = .manual
        settings.cursorCookieHeader = "fixture-session=isolated"
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = false
        for provider in UsageProvider.allCases {
            let metadata = try #require(ProviderRegistry.shared.metadata[provider])
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == selectedProvider)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                fileURL: root.appendingPathComponent("historical.json")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: root
                .appendingPathComponent("plans")),
            startupBehavior: .testing,
            environmentBase: environment,
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        store._test_widgetSnapshotSaveOverride = { _ in }
        store._test_codexCostCatchUpStatusOverride = { _ in
            .init(pending: false, progressKey: "isolated")
        }
        return store
    }
}
