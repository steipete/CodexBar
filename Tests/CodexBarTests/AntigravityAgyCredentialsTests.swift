import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityAgyCredentialsTests {
    @Test
    func `loads oauth credentials from gemini home directory`() throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }

        try env.writeCredentials(
            accessToken: "agy-access-token",
            refreshToken: "agy-refresh-token",
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let credentials = try #require(try AntigravityAgyCredentials.loadCredentials(homeDirectory: env.homeURL.path))

        #expect(credentials.accessToken == "agy-access-token")
        #expect(credentials.refreshToken == "agy-refresh-token")
        #expect(AntigravityAgyCredentials.hasStoredCredentials(homeDirectory: env.homeURL.path))
    }

    @Test
    func `maps gemini quota snapshot into antigravity models`() {
        let gemini = GeminiStatusSnapshot(
            modelQuotas: [
                GeminiModelQuota(
                    modelId: "gemini-2.5-pro",
                    percentLeft: 80,
                    resetTime: Date(timeIntervalSince1970: 1_700_000_000),
                    resetDescription: "Resets in 1d"),
            ],
            rawText: "{}",
            accountEmail: "user@example.com",
            accountPlan: "Free")

        let snapshot = AntigravityAgyQuotaFetcher.makeAntigravitySnapshot(from: gemini)

        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountPlan == "Free")
        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas[0].modelId == "gemini-2.5-pro")
        #expect(snapshot.modelQuotas[0].remainingFraction == 0.8)
    }

    @Test
    func `agy fetch strategy falls back in auto mode`() async {
        let strategy = AntigravityAgyFetchStrategy()
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))

        #expect(strategy.shouldFallback(on: AntigravityRemoteFetchError.notLoggedIn, context: context))
        #expect(strategy.shouldFallback(on: GeminiStatusProbeError.notLoggedIn, context: context))
    }

    @Test
    func `agy fetch strategy does not fall back in cli mode`() async {
        let strategy = AntigravityAgyFetchStrategy()
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .cli,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))

        #expect(strategy.shouldFallback(on: AntigravityRemoteFetchError.notLoggedIn, context: context) == false)
    }
}

private struct StubClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ClaudeUsageError.parseFailed("stub")
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}
