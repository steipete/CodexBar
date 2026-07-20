import Foundation

public enum OpenRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

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
                color: ProviderColor(red: 100 / 255, green: 103 / 255, blue: 242 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x96A5B9),
                    ProviderColor(hex: 0x161616),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenRouter cost summary is not yet supported." }),
            fetchPlan: .apiToken(
                strategyID: "openrouter.api",
                resolveToken: { ProviderTokenResolver.openRouterToken(environment: $0) },
                missingCredentialsError: { OpenRouterSettingsError.missingToken },
                loadUsage: { apiKey, context in
                    try await OpenRouterUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "openrouter",
                aliases: ["or"],
                versionDetector: nil))
    }
}

/// Errors related to OpenRouter settings
public enum OpenRouterSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "OpenRouter API token not configured. Set OPENROUTER_API_KEY environment variable or configure in Settings."
        case let .invalidEndpointOverride(key):
            "OpenRouter endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
