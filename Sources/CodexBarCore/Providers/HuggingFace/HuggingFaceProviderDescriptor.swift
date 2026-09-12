import Foundation

public enum HuggingFaceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: HuggingFaceSettingsReader.configAPIKeyEnvironmentKey,
        resolve: { HuggingFaceSettingsReader.apiKey(environment: $0) },
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Hugging Face access tokens.",
            placeholder: "Paste access token…",
            injection: .environment(key: HuggingFaceSettingsReader.configAPIKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in HuggingFaceUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .huggingface,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .huggingface,
                displayName: "Hugging Face",
                sessionLabel: "Credits",
                weeklyLabel: "ZeroGPU",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Hugging Face usage",
                cliName: "huggingface",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://huggingface.co/settings/billing",
                statusPageURL: "https://status.huggingface.co"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .huggingface),
                iconResourceName: "ProviderIcon-huggingface",
                color: ProviderColor(hex: 0xFFD21E),
                confettiPalette: [
                    ProviderColor(hex: 0xFFD21E),
                    ProviderColor(hex: 0xFF9D00),
                    ProviderColor(hex: 0x6B7280),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Hugging Face usage comes from the billing API; cost history is not tracked." }),
            fetchPlan: .apiToken(
                strategyID: "huggingface.api",
                resolveToken: { HuggingFaceSettingsReader.apiKey(environment: $0) },
                missingCredentialsError: { HuggingFaceUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await HuggingFaceUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "huggingface",
                aliases: ["hf"],
                versionDetector: nil))
    }
}
