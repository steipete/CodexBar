import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreSecurityCLIFallbackPolicyTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func experimentalReader_hasClaudeKeychainCredentialsWithoutPrompt_backgroundFallbackBlockedByStoredPolicy() {
        let fallbackData = self.makeCredentialsData(
            accessToken: "fallback-should-be-blocked",
            expiresAt: Date(timeIntervalSinceNow: 3600))

        let hasCredentials = KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                .securityCLIExperimental,
                operation: {
                    ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                        .onlyOnUserAction,
                        operation: {
                            ProviderInteractionContext.$current.withValue(.background) {
                                ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: fallbackData,
                                    fingerprint: nil)
                                {
                                    ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                        .nonZeroExit)
                                    {
                                        ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
                                    }
                                }
                            }
                        })
                })
        }

        #expect(hasCredentials == false)
    }

    @Test
    func experimentalReader_syncFromClaudeKeychainWithoutPrompt_backgroundFallbackBlockedByStoredPolicy() {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    defer { ClaudeOAuthCredentialsStore.invalidateCache() }

                    let fallbackData = self.makeCredentialsData(
                        accessToken: "sync-fallback-should-be-blocked",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    final class Counter: @unchecked Sendable {
                        var value = 0
                    }
                    let preflightCalls = Counter()
                    let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                        preflightCalls.value += 1
                        return .allowed
                    }

                    let synced = KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                        preflightOverride,
                        operation: {
                            ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                .securityCLIExperimental,
                                operation: {
                                    ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction,
                                        operation: {
                                            ProviderInteractionContext.$current.withValue(.background) {
                                                ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                    data: fallbackData,
                                                    fingerprint: nil)
                                                {
                                                    ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                        .timedOut)
                                                    {
                                                        ClaudeOAuthCredentialsStore
                                                            .syncFromClaudeKeychainWithoutPrompt(now: Date())
                                                    }
                                                }
                                            }
                                        })
                                })
                        })

                    #expect(synced == false)
                    #expect(preflightCalls.value == 0)
                }
            }
        }
    }
}
