import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite
struct PlatformGatingTests {
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
        let context = self.makeClaudeAutoContext()
        let cliFetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            Self.makeClaudeStatus()
        }
        let outcome = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            await ClaudeStatusProbe.withFetchOverrideForTesting(cliFetchOverride) {
                await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                    context: context,
                    provider: .claude)
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
    private func makeClaudeAutoContext() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .auto,
                manualCookieHeader: nil)),
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
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
