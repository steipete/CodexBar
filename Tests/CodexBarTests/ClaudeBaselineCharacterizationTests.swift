import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeBaselineCharacterizationTests {
    private func makeStubClaudeCLI(loggedIn: Bool = true, invocationLog: URL? = nil) throws -> String {
        let loggedInJSON = loggedIn ? "true" : "false"
        return try self.makeStubClaudeCLI(
            authStatusScript: "printf '%s\\n' '{\"loggedIn\":\(loggedInJSON)}'",
            invocationLog: invocationLog)
    }

    private func makeStubClaudeCLI(authStatusScript: String, invocationLog: URL? = nil) throws -> String {
        let sample = """
        Current session
        12% used  (Resets 11am)
        Current week (all models)
        40% used  (Resets Nov 21)
        Current week (Sonnet only)
        5% used (Resets Nov 21)
        Account: user@example.com
        Org: Example Org
        """
        let recordInvocation = invocationLog.map { "printf '%s\\n' \"$*\" >> '\($0.path)'" } ?? ""
        let script = """
        #!/bin/sh
        \(recordInvocation)
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          \(authStatusScript)
          exit 0
        fi
        cat <<'EOF'
        \(sample)
        EOF
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stub-\(UUID().uuidString)")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeContext(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func strategyIDs(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) async -> [String]
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: runtime, sourceMode: sourceMode, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        return strategies.map(\.id)
    }

    private func fetchOutcome(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: runtime, sourceMode: sourceMode, env: env, settings: settings)
        return await descriptor.fetchPlan.fetchOutcome(context: context, provider: .claude)
    }

    @Test
    func `app auto pipeline order is CLI then web and excludes OAuth`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: true,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let env = [
            ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
            ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
            "CLAUDE_CLI_PATH": "/usr/bin/true",
        ]
        let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        #expect(strategyIDs == ["claude.cli", "claude.web"])
    }

    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
        ProviderSourceMode.cli,
    ])
    func `selected OAuth token account overrides every global app source`(sourceMode: ProviderSourceMode) async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .oauth,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = [
            ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
            "CLAUDE_CLI_PATH": "/usr/bin/true",
        ]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let baseContext = self.makeContext(runtime: .app, sourceMode: sourceMode, env: env, settings: settings)
        let context = ProviderFetchContext(
            runtime: baseContext.runtime,
            sourceMode: baseContext.sourceMode,
            includeCredits: baseContext.includeCredits,
            webTimeout: baseContext.webTimeout,
            webDebugDumpHTML: baseContext.webDebugDumpHTML,
            verbose: baseContext.verbose,
            env: baseContext.env,
            settings: baseContext.settings,
            fetcher: baseContext.fetcher,
            claudeFetcher: baseContext.claudeFetcher,
            browserDetection: baseContext.browserDetection,
            selectedTokenAccountID: UUID())

        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.oauth"])
        #expect(await strategies[0].isAvailable(context))
    }

    @Test
    func `CLI auto pipeline order is web then CLI`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let env = [
            "CLAUDE_CLI_PATH": "/usr/bin/true",
        ]
        let strategyIDs = await self.strategyIDs(runtime: .cli, sourceMode: .auto, env: env, settings: settings)
        #expect(strategyIDs == ["claude.web", "claude.cli"])
    }

    @Test
    func `explicit CLI pipeline attempts strategy even when planner marks CLI unavailable`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .cli,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = [
            "CLAUDE_CLI_PATH": "/definitely/missing/claude",
        ]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: .app, sourceMode: .cli, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.cli"])
        let isAvailable = await strategies[0].isAvailable(context)
        #expect(!isAvailable)
    }

    @Test
    func `auto pipeline records unavailable planned steps when planner has no executable source`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: true,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = ["CLAUDE_CLI_PATH": "/definitely/missing/claude"]

        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: .auto, env: env, settings: settings)
            #expect(strategyIDs == ["claude.cli", "claude.web"])

            let outcome = await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env, settings: settings)
            #expect(outcome.attempts.map(\.strategyID) == ["claude.cli", "claude.web"])
            #expect(outcome.attempts.map(\.wasAvailable) == [false, false])

            switch outcome.result {
            case let .failure(error as ProviderFetchError):
                switch error {
                case let .noAvailableStrategy(provider):
                    #expect(provider == .claude)
                }
            case let .failure(error):
                Issue.record("Unexpected failure: \(error)")
            case let .success(result):
                Issue.record("Unexpected success: \(result.sourceLabel)")
            }
        }
    }

    @Test
    func `app and CLI runtimes use owner mediated auth status before interactive usage`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(loggedIn: false, invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let appContext = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        let appStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(appContext)
        let appCLI = try #require(appStrategies.first { $0.id == "claude.cli" })

        let appCLIAvailable = await appCLI.isAvailable(appContext)
        #expect(!appCLIAvailable)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")

        let cliContext = self.makeContext(runtime: .cli, sourceMode: .auto, env: env, settings: settings)
        let cliStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(cliContext)
        let cli = try #require(cliStrategies.first { $0.id == "claude.cli" })
        let cliAvailable = await ClaudeCLIAuthStatusProbe.withTimeoutOverrideForTesting(20) {
            await cli.isAvailable(cliContext)
        }

        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
        #expect(!cliAvailable)
        #expect(invocations == "auth status --json\nauth status --json\n")
    }

    @Test
    func `app background auto availability ignores OAuth prompt settings`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let cli = try #require(strategies.first { $0.id == "claude.cli" })

        let available = await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental)
        {
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                await cli.isAvailable(context)
            }
        }

        #expect(available)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test
    func `app background auto availability is independent of Keychain access gate`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let cli = try #require(strategies.first { $0.id == "claude.cli" })

        let available = await KeychainAccessGate.withTaskOverrideForTesting(true) {
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                await cli.isAvailable(context)
            }
        }

        #expect(available)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test
    func `app user initiated auto does not launch logged out interactive CLI`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(loggedIn: false, invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let cli = try #require(strategies.first { $0.id == "claude.cli" })

        let cliAvailable = await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await cli.isAvailable(context)
        }

        #expect(!cliAvailable)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test
    func `app auto pipeline excludes OAuth bootstrap strategy at startup`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))

        let strategyIDs = await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            await ProviderRefreshContext.$current.withValue(.startup) {
                await ProviderInteractionContext.$current.withValue(.background) {
                    await self.strategyIDs(
                        runtime: .app,
                        sourceMode: .auto,
                        env: [ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token"],
                        settings: settings)
                }
            }
        }
        #expect(strategyIDs == ["claude.cli", "claude.web"])
    }

    @Test
    func `auto pipeline CLI uses planned environment for execution`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let stubCLIPath = try self.makeStubClaudeCLI()
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]

        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { binary, _, _ in
                #expect(binary == stubCLIPath)
                return ClaudeStatusSnapshot(
                    sessionPercentLeft: 88,
                    weeklyPercentLeft: 60,
                    opusPercentLeft: 95,
                    accountEmail: "user@example.com",
                    accountOrganization: "Example Org",
                    loginMethod: nil,
                    primaryResetDescription: "Resets 11am",
                    secondaryResetDescription: "Resets Nov 21",
                    opusResetDescription: "Resets Nov 21",
                    rawText: "stub")
            }
        let outcome = await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
            await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        }

        #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true])

        switch outcome.result {
        case let .success(result):
            #expect(result.strategyID == "claude.cli")
            #expect(result.sourceLabel == "claude")
            #expect(result.usage.primary?.usedPercent == 12)
            #expect(result.usage.secondary?.usedPercent == 40)
            #expect(result.usage.tertiary?.usedPercent == 5)
            #expect(result.usage.identity?.accountEmail == "user@example.com")
        case let .failure(error):
            Issue.record("Unexpected failure: \(error)")
        }
    }

    @Test(arguments: [
        (ProviderSourceMode.cli, "claude.cli"),
        (ProviderSourceMode.web, "claude.web"),
    ])
    func `explicit modes resolve single Claude strategy`(
        sourceMode: ProviderSourceMode,
        expectedStrategyID: String) async
    {
        let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: sourceMode)
        #expect(strategyIDs == [expectedStrategyID])
    }

    @Test
    func `app explicit OAuth plans direct credentials before owner mediated CLI`() async {
        let strategyIDs = await self.strategyIDs(
            runtime: .app,
            sourceMode: .oauth,
            env: ["CLAUDE_CLI_PATH": "/usr/bin/true"])

        #expect(strategyIDs == ["claude.oauth", "claude.cli"])
    }

    @Test(arguments: [
        (ProviderSourceMode.oauth, "claude.oauth"),
        (ProviderSourceMode.cli, "claude.cli"),
        (ProviderSourceMode.web, "claude.web"),
    ])
    func `CLI explicit modes resolve single Claude strategy`(
        sourceMode: ProviderSourceMode,
        expectedStrategyID: String) async
    {
        let strategyIDs = await self.strategyIDs(
            runtime: .cli,
            sourceMode: sourceMode,
            env: ["CLAUDE_CLI_PATH": "/usr/bin/true"])
        #expect(strategyIDs == [expectedStrategyID])
    }

    @Test
    func `Claude OAuth token heuristics accept raw and bearer inputs`() {
        #expect(TokenAccountSupportCatalog.isClaudeOAuthToken("sk-ant-oat-test-token"))
        #expect(TokenAccountSupportCatalog.isClaudeOAuthToken("Bearer sk-ant-oat-test-token"))
    }

    @Test
    func `Claude OAuth token heuristics reject cookie shaped inputs`() {
        #expect(!TokenAccountSupportCatalog.isClaudeOAuthToken("sessionKey=sk-ant-session"))
        #expect(!TokenAccountSupportCatalog.isClaudeOAuthToken("Cookie: sessionKey=sk-ant-session; foo=bar"))
    }
}
