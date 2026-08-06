import Foundation

public enum NeuralWattProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: NeuralWattSettingsReader.apiKeyEnvironmentKey,
        resolve: NeuralWattSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Neuralwatt API keys.",
            placeholder: "sk-...",
            injection: .environment(key: NeuralWattSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            minimumDelayBetweenAccountRefreshes: .seconds(1)))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .neuralwatt,
            credentials: self.credentials,
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
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://portal.neuralwatt.com/dashboard",
                subscriptionDashboardURL: "https://portal.neuralwatt.com/dashboard",
                changelogURL: nil,
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .neuralwatt),
                iconResourceName: "ProviderIcon-neuralwatt",
                color: ProviderColor(red: 0.22, green: 0.85, blue: 0.55),
                confettiPalette: [
                    ProviderColor(hex: 0x38D98C),
                    ProviderColor(hex: 0x17243A),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 56 / 255, green: 217 / 255, blue: 140 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Neuralwatt token cost history is not available via the quota API." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .payAsYouGoBalance) },
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
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
