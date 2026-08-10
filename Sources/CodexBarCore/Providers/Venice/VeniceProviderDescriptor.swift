import Foundation

public enum VeniceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: VeniceSettingsReader.apiKeyEnvironmentKey,
        resolve: VeniceSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Venice API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: VeniceSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .venice,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .venice,
                displayName: "Venice",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Venice usage",
                cliName: "venice",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Venice debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://venice.ai/settings/api",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .venice),
                iconResourceName: "ProviderIcon-venice",
                color: ProviderColor(red: 0.2, green: 0.6, blue: 1.0),
                confettiPalette: [
                    ProviderColor(hex: 0x0E2942),
                    ProviderColor(hex: 0xF7F5ED),
                    ProviderColor(hex: 0x3C8FDD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Venice per-day cost history is not available via API." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "venice",
                aliases: ["ven"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "venice.js",
                    provider: .venice,
                    bundledPlugin: "venice",
                    secretKey: VeniceSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
