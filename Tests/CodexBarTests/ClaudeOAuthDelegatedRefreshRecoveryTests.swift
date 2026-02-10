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
    func delegatedRefresh_attemptedSucceeded_silentKeychainSync_recovers() async throws {
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

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
                defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

                // Seed an expired cache entry owned by Claude CLI, so the initial load delegates refresh.
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

                // Sanity: setup should be visible to the code under test (otherwise it may attempt interactive reads).
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

                let snapshot = try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                    data: freshData,
                    fingerprint: fingerprint)
                {
                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                        try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(delegatedOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }

                #expect(await delegatedCounter.current() == 1)
                #expect(await tokenCapture.get() == "fresh-token")
                #expect(snapshot.primary.usedPercent == 7)
                #expect(snapshot.secondary?.usedPercent == 21)
            }
        }
    }
}
