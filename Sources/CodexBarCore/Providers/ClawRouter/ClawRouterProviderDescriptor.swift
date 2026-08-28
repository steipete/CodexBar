import Foundation

public enum ClawRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ClawRouterSettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(ClawRouterSettingsReader.baseURLEnvironmentKey)],
        resolve: ClawRouterSettingsReader.apiKey,
        missingCredentialMessage: { _ in ClawRouterSettingsReader.missingCredentialsMessage })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .clawrouter,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .clawrouter,
                displayName: "ClawRouter",
                sessionLabel: "Monthly budget",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ClawRouter usage",
                cliName: "clawrouter",
                defaultEnabled: false,
                widgetSelectable: false,
                debugLogUnavailableMessage: "ClawRouter debug log not yet implemented",
                dashboardURL: "https://clawrouter.openclaw.ai/dashboard/access",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .clawrouter),
                iconResourceName: "ProviderIcon-clawrouter",
                color: ProviderColor(red: 89 / 255, green: 110 / 255, blue: 246 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x332CB3),
                    ProviderColor(hex: 0x456FDD),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ClawRouter spend is reported by its usage API." }),
            presentation: ProviderUsagePresentation(costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .clawRouter)
            }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "clawrouter",
                aliases: ["claw-router"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "clawrouter.js",
                    provider: .clawrouter,
                    bundledPlugin: "clawrouter",
                    secretKey: ClawRouterSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    validateContext: { context in
                        try ClawRouterSettingsReader.validateEndpointOverride(environment: context.env)
                    },
                    resolveValues: { context in
                        guard let token = self.credentials.resolveToken(environment: context.env)?.token else {
                            return nil
                        }
                        return ScriptFetchStrategy.Values(
                            settings: [
                                ClawRouterSettingsReader.baseURLEnvironmentKey:
                                    ClawRouterSettingsReader.baseURL(environment: context.env).absoluteString,
                            ],
                            secrets: [ClawRouterSettingsReader.apiKeyEnvironmentKey: token])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
