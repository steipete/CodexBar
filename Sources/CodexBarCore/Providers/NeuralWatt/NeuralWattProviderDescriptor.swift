import Foundation

public enum NeuralWattProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .neuralwatt,
            metadata: ProviderMetadata(
                id: .neuralwatt,
                displayName: "Neuralwatt",
                sessionLabel: "Credits",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Energy-based USD credit balance.",
                toggleTitle: "Show Neuralwatt usage",
                cliName: "neuralwatt",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://portal.neuralwatt.com/dashboard",
                subscriptionDashboardURL: "https://portal.neuralwatt.com/dashboard",
                changelogURL: nil,
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .neuralwatt,
                iconResourceName: "ProviderIcon-neuralwatt",
                color: ProviderColor(red: 0.22, green: 0.85, blue: 0.55)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Neuralwatt token cost history is not available via the quota API." }),
            fetchPlan: .apiToken(
                strategyID: "neuralwatt.api",
                resolveToken: { ProviderTokenResolver.neuralWattToken(environment: $0) },
                missingCredentialsError: { NeuralWattUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try await NeuralWattUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "neuralwatt",
                aliases: ["nw", "neural"],
                versionDetector: nil))
    }
}
