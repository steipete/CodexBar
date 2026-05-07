import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeUsageDelegatedRefreshEnvironmentTests {
    @Test
    func `oauth delegated retry passes fetcher environment to delegated refresh`() async throws {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["CLAUDE_CLI_PATH": "/tmp/rat110-env-claude"],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let delegatedOverride: (@Sendable (Date, TimeInterval, [String: String]) async
            -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _, environment in
            #expect(environment["CLAUDE_CLI_PATH"] == "/tmp/rat110-env-claude")
            return .cliUnavailable
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredsOverride,
                                operation: {
                                    try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(
                                        false,
                                        operation: {
                                            try await fetcher.loadLatestUsage(model: "sonnet")
                                        })
                                })
                        })
                }
            }
            Issue.record("Expected delegated retry to fail when the override reports CLI unavailable")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("Claude CLI is not available"))
        }
    }
}
