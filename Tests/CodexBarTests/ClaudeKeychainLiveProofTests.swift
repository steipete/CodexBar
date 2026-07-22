import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeKeychainLiveProofTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_CLAUDE_KEYCHAIN_PROOF"] == "1"
    }

    @Test
    func `live app Auto transitions missing safe OAuth to the owner CLI`() async throws {
        guard Self.isEnabled else { return }
        let binary = try #require(TTYCommandRunner.which("claude"))
        let mode = ClaudeOAuthKeychainPromptPreference.storedMode()
        #expect(
            ClaudeOAuthCredentialsStore.directClaudeCodeKeychainAccessAllowedForTesting == false,
            "Stored mode \(mode.rawValue) must not reopen Claude Code's Keychain item")

        var environment = ProcessInfo.processInfo.environment
        for key in ClaudeAdminAPISettingsReader.apiKeyEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: ClaudeOAuthCredentialsStore.environmentTokenKey)
        environment.removeValue(forKey: ClaudeOAuthCredentialsStore.environmentScopesKey)
        environment["CLAUDE_CLI_PATH"] = binary
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=synthetic-session"))
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let strategies = await ProviderDescriptorRegistry.descriptor(for: .claude)
            .fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.oauth", "claude.cli", "claude.web"])
        #expect(await strategies[0].isAvailable(context))
        #expect(await strategies[1].isAvailable(context))

        let missingCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-live-claude-credentials-\(UUID().uuidString).json")
        let outcome = await KeychainCacheStore.withServiceOverrideForTesting(
            "com.steipete.codexbar.live-proof.\(UUID().uuidString)")
        {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                        missingCredentialsURL)
                    {
                        await ProviderDescriptorRegistry.descriptor(for: .claude)
                            .fetchPlan.fetchOutcome(context: context, provider: .claude)
                    }
                }
            }
        }

        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true, true])
        #expect(outcome.attempts.first?.errorDescription?.contains("credentials not found") == true)
        switch outcome.result {
        case let .success(result):
            #expect(result.strategyID == "claude.cli")
            #expect(result.sourceLabel == "claude")
        case .failure:
            Issue.record("Expected live owner CLI fallback to succeed")
        }
    }

    @Test
    func `live explicit user auth probe reports Claude login`() async throws {
        guard Self.isEnabled else { return }
        let binary = try #require(TTYCommandRunner.which("claude"))

        let isLoggedIn = await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await ClaudeCLIAuthStatusProbe.isLoggedIn(
                binary: binary,
                environment: ProcessInfo.processInfo.environment,
                timeout: 8)
        }

        #expect(isLoggedIn)
    }
}
