import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct MiniMaxWebEnrichmentResolverTests {
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

    @Test
    func `manual cookie candidate is available without browser import gate`() {
        let settings = ProviderSettingsSnapshot.make(
            minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "_token=manual-session",
                apiRegion: .chinaMainland))
        let context = self.makeContext(runtime: .cli, settings: settings)

        let candidates = MiniMaxWebEnrichmentResolver.candidates(context: context)

        #expect(
            candidates.contains {
                $0.sourceLabel == "settings" && $0.override.cookieHeader.contains("_token=manual-session")
            })
    }

    @Test
    func `browser import gate only allows user initiated app refresh`() {
        let context = self.makeContext(runtime: .app, includeOptionalUsage: true)

        ProviderInteractionContext.$current.withValue(.background) {
            #expect(!MiniMaxWebEnrichmentResolver.allowsBrowserCookieImport(context: context))
        }

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            #expect(MiniMaxWebEnrichmentResolver.allowsBrowserCookieImport(context: context))
        }
    }

    @Test
    func `explicit candidates exclude cached browser cookies`() {
        CookieHeaderCache.store(
            provider: .minimax,
            cookieHeader: "_token=cached-session",
            sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .minimax) }

        let context = self.makeContext(runtime: .app)
        let explicit = MiniMaxWebEnrichmentResolver.explicitCandidates(context: context)
        let api = MiniMaxWebEnrichmentResolver.apiEnrichmentCandidates(context: context)

        #expect(!explicit.contains { $0.sourceLabel == "Chrome" })
        #expect(api.contains { $0.isCached && $0.sourceLabel == "Chrome" })
    }

    private func makeContext(
        runtime: ProviderRuntime,
        includeOptionalUsage: Bool = true,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: runtime,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}
#endif
