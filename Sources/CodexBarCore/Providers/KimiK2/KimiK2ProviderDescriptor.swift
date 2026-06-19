import Foundation

public enum KimiK2ProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kimik2,
            metadata: ProviderMetadata(
                id: .kimik2,
                displayName: "Kimi K2 (unofficial)",
                sessionLabel: "Credits",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show unofficial Kimi K2 usage",
                cliName: "kimik2",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 76 / 255, green: 0 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Unofficial Kimi K2 cost summary is not available." }),
            fetchPlan: .apiToken(
                strategyID: "kimik2.api",
                resolveToken: { ProviderTokenResolver.kimiK2Token(environment: $0) },
                missingCredentialsError: { KimiK2UsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await KimiK2UsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "kimik2",
                aliases: ["kimi-k2", "kimiK2"],
                versionDetector: nil))
    }
}
