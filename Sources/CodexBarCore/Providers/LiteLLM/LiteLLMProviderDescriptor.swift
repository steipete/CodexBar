import Foundation

public enum LiteLLMProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .litellm,
            metadata: ProviderMetadata(
                id: .litellm,
                displayName: "LiteLLM",
                sessionLabel: "Personal budget",
                weeklyLabel: "Team budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Reads spend and budget from LiteLLM key, user, and team info endpoints.",
                toggleTitle: "Show LiteLLM usage",
                cliName: "litellm",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .litellm,
                iconResourceName: "ProviderIcon-litellm",
                color: ProviderColor(red: 76 / 255, green: 137 / 255, blue: 240 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LiteLLM spend is reported by the provider API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LiteLLMAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "litellm",
                aliases: ["litellm-proxy"],
                versionDetector: nil))
    }
}

struct LiteLLMAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "litellm.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.liteLLMToken(environment: context.env) != nil &&
            LiteLLMSettingsReader.baseURL(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.liteLLMToken(environment: context.env) else {
            throw LiteLLMUsageError.missingCredentials
        }
        guard let baseURL = LiteLLMSettingsReader.baseURL(environment: context.env) else {
            throw LiteLLMUsageError.missingBaseURL
        }
        let usage = try await LiteLLMUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: baseURL)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
