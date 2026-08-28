import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthFetchStrategyProfileRoutingTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `selected profile file ignores unrelated global MCP-only keychain`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = root.appendingPathComponent("selected-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["CLAUDE_CONFIG_DIR": profile.path]
        try self.makeCredentialsData(
            accessToken: "selected-expired",
            expiresAt: Date(timeIntervalSinceNow: -60))
            .write(to: ClaudeConfigPaths.credentialsURL(environment: environment))

        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let record = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "selected-expired",
                refreshToken: "selected-refresh",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:profile"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .cacheKeychain)
        let mcpOAuthOnly = Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"other-profile"}}}"#.utf8)
        let strategy = ClaudeOAuthFetchStrategy()

        let available = await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride.withValue(record) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await KeychainAccessGate.withTaskOverrideForTesting(false) {
                        await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                            await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: mcpOAuthOnly,
                                fingerprint: nil)
                            {
                                await ProviderInteractionContext.$current.withValue(.background) {
                                    await strategy.isAvailable(context)
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(available)
    }

    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "refreshToken": "selected-refresh",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }
}
#endif
