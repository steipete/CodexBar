import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRateLimitResilienceTests {
    @Test
    func `classifier accepts only the canonical O auth rate limit`() {
        let canonical = ClaudeOAuthFetchError.usageRateLimitDescription

        #expect(ClaudeUsageError.isClaudeOAuthUsageRateLimit(ClaudeOAuthFetchError.rateLimited(retryAfter: nil)))
        #expect(ClaudeUsageError.isClaudeOAuthUsageRateLimit(ClaudeUsageError.oauthFailed(canonical)))
        #expect(!ClaudeUsageError.isClaudeOAuthUsageRateLimit(ClaudeUsageError.oauthFailed(canonical + " extra")))
        #expect(!ClaudeUsageError.isClaudeOAuthUsageRateLimit(ClaudeUsageError.oauthFailed("rate limited")))
        #expect(!ClaudeUsageError.isClaudeOAuthUsageRateLimit(ClaudeUsageError.oauthFailed("HTTP 429")))
        #expect(!ClaudeUsageError.isClaudeOAuthUsageRateLimit(NSError(
            domain: "test",
            code: 429,
            userInfo: [NSLocalizedDescriptionKey: canonical])))
    }

    @MainActor
    @Test
    func `stable unscoped O auth refresh keeps the prior card on rate limit`() async throws {
        let store = try self.makeStore(suite: "ClaudeOAuthRateLimit-unscoped")
        let prior = self.snapshot(usedPercent: 28)
        store._setSnapshotForTesting(prior, provider: .claude)
        store.lastKnownResetSnapshots[.claude] = prior
        store.lastSourceLabels[.claude] = "oauth"
        try self.installRateLimitDescriptor(store)

        await self.refreshWithStableClaudeCredentials(store)

        #expect(store.snapshot(for: .claude)?.updatedAt == prior.updatedAt)
        #expect(store.lastKnownResetSnapshots[.claude]?.updatedAt == prior.updatedAt)
        #expect(store.lastSourceLabels[.claude] == "oauth")
        #expect(store.error(for: .claude) == nil)
    }

    @MainActor
    @Test
    func `missing prior card surfaces the O auth rate limit`() async throws {
        let store = try self.makeStore(suite: "ClaudeOAuthRateLimit-missing")
        try self.installRateLimitDescriptor(store)

        await self.refreshWithStableClaudeCredentials(store)

        #expect(store.snapshot(for: .claude) == nil)
        #expect(store.error(for: .claude)?.contains("rate limited") == true)
    }

    @MainActor
    @Test
    func `segmented account keeps only its exact O auth cache without recording history`() async throws {
        let store = try self.makeStore(suite: "ClaudeOAuthRateLimit-segmented", layout: .segmented)
        store.settings.addTokenAccount(provider: .claude, label: "Primary", token: "test-auth-token")
        let account = try #require(store.settings.selectedTokenAccount(for: .claude))
        let prior = self.snapshot(usedPercent: 31)
        self.seedAccountSnapshot(store: store, account: account, snapshot: prior)
        store._setKnownLimitsAvailabilityForTesting(.available, provider: .claude)
        try self.installRateLimitDescriptor(store)

        await self.refreshWithStableClaudeCredentials(store)

        let row = try #require(store.accountSnapshots[.claude]?.first)
        #expect(store.snapshot(for: .claude)?.updatedAt == prior.updatedAt)
        #expect(store.error(for: .claude) == nil)
        #expect(row.cacheKey == store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
        #expect(row.snapshot?.updatedAt == prior.updatedAt)
        #expect(row.error == nil)
        #expect(store.knownLimitsAvailability(for: .claude) == .available)
        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    @Test
    func `edited account cannot reuse its previous O auth cache`() async throws {
        let store = try self.makeStore(suite: "ClaudeOAuthRateLimit-edited", layout: .segmented)
        store.settings.addTokenAccount(provider: .claude, label: "Primary", token: "test-auth-token")
        let original = try #require(store.settings.selectedTokenAccount(for: .claude))
        self.seedAccountSnapshot(store: store, account: original, snapshot: self.snapshot(usedPercent: 47))
        store.settings.updateTokenAccount(
            provider: .claude,
            accountID: original.id,
            token: "test-token-placeholder")
        try self.installRateLimitDescriptor(store)

        await self.refreshWithStableClaudeCredentials(store)

        #expect(store.snapshot(for: .claude) == nil)
        #expect(store.error(for: .claude)?.contains("rate limited") == true)
        #expect(store.accountSnapshots[.claude]?.first?.snapshot == nil)
    }

    @MainActor
    @Test
    func `stacked accounts keep exact O auth caches without recording cached history`() async throws {
        let store = try self.makeStore(suite: "ClaudeOAuthRateLimit-stacked", layout: .stacked)
        store.settings.addTokenAccount(provider: .claude, label: "Primary", token: "test-auth-token")
        store.settings.addTokenAccount(provider: .claude, label: "Secondary", token: "test-token-placeholder")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let primary = try #require(accounts.first)
        let secondary = try #require(accounts.last)
        let selected = try #require(store.settings.selectedTokenAccount(for: .claude))
        let primaryPrior = self.snapshot(usedPercent: 21)
        let secondaryPrior = self.snapshot(usedPercent: 64)
        let selectedPrior = selected.id == primary.id ? primaryPrior : secondaryPrior
        self.seedAccountSnapshots(
            store: store,
            values: [(primary, primaryPrior), (secondary, secondaryPrior)])
        store._setKnownLimitsAvailabilityForTesting(.available, provider: .claude)
        try self.installRateLimitDescriptor(store)

        await self.refreshWithStableClaudeCredentials(store)

        let rows = store.accountSnapshots[.claude] ?? []
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.account.id == primary.id })?.snapshot?.updatedAt == primaryPrior.updatedAt)
        #expect(rows.first(where: { $0.account.id == secondary.id })?.snapshot?.updatedAt == secondaryPrior.updatedAt)
        #expect(store.snapshot(for: .claude)?.updatedAt == selectedPrior.updatedAt)
        #expect(store.error(for: .claude) == nil)
        #expect(store.knownLimitsAvailability(for: .claude) == .available)
        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    private func makeStore(
        suite: String,
        layout: MultiAccountMenuLayout = .segmented) throws -> UsageStore
    {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
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
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = .oauth
        settings.claudeOAuthKeychainPromptMode = .never
        settings.multiAccountMenuLayout = layout
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    @MainActor
    private func installRateLimitDescriptor(_ store: UsageStore) throws {
        let baseSpec = try #require(store.providerSpecs[.claude])
        let descriptor = ProviderDescriptor(
            id: .claude,
            metadata: baseSpec.descriptor.metadata,
            branding: baseSpec.descriptor.branding,
            tokenCost: baseSpec.descriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.oauth],
                pipeline: ProviderFetchPipeline { _ in [ClaudeOAuthRateLimitStrategy()] }),
            cli: baseSpec.descriptor.cli)
        store.providerSpecs[.claude] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }

    private func refreshWithStableClaudeCredentials(_ store: UsageStore) async {
        await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let missingCredentialsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                await store.refreshProvider(.claude)
            }
        }
    }

    @MainActor
    private func seedAccountSnapshot(
        store: UsageStore,
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot)
    {
        self.seedAccountSnapshots(store: store, values: [(account, snapshot)])
    }

    @MainActor
    private func seedAccountSnapshots(
        store: UsageStore,
        values: [(ProviderTokenAccount, UsageSnapshot)])
    {
        store.accountSnapshots[.claude] = values.map { account, snapshot in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: snapshot,
                error: nil,
                sourceLabel: "oauth",
                cacheKey: store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
        }
    }

    private func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_900_000_000 + usedPercent),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + usedPercent),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "test@example.com",
                accountOrganization: nil,
                loginMethod: "OAuth"))
    }
}

private struct ClaudeOAuthRateLimitStrategy: ProviderFetchStrategy {
    let id = "test.claude-oauth-rate-limit"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ClaudeUsageError.oauthFailed(ClaudeOAuthFetchError.usageRateLimitDescription)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
