import Foundation

public enum ZaiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zai,
            metadata: ProviderMetadata(
                id: .zai,
                displayName: "z.ai",
                sessionLabel: "Tokens",
                weeklyLabel: "MCP",
                opusLabel: "5-hour",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show z.ai usage",
                cliName: "zai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: ZaiAPIRegion.global.dashboardURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .zai,
                iconResourceName: "ProviderIcon-zai",
                color: ProviderColor(red: 232 / 255, green: 90 / 255, blue: 106 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "z.ai cost summary is not supported." }),
            fetchPlan: .apiToken(
                strategyID: "zai.api",
                resolveToken: { ProviderTokenResolver.zaiToken(environment: $0) },
                missingCredentialsError: { ZaiSettingsError.missingToken },
                loadUsage: { apiKey, context in
                    let region = context.settings?.zai?.apiRegion ?? .global
                    return try await ZaiUsageFetcher.fetchUsageWithModelUsage(
                        apiKey: apiKey,
                        region: region,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "zai",
                aliases: ["z.ai"],
                versionDetector: nil))
    }
}
