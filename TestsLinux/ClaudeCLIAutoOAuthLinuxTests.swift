#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIAutoOAuthLinuxTests {
    private func makeContext(sourceMode: ProviderSourceMode) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot.make(),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `CLI auto tries OAuth before the Claude CLI PTY fallback off macOS`() async {
        // Without browser cookies, CLI Auto used to jump straight to the PTY fallback, which boots a full
        // interactive `claude` session (~9s on WSL). The noninteractive OAuth file read must come first.
        let context = self.makeContext(sourceMode: .auto)
        let ids = await ProviderDescriptorRegistry
            .descriptor(for: .claude)
            .fetchPlan
            .pipeline
            .resolveStrategies(context)
            .map(\.id)

        let oauthIndex = ids.firstIndex(of: "claude.oauth")
        let cliIndex = ids.firstIndex(of: "claude.cli")
        #expect(oauthIndex != nil)
        #expect(cliIndex != nil)
        if let oauthIndex, let cliIndex {
            #expect(oauthIndex < cliIndex)
        }
    }

    @Test
    func `CLI auto OAuth failure falls back to the next strategy`() {
        let context = self.makeContext(sourceMode: .auto)
        #expect(ClaudeOAuthFetchStrategy().shouldFallback(
            on: ClaudeOAuthCredentialsError.notFound,
            context: context))
    }

    @Test(arguments: [
        ClaudeOAuthFetchError.unauthorized,
        ClaudeOAuthFetchError.rateLimited(retryAfter: nil),
        ClaudeOAuthFetchError.serverError(503, nil),
    ])
    func `CLI auto OAuth request failures fall back to the Claude CLI`(error: ClaudeOAuthFetchError) {
        let context = self.makeContext(sourceMode: .auto)
        #expect(ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: context))
    }

    @Test
    func `CLI auto OAuth cancellation does not fall back to the Claude CLI`() {
        let context = self.makeContext(sourceMode: .auto)
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: CancellationError(), context: context))
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(
            on: ClaudeOAuthFetchError.networkError(URLError(.cancelled)),
            context: context))
    }

    @Test
    func `explicit CLI OAuth stays terminal`() {
        let context = self.makeContext(sourceMode: .oauth)
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(
            on: ClaudeOAuthCredentialsError.notFound,
            context: context))
    }
}
#endif
