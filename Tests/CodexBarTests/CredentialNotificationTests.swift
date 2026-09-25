import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CredentialNotificationTests {
    @Test
    func `episodes survive network quota and cached data and recover only for the same account`() {
        let settings = testSettingsStore(suiteName: "credential-episodes")
        let store = Self.store(settings)
        let key = CredentialNotificationKey(provider: .kimi, account: "first")
        let expired = Result<ProviderFetchResult, Error>.failure(KimiAPIError.expiredCodeCredential)
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: expired)
        #expect(store.credentialNotificationEpisodes.isEmpty)
        settings.credentialExpiryNotificationsEnabled = true
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: expired)
        let episode = store.credentialNotificationEpisodes[key]
        #expect(episode != nil)
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: expired)
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: .failure(URLError(.timedOut)))
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: .failure(
            ProviderFetchClassifiedError(kind: .rateLimited, message: "Token quota exhausted")))
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: .success(Self.result(source: "cache")))
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: .success(
            Self.result(source: "oauth", diagnostic: "offline fallback")))
        store.handleCredentialOutcome(provider: .kimi, account: "second", result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes[key] == episode)
        store.handleCredentialOutcome(provider: .kimi, account: "second", result: expired)
        store.handleCredentialOutcome(provider: .claude, account: "first", result: expired)
        #expect(store.credentialNotificationEpisodes.count == 3)
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes[key] == nil)
        store.handleCredentialOutcome(provider: .kimi, account: "first", result: expired)
        #expect(store.credentialNotificationEpisodes[key] != episode)
        #expect(store.credentialNotificationEpisodes.count == 3)
    }

    @Test
    func `turning notifications off does not forget an unresolved episode`() {
        let settings = testSettingsStore(suiteName: "credential-disable")
        settings.credentialExpiryNotificationsEnabled = true
        let store = Self.store(settings)
        let expired = Result<ProviderFetchResult, Error>.failure(AugmentStatusProbeError.sessionExpired)
        store.handleCredentialOutcome(provider: .augment, result: expired)
        let episodes = store.credentialNotificationEpisodes
        settings.credentialExpiryNotificationsEnabled = false
        store.handleCredentialOutcome(provider: .augment, result: expired)
        settings.credentialExpiryNotificationsEnabled = true
        store.handleCredentialOutcome(provider: .augment, result: expired)
        #expect(store.credentialNotificationEpisodes == episodes)
        store.credentialNotificationsStopped = true
        store.credentialNotificationEpisodes.removeAll()
        store.handleCredentialOutcome(provider: .augment, result: expired)
        #expect(store.credentialNotificationEpisodes.isEmpty)
    }

    @Test(arguments: ProviderFetchClassifiedError.Kind.allCases)
    func `classified provider failures are authoritative`(kind: ProviderFetchClassifiedError.Kind) {
        let error = ProviderFetchClassifiedError(kind: kind, message: "token expired, login required")
        #expect(ProviderCredentialFailure.isAuthenticationFailure(error) ==
            (kind == .authenticationExpired || kind == .missingCredential))
    }

    @Test
    func `native credential errors exclude quota network permission and parse failures`() {
        let auth: [Error] = [
            KimiAPIError.expiredCodeCredential, KimiAPIError.invalidCodeCredential,
            DoubaoUsageError.arkcliAuthenticationRequired, AlibabaTokenPlanUsageError.loginRequired,
            ClaudeOAuthFetchError.unauthorized, CodexOAuthFetchError.unauthorized,
            ClaudeUsageError.oauthFailed(ClaudeOAuthFetchError.unauthorized.localizedDescription),
            ClaudeUsageError
                .oauthFailed(ClaudeOAuthCredentialsError.refreshFailed("invalid_grant").localizedDescription),
            ClaudeUsageError.oauthFailed("Claude OAuth token expired and delegated refresh is cooling down."),
            AugmentStatusProbeError.sessionExpired,
        ]
        #expect(auth.allSatisfy(ProviderCredentialFailure.isAuthenticationFailure))
        let other: [Error] = [
            KimiAPIError.apiError("You've reached your token usage limit for this billing cycle"),
            KimiAPIError.networkError("token expired"), URLError(.notConnectedToInternet),
            ClaudeUsageError.oauthFailed(ClaudeOAuthFetchError.usageRateLimitDescription),
            ClaudeOAuthCredentialsError.keychainAccessRevoked,
            ClaudeOAuthCredentialsError.refreshFailed("network offline"),
            ClaudeUsageError
                .oauthFailed(ClaudeOAuthCredentialsError.refreshFailed("network offline").localizedDescription),
            DoubaoUsageError.arkcliTimedOut, DoubaoUsageError.arkcliNotFound,
            AlibabaTokenPlanUsageError.apiError("insufficient balance"),
            AugmentStatusProbeError.networkError("login required"),
        ]
        #expect(other.allSatisfy { !ProviderCredentialFailure.isAuthenticationFailure($0) })
    }

    @Test(arguments: [false, true])
    func `ordinary and selected account outcomes share account-specific episodes`(selected: Bool) async {
        let settings = testSettingsStore(
            suiteName: "credential-refresh-\(selected)", tokenAccountStore: InMemoryTokenAccountStore())
        settings.credentialExpiryNotificationsEnabled = true
        settings.statusChecksEnabled = false
        settings.addTokenAccount(provider: .deepseek, label: "First", token: "fixture-first")
        settings.addTokenAccount(provider: .deepseek, label: "Second", token: "fixture-second")
        let store = Self.store(settings)
        let accounts = settings.tokenAccounts(for: .deepseek)
        #expect(accounts.count == 2)
        for index in [0, 1, 0] {
            settings.setActiveTokenAccountIndex(index, for: .deepseek)
            let outcome = ProviderFetchOutcome(
                result: .failure(
                    ProviderFetchClassifiedError(
                        kind: .authenticationExpired,
                        message: "synthetic expired credential")),
                attempts: [])
            if selected {
                await store.applySelectedOutcome(
                    outcome,
                    provider: .deepseek,
                    account: accounts[index],
                    fallbackSnapshot: nil)
            } else {
                store._test_providerFetchOutcomeOverride = { _ in outcome }
                await store.refreshProvider(.deepseek, allowDisabled: true)
            }
        }
        #expect(store.credentialNotificationEpisodes.count == 2)
        #expect(Set(store.credentialNotificationEpisodes.keys.map(\.account)) ==
            Set(accounts.compactMap(UsageStore.warningTokenAccountDiscriminator)))
    }

    @Test(arguments: ["before", "authorization", "submission", "denied", "never"])
    func `shared delivery retires notifications when consent or lifecycle changes`(retireAt: String) async throws {
        var current = retireAt != "before"
        var authorized = 0
        var submitted = 0
        var removed = 0
        try await AppNotifications.deliverIfCurrent(
            authorize: {
                authorized += 1
                if retireAt == "authorization" { current = false }
                return retireAt != "denied"
            },
            submit: {
                submitted += 1
                if retireAt == "submission" { current = false }
            },
            remove: { removed += 1 },
            isCurrent: { current })
        #expect(authorized == (retireAt == "before" ? 0 : 1))
        #expect(submitted == (["submission", "never"].contains(retireAt) ? 1 : 0))
        #expect(removed == (retireAt == "submission" ? 1 : 0))
    }

    @Test
    func `failed delivery retries while delivered episodes retire on recovery or shutdown`() {
        let settings = testSettingsStore(suiteName: "credential-delivery")
        settings.credentialExpiryNotificationsEnabled = true
        let store = Self.store(settings)
        var submitted: [String] = []
        var removed: [String] = []
        var completions: [@MainActor (Bool) -> Void] = []
        store._test_credentialNotificationPost = { id, completion in
            submitted.append(id)
            completions.append(completion)
        }
        store._test_credentialNotificationRemove = { removed.append($0) }
        let expired = Result<ProviderFetchResult, Error>.failure(AugmentStatusProbeError.sessionExpired)
        store.handleCredentialOutcome(provider: .augment, result: expired)
        completions[0](false)
        #expect(store.credentialNotificationEpisodes.isEmpty)
        store.handleCredentialOutcome(provider: .augment, result: expired)
        #expect(submitted.count == 2)
        completions[0](false) // A late callback must not clear the replacement episode.
        completions[1](true)
        store.handleCredentialOutcome(provider: .augment, result: expired)
        #expect(submitted.count == 2)
        store.handleCredentialOutcome(provider: .augment, result: .success(Self.result()))
        #expect(removed == [submitted[1]])
        store.handleCredentialOutcome(provider: .augment, result: expired)
        completions[2](true)
        store.retireCredentialNotifications(provider: .augment)
        #expect(removed == [submitted[1], submitted[2]])
        #expect(store.credentialNotificationEpisodes.isEmpty)
        store.handleCredentialOutcome(provider: .augment, result: expired)
        completions[3](true)
        store.retireCredentialNotifications()
        #expect(removed.last == submitted[3])
    }

    @Test
    func `Claude identity gaps and later identity resolution preserve independent episodes`() {
        let settings = testSettingsStore(suiteName: "credential-claude-identity")
        settings.credentialExpiryNotificationsEnabled = true
        let store = Self.store(settings)
        let first = store.claudeCredentialNotificationScope(identity: nil, fingerprint: "first-file")
        let second = store.claudeCredentialNotificationScope(identity: nil, fingerprint: "second-file")
        #expect(first != second)
        let expired = Result<ProviderFetchResult, Error>.failure(ClaudeOAuthFetchError.unauthorized)
        store.handleCredentialOutcome(provider: .claude, account: first, result: expired)
        store.handleCredentialOutcome(provider: .claude, account: second, result: expired)
        #expect(store.credentialNotificationEpisodes.count == 2)
        #expect(store.claudeCredentialNotificationScope(identity: "first-account", fingerprint: "first-file") == first)
        #expect(store.claudeCredentialNotificationScope(identity: "first-account", fingerprint: nil) == first)
        #expect(store
            .claudeCredentialNotificationScope(identity: "first-account", fingerprint: "rotated-file") == first)
        #expect(store.claudeCredentialNotificationScope(identity: nil, fingerprint: "rotated-file") == first)
        let switched = store.claudeCredentialNotificationScope(identity: "second-account", fingerprint: "rotated-file")
        #expect(switched != first)
        store.handleCredentialOutcome(provider: .claude, account: switched, result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes.count == 2)
        store.handleCredentialOutcome(provider: .claude, account: first, result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes.count == 1)
    }

    @Test
    func `disabling a provider retires only its delivered credential alerts`() {
        let settings = testSettingsStore(suiteName: "credential-provider-disable", userDefaults: InMemoryUserDefaults())
        settings.credentialExpiryNotificationsEnabled = true
        enableTestProviders([.deepseek, .kimi], settings: settings)
        let store = Self.store(settings)
        var submitted: [String] = []
        var removed: [String] = []
        store._test_credentialNotificationPost = { id, completion in
            submitted.append(id)
            completion(true)
        }
        store._test_credentialNotificationRemove = { removed.append($0) }
        let expired = Result<ProviderFetchResult, Error>.failure(
            ProviderFetchClassifiedError(kind: .authenticationExpired, message: "Synthetic expiry"))
        store.handleCredentialOutcome(provider: .deepseek, result: expired)
        store.handleCredentialOutcome(provider: .kimi, result: expired)
        enableTestProviders([.kimi], settings: settings)
        store.retireDisabledCredentialNotifications()
        store.retireDisabledCredentialNotifications()
        #expect(removed == [submitted[0]])
        #expect(Set(store.credentialNotificationEpisodes.keys.map(\.provider)) == [.kimi])
        enableTestProviders([], settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        #expect(removed == submitted)
        #expect(store.credentialNotificationEpisodes.isEmpty)
    }

    private static func store(_ settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private static func result(source: String = "oauth", diagnostic: String? = nil) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            credits: nil,
            dashboard: nil,
            sourceLabel: source,
            strategyID: "fixture",
            strategyKind: .oauth,
            diagnostic: diagnostic)
    }
}
