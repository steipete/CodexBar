import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuCardOverrideIsolationTests {
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
}
