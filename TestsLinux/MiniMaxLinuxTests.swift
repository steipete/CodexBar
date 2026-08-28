#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct MiniMaxLinuxTests {
    @Test
    func `coding plan API key does not require macOS web support`() {
        // A coding-plan key resolves to the plain HTTPS + Bearer API strategy, so it must be
        // usable off macOS (matches the Factory/Kimi credential exemptions).
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.codingPlanAPITokenKey: "sk-cp-test"]))
    }

    @Test
    func `standard API key still requires web support because Auto resolves to the coding plan page`() {
        // `MiniMaxAPIFetchStrategy` refuses standard `sk-api-` keys, so Auto falls back to the
        // Coding Plan web strategy. Exempting it here would only produce `noAvailableStrategy`.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.apiTokenKey: "sk-api-test"]))
    }

    @Test
    func `auto without an API key still requires web support off macOS`() {
        // Without a credential the only remaining Auto path is the web/cookie one, which
        // genuinely needs macOS — the gate must still fire.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [:]))
    }

    @Test
    func `explicit web source still requires web support even with an API key`() {
        // The exemption is scoped to Auto; asking for the web source explicitly must not
        // be silently redirected to the API path.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.codingPlanAPITokenKey: "sk-cp-test"]))
    }

    @Test
    func `exempted coding plan key actually resolves a linux capable strategy`() async {
        // Gate agreement is not enough: the Auto plan must contain a strategy that can run
        // without the macOS web path, otherwise the exemption ends in `noAvailableStrategy`.
        let env = [MiniMaxAPISettingsReader.codingPlanAPITokenKey: "sk-cp-test"]
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let strategies = await ProviderDescriptorRegistry
            .descriptor(for: .minimax)
            .fetchPlan
            .pipeline
            .resolveStrategies(context)
        #expect(strategies.contains { $0.id == "minimax.api" })
    }
}
#endif
