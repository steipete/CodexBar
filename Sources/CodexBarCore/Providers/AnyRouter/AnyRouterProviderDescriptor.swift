import Foundation

public enum AnyRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .anyrouter,
            metadata: ProviderMetadata(
                id: .anyrouter,
                displayName: "AnyRouter",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show AnyRouter usage",
                cliName: "anyrouter",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://anyrouter.dev/dashboard/credits",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .anyrouter,
                iconResourceName: "ProviderIcon-anyrouter",
                color: ProviderColor(red: 26 / 255, green: 26 / 255, blue: 46 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "AnyRouter spend is reported by its credits API." }),
            fetchPlan: .apiToken(
                strategyID: "anyrouter.api",
                resolveToken: { ProviderTokenResolver.anyRouterToken(environment: $0) },
                missingCredentialsError: { AnyRouterUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try AnyRouterSettingsReader.validateEndpointOverride(environment: context.env)
                    return try await AnyRouterUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        baseURL: AnyRouterSettingsReader.baseURL(environment: context.env)).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "anyrouter",
                aliases: ["ar"],
                versionDetector: nil))
    }
}
