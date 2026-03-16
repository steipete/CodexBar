import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CheapestInferenceProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cheapestinference,
            metadata: ProviderMetadata(
                id: .cheapestinference,
                displayName: "CheapestInference",
                sessionLabel: "Budget",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Budget utilization from CheapestInference API",
                toggleTitle: "Show CheapestInference usage",
                cliName: "cheapestinference",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://cheapestinference.com/dashboard",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .cheapestinference,
                iconResourceName: "ProviderIcon-cheapestinference",
                color: ProviderColor(red: 16 / 255, green: 185 / 255, blue: 129 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "CheapestInference cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [CheapestInferenceAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "cheapestinference",
                aliases: ["ci"],
                versionDetector: nil))
    }
}

struct CheapestInferenceAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "cheapestinference.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw CheapestInferenceSettingsError.missingToken
        }
        let usage = try await CheapestInferenceUsageFetcher.fetchUsage(
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
        ProviderTokenResolver.cheapestInferenceToken(environment: environment)
    }
}

/// Errors related to CheapestInference settings
public enum CheapestInferenceSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "CheapestInference API token not configured. Set CHEAPESTINFERENCE_API_KEY environment variable or configure in Settings."
        }
    }
}
