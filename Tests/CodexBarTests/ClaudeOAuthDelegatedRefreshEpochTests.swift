import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshEpochTests {
    private actor LoadState {
        private var requestIDs: [UUID?] = []

        func nextCall(requestID: UUID?) -> Int {
            self.requestIDs.append(requestID)
            return self.requestIDs.count
        }

        func recordedRequestIDs() -> [UUID?] {
            self.requestIDs
        }
    }

    @Test
    func `post delegated credential reload starts a new prompt coalescing epoch`() async throws {
        let state = LoadState()
        let initialRequestID = UUID()
        let usageResponse = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """.utf8))
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let loadOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            let call = await state.nextCall(requestID: ProviderRefreshRequestContext.id)
            guard call > 1 else {
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }
        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval,
            [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _, _ in
            .attemptedFailed("no-change")
        }
        let fetchOverride: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
            usageResponse
        }

        _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await ProviderRefreshRequestContext.$id.withValue(initialRequestID) {
                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride, operation: {
                        try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                            delegatedOverride,
                            operation: {
                                try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                    loadOverride,
                                    operation: {
                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                    })
                            })
                    })
                }
            }
        }

        let requestIDs = await state.recordedRequestIDs()
        #expect(requestIDs.count == 2)
        #expect(requestIDs[0] == initialRequestID)
        #expect(requestIDs[1] != nil)
        #expect(requestIDs[1] != initialRequestID)
    }
}
