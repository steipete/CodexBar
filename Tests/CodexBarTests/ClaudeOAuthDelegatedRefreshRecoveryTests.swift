import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshRecoveryTests {
    private actor AsyncCounter {
        private var value = 0

        func increment() -> Int {
            self.value += 1
            return self.value
        }

        func current() -> Int {
            self.value
        }
    }

    private actor TokenCapture {
        private var token: String?

        func set(_ token: String) {
            self.token = token
        }

        func get() -> String? {
            self.token
        }
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }

    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField: String = {
            guard let refreshToken else { return "" }
            return ",\n            \"refreshToken\": \"\(refreshToken)\""
        }()
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]\(refreshField)
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func silentKeychainRepair_recoversWithoutDelegation() async throws {
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let tokenCapture = TokenCapture()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        let snapshot = try await ClaudeOAuthCredentialsStore
                            .withCredentialsURLOverrideForTesting(fileURL) {
                                // Seed an expired cache entry owned by Claude CLI, so the initial load delegates
                                // refresh.
                                ClaudeOAuthCredentialsStore.invalidateCache()
                                let expiredData = self.makeCredentialsData(
                                    accessToken: "expired-token",
                                    expiresAt: Date(timeIntervalSinceNow: -3600))
                                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                                let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(),
                                    owner: .claudeCLI)
                                KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                                defer { KeychainCacheStore.clear(key: cacheKey) }

                                // Sanity: setup should be visible to the code under test.
                                // Otherwise it may attempt interactive reads.
                                #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:]) == true)

                                // Simulate Claude CLI writing fresh credentials into the Claude Code keychain entry.
                                let freshData = self.makeCredentialsData(
                                    accessToken: "fresh-token",
                                    expiresAt: Date(timeIntervalSinceNow: 3600))
                                let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                    modifiedAt: 1,
                                    createdAt: 1,
                                    persistentRefHash: "test")

                                let fetcher = ClaudeUsageFetcher(
                                    browserDetection: BrowserDetection(cacheTTL: 0),
                                    environment: [:],
                                    dataSource: .oauth,
                                    oauthKeychainPromptCooldownEnabled: true)

                                let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { token in
                                    await tokenCapture.set(token)
                                    return usageResponse
                                }
                                let delegatedOverride: (@Sendable (
                                    Date,
                                    TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
                                    _ = await delegatedCounter.increment()
                                    return .attemptedSucceeded
                                }

                                let snapshot = try await ClaudeOAuthKeychainPromptPreference
                                    .withTaskOverrideForTesting(.onlyOnUserAction) {
                                        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: freshData,
                                                fingerprint: fingerprint)
                                            {
                                                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride
                                                    .withValue(fetchOverride) {
                                                        try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                                            .withValue(delegatedOverride) {
                                                                try await fetcher.loadLatestUsage(model: "sonnet")
                                                            }
                                                    }
                                            }
                                        }
                                    }

                                // If Claude keychain already contains fresh credentials, we should recover without
                                // needing a
                                // CLI
                                // touch.
                                #expect(await delegatedCounter.current() == 0)
                                #expect(await tokenCapture.get() == "fresh-token")
                                #expect(snapshot.primary.usedPercent == 7)
                                #expect(snapshot.secondary?.usedPercent == 21)
                                return snapshot
                            }
                        _ = snapshot
                    }
                }
            }
        }
    }

    @Test
    func delegatedRefresh_attemptedSucceeded_recoversAfterKeychainSync() async throws {
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let tokenCapture = TokenCapture()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        let snapshot = try await ClaudeOAuthCredentialsStore
                            .withCredentialsURLOverrideForTesting(fileURL) {
                                // Seed an expired cache entry owned by Claude CLI, so the initial load delegates
                                // refresh.
                                ClaudeOAuthCredentialsStore.invalidateCache()
                                let expiredData = self.makeCredentialsData(
                                    accessToken: "expired-token",
                                    expiresAt: Date(timeIntervalSinceNow: -3600))
                                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                                let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(),
                                    owner: .claudeCLI)
                                KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                                defer { KeychainCacheStore.clear(key: cacheKey) }

                                // Ensure we don't silently repair from the Claude keychain before delegation.
                                // Use an explicit empty-data override so we never consult the real system Keychain
                                // during
                                // tests.
                                let stubFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                    modifiedAt: 1,
                                    createdAt: 1,
                                    persistentRefHash: "test")
                                let keychainOverrideStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
                                    data: Data(),
                                    fingerprint: stubFingerprint)

                                let freshData = self.makeCredentialsData(
                                    accessToken: "fresh-token",
                                    expiresAt: Date(timeIntervalSinceNow: 3600))

                                let fetcher = ClaudeUsageFetcher(
                                    browserDetection: BrowserDetection(cacheTTL: 0),
                                    environment: [:],
                                    dataSource: .oauth,
                                    oauthKeychainPromptCooldownEnabled: true)

                                let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { token in
                                    await tokenCapture.set(token)
                                    return usageResponse
                                }

                                let delegatedOverride: (@Sendable (
                                    Date,
                                    TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
                                    // Simulate Claude CLI writing fresh credentials after the delegated refresh touch.
                                    keychainOverrideStore.data = freshData
                                    keychainOverrideStore.fingerprint = stubFingerprint
                                    _ = await delegatedCounter.increment()
                                    return .attemptedSucceeded
                                }

                                let snapshot = try await ClaudeOAuthKeychainPromptPreference
                                    .withTaskOverrideForTesting(.always) {
                                        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try await ClaudeOAuthCredentialsStore
                                                .withMutableClaudeKeychainOverrideStoreForTesting(
                                                    keychainOverrideStore)
                                                {
                                                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride
                                                        .withValue(fetchOverride) {
                                                            try await ClaudeUsageFetcher
                                                                .$delegatedRefreshAttemptOverride
                                                                .withValue(delegatedOverride) {
                                                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                                                }
                                                        }
                                                }
                                        }
                                    }

                                #expect(await delegatedCounter.current() == 1)
                                let capturedToken = await tokenCapture.get()
                                if capturedToken != "fresh-token" {
                                    Issue.record("Expected fresh-token, got \(capturedToken ?? "nil")")
                                }
                                #expect(capturedToken == "fresh-token")
                                #expect(snapshot.primary.usedPercent == 7)
                                #expect(snapshot.secondary?.usedPercent == 21)
                                return snapshot
                            }
                        _ = snapshot
                    }
                }
            }
        }
    }

    @Test
    func delegatedRefresh_attemptedSucceeded_backgroundOnlyOnUserAction_doesNotRecoverFromKeychain() async throws {
        let delegatedCounter = AsyncCounter()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let fileURL = tempDir.appendingPathComponent("credentials.json")

                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-token",
                                expiresAt: Date(timeIntervalSinceNow: -3600))
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                data: expiredData,
                                storedAt: Date(),
                                owner: .claudeCLI)
                            KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            // Expired Claude-CLI-owned credentials are still considered cache-present (delegatable).
                            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:]) == true)

                            let stubFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                modifiedAt: 1,
                                createdAt: 1,
                                persistentRefHash: "test")
                            let keychainOverrideStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
                                data: Data(),
                                fingerprint: stubFingerprint)
                            let freshData = self.makeCredentialsData(
                                accessToken: "fresh-token",
                                expiresAt: Date(timeIntervalSinceNow: 3600))

                            let fetcher = ClaudeUsageFetcher(
                                browserDetection: BrowserDetection(cacheTTL: 0),
                                environment: [:],
                                dataSource: .oauth,
                                oauthKeychainPromptCooldownEnabled: false,
                                allowBackgroundDelegatedRefresh: true)

                            let delegatedOverride: (@Sendable (
                                Date,
                                TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
                                keychainOverrideStore.data = freshData
                                keychainOverrideStore.fingerprint = stubFingerprint
                                _ = await delegatedCounter.increment()
                                return .attemptedSucceeded
                            }

                            do {
                                _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                    .onlyOnUserAction)
                                {
                                    try await ProviderInteractionContext.$current.withValue(.background) {
                                        try await ClaudeOAuthCredentialsStore
                                            .withMutableClaudeKeychainOverrideStoreForTesting(keychainOverrideStore) {
                                                try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                                    .withValue(delegatedOverride) {
                                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                                    }
                                            }
                                    }
                                }
                                Issue.record(
                                    "Expected OAuth fetch failure: background keychain recovery should stay blocked")
                            } catch let error as ClaudeUsageError {
                                guard case let .oauthFailed(message) = error else {
                                    Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                                    return
                                }
                                #expect(message.contains("still unavailable after delegated Claude CLI refresh"))
                            } catch {
                                Issue.record("Expected ClaudeUsageError, got \(error)")
                            }

                            #expect(await delegatedCounter.current() == 1)
                        }
                    }
                }
            }
        }
    }
}
