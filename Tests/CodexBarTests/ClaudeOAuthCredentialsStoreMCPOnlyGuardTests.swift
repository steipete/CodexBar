import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreMCPOnlyGuardTests {
    @Test
    func `standard reader skips MCP keychain probe in background but preserves user refresh`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let mcpOAuthOnly = Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"synthetic"}}}"#.utf8)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let credentialsURL = tempDir.appendingPathComponent("credentials.json")

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                    await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                            await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: mcpOAuthOnly,
                                fingerprint: nil)
                            {
                                let isMcpOnly = ProviderInteractionContext.$current.withValue(.background) {
                                    ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                                        interaction: .background,
                                        readStrategy: .securityFramework,
                                        keychainAccessDisabled: false,
                                        environment: [:])
                                }
                                #expect(!isMcpOnly)

                                let userInitiatedIsMcpOnly = ProviderInteractionContext.$current
                                    .withValue(.userInitiated) {
                                        ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                                            interaction: .userInitiated,
                                            readStrategy: .securityFramework,
                                            keychainAccessDisabled: false,
                                            environment: [:])
                                    }
                                #expect(userInitiatedIsMcpOnly)

                                ClaudeOAuthCredentialsStore.invalidateCache()
                                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                                defer { KeychainCacheStore.clear(key: cacheKey) }
                                KeychainCacheStore.store(
                                    key: cacheKey,
                                    entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                        data: self.expiredCredentialsData,
                                        storedAt: Date(),
                                        owner: .claudeCLI))

                                do {
                                    _ = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                    Issue.record("Expected background refresh delegation")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case .refreshDelegatedToClaudeCLI = error else {
                                        Issue.record("Expected .refreshDelegatedToClaudeCLI, got \(error)")
                                        return
                                    }
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }

                                do {
                                    _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                            environment: [:],
                                            allowKeychainPrompt: false,
                                            respectKeychainPromptCooldown: true)
                                    }
                                    Issue.record("Expected explicit user Refresh to delegate")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case .refreshDelegatedToClaudeCLI = error else {
                                        Issue.record("Expected .refreshDelegatedToClaudeCLI, got \(error)")
                                        return
                                    }
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var expiredCredentialsData: Data {
        let json = #"""
        {
          "claudeAiOauth": {
            "accessToken": "expired",
            "refreshToken": "refresh",
            "expiresAt": 1000,
            "scopes": ["user:profile"]
          }
        }
        """#
        return Data(json.utf8)
    }
}
#endif
