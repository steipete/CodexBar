import Foundation

public enum ChutesProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ChutesSettingsReader.apiKeyEnvironmentKey,
        resolve: ChutesSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .chutes,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .chutes,
                displayName: "Chutes",
                sessionLabel: "4-hour quota",
                weeklyLabel: "Monthly quota",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Subscription usage from the Chutes API.",
                toggleTitle: "Show Chutes usage",
                cliName: "chutes",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Chutes debug log not yet implemented",
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://chutes.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .chutes),
                iconResourceName: "ProviderIcon-chutes",
                color: ProviderColor(red: 49 / 255, green: 132 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x121212),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x63D297),
                ],
                widgetColor: ProviderColor(red: 24 / 255, green: 160 / 255, blue: 88 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Chutes cost history is not available from CodexBar." }),
            presentation: ProviderUsagePresentation(
                primaryBindingQuotaLanes: [.secondary],
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .detailWhenResetDatePresent)),
            fetchPlan: .apiToken(
                strategyID: "chutes.api",
                resolveToken: ChutesSettingsReader.apiKey,
                missingCredentialsError: { ChutesSettingsError.missingToken },
                loadUsage: { apiKey, context in
                    try await ChutesUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "chutes",
                aliases: ["chutes.ai"],
                versionDetector: nil))
    }
}
