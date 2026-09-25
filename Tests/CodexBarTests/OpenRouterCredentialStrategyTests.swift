import Foundation
import Testing
@testable import CodexBarCore

struct OpenRouterCredentialStrategyTests {
    @Test(arguments: [ProviderRuntime.app, .cli])
    func `saved primary key passes credential validation without a shell key`(runtime: ProviderRuntime) async {
        let config = ProviderConfig(id: .openrouter, apiKey: "fixture-saved-primary")
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [OpenRouterSettingsReader.apiURLEnvironmentKey: "http://fixture.invalid/v1"],
            provider: .openrouter,
            config: config)
        #expect(environment[OpenRouterSettingsReader.envKey] == "fixture-saved-primary")
        let outcome = await OpenRouterProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
            context: ProviderCutoverTestSupport.context(environment: environment, runtime: runtime),
            provider: .openrouter)
        // An invalid endpoint stops the fetch before networking, after the saved key passes validation.
        switch outcome.result {
        case .success:
            Issue.record("Invalid endpoint unexpectedly fetched usage")
        case let .failure(error):
            #expect((error as? OpenRouterSettingsError) == .invalidEndpointOverride(
                OpenRouterSettingsReader.apiURLEnvironmentKey))
        }
    }

    @Test(arguments: [ProviderRuntime.app, .cli], [ProviderSourceMode.auto, .api])
    func `missing primary key explains where a management key belongs`(
        runtime: ProviderRuntime, source: ProviderSourceMode) async throws
    {
        for environment in [
            [:],
            [OpenRouterSettingsReader.envKey: " \n "],
            [OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "fixture-management-key"],
        ] {
            let config = ProviderConfig(
                id: .openrouter,
                pluginSecrets: [OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "fixture-configured-key"])
            let contribution = try #require(OpenRouterProviderDescriptor.descriptor.settingsSection
                .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil)))
            let context = ProviderFetchContext(
                runtime: runtime,
                sourceMode: source,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: environment,
                settings: ProviderSettingsSnapshot(contributions: [contribution]),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: UnusedClaudeFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0))
            let outcome = await OpenRouterProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
                context: context, provider: .openrouter)
            let error: Error
            switch outcome.result {
            case .success:
                Issue.record("Missing credentials unexpectedly fetched usage")
                continue
            case let .failure(failure):
                error = failure
            }
            #expect((error as? ProviderFetchClassifiedError)?.kind == .missingCredential)
            #expect(error.localizedDescription.contains("regular API key or a Management API key"))
            #expect(error.localizedDescription.contains("API key field"))
            #expect(error.localizedDescription.contains("OPENROUTER_API_KEY"))
            #expect(outcome.attempts.count == 1)
            #expect(outcome.attempts.first?.outcome == .failed)
        }
    }

    private struct UnusedClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            Issue.record("OpenRouter must not fetch Claude credentials")
            throw CancellationError()
        }

        func debugRawProbe(model _: String) async -> String { "unused" }
        func detectVersion() -> String? { nil }
    }
}
