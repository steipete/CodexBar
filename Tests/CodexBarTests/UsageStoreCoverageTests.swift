import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreCoverageTests {
    @Test
    func `provider with highest usage and icon style`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-highest")
        let store = Self.makeUsageStore(settings: settings)
        let metadata = ProviderRegistry.shared.metadata

        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .factory, metadata: #require(metadata[.factory]), enabled: true)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: now),
            provider: .factory)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .factory)
        #expect(highest?.usedPercent == 70)
        #expect(store.iconStyle == .combined)

        try settings.setProviderEnabled(provider: .factory, metadata: #require(metadata[.factory]), enabled: false)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: false)
        #expect(store.iconStyle == store.style(for: .codex))

        store._setErrorForTesting("error", provider: .codex)
        #expect(store.isStale)
    }

    @Test
    func `source label adds open AI web`() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-source")
        settings.debugDisableKeychainAccess = false
        settings.codexUsageDataSource = .oauth
        settings.codexCookieSource = .manual

        let store = Self.makeUsageStore(settings: settings)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboardRequiresLogin = false

        let label = store.sourceLabel(for: .codex)
        #expect(label.contains("openai-web"))
    }

    @Test
    func `source label uses configured kilo source`() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-kilo-source")
        settings.kiloUsageDataSource = .api

        let store = Self.makeUsageStore(settings: settings)
        #expect(store.sourceLabel(for: .kilo) == "api")
    }

    @Test
    func `provider with highest usage prefers kimi rate limit window`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-kimi-highest")
        let store = Self.makeUsageStore(settings: settings)
        let metadata = ProviderRegistry.shared.metadata

        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .kimi, metadata: #require(metadata[.kimi]), enabled: true)

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                updatedAt: now),
            provider: .kimi)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .kimi)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `provider availability and subscription detection`() {
        let zaiStore = InMemoryZaiTokenStore(value: "zai-token")
        let syntheticStore = InMemorySyntheticTokenStore(value: "synthetic-token")
        let settings = Self.makeSettingsStore(
            suite: "UsageStoreCoverageTests-availability",
            zaiTokenStore: zaiStore,
            syntheticTokenStore: syntheticStore)
        let store = Self.makeUsageStore(settings: settings)

        #expect(store.isProviderAvailable(.zai))
        #expect(store.isProviderAvailable(.synthetic))

        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro")
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date(), identity: identity),
            provider: .claude)
        #expect(store.isClaudeSubscription())
        #expect(UsageStore.isSubscriptionPlan("Team"))
        #expect(!UsageStore.isSubscriptionPlan("api"))
    }

    @Test
    func `background refresh only tracks enabled providers`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-refresh")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(staleSnapshot, provider: .claude)
        store._setErrorForTesting("stale", provider: .claude)
        store.statuses[.claude] = ProviderStatus(indicator: .major, description: "Outage", updatedAt: Date())

        #expect(store.enabledProviders() == [.codex])

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .claude) == nil)
        #expect(store.errors[.claude] == nil)
        #expect(store.statuses[.claude] == nil)
    }

    @Test
    func `cleanup preserves enabled but unavailable provider state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-preserve-unavailable")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(staleSnapshot, provider: .synthetic)
        store._setErrorForTesting("stale", provider: .synthetic)
        store.statuses[.synthetic] = ProviderStatus(indicator: .major, description: "Outage", updatedAt: Date())

        #expect(store.enabledProviders().isEmpty)
        #expect(store.enabledProvidersForDisplay() == [.synthetic])

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .synthetic) != nil)
        #expect(store.errors[.synthetic] == "stale")
        #expect(store.statuses[.synthetic]?.indicator == .major)
    }

    @Test
    func `background work excludes enabled but unavailable providers`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-unavailable")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)

        #expect(store.enabledProvidersForDisplay() == [.synthetic])
        #expect(store.enabledProviders().isEmpty)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)
    }

    @Test
    func `visible unavailable provider gets explicit user facing state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-unavailable-message")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)

        #expect(store.errors[.synthetic] == nil)
        #expect(store.enabledProvidersForDisplay() == [.synthetic])
        #expect(store.isProviderAvailable(.synthetic) == false)
        #expect(store.userFacingError(for: .synthetic) == SyntheticSettingsError.missingToken.errorDescription)
        #expect(store.unavailableMessage(for: .synthetic) == SyntheticSettingsError.missingToken.errorDescription)
    }

    @Test
    func `refresh clears enabled but unavailable cached state`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-cleanup")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let cachedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(cachedSnapshot, provider: .synthetic)
        let account = ProviderTokenAccount(id: UUID(), label: "Account", token: "token", addedAt: 0, lastUsed: nil)
        store.accountSnapshots[.synthetic] = [
            TokenAccountUsageSnapshot(account: account, snapshot: cachedSnapshot, error: nil, sourceLabel: "api"),
        ]
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 10,
                sessionCostUSD: 1.23,
                last30DaysTokens: 100,
                last30DaysCostUSD: 4.56,
                daily: [],
                updatedAt: Date()),
            provider: .synthetic)

        #expect(store.enabledProvidersForDisplay() == [.synthetic])
        #expect(store.enabledProviders().isEmpty)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)

        await store.refresh()
        #expect(store.snapshot(for: .synthetic) == nil)
        #expect((store.accountSnapshots[.synthetic] ?? []).isEmpty)
        #expect(store.tokenSnapshots[.synthetic] == nil)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)
    }

    @Test
    func `refresh clears enabled but unavailable failure state`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-failure-cleanup")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        store._setErrorForTesting("stale", provider: .synthetic)
        store.statuses[.synthetic] = ProviderStatus(indicator: .major, description: "Outage", updatedAt: Date())
        store.tokenErrors[.synthetic] = "token stale"

        #expect(store.enabledProvidersForDisplay() == [.synthetic])
        #expect(store.enabledProviders().isEmpty)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)

        await store.refresh()

        #expect(store.errors[.synthetic] == nil)
        #expect(store.tokenErrors[.synthetic] == nil)
        #expect(store.statuses[.synthetic] == nil)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)
    }

    @Test
    func `unavailable provider with only cached status gets single cleanup pass`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-status-cleanup")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true

        let metadata = ProviderRegistry.shared.metadata

        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .synthetic,
            metadata: #require(metadata[.synthetic]),
            enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        store.statuses[.synthetic] = ProviderStatus(indicator: .major, description: "Outage", updatedAt: Date())

        #expect(store.enabledProvidersForDisplay() == [.synthetic])
        #expect(store.enabledProviders().isEmpty)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)

        await store.refresh()

        #expect(store.statuses[.synthetic] == nil)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)
    }

    @Test
    func `status indicators and failure gate`() {
        #expect(!ProviderStatusIndicator.none.hasIssue)
        #expect(ProviderStatusIndicator.maintenance.hasIssue)
        #expect(ProviderStatusIndicator.unknown.label == "Status unknown")

        var gate = ConsecutiveFailureGate()
        let first = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(!first)
        let second = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(second)
        gate.recordSuccess()
        let third = gate.shouldSurfaceError(onFailureWithPriorData: false)
        #expect(third)
        gate.reset()
        #expect(gate.streak == 0)
    }

    private static func makeSettingsStore(
        suite: String,
        zaiTokenStore: any ZaiTokenStoring = NoopZaiTokenStore(),
        syntheticTokenStore: any SyntheticTokenStoring = NoopSyntheticTokenStore())
        -> SettingsStore
    {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: zaiTokenStore,
            syntheticTokenStore: syntheticTokenStore,
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }
}

private final class InMemoryZaiTokenStore: ZaiTokenStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadToken() throws -> String? {
        self.value
    }

    func storeToken(_ token: String?) throws {
        self.value = token
    }
}

private final class InMemorySyntheticTokenStore: SyntheticTokenStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadToken() throws -> String? {
        self.value
    }

    func storeToken(_ token: String?) throws {
        self.value = token
    }
}
