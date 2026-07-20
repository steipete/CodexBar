import Foundation

public enum VeniceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .venice,
            metadata: ProviderMetadata(
                id: .venice,
                displayName: "Venice",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Venice usage",
                cliName: "venice",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://venice.ai/settings/api",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .venice,
                iconResourceName: "ProviderIcon-venice",
                color: ProviderColor(red: 0.2, green: 0.6, blue: 1.0),
                confettiPalette: [
                    ProviderColor(hex: 0x0E2942),
                    ProviderColor(hex: 0xF7F5ED),
                    ProviderColor(hex: 0x3C8FDD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Venice per-day cost history is not available via API." }),
            fetchPlan: .apiToken(
                strategyID: "venice.api",
                resolveToken: { ProviderTokenResolver.veniceToken(environment: $0) },
                missingCredentialsError: { VeniceUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await VeniceUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "venice",
                aliases: ["ven"],
                versionDetector: nil))
    }
}
