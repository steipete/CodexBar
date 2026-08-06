import Foundation

public enum DeepInfraProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: DeepInfraSettingsReader.apiKeyEnvironmentKey,
        resolve: DeepInfraSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple DeepInfra API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: DeepInfraSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in DeepInfraUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepinfra,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .deepinfra,
                displayName: "DeepInfra",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show DeepInfra usage",
                cliName: "deepinfra",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "DeepInfra debug log not yet implemented",
                balanceOnly: true,
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://deepinfra.com/dash",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepinfra.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .deepinfra),
                iconResourceName: "ProviderIcon-deepinfra",
                color: ProviderColor(red: 42 / 255, green: 50 / 255, blue: 117 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x2A3275),
                    ProviderColor(hex: 0x747FDE),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepInfra per-request cost history is not available in CodexBar." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    movePrimaryDetailToStatus: { _ in true }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: .apiToken(
                strategyID: "deepinfra.api",
                resolveToken: { ProviderTokenResolver.token(for: .deepinfra, environment: $0) },
                missingCredentialsError: { DeepInfraUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await DeepInfraUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "deepinfra",
                aliases: ["deep-infra", "di"],
                versionDetector: nil))
    }
}
