import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite
struct PlatformGatingTests {
    @Test
    func `shell probe requests a detached Linux session`() {
        #if os(Linux)
        #expect(ShellCommandLocator.test_shellSpawnFlags == 0x80)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func ampAutoSource_doesNotRequireWebSupport() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .amp))
    }

    @Test
    func claudeAutoSource_allowsPlannerToFallBackToCLI() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .claude))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .claude))
    }

    @Test
    func claudeAutoPipeline_skipsUnsupportedWebAndUsesCLI() async throws {
        #if os(Linux)
        let binaryURL = try Self.makeClaudeCLI(loggedIn: true)
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let context = self.makeClaudeAutoContext(env: ["CLAUDE_CLI_PATH": binaryURL.path])
        let cliFetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            Self.makeClaudeStatus()
        }
        let outcome = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(binaryURL.path) {
            await ClaudeCLIAuthStatusProbe.withResultOverrideForTesting(true) {
                await ClaudeStatusProbe.withFetchOverrideForTesting(cliFetchOverride) {
                    await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                        context: context,
                        provider: .claude)
                }
            }
        }
        let result = try outcome.result.get()

        #expect(result.strategyID == "claude.cli")
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web", "claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, true])
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeAutoPipeline_withoutCLIReportsNoAvailableStrategy() async {
        #if os(Linux)
        let context = self.makeClaudeAutoContext()
        let outcome = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(
            "/definitely/missing/claude")
        {
            await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                context: context,
                provider: .claude)
        }

        switch outcome.result {
        case .success:
            Issue.record("Expected Claude auto without a CLI to report no available strategy")
        case let .failure(error):
            guard let fetchError = error as? ProviderFetchError else {
                Issue.record("Expected ProviderFetchError, got \(error)")
                return
            }
            switch fetchError {
            case let .noAvailableStrategy(provider):
                #expect(provider == .claude)
            }
        }
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web", "claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, false])
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(arguments: [ProviderSourceMode.auto, .cli])
    func `Claude CLI runtime skips logged out interactive fallback`(sourceMode: ProviderSourceMode) async throws {
        #if os(Linux)
        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-runtime-invocations-\(UUID().uuidString).log")
        let binaryURL = try Self.makeClaudeCLI(loggedIn: false, invocationLog: invocationLog)
        defer {
            try? FileManager.default.removeItem(at: binaryURL)
            try? FileManager.default.removeItem(at: invocationLog)
        }
        let context = self.makeClaudeContext(
            sourceMode: sourceMode,
            env: ["CLAUDE_CLI_PATH": binaryURL.path])
        let cliFetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            Issue.record("Logged-out Claude CLI reached the interactive usage probe")
            return Self.makeClaudeStatus()
        }

        let outcome = await ClaudeStatusProbe.withFetchOverrideForTesting(cliFetchOverride) {
            await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                context: context,
                provider: .claude)
        }

        switch outcome.result {
        case .success:
            Issue.record("Expected logged-out Claude CLI to report no available strategy")
        case let .failure(error):
            guard let fetchError = error as? ProviderFetchError else {
                Issue.record("Expected ProviderFetchError, got \(error)")
                return
            }
            switch fetchError {
            case let .noAvailableStrategy(provider):
                #expect(provider == .claude)
            }
        }
        let expectedStrategyIDs = sourceMode == .auto ? ["claude.web", "claude.cli"] : ["claude.cli"]
        #expect(outcome.attempts.map(\.strategyID) == expectedStrategyIDs)
        #expect(outcome.attempts.allSatisfy { !$0.wasAvailable })
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "auth status --json\n")
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeOAuthUsageDoesNotDetectCLIVersion() {
        #expect(!CodexBarCLI.shouldDetectVersion(
            provider: .claude,
            result: self.makeResult(kind: .oauth)))
        #expect(CodexBarCLI.shouldDetectVersion(
            provider: .claude,
            result: self.makeResult(kind: .cli)))
        #expect(CodexBarCLI.shouldDetectVersion(
            provider: .codex,
            result: self.makeResult(kind: .oauth)))
    }

    @Test
    func claudeWebFetcher_isNotSupportedOnLinux() async {
        #if os(Linux)
        let error = await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
            _ = try await ClaudeWebAPIFetcher.fetchUsage()
        }
        let isExpectedError = error.map { thrown in
            if case .notSupportedOnThisPlatform = thrown { return true }
            return false
        } ?? false
        #expect(isExpectedError)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeWebFetcher_hasSessionKey_isFalseOnLinux() {
        #if os(Linux)
        #expect(ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: nil) == false)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeWebFetcher_sessionKeyInfo_throwsOnLinux() {
        #if os(Linux)
        let error = #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
            _ = try ClaudeWebAPIFetcher.sessionKeyInfo()
        }
        let isExpectedError = error.map { thrown in
            if case .notSupportedOnThisPlatform = thrown { return true }
            return false
        } ?? false
        #expect(isExpectedError)
        #else
        #expect(Bool(true))
        #endif
    }
    private func makeClaudeAutoContext(env: [String: String] = [:]) -> ProviderFetchContext {
        self.makeClaudeContext(sourceMode: .auto, env: env)
    }

    private func makeClaudeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let usageDataSource: ClaudeUsageDataSource = sourceMode == .cli ? .cli : .auto
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: usageDataSource,
                webExtrasEnabled: false,
                cookieSource: .auto,
                manualCookieHeader: nil)),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func makeClaudeCLI(loggedIn: Bool, invocationLog: URL? = nil) throws -> URL {
        if let invocationLog {
            try Data().write(to: invocationLog)
        }
        let binaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-runtime-\(UUID().uuidString)")
        let recordInvocation = invocationLog.map { "printf '%s\\n' \"$*\" >> '\($0.path)'" } ?? ""
        let loggedInJSON = loggedIn ? "true" : "false"
        let script = """
        #!/bin/sh
        \(recordInvocation)
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf '%s\\n' '{"loggedIn":\(loggedInJSON)}'
        fi
        """
        try Data(script.utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return binaryURL
    }

    private static func makeClaudeStatus() -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 80,
            weeklyPercentLeft: nil,
            opusPercentLeft: nil,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            opusResetDescription: nil,
            rawText: "stub")
    }

    private func makeResult(kind: ProviderFetchKind) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: 0)),
            credits: nil,
            dashboard: nil,
            sourceLabel: "test",
            strategyID: "test",
            strategyKind: kind)
    }
}
