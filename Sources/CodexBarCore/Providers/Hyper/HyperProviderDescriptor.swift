import Foundation

public enum HyperProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
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
            color: ProviderColor(red: 0.97, green: 0.35, blue: 0.50),
            confettiPalette: [
                ProviderColor(red: 0.97, green: 0.35, blue: 0.50),
                ProviderColor(red: 0.45, green: 0.32, blue: 0.96),
            ]),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Charm Hyper per-day cost history is not available via API." }),
        fetchPlan: .apiToken(
            strategyID: "hyper.api",
            resolveToken: { ProviderTokenResolver.hyperToken(environment: $0) },
            missingCredentialsError: { HyperUsageError.missingCredentials },
            loadUsage: { apiKey, _ in
                try await HyperUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
            }),
        cli: ProviderCLIConfig(name: "hyper", aliases: [], versionDetector: nil))
}
