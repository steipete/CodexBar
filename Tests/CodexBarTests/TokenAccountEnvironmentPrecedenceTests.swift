import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
@Suite
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func tokenAccountEnvironmentOverridesConfigAPIKey_inAppEnvironmentBuilder() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-app")
        settings.zaiAPIToken = "config-token"
        settings.addTokenAccount(provider: .zai, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .zai,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func tokenAccountEnvironmentOverridesConfigAPIKey_inCLIEnvironmentBuilder() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(id: .zai, apiKey: "config-token"),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Account 1",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)

        let env = tokenContext.environment(base: [:], provider: .zai, account: account)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func ollamaTokenAccountSelectionForcesManualCookieSourceInCLISettingsSnapshot() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "session=account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .ollama,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .ollama).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .ollama, account: account))
        let ollamaSettings = try #require(snapshot.ollama)

        #expect(ollamaSettings.cookieSource == .manual)
        #expect(ollamaSettings.manualCookieHeader == "session=account-token")
    }

    @Test
    func applyAccountLabelInAppPreservesSnapshotFields() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-apply-app")
        let store = Self.makeUsageStore(settings: settings)
        let snapshot = Self.makeSnapshotWithAllFields(provider: .zai)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Team Account",
            token: "account-token",
            addedAt: 0,
            lastUsed: nil)

        let labeled = store.applyAccountLabel(snapshot, provider: .zai, account: account)

        Self.expectSnapshotFieldsPreserved(before: snapshot, after: labeled)
        #expect(labeled.identity?.providerID == .zai)
        #expect(labeled.identity?.accountEmail == "Team Account")
    }

    @Test
    func applyAccountLabelInCLIPreservesSnapshotFields() throws {
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: []),
            verbose: false)
        let snapshot = Self.makeSnapshotWithAllFields(provider: .zai)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "CLI Account",
            token: "account-token",
            addedAt: 0,
            lastUsed: nil)

        let labeled = context.applyAccountLabel(snapshot, provider: .zai, account: account)

        Self.expectSnapshotFieldsPreserved(before: snapshot, after: labeled)
        #expect(labeled.identity?.providerID == .zai)
        #expect(labeled.identity?.accountEmail == "CLI Account")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
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
            settings: settings)
    }

    private static func makeSnapshotWithAllFields(provider: UsageProvider) -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_003_600)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 6,
            usage: 200,
            currentValue: 40,
            remaining: 160,
            percentage: 20,
            usageDetails: [ZaiUsageDetail(modelCode: "glm-4", usage: 40)],
            nextResetTime: reset)
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: nil,
            accountOrganization: "Org",
            loginMethod: "Pro")

        return UsageSnapshot(
            primary: RateWindow(usedPercent: 21, windowMinutes: 60, resetsAt: reset, resetDescription: "primary"),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 1440, resetsAt: nil, resetDescription: "secondary"),
            tertiary: RateWindow(usedPercent: 7, windowMinutes: nil, resetsAt: nil, resetDescription: "tertiary"),
            providerCost: ProviderCostSnapshot(
                used: 12.5,
                limit: 25,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: reset,
                updatedAt: now),
            zaiUsage: ZaiUsageSnapshot(
                tokenLimit: tokenLimit,
                timeLimit: nil,
                planName: "Z.ai Pro",
                updatedAt: now),
            minimaxUsage: MiniMaxUsageSnapshot(
                planName: "MiniMax",
                availablePrompts: 500,
                currentPrompts: 120,
                remainingPrompts: 380,
                windowMinutes: 1440,
                usedPercent: 24,
                resetsAt: reset,
                updatedAt: now),
            openRouterUsage: OpenRouterUsageSnapshot(
                totalCredits: 50,
                totalUsage: 10,
                balance: 40,
                usedPercent: 20,
                rateLimit: nil,
                updatedAt: now),
            cursorRequests: CursorRequestUsage(used: 7, limit: 70),
            updatedAt: now,
            identity: identity)
    }

    private static func expectSnapshotFieldsPreserved(before: UsageSnapshot, after: UsageSnapshot) {
        #expect(after.primary?.usedPercent == before.primary?.usedPercent)
        #expect(after.secondary?.usedPercent == before.secondary?.usedPercent)
        #expect(after.tertiary?.usedPercent == before.tertiary?.usedPercent)
        #expect(after.providerCost?.used == before.providerCost?.used)
        #expect(after.providerCost?.limit == before.providerCost?.limit)
        #expect(after.providerCost?.currencyCode == before.providerCost?.currencyCode)
        #expect(after.zaiUsage?.planName == before.zaiUsage?.planName)
        #expect(after.zaiUsage?.tokenLimit?.usage == before.zaiUsage?.tokenLimit?.usage)
        #expect(after.minimaxUsage?.planName == before.minimaxUsage?.planName)
        #expect(after.minimaxUsage?.availablePrompts == before.minimaxUsage?.availablePrompts)
        #expect(after.openRouterUsage?.balance == before.openRouterUsage?.balance)
        #expect(after.openRouterUsage?.rateLimit?.requests == before.openRouterUsage?.rateLimit?.requests)
        #expect(after.cursorRequests?.used == before.cursorRequests?.used)
        #expect(after.cursorRequests?.limit == before.cursorRequests?.limit)
        #expect(after.updatedAt == before.updatedAt)
    }
}
