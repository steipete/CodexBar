import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuCardOverrideIsolationTests {
    @Test
    func `explicit selected token account adopts legacy unscoped history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "fixture")
        let account = try #require(store.settings.selectedTokenAccount(for: .claude))
        let accountKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: account))
        let legacyHistory = [planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
        ])]
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: legacyHistory)
        let originalRevision = store.planUtilizationHistoryRevision

        let selection = store.planUtilizationHistorySelection(for: .claude, account: account)

        #expect(selection.accountKey == accountKey)
        #expect(selection.histories == legacyHistory)
        #expect(store.planUtilizationHistory[.claude]?.unscoped.isEmpty == true)
        #expect(store.planUtilizationHistoryRevision == originalRevision + 1)
    }

    @Test
    func `nil snapshot account card does not inherit ambient Claude costs`() throws {
        let suite = "MenuCardOverrideIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.costUsageEnabled = true
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 1.23,
                daily: [],
                updatedAt: Date()),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        let model = try #require(controller.menuCardModel(
            for: .claude,
            errorOverride: "Token expired",
            forceOverrideCard: true,
            accountOverride: AccountInfo(email: "account@example.com", plan: nil)))

        #expect(model.tokenUsage == nil)
        #expect(model.email == "account@example.com")
    }

    @Test
    func `account card without its own error does not inherit the ambient Claude error`() throws {
        let suite = "MenuCardOverrideIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setErrorForTesting("Claude OAuth credentials unavailable", provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        let accountSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "account@example.com",
                accountOrganization: nil,
                loginMethod: "claude-swap"))

        let model = try #require(controller.menuCardModel(
            for: .claude,
            snapshotOverride: accountSnapshot,
            accountOverride: AccountInfo(email: "account@example.com", plan: nil)))

        #expect(model.subtitleStyle != .error)
        #expect(!model.subtitleText.contains("Claude OAuth credentials unavailable"))

        let liveModel = try #require(controller.menuCardModel(for: .claude))
        #expect(liveModel.subtitleStyle == .error)
        #expect(liveModel.subtitleText == "Claude OAuth credentials unavailable")
    }

    @Test
    func `stacked token account card uses its own session equivalent history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "fixture")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "fixture")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let now = Date()
        let currentSessionReset = now.addingTimeInterval(2 * 3600)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(accounts: [
            aliceKey: Self.sessionEquivalentHistory(
                burnPerWindow: 20,
                currentSessionReset: currentSessionReset),
            bobKey: Self.sessionEquivalentHistory(
                burnPerWindow: 5,
                currentSessionReset: currentSessionReset),
        ])
        store.planUtilizationHistoryRevision = 1

        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: currentSessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "bob@example.com",
                accountOrganization: nil,
                loginMethod: "max"))
        let controller = StatusItemController(
            store: store,
            settings: store.settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        let model = try #require(controller.tokenAccountMenuCardModel(
            for: .claude,
            accountSnapshot: TokenAccountUsageSnapshot(
                account: bob,
                snapshot: snapshot,
                error: nil,
                sourceLabel: nil,
                cacheKey: "bob")))
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })
        let numberText = try #require(weeklyMetric.sessionEquivalentDetail?.numberText)

        #expect(numberText.hasPrefix("≈8 full 5h windows"))
        #expect(!numberText.hasPrefix("≈2 full 5h windows"))
    }

    @Test
    func `failed stacked token account card keeps its configured label`() throws {
        let suite = "MenuCardOverrideIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Rejected group",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountSnapshot = TokenAccountUsageSnapshot(
            account: account,
            snapshot: nil,
            error: "sub2api rejected the API key.",
            sourceLabel: nil,
            cacheKey: "fixture-cache")

        let model = try #require(controller.tokenAccountMenuCardModel(
            for: .sub2api,
            accountSnapshot: accountSnapshot))

        #expect(model.email == "Rejected group")
        #expect(model.subtitleStyle == .error)
    }

    @Test
    func `successful stacked token account card prefers fetched identity over configured label`() throws {
        let suite = "MenuCardOverrideIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Configured group",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .sub2api,
                accountEmail: "fetched@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        let accountSnapshot = TokenAccountUsageSnapshot(
            account: account,
            snapshot: usage,
            error: nil,
            sourceLabel: "api",
            cacheKey: "fixture-cache")

        let model = try #require(controller.tokenAccountMenuCardModel(
            for: .sub2api,
            accountSnapshot: accountSnapshot))

        #expect(model.email == "fetched@example.com")
    }

    private static func sessionEquivalentHistory(
        burnPerWindow: Double,
        currentSessionReset: Date) -> [PlanUtilizationSeriesHistory]
    {
        let duration: TimeInterval = 5 * 3600
        let start = currentSessionReset.addingTimeInterval(-4 * duration)
        let weeklyReset = currentSessionReset.addingTimeInterval(6 * 24 * 3600)
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for index in 0..<3 {
            let windowStart = start.addingTimeInterval(Double(index) * duration)
            let reset = windowStart.addingTimeInterval(duration)
            sessionEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30 * 60),
                usedPercent: 20,
                resetsAt: reset))
            sessionEntries.append(planEntry(
                at: reset.addingTimeInterval(-30 * 60),
                usedPercent: 100,
                resetsAt: reset))
            weeklyEntries.append(planEntry(at: windowStart, usedPercent: weeklyUsed, resetsAt: weeklyReset))
            weeklyUsed += burnPerWindow
            weeklyEntries.append(planEntry(at: reset, usedPercent: weeklyUsed, resetsAt: weeklyReset))
        }

        return [
            planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
            planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
        ]
    }
}
