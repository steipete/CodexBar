import Foundation

public enum NeuralWattProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .neuralwatt,
            metadata: ProviderMetadata(
                id: .neuralwatt,
                displayName: "Neuralwatt",
                sessionLabel: "Subscription",
                weeklyLabel: "Key allowance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Subscription kWh and prepaid USD balance.",
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
                color: ProviderColor(red: 0.22, green: 0.85, blue: 0.55),
                confettiPalette: [
                    ProviderColor(hex: 0x38D98C),
                    ProviderColor(hex: 0x17243A),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
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
