import Foundation

public enum WarpProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .warp,
            metadata: ProviderMetadata(
                id: .warp,
                displayName: "Warp",
                sessionLabel: "Credits",
                weeklyLabel: "Add-on credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Warp usage",
                cliName: "warp",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://docs.warp.dev/reference/cli/api-keys",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .warp,
                iconResourceName: "ProviderIcon-warp",
                color: ProviderColor(red: 147 / 255, green: 139 / 255, blue: 180 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Warp cost summary is not available." }),
            fetchPlan: .apiToken(
                strategyID: "warp.api",
                resolveToken: { ProviderTokenResolver.warpToken(environment: $0) },
                missingCredentialsError: { WarpUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await WarpUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "warp",
                aliases: ["warp-ai", "warp-terminal"],
                versionDetector: nil))
    }
}
