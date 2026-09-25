import Foundation

public enum XKiroProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    public static let apiKey = "XKIRO_API_KEY"
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: Self.apiKey,
        resolve: { SettingsValue.cleaned($0[Self.apiKey]) },
        missingCredentialMessage: { _ in "Set an xKiro API key in Settings or XKIRO_API_KEY." })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .xkiro,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .xkiro,
                displayName: "xKiro",
                sessionLabel: "Daily free tokens",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show xKiro usage",
                cliName: "xkiro",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://xkiro.com",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .xkiro),
                iconResourceName: "ProviderIcon-xkiro",
                color: ProviderColor(hex: 0x52C99B),
                confettiPalette: [ProviderColor(hex: 0x52C99B), ProviderColor(hex: 0xB7F2D7)]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "xKiro cost history is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "xkiro.js",
                        provider: .xkiro,
                        bundledPlugin: "xkiro",
                        secretKey: self.apiKey,
                        sourceLabel: "api",
                        resolveSecret: { self.credentials.resolveToken(environment: $0)?.token },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(name: "xkiro", versionDetector: nil))
    }
}
