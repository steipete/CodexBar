import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized, ProviderTransportRegressionFixtures())
@MainActor
struct WidgetEmptyProjectionTests {
    @Test(arguments: [false, true])
    func `all failed providers retain published entries and original ages`(queued: Bool) async throws {
        let (store, settings) = self.makeStore()
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        self.seed(store)
        store.persistWidgetSnapshot(reason: "synthetic-success")
        if !queued { await store.widgetSnapshotPersistTask?.value }
        store.snapshots.removeAll()
        store.errors = [.minimax: "Synthetic offline failure", .deepseek: "Synthetic offline failure"]
        settings.usageBarsShowUsed = true
        store.persistWidgetSnapshot(reason: "synthetic-all-failed")
        await store.widgetSnapshotPersistTask?.value
        let before = try #require(saved.first)
        let after = try #require(saved.last)
        #expect(saved.count == 2)
        #expect(before.entries.count == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(after.entries) == encoder.encode(before.entries))
        #expect(after.usageBarsShowUsed)
        #expect(after.generatedAt >= before.generatedAt)
    }

    @Test(arguments: ["disabled", "blocked", "retired", "no-failure", "partial", "cold-start"])
    func `empty projection fallback respects invalidation boundaries`(scenario: String) async throws {
        let (store, settings) = self.makeStore()
        let url = try #require(store.widgetSnapshotURL)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        self.seed(store)
        store.persistWidgetSnapshot(reason: "synthetic-success")
        await store.widgetSnapshotPersistTask?.value
        store.snapshots.removeAll()
        store.errors = [.minimax: "Synthetic offline failure", .deepseek: "Synthetic offline failure"]
        switch scenario {
        case "disabled":
            settings.setProviderEnabled(provider: .minimax, metadata: store.metadata(for: .minimax), enabled: false)
        case "blocked": store.widgetUsagePreservationBlockedProviders.insert(.minimax)
        case "retired":
            store.clearProviderRuntimeState(.minimax)
            store.errors[.minimax] = "Synthetic offline failure"
        case "no-failure": store.errors.removeAll()
        case "partial": self.seed(store, providers: [.deepseek])
        case "cold-start":
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try WidgetSnapshotStore.save(#require(saved), to: url)
            store._test_widgetSnapshotSaveOverride = nil
            store.lastQueuedWidgetSnapshot = nil
        default: break
        }
        store.persistWidgetSnapshot(reason: "synthetic-invalidation")
        await store.widgetSnapshotPersistTask?.value
        if scenario == "cold-start" { saved = WidgetSnapshotStore.load(from: url) }
        #expect(saved?.entries.count == (scenario == "partial" ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func `terminal failures cannot revive published usage`(clearBeforeFailure: Bool) async {
        let (store, _) = self.makeStore()
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        self.seed(store)
        store.persistWidgetSnapshot(reason: "synthetic-success")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.count == 2)
        if clearBeforeFailure { store.snapshots.removeAll() }
        store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.userAuthenticationRequired)), attempts: [])
        }
        for provider in [UsageProvider.minimax, .deepseek] {
            await store.refreshProvider(provider, allowDisabled: true)
            await store.refreshProvider(provider, allowDisabled: true)
        }
        store.persistWidgetSnapshot(reason: "synthetic-terminal-failures")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.isEmpty == true)
    }

    @Test(arguments: ["summary", "unknown-summary", "legacy", "primary"])
    func `Antigravity row projection preserves summary and fallback precedence`(scenario: String) {
        let (store, _) = self.makeStore()
        let legacyID = "antigravity-compact-fallback-fixture"
        let summaryID = "antigravity-quota-summary-gemini-5h"
        var windows = [NamedRateWindow(
            id: legacyID,
            title: "Experimental Model",
            window: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil))]
        let hasSummary = scenario.contains("summary")
        if hasSummary {
            windows.append(NamedRateWindow(
                id: summaryID,
                title: "Gemini 5-hour",
                window: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                usageKnown: scenario != "unknown-summary"))
        }
        let snapshot = UsageSnapshot(
            primary: scenario == "primary"
                ? RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil) : nil,
            secondary: nil,
            extraRateWindows: windows,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rows = store.widgetUsageRows(provider: .antigravity, snapshot: snapshot, now: snapshot.updatedAt)
        #expect(rows.map(\.id) == [hasSummary ? summaryID : scenario == "primary" ? "primary" : legacyID])
        let expectedPercent: Double? = switch scenario {
        case "summary": 100
        case "unknown-summary": nil
        case "primary": 60
        default: 80
        }
        #expect(rows.first?.percentLeft == expectedPercent)
    }

    @Test(arguments: [false, true])
    func `successful refresh must publish before invalidated widget usage can be retained`(
        publishWhileBlocked: Bool) async
    {
        let (store, _) = self.makeStore(providers: [.minimax])
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        self.seed(store, providers: [.minimax])
        store.persistWidgetSnapshot(reason: "synthetic-old-account")
        await store.widgetSnapshotPersistTask?.value
        if publishWhileBlocked {
            store._test_providerFetchOutcomeOverride = { _ in
                ProviderFetchOutcome(result: .failure(URLError(.userAuthenticationRequired)), attempts: [])
            }
            await store.refreshProvider(.minimax)
            store.persistWidgetSnapshot(reason: "synthetic-gated-terminal-error")
            await store.widgetSnapshotPersistTask?.value
            #expect(saved?.entries.first?.primary?.usedPercent == 25)
        } else {
            store.clearProviderRuntimeState(.minimax)
        }
        let replacement = UsageSnapshot(
            primary: RateWindow(usedPercent: 75, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_060))
        store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .success(ProviderFetchResult(
                usage: replacement,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .apiToken)), attempts: [])
        }
        await store.refreshProvider(.minimax)
        #expect(store.snapshot(for: .minimax)?.primary?.usedPercent == 75)
        store.snapshots.removeAll()
        store.errors[.minimax] = "Synthetic offline failure"
        store.persistWidgetSnapshot(reason: "synthetic-offline-before-replacement-publication")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.isEmpty == true)

        store._setSnapshotForTesting(replacement, provider: .minimax)
        store.persistWidgetSnapshot(reason: "synthetic-replacement-publication")
        await store.widgetSnapshotPersistTask?.value
        store.snapshots.removeAll()
        store.persistWidgetSnapshot(reason: "synthetic-offline-after-replacement-publication")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.first?.primary?.usedPercent == 75)
        #expect(saved?.entries.first?.updatedAt == replacement.updatedAt)
    }

    @Test
    func `selecting an unavailable cached account cannot revive the previous account`() async throws {
        let (store, settings) = self.makeStore(providers: [.openrouter])
        settings.addTokenAccount(provider: .openrouter, label: "First", token: "fixture-first-key")
        settings.addTokenAccount(provider: .openrouter, label: "Second", token: "fixture-second-key")
        settings.setActiveTokenAccountIndex(0, for: .openrouter)
        self.seed(store, providers: [.openrouter])
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        store.persistWidgetSnapshot(reason: "synthetic-first-account")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.count == 1)
        settings.setActiveTokenAccountIndex(1, for: .openrouter)
        let account = try #require(settings.effectiveSelectedTokenAccount(for: .openrouter))
        store.accountSnapshots[.openrouter] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: nil,
            error: "Synthetic unavailable account",
            sourceLabel: "fixture",
            cacheKey: store.tokenAccountSnapshotCacheKey(provider: .openrouter, account: account))]
        store.activateCachedTokenAccountSnapshot(provider: .openrouter, accountID: account.id)
        #expect(store.snapshot(for: .openrouter) == nil)
        store.persistWidgetSnapshot(reason: "synthetic-second-account-unavailable")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.isEmpty == true)
    }

    @Test
    func `retained entries respect hidden optional spending`() async throws {
        let (store, settings) = self.makeStore(providers: [.devin])
        settings.showOptionalCreditsAndExtraUsage = true
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
        store._setSnapshotForTesting(UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: measuredAt),
            updatedAt: measuredAt), provider: .devin)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        store.persistWidgetSnapshot(reason: "synthetic-visible-spending")
        await store.widgetSnapshotPersistTask?.value
        let before = try #require(saved)
        #expect(before.enabledProviders.contains(.devin))
        #expect(before.entries.first?.providerCost != nil)
        settings.showOptionalCreditsAndExtraUsage = false
        store.snapshots.removeAll()
        store.errors[.devin] = "Synthetic offline failure"
        store.persistWidgetSnapshot(reason: "synthetic-hidden-spending")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains(where: { $0.providerCost != nil }) == false)
    }

    private func makeStore(
        providers: Set<UsageProvider> = [.minimax, .deepseek]) -> (UsageStore, SettingsStore)
    {
        let root = ProviderTransportRegressionFixtures.root.appendingPathComponent(UUID().uuidString)
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        let settings = testSettingsStore(
            suiteName: "WidgetEmptyProjectionTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings._test_codexReconciliationEnvironment = environment
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        enableTestProviders(providers, settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root
                .appendingPathComponent("history.json")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: environment,
            widgetSnapshotURL: root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        return (store, settings)
    }

    private func seed(_ store: UsageStore, providers: [UsageProvider] = [.minimax, .deepseek]) {
        for (index, provider) in providers.enumerated() {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))),
                provider: provider)
        }
    }
}
