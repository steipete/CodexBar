import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenAIAPIProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openai,
            metadata: ProviderMetadata(
                id: .openai,
                displayName: "OpenAI API",
                sessionLabel: "API credits",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "OpenAI API platform credit balance from the billing endpoint.",
                toggleTitle: "Show OpenAI API balance",
                cliName: "openai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://platform.openai.com/settings/organization/billing/overview",
                statusPageURL: "https://status.openai.com"),
            branding: ProviderBranding(
                iconStyle: .openai,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0.06, green: 0.51, blue: 0.43)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenAI API credit balance uses billing credits, not model cost estimates." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenAIAPIBalanceFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "openai",
                aliases: ["openai-api"],
                versionDetector: nil))
    }
}

struct OpenAIAPIBalanceFetchStrategy: ProviderFetchStrategy {
    let id: String = "openai.api.balance"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw OpenAIAPISettingsError.missingToken
        }

        let balance = try await OpenAIAPICreditBalanceFetcher.fetchBalance(apiKey: apiKey)
        return self.makeResult(
            usage: balance.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.openAIAPIToken(environment: environment)
    }
}
