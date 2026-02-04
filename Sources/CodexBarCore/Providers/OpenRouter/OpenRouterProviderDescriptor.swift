import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenRouterProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openrouter,
            metadata: ProviderMetadata(
                id: .openrouter,
                displayName: "OpenRouter",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credit balance from OpenRouter API",
                toggleTitle: "Show OpenRouter usage",
                cliName: "openrouter",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://openrouter.ai/settings/credits",
                statusPageURL: nil,
                statusLinkURL: "https://status.openrouter.ai"),
            branding: ProviderBranding(
                iconStyle: .openrouter,
                iconResourceName: "ProviderIcon-openrouter",
                color: ProviderColor(red: 111 / 255, green: 66 / 255, blue: 193 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenRouter cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenRouterAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "openrouter",
                aliases: ["or"],
                versionDetector: nil))
    }
}

struct OpenRouterAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "openrouter.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw OpenRouterSettingsError.missingToken
        }
        let usage = try await OpenRouterUsageFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.openRouterToken(environment: environment)
    }
}

/// Errors related to OpenRouter settings
public enum OpenRouterSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "OpenRouter API token not configured. Set OPENROUTER_API_KEY environment variable or configure in Settings."
        }
    }
}
