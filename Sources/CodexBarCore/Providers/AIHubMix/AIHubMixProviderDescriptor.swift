import Foundation

public enum AIHubMixProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: AIHubMixSettingsReader.apiKeyEnvironmentKey,
        resolve: AIHubMixSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "Manage keys",
            subtitle: "Store multiple AIHubMix Manage Keys.",
            placeholder: "Paste Manage Key…",
            injection: .environment(key: AIHubMixSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentKeysToScrub: [AIHubMixSettingsReader.tokenEnvironmentKey]),
        missingCredentialMessage: { _ in AIHubMixUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .aihubmix,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .aihubmix,
                displayName: "AIHubMix",
                shortDisplayName: "AIHubMix",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Prepaid USD balance from the AIHubMix Manage Key.",
                toggleTitle: "Show AIHubMix usage",
                cliName: "aihubmix",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                dashboardURL: "https://aihubmix.com/setting",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .aihubmix),
                iconResourceName: "ProviderIcon-aihubmix",
                color: ProviderColor(hex: 0x2563EB),
                confettiPalette: [
                    ProviderColor(hex: 0x2563EB),
                    ProviderColor(hex: 0x0049DF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "AIHubMix cost history is not exposed by the account API." }),
            presentation: ProviderUsagePresentation(
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: .apiToken(
                strategyID: "aihubmix.api",
                resolveToken: { AIHubMixSettingsReader.apiKey(environment: $0) },
                missingCredentialsError: { AIHubMixUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try await AIHubMixUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "aihubmix",
                aliases: ["aihub"],
                versionDetector: nil))
    }
}
