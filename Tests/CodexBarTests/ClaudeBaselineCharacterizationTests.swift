import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeBaselineCharacterizationTests {
    private enum ExpectedFetchError: Error {
        case failed
    }

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
        settings: ProviderSettingsSnapshot? = nil,
        claudeOwnerCLIRecoveryOnly: Bool = false) -> ProviderFetchContext
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
            browserDetection: browserDetection,
            claudeOwnerCLIRecoveryOnly: claudeOwnerCLIRecoveryOnly)
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

    private func withNoOAuthCredentials<T>(operation: () async throws -> T) async rethrows -> T {
        let missingCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-claude-creds-\(UUID().uuidString).json")
        return try await KeychainCacheStore.withServiceOverrideForTesting("claude-baseline-\(UUID().uuidString)") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: nil,
                                fingerprint: nil)
                            {
                                try await operation()
                            }
                        }
                    }
                }
            }
        }
    }

    private func withBackgroundKeychainAccess<T>(operation: () async throws -> T) async rethrows -> T {
        try await KeychainAccessGate.withTaskOverrideForTesting(false) {
            try await operation()
        }
    }

    @Test
    func `app auto pipeline order is safe OAuth then CLI then web`() async {
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
        #expect(strategyIDs == ["claude.oauth", "claude.cli", "claude.web"])
    }

    @Test
    func `owner CLI recovery retry excludes stale OAuth and unrelated fallbacks`() async throws {
        let stubCLIPath = try self.makeStubClaudeCLI()
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: true,
            cookieSource: .auto,
            manualCookieHeader: nil))
        let context = self.makeContext(
            runtime: .app,
            sourceMode: .auto,
            env: ["CLAUDE_CLI_PATH": stubCLIPath],
            settings: settings,
            claudeOwnerCLIRecoveryOnly: true)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)

        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.cli"])
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
    func `CLI explicit source delegates authentication to the configured Claude executable`() async throws {
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(
            authStatusScript: "printf '%s\\n' 'not-json'",
            invocationLog: invocationLog)
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(at: invocationLog)
        }
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .cli,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { binary, _, _ in
            #expect(binary == stubCLIPath)
            return Self.makeUsageStatusSnapshot()
        }

        let outcome = await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
            await self.fetchOutcome(runtime: .cli, sourceMode: .cli, env: env, settings: settings)
        }
        let result = try outcome.result.get()

        #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
        #expect(result.strategyID == "claude.cli")
        #expect(result.usage.dataConfidence == .percentOnly)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test
    func `CLI auto reaches Claude executable after web credentials are unavailable`() async throws {
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(
            authStatusScript: "printf '%s\\n' 'not-json'",
            invocationLog: invocationLog)
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(at: invocationLog)
        }
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .auto,
            manualCookieHeader: nil))
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let webLoader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            throw ClaudeWebAPIFetcher.FetchError.noSessionKeyFound
        }
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { binary, _, _ in
            #expect(binary == stubCLIPath)
            return Self.makeUsageStatusSnapshot()
        }

        let outcome = await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(webLoader) {
            await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                await self.fetchOutcome(runtime: .cli, sourceMode: .auto, env: env, settings: settings)
            }
        }
        let result = try outcome.result.get()

        #expect(outcome.attempts.map(\.strategyID) == ["claude.web", "claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true, true])
        #expect(result.strategyID == "claude.cli")
        #expect(result.usage.dataConfidence == .percentOnly)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test(arguments: [
        "/definitely/missing/claude",
        "/etc/hosts",
    ])
    func `CLI source rejects missing and non executable Claude paths`(path: String) async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .cli,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let outcome = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(path) {
            await self.fetchOutcome(
                runtime: .cli,
                sourceMode: .cli,
                env: ["CLAUDE_CLI_PATH": path],
                settings: settings)
        }

        #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false])
        switch outcome.result {
        case let .failure(error as ProviderFetchError):
            guard case .noAvailableStrategy(.claude) = error else {
                Issue.record("Unexpected provider fetch error: \(error)")
                return
            }
        case let .failure(error):
            Issue.record("Unexpected error: \(error)")
        case let .success(result):
            Issue.record("Unavailable Claude executable unexpectedly produced \(result.strategyID)")
        }
    }

    @Test
    func `CLI source keeps definitive logged out guard`() async throws {
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(loggedIn: false, invocationLog: invocationLog)
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(at: invocationLog)
        }
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .cli,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let outcome = await self.fetchOutcome(
            runtime: .cli,
            sourceMode: .cli,
            env: ["CLAUDE_CLI_PATH": stubCLIPath],
            settings: settings)

        #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false])
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
    }

    @Test
    func `app explicit CLI remains available for interactive authentication without preflight`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .cli,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = [
            "CLAUDE_CLI_PATH": "/usr/bin/true",
        ]
        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
            let context = self.makeContext(runtime: .app, sourceMode: .cli, env: env, settings: settings)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

            #expect(strategies.map(\.id) == ["claude.cli"])
            let isAvailable = await strategies[0].isAvailable(context)
            #expect(isAvailable)
        }
    }

    @Test
    func `auto pipeline records its OAuth attempt when no fallback source is available`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: true,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = ["CLAUDE_CLI_PATH": "/definitely/missing/claude"]

        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: .auto, env: env, settings: settings)
            #expect(strategyIDs == ["claude.oauth", "claude.cli", "claude.web"])

            let outcome = await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env, settings: settings)
            #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli", "claude.web"])
            #expect(outcome.attempts.map(\.wasAvailable) == [true, false, false])

            switch outcome.result {
            case let .failure(error as ClaudeOAuthCredentialsError):
                guard case .notFound = error else {
                    Issue.record("Unexpected OAuth failure: \(error)")
                    return
                }
            case let .failure(error):
                Issue.record("Unexpected failure: \(error)")
            case let .success(result):
                Issue.record("Unexpected success: \(result.sourceLabel)")
            }
        }
    }

    @Test
    func `app background auto does not start Claude CLI before foreground availability`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(loggedIn: false, invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await self.withBackgroundKeychainAccess {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await self.withNoOAuthCredentials {
                        let outcome = await self.fetchOutcome(
                            runtime: .app,
                            sourceMode: .auto,
                            env: env,
                            settings: settings)

                        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli", "claude.web"])
                        #expect(outcome.attempts.map(\.wasAvailable) == [true, false, false])
                    }
                }
            }
        }

        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `app background auto honors stored user action policy with experimental reader`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]

        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityCLIExperimental) {
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                await self.withNoOAuthCredentials {
                    let outcome = await self.fetchOutcome(
                        runtime: .app,
                        sourceMode: .auto,
                        env: env,
                        settings: settings)
                    #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli", "claude.web"])
                    #expect(outcome.attempts.map(\.wasAvailable) == [true, false, false])
                }
            }
        }

        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `app background auto falls back to web without probing Claude CLI`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(invocationLog: invocationLog)
        let env = ["CLAUDE_CLI_PATH": stubCLIPath]
        let usageLoader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            ClaudeUsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                opus: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil,
                rawText: nil)
        }

        let outcome = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await self.withBackgroundKeychainAccess {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await self.withNoOAuthCredentials {
                        await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(usageLoader) {
                            await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env, settings: settings)
                        }
                    }
                }
            }
        }
        let result = try outcome.result.get()

        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli", "claude.web"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true, false, true])
        #expect(result.strategyID == "claude.web")
        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `app background auto availability honors stored user action prompt policy`() async throws {
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

        let available = await self.withBackgroundKeychainAccess {
            await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                .securityCLIExperimental)
            {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    await cli.isAvailable(context)
                }
            }
        }

        #expect(!available)
        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `app background auto availability uses owner CLI when Keychain access is disabled`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-invocations-\(UUID().uuidString).log")
        let stubCLIPath = try self.makeStubClaudeCLI(invocationLog: invocationLog)
        let profileRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-disabled-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profileRoot) }
        try Data(#"{"oauthAccount":{"accountUuid":"disabled-keychain-account"}}"#.utf8)
            .write(to: profileRoot.appendingPathComponent(".config.json"), options: .atomic)
        let env = [
            "CLAUDE_CLI_PATH": stubCLIPath,
            "CLAUDE_CONFIG_DIR": profileRoot.path,
        ]
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
        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `app user initiated auto preserves CLI fallback without auth preflight`() async throws {
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

        #expect(cliAvailable)
        #expect(!FileManager.default.fileExists(atPath: invocationLog.path))
    }

    @Test
    func `successful user initiated CLI fetch establishes background availability`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let stubCLIPath = try self.makeStubClaudeCLI()
        let profileRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-background-establishment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profileRoot) }
        try Data(#"{"oauthAccount":{"accountUuid":"established-account"}}"#.utf8)
            .write(to: profileRoot.appendingPathComponent(".config.json"), options: .atomic)
        let env = [
            "CLAUDE_CLI_PATH": stubCLIPath,
            "CLAUDE_CONFIG_DIR": profileRoot.path,
        ]
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let cli = try #require(strategies.first { $0.id == "claude.cli" })
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
                    rawText: "")
            }

        try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            _ = try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await cli.fetch(context)
                }
            }
            let available = await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await cli.isAvailable(context)
                    }
                }
            }
            #expect(available)
        }
    }

    @Test
    func `failed CLI fetch revokes the account marker captured before an in flight account change`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let stubCLIPath = try self.makeStubClaudeCLI()
        let profileRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-background-revocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profileRoot) }
        let configURL = profileRoot.appendingPathComponent(".config.json")
        let accountA = Data(#"{"oauthAccount":{"accountUuid":"account-a"}}"#.utf8)
        let accountB = Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
        let env = [
            "CLAUDE_CLI_PATH": stubCLIPath,
            "CLAUDE_CONFIG_DIR": profileRoot.path,
        ]
        let strategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
        let context = self.makeContext(runtime: .app, sourceMode: .auto, env: env, settings: settings)

        try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            try accountB.write(to: configURL, options: .atomic)
            ClaudeCLIBackgroundAvailability.establish(binary: stubCLIPath, environment: env)
            try accountA.write(to: configURL, options: .atomic)
            ClaudeCLIBackgroundAvailability.establish(binary: stubCLIPath, environment: env)

            let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
                -> ClaudeStatusSnapshot = { _, _, _ in
                    try accountB.write(to: configURL, options: .atomic)
                    throw ExpectedFetchError.failed
                }

            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        try await strategy.fetch(context)
                    }
                }
            }

            #expect(ClaudeCLIBackgroundAvailability.isEstablished(binary: stubCLIPath, environment: env))
            try accountA.write(to: configURL, options: .atomic)
            #expect(!ClaudeCLIBackgroundAvailability.isEstablished(binary: stubCLIPath, environment: env))
        }
    }

    @Test
    func `app auto pipeline retains OAuth bootstrap strategy at startup`() async {
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
        #expect(strategyIDs == ["claude.oauth", "claude.cli", "claude.web"])
    }

    @Test
    func `auto pipeline CLI uses planned environment for execution`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))
        let stubCLIPath = try self.makeStubClaudeCLI()
        let profileRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-planned-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profileRoot) }
        try Data(#"{"oauthAccount":{"accountUuid":"planned-account"}}"#.utf8)
            .write(to: profileRoot.appendingPathComponent(".config.json"), options: .atomic)
        let env = [
            "CLAUDE_CLI_PATH": stubCLIPath,
            "CLAUDE_CONFIG_DIR": profileRoot.path,
        ]

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: stubCLIPath, environment: env)
            await self.withBackgroundKeychainAccess {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await self.withNoOAuthCredentials {
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

                        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli"])
                        #expect(outcome.attempts.map(\.wasAvailable) == [true, true])

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
                }
            }
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

    private static func makeUsageStatusSnapshot() -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
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
}
