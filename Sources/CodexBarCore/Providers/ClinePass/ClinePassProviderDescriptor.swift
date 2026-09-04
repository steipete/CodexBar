import Foundation

public enum ClinePassProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ClinePassSettingsReader.apiKeyEnvironmentKey,
        resolve: ClinePassSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .clinepass,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .clinepass,
                displayName: "ClinePass",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ClinePass usage",
                cliName: "clinepass",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "ClinePass debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://app.cline.bot/dashboard/subscription?personal=true",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .clinepass),
                iconResourceName: "ProviderIcon-clinepass",
                color: ProviderColor(red: 84 / 255, green: 135 / 255, blue: 200 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x5487C8),
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ClinePass cost history is not available via the usage-limits API." }),
            presentation: ProviderUsagePresentation(
                primaryBindingQuotaLanes: [.secondary, .tertiary]),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "clinepass",
                aliases: [],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "clinepass.js",
                    provider: .clinepass,
                    bundledPlugin: "clinepass",
                    secretKey: ClinePassSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
