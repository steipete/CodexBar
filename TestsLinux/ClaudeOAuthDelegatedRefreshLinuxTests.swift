import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshLinuxTests {
    private actor Counter {
        private var value = 0

        func increment() {
            self.value += 1
        }

        func current() -> Int {
            self.value
        }
    }

    private actor VersionDetectionCapture {
        private var value: Bool?

        func record(_ value: Bool) {
            self.value = value
        }

        func current() -> Bool? {
            self.value
        }
    }

    @Test
    func cliOAuthSkipsVersionDetectionWhileAppPreservesIt() async throws {
        #expect(try await self.detectsClaudeVersion(runtime: .cli) == false)
        #expect(try await self.detectsClaudeVersion(runtime: .app) == true)
    }

    @Test
    func cliOAuthDoesNotDelegateRefreshEvenForUserAction() async {
        let result = await self.runDelegatedRefresh(
            runtime: .cli,
            interaction: .userInitiated,
            promptMode: .always)

        #expect(result.attempts == 0)
        #expect(result.message.contains("CodexBar CLI does not launch Claude"))
    }

    @Test
    func appOAuthPreservesUserInitiatedDelegatedRefresh() async {
        let result = await self.runDelegatedRefresh(
            runtime: .app,
            interaction: .userInitiated,
            promptMode: .onlyOnUserAction)

        #expect(result.attempts == 1)
        #expect(result.message.contains("still unavailable after delegated Claude CLI refresh"))
    }

    @Test
    func appOAuthBackgroundRespectsPlatformKeychainPromptPolicy() async {
        let result = await self.runDelegatedRefresh(
            runtime: .app,
            interaction: .background,
            promptMode: .onlyOnUserAction)

        #expect(result.attempts == 0)
        #expect(result.message.contains("background repair is suppressed"))
        #expect(result.message.contains("Click Refresh in the CodexBar menu"))
        #expect(!result.message.contains("Open the CodexBar menu or"))
    }

    private func runDelegatedRefresh(
        runtime: ProviderRuntime,
        interaction: ProviderInteraction,
        promptMode: ClaudeOAuthKeychainPromptMode) async -> (attempts: Int, message: String)
    {
        let counter = Counter()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            runtime: runtime,
            dataSource: .oauth)
        let credentialsOverride: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
        let delegatedOverride: @Sendable (
            Date,
            TimeInterval,
            [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome = { _, _, _ in
                await counter.increment()
                return .attemptedSucceeded
            }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                try await ProviderInteractionContext.$current.withValue(interaction) {
                    try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride
                        .withValue(credentialsOverride) {
                            try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                .withValue(delegatedOverride) {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                }
                        }
                }
            }
            Issue.record("Expected delegated-refresh path to fail with mocked stale credentials")
            return (await counter.current(), "")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return (await counter.current(), "")
            }
            return (await counter.current(), message)
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
            return (await counter.current(), "")
        }
    }

    private func detectsClaudeVersion(runtime: ProviderRuntime) async throws -> Bool {
        let capture = VersionDetectionCapture()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            runtime: runtime,
            dataSource: .oauth)
        let credentialsOverride: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
                ClaudeOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: nil,
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    scopes: ["user:profile"],
                    rateLimitTier: nil)
            }
        let fetchOverride: @Sendable (String, Bool) async throws -> OAuthUsageResponse = {
            _, detectClaudeVersion in
            await capture.record(detectClaudeVersion)
            return try Self.makeOAuthUsageResponse()
        }

        _ = try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentialsOverride) {
            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }

        guard let value = await capture.current() else {
            Issue.record("Expected OAuth fetch to report its version-detection policy")
            return false
        }
        return value
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }
}
