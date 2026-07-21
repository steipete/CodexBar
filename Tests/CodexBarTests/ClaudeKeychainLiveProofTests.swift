import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeKeychainLiveProofTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_CLAUDE_KEYCHAIN_PROOF"] == "1"
    }

    @Test
    func `live app Auto enforces Claude credential ownership and builds CLI then web`() async throws {
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
        environment["CLAUDE_CLI_PATH"] = binary
        environment[ClaudeOAuthCredentialsStore.environmentTokenKey] = "synthetic-ambient-oauth-token"
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

        #expect(strategies.map(\.id) == ["claude.cli", "claude.web"])
        #expect(await strategies[0].isAvailable(context))
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
