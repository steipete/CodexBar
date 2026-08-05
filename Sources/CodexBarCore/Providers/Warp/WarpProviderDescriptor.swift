import Foundation

public enum WarpProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: WarpSettingsReader.apiKeyEnvironmentKeys[0],
        resolve: WarpSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .warp,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .warp,
                displayName: "Warp",
                sessionLabel: "Credits",
                weeklyLabel: "Add-on credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Warp usage",
                cliName: "warp",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://docs.warp.dev/reference/cli/api-keys",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .warp),
                iconResourceName: "ProviderIcon-warp",
                color: ProviderColor(red: 147 / 255, green: 139 / 255, blue: 180 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xC7AEFF),
                    ProviderColor(hex: 0x1C1A26),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Warp cost summary is not available." }),
            presentation: ProviderUsagePresentation(
                iconDecorations: [.warp],
                treatsExhaustedSecondaryIconWindowAsMissing: true,
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .resetOverride)),
            fetchPlan: .apiToken(
                strategyID: "warp.api",
                resolveToken: { ProviderTokenResolver.warpToken(environment: $0) },
                missingCredentialsError: { WarpUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await WarpUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "warp",
                aliases: ["warp-ai", "warp-terminal"],
                versionDetector: nil))
    }
}
