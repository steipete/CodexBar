import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeUsageDelegatedRefreshEnvironmentTests {
    private typealias CredentialLoader = @Sendable (
        [String: String],
        Bool,
        Bool) async throws -> ClaudeOAuthCredentials

    private func credentialsData(accessToken: String) -> Data {
        Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "\(accessToken)",
                "refreshToken": "refresh-\(accessToken)",
                "expiresAt": \(Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)),
                "scopes": ["user:profile"]
              }
            }
            """.utf8)
    }

    private func cacheKey(environment: [String: String]) -> KeychainCacheStore.Key {
        ClaudeOAuthCredentialsStore.cacheKeyForTesting(
            profileIdentifier: ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment))
    }

    private func storeCache(accessToken: String, environment: [String: String]) {
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        KeychainCacheStore.store(
            key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: profileIdentifier),
            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                data: self.credentialsData(accessToken: accessToken),
                storedAt: Date(),
                owner: .claudeCLI,
                profileIdentifier: profileIdentifier))
    }

    private func cachedToken(environment: [String: String]) throws -> String? {
        switch KeychainCacheStore.load(
            key: self.cacheKey(environment: environment),
            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
        {
        case let .found(entry):
            return try ClaudeOAuthCredentials.parse(data: entry.data).accessToken
        case .missing:
            return nil
        case .invalid, .temporarilyUnavailable:
            Issue.record("Expected a valid or missing profile cache entry")
            return nil
        }
    }

    @Test
    func `oauth delegated retry passes fetcher environment to delegated refresh`() async throws {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["CLAUDE_CLI_PATH": "/tmp/rat110-env-claude"],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let delegatedOverride: (@Sendable (Date, TimeInterval, [String: String]) async
            -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _, environment in
            #expect(environment["CLAUDE_CLI_PATH"] == "/tmp/rat110-env-claude")
            return .cliUnavailable
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredsOverride,
                                operation: {
                                    try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(
                                        false,
                                        operation: {
                                            try await fetcher.loadLatestUsage(model: "sonnet")
                                        })
                                })
                        })
                }
            }
            Issue.record("Expected delegated retry to fail when the override reports CLI unavailable")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("Claude CLI is not available"))
        }
    }

    @Test
    func `oauth rejection invalidates only the fetcher profile`() async throws {
        let service = "com.steipete.codexbar.cache.environment-tests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let environmentA = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-a").path]
        let environmentB = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-b").path]
        let credentials = try ClaudeOAuthCredentials.parse(data: self.credentialsData(accessToken: "request-token"))
        let loadOverride: CredentialLoader? = { environment, _, _ in
            #expect(environment == environmentA)
            return credentials
        }
        let fetchOverride: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
            throw ClaudeOAuthFetchError.serverError(500, "synthetic rejection")
        }
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: environmentA,
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        self.storeCache(accessToken: "profile-a-token", environment: environmentA)
                        self.storeCache(accessToken: "profile-b-token", environment: environmentB)

                        await #expect(throws: ClaudeUsageError.self) {
                            try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(true) {
                                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                                    try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                        loadOverride)
                                    {
                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                    }
                                }
                            }
                        }

                        let cachedA = try self.cachedToken(environment: environmentA)
                        let cachedB = try self.cachedToken(environment: environmentB)
                        #expect(cachedA == nil)
                        #expect(cachedB == "profile-b-token")
                    }
                }
            }
        }
    }

    @Test
    func `delegated recovery syncs only the fetcher profile`() async throws {
        let service = "com.steipete.codexbar.cache.environment-tests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let environmentA = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-a").path]
        let environmentB = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-b").path]
        let syncedData = self.credentialsData(accessToken: "synced-profile-a-token")
        let loadOverride: CredentialLoader? = { environment, _, _ in
            #expect(environment == environmentA)
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }
        let delegatedOverride: (@Sendable (Date, TimeInterval, [String: String]) async
            -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _, environment in
            #expect(environment == environmentA)
            return .attemptedSucceeded
        }
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: environmentA,
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        self.storeCache(accessToken: "profile-a-old", environment: environmentA)
                        self.storeCache(accessToken: "profile-b-token", environment: environmentB)

                        await #expect(throws: ClaudeUsageError.self) {
                            try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                .onlyOnUserAction)
                            {
                                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                    try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                        data: syncedData,
                                        fingerprint: nil)
                                    {
                                        try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(true) {
                                            try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                                                delegatedOverride)
                                            {
                                                try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride
                                                    .withValue(loadOverride) {
                                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                                    }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        let cachedA = try self.cachedToken(environment: environmentA)
                        let cachedB = try self.cachedToken(environment: environmentB)
                        #expect(cachedA == "synced-profile-a-token")
                        #expect(cachedB == "profile-b-token")
                    }
                }
            }
        }
    }
}
