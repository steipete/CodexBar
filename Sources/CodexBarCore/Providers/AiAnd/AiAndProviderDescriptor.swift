import Foundation

public enum AiAndProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: AiAndSettingsReader.apiKeyEnvironmentKey,
        resolve: AiAndSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .aiand,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .aiand,
                displayName: "ai&",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ai& usage",
                cliName: "aiand",
                defaultEnabled: false,
                widgetSelectable: false,
                debugLogUnavailableMessage: "ai& debug log not yet implemented",
                dashboardURL: "https://console.aiand.com",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .aiand),
                iconResourceName: "ProviderIcon-aiand",
                color: ProviderColor(red: 226 / 255, green: 92 / 255, blue: 43 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xE25C2B),
                    ProviderColor(hex: 0xF2A17E),
                    ProviderColor(hex: 0x33231C),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ai& spend is summed from the request logs API." }),
            presentation: ProviderUsagePresentation(costPresenter: { snapshot in
                let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                    ? .apiSpend
                    : .generic
                return ProviderCostPresentation(menuCardStyle: style)
            }),
            fetchPlan: .apiToken(
                strategyID: "aiand.api",
                resolveToken: AiAndSettingsReader.apiKey,
                missingCredentialsError: { AiAndUsageError.notConfigured },
                loadUsage: { credential, _ in
                    try await AiAndUsageFetcher.fetchUsage(credential).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "aiand",
                aliases: ["ai&", "ai-and"],
                versionDetector: nil))
    }
}
