import Foundation

public enum CrossModelProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .crossmodel,
            metadata: ProviderMetadata(
                id: .crossmodel,
                displayName: "CrossModel",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show CrossModel usage",
                cliName: "crossmodel",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://crossmodel.ai/console/usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .crossmodel,
                iconResourceName: "ProviderIcon-crossmodel",
                color: ProviderColor(red: 124 / 255, green: 58 / 255, blue: 237 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "CrossModel cost summary is not yet supported." }),
            fetchPlan: .apiToken(
                strategyID: "crossmodel.api",
                resolveToken: { ProviderTokenResolver.crossModelToken(environment: $0) },
                missingCredentialsError: { CrossModelSettingsError.missingToken },
                loadUsage: { apiKey, context in
                    try await CrossModelUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env,
                        includeOptionalUsage: context.includeOptionalUsage).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "crossmodel",
                aliases: ["cm"],
                versionDetector: nil))
    }
}

/// Errors related to CrossModel settings.
public enum CrossModelSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "CrossModel API token not configured. Set CROSSMODEL_API_KEY environment variable or configure in Settings."
        case let .invalidEndpointOverride(key):
            "CrossModel endpoint override \(key) must use HTTPS (or a loopback HTTP host)."
        }
    }
}
