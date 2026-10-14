import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures())
struct ClaudeOAuthNoninteractiveCredentialLoadTests {
    @Test(arguments: [true, false], [
        ClaudeOAuthKeychainPromptMode.never, .onlyOnUserAction, .always,
    ])
    func `explicit refresh reaches the prompt reader only with consent and an allowing policy`(
        consent: Bool,
        mode: ClaudeOAuthKeychainPromptMode) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let response = try Self.makeOAuthUsageResponse()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["HOME": root.path],
            dataSource: .oauth)
        let read: @Sendable () throws -> Data = {
            #expect(consent && mode != .never)
            return Data("""
            {"claudeAiOauth":{"accessToken":"synthetic-prompt-token",
            "expiresAt":4102444800000,"scopes":["user:profile"]}}
            """.utf8)
        }
        let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
            #expect(token == "synthetic-prompt-token")
            return response
        }
        try await KeychainCacheStore.withServiceOverrideForTesting("synthetic-prompt-\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                root.appendingPathComponent(".credentials.json"))
            {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try await ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(consent) {
                            try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                                try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                    .securityFramework)
                                {
                                    try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try await ClaudeOAuthCredentialsStore
                                            .withInteractiveClaudeKeychainReadOverridesForTesting(read: read) {
                                                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride
                                                    .withValue(fetchUsage) {
                                                        if consent, mode != .never {
                                                            let usage = try await fetcher
                                                                .loadLatestUsage(model: "sonnet")
                                                            #expect(usage.primary?.usedPercent == 7)
                                                        } else {
                                                            await #expect(throws: (any Error).self) {
                                                                try await fetcher.loadLatestUsage(model: "sonnet")
                                                            }
                                                        }
                                                    }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [
        ClaudeOAuthKeychainPromptMode.never,
        ClaudeOAuthKeychainPromptMode.onlyOnUserAction,
        ClaudeOAuthKeychainPromptMode.always,
    ])
    func `oauth credential loads allow repair only for an authorized user action`(
        mode: ClaudeOAuthKeychainPromptMode) async throws
    {
        final class FlagBox: @unchecked Sendable {
            var values: [Bool] = []
        }

        for interaction in [ProviderInteraction.background, .userInitiated] {
            let flags = FlagBox()
            let usageResponse = try Self.makeOAuthUsageResponse()
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                dataSource: .oauth,
                oauthKeychainPromptCooldownEnabled: true)
            let fetchUsage: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
                usageResponse
            }
            let loadCredentials: @Sendable ([String: String], Bool, Bool) async throws
                -> ClaudeOAuthCredentials = { _, allowKeychainPrompt, _ in
                    flags.values.append(allowKeychainPrompt)
                    return ClaudeOAuthCredentials(
                        accessToken: "explicit-token",
                        refreshToken: nil,
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        scopes: ["user:profile"],
                        rateLimitTier: nil)
                }

            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                try await ProviderInteractionContext.$current.withValue(interaction) {
                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(
                        fetchUsage,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredentials,
                                operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                }
            }

            #expect(flags.values == [interaction == .userInitiated && mode != .never])
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
}
