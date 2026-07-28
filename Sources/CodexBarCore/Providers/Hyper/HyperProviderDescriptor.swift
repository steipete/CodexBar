import Foundation

public enum HyperProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .hyper,
            metadata: ProviderMetadata(
                id: .hyper,
                displayName: "Charm Hyper",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Charm Hyper usage",
                cliName: "hyper",
                defaultEnabled: false,
                dashboardURL: "https://hyper.charm.land",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .hyper,
                iconResourceName: "ProviderIcon-hyper",
                color: ProviderColor(red: 1, green: 96 / 255, blue: 1),
                confettiPalette: [
                    ProviderColor(red: 1, green: 96 / 255, blue: 1),
                    ProviderColor(red: 1, green: 1, blue: 1),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Charm Hyper cost history is not available via API." }),
            fetchPlan: .apiToken(
                strategyID: "hyper.api",
                resolveToken: { ProviderTokenResolver.hyperToken(environment: $0) },
                missingCredentialsError: { HyperUsageError.missingCredentials },
                loadUsage: { apiKey, _ in try await HyperUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot() }),
            cli: ProviderCLIConfig(name: "hyper", aliases: [], versionDetector: nil))
    }
}
