import Foundation

public enum V0ProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: V0SettingsReader.apiKeyEnvironmentKey,
        apiKeyDebugLabel: V0SettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [
            .workspaceID(V0SettingsReader.scopeEnvironmentKey),
        ],
        resolve: V0SettingsReader.apiKey,
        missingCredentialMessage: { _ in
            "v0 API key not configured. Create one at v0.app/settings/keys."
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .v0,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .v0,
                displayName: "v0",
                sessionLabel: "Billing",
                weeklyLabel: "Rate limit",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Billing and rate-limit data from the v0 Platform API",
                toggleTitle: "Show v0 usage",
                cliName: "v0",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://v0.app/settings/billing",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .v0),
                iconResourceName: "ProviderIcon-v0",
                color: ProviderColor(hex: 0x111111),
                confettiPalette: [
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x888888),
                ],
                widgetColor: ProviderColor(hex: 0x111111)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "v0 cost history is not available via the Platform API." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "v0",
                aliases: [],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "v0.js",
                    provider: .v0,
                    bundledPlugin: "v0",
                    secretKey: V0SettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveValues: { context in
                        guard let key = self.credentials.resolveToken(environment: context.env)?.token else {
                            return nil
                        }
                        var settings: [String: String] = [:]
                        if let scope = V0SettingsReader.scope(environment: context.env) {
                            settings[V0SettingsReader.scopeEnvironmentKey] = scope
                        }
                        return ScriptFetchStrategy.Values(
                            settings: settings,
                            secrets: [V0SettingsReader.apiKeyEnvironmentKey: key])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
