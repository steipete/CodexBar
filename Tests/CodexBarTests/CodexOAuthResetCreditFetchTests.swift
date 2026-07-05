import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthResetCreditFetchTests {
    @Test
    func `app enrichment can rescue reset-credit-only O auth usage`() throws {
        let json = #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: Self.credentials(),
            allowEmptyUsageForResetCreditEnrichment: true)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.codexResetCredits == nil)
        #expect(result.credits == nil)
        #expect(result.strategyID == "codex.oauth")
    }

    @Test
    func `app defers reset credit GET while CLI attempts it once on failure`() async throws {
        let credentials = Self.credentials()
        let recorder = CodexOAuthResetCreditFetchRecorder()
        let fetcher: @Sendable (CodexOAuthCredentials) async throws -> CodexRateLimitResetCreditsSnapshot = { _ in
            await recorder.recordRequest()
            throw CodexOAuthFetchError.serverError(500, nil)
        }

        let appResult = try await CodexOAuthFetchStrategy._fetchResetCreditsForTesting(
            context: Self.context(runtime: .app),
            credentials: credentials,
            fetcher: fetcher)
        #expect(appResult == nil)
        #expect(await recorder.requestCount() == 0)

        let cliResult = try await CodexOAuthFetchStrategy._fetchResetCreditsForTesting(
            context: Self.context(runtime: .cli),
            credentials: credentials,
            fetcher: fetcher)
        #expect(cliResult == nil)
        #expect(await recorder.requestCount() == 1)
    }

    @Test
    func `CLI reset credit GET preserves cancellation without retry`() async throws {
        let recorder = CodexOAuthResetCreditFetchRecorder()

        await #expect(throws: CancellationError.self) {
            _ = try await CodexOAuthFetchStrategy._fetchResetCreditsForTesting(
                context: Self.context(runtime: .cli),
                credentials: Self.credentials(),
                fetcher: { _ in
                    await recorder.recordRequest()
                    throw CancellationError()
                })
        }
        #expect(await recorder.requestCount() == 1)
    }

    @Test
    func `reset credit inventory only O auth payload still returns usage result`() throws {
        let json = #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#
        let now = Date()
        let resetCredits = CodexRateLimitResetCreditsSnapshot(
            credits: [
                CodexRateLimitResetCredit(
                    id: "available-no-expiry",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: now,
                    expiresAt: nil,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
            ],
            availableCount: 1,
            updatedAt: now)

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: Self.credentials(),
            resetCredits: resetCredits)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.codexResetCredits?.availableInventory(at: now).count == 1)
        #expect(result.credits == nil)
        #expect(result.sourceLabel == "oauth")
    }

    @Test
    func `empty reset credits do not mask missing O auth usage`() {
        let json = #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#
        let resetCredits = CodexRateLimitResetCreditsSnapshot(
            credits: [],
            availableCount: 0,
            updatedAt: Date())

        #expect(throws: UsageError.self) {
            try CodexOAuthFetchStrategy._mapResultForTesting(
                Data(json.utf8),
                credentials: Self.credentials(),
                resetCredits: resetCredits)
        }
    }

    @Test
    func `O auth strategy defers app inventory and CLI follows credits flag`() {
        let appContext = Self.context(runtime: .app, includeCredits: false, includeOptionalUsage: false)
        let cliNoCreditsContext = Self.context(runtime: .cli, includeCredits: false, includeOptionalUsage: true)
        let cliCreditsContext = Self.context(runtime: .cli, includeCredits: true, includeOptionalUsage: false)

        #expect(CodexOAuthFetchStrategy._shouldFetchResetCreditsForTesting(appContext) == false)
        #expect(CodexOAuthFetchStrategy._shouldFetchResetCreditsForTesting(cliNoCreditsContext) == false)
        #expect(CodexOAuthFetchStrategy._shouldFetchResetCreditsForTesting(cliCreditsContext))
    }

    private static func context(
        runtime: ProviderRuntime,
        includeCredits: Bool = true,
        includeOptionalUsage: Bool = false) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .auto,
            includeCredits: includeCredits,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func credentials() -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: "account-123",
            lastRefresh: Date())
    }
}

private actor CodexOAuthResetCreditFetchRecorder {
    private var count = 0

    func recordRequest() {
        self.count += 1
    }

    func requestCount() -> Int {
        self.count
    }
}
