import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Coverage for the #2634 consent gate: reading Claude Code's own Keychain item is allowed only after an
/// explicit opt-in, and every production read path (direct read, freshness sync, delegated-refresh
/// verification) resolves through the single `keychainAccessAllowed` choke point.
@Suite(.serialized)
struct ClaudeOAuthDirectKeychainReadConsentTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            ""
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        runtime: CodexBarCore.ProviderRuntime,
        sourceMode: ProviderSourceMode) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    // MARK: - Consent choke point

    @Test
    func `keychain access stays denied without consent even when the global gate is enabled`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            // Task-isolated consent default is OFF; no silent enable on upgrade.
            #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed == false)
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(false) {
                #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed == false)
            }
        }
    }

    @Test
    func `explicit consent reopens the single keychain access choke point`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed == true)
            }
        }
    }

    @Test
    func `disabling the global keychain gate wins over granted consent`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed == false)
            }
        }
    }

    // MARK: - Consent storage

    @Test
    func `stored consent defaults to off and honors an explicit opt in`() throws {
        let suiteName = "codexbar-consent-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ClaudeOAuthDirectKeychainReadConsent.isGranted(userDefaults: defaults) == false)
        defaults.set(true, forKey: ClaudeOAuthDirectKeychainReadConsent.userDefaultsKey)
        #expect(ClaudeOAuthDirectKeychainReadConsent.isGranted(userDefaults: defaults) == true)
        defaults.set(false, forKey: ClaudeOAuthDirectKeychainReadConsent.userDefaultsKey)
        #expect(ClaudeOAuthDirectKeychainReadConsent.isGranted(userDefaults: defaults) == false)
    }

    // MARK: - Unreadable terminal state typing

    @Test
    func `unreadable refresh result surfaces as the typed unreadable credentials error`() {
        let result = ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult(
            .attemptedFailed("No readable Claude credential source after the Claude CLI touch."),
            isUnreadableAfterRefresh: true)
        let error = ClaudeUsageFetcher.delegatedRefreshFailureError(
            for: result,
            retryError: ClaudeOAuthCredentialsError.notFound)
        let unreadable = error as? ClaudeOAuthUnreadableCredentialsError
        #expect(unreadable != nil)
        #expect(ClaudeOAuthUnreadableCredentialsError.matches(description: unreadable?.errorDescription))
        #expect(unreadable?.message.contains("Allow reading Claude Code credentials") == true)
    }

    @Test
    func `rate limited retries stay plain oauth failures even when unreadable`() {
        let result = ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult(
            .attemptedFailed("touch failed"),
            isUnreadableAfterRefresh: true)
        let error = ClaudeUsageFetcher.delegatedRefreshFailureError(
            for: result,
            retryError: ClaudeOAuthFetchError.rateLimited(retryAfter: nil))
        #expect(error is ClaudeUsageError)
        #expect(!(error is ClaudeOAuthUnreadableCredentialsError))
    }

    @Test
    func `readable refresh failures stay plain oauth failures`() {
        let result = ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult(
            .attemptedFailed("touch failed"),
            isUnreadableAfterRefresh: false)
        let error = ClaudeUsageFetcher.delegatedRefreshFailureError(
            for: result,
            retryError: ClaudeOAuthCredentialsError.notFound)
        #expect(error is ClaudeUsageError)
    }

    // MARK: - CLI usage fallback routing

    @Test
    func `unreadable oauth error falls back to the owner cli step for explicit oauth and auto`() {
        let strategy = ClaudeOAuthFetchStrategy()
        let error = ClaudeOAuthUnreadableCredentialsError(message: "unreadable")
        #expect(strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .oauth)))
        #expect(strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .auto)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .cli, sourceMode: .oauth)))
    }

    // MARK: - Degraded fidelity marker

    @Test
    func `cli scraped usage carries the percent only confidence marker`() {
        let usage = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil)
        let degraded = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage, dataConfidence: .percentOnly)
        #expect(degraded.dataConfidence == .percentOnly)
        let oauth = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(oauth.dataConfidence == .unknown)
    }

    // MARK: - Consent revocation invalidates cached credentials

    @Test
    @MainActor
    func `revoking consent drops codexbar cached claude credentials and reroutes to the cli fallback`() throws {
        let suite = "codexbar-consent-revocation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let memory = ClaudeOAuthCredentialsStore.MemoryCacheStore()
        try ClaudeOAuthCredentialsStore.$taskMemoryCacheStoreOverride.withValue(memory) {
            // Consent on: a credential read from Claude Code's Keychain lands in CodexBar's caches.
            settings.claudeOAuthDirectKeychainReadAllowed = true
            memory.record = ClaudeOAuthCredentialRecord(
                credentials: ClaudeOAuthCredentials(
                    accessToken: "cached-from-claude-keychain",
                    refreshToken: nil,
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    scopes: ["user:profile"],
                    rateLimitTier: nil),
                owner: .claudeCLI,
                source: .claudeKeychain)
            memory.timestamp = Date()
            memory.profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                environment: [:])
            #expect(memory.record != nil)

            // Consent off: the cached copy must not outlive the permission that obtained it.
            settings.claudeOAuthDirectKeychainReadAllowed = false
            #expect(memory.record == nil)
            #expect(settings.claudeOAuthDirectKeychainReadAllowed == false)

            // The direct-read gate is closed again, and with no readable credential the explicit
            // OAuth route hands off to the owner CLI usage fallback instead of reusing stale caches.
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(false) {
                #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed == false)
            }
            #expect(ClaudeOAuthFetchStrategy().shouldFallback(
                on: ClaudeOAuthCredentialsError.notFound,
                context: self.makeContext(runtime: .app, sourceMode: .oauth)))
        }
    }
}
