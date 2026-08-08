import Foundation

public enum SyntheticProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: SyntheticSettingsReader.apiKeyKey,
        resolve: SyntheticSettingsReader.apiKey,
        missingCredentialMessage: { _ in SyntheticSettingsError.missingToken.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .synthetic,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .synthetic,
                displayName: "Synthetic",
                sessionLabel: "Five-hour quota",
                weeklyLabel: "Weekly tokens",
                opusLabel: "Search hourly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "Weekly token quota regenerates continuously.",
                toggleTitle: "Show Synthetic usage",
                cliName: "synthetic",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["starter": "Starter", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"],
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .synthetic),
                iconResourceName: "ProviderIcon-synthetic",
                color: ProviderColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x6366F1),
                    ProviderColor(hex: 0x3E3E3E),
                    ProviderColor(hex: 0xF7F6F3),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Synthetic cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .hidden) },
                menuCard: ProviderMenuCardPresentation(usesSyntheticRollingRegen: true)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "synthetic",
                aliases: ["synthetic.new"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        .scriptPrototypeAPI(
            configuration: .init(
                provider: .synthetic,
                plugin: "synthetic",
                secretKey: SyntheticSettingsReader.apiKeyKey,
                strategyID: "synthetic.api"),
            resolveToken: { ProviderTokenResolver.token(for: .synthetic, environment: $0) },
            missingCredentialsError: { SyntheticSettingsError.missingToken },
            loadUsage: { apiKey, _ in
                try await SyntheticUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
            })
    }
}
