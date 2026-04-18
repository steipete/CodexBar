import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeBaselineCharacterizationTests {
    private func makeStubClaudeCLI() throws -> String {
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
        let script = """
        #!/bin/sh
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

    private func withNoOAuthCredentials<T>(operation: () async throws -> T) async rethrows -> T {
        let missingCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-claude-creds-\(UUID().uuidString).json")
        return try await KeychainCacheStore.withServiceOverrideForTesting("rat-110-\(UUID().uuidString)") {
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

    @Test
    func `app auto pipeline order is OAuth then CLI then web`() async {
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
        #expect(await strategies[0].isAvailable(context))
    }

    @Test
    func `auto pipeline records unavailable planned steps when planner has no executable source`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: true,
            cookieSource: .off,
            manualCookieHeader: nil))
        let env = ["CLAUDE_CLI_PATH": "/definitely/missing/claude"]

        await self.withNoOAuthCredentials {
            await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
                let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: .auto, env: env, settings: settings)
                #expect(strategyIDs == ["claude.oauth", "claude.cli", "claude.web"])

                let outcome = await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env, settings: settings)
                #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth", "claude.cli", "claude.web"])
                #expect(outcome.attempts.map(\.wasAvailable) == [false, false, false])

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
    }

    @Test
    func `app auto pipeline retains OAuth bootstrap strategy at startup`() async {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .off,
            manualCookieHeader: nil))

        await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer {
                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                ClaudeOAuthKeychainAccessGate.resetForTesting()
            }

            await self.withNoOAuthCredentials {
                let strategyIDs = await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .onlyOnUserAction)
                {
                    await ProviderRefreshContext.$current.withValue(.startup) {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            await self.strategyIDs(runtime: .app, sourceMode: .auto, settings: settings)
                        }
                    }
                }
                #expect(strategyIDs.first == "claude.oauth")
                #expect(strategyIDs.contains("claude.oauth"))
            }
        }
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
            #expect(outcome.attempts.map(\.wasAvailable) == [false, true])

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

    @Test(arguments: [
        (ProviderSourceMode.oauth, "claude.oauth"),
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

    @Test(arguments: [
        (ProviderSourceMode.oauth, "claude.oauth"),
        (ProviderSourceMode.cli, "claude.cli"),
        (ProviderSourceMode.web, "claude.web"),
    ])
    func `CLI explicit modes resolve single Claude strategy`(
        sourceMode: ProviderSourceMode,
        expectedStrategyID: String) async
    {
        let strategyIDs = await self.strategyIDs(runtime: .cli, sourceMode: sourceMode)
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
