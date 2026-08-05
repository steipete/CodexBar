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
                ProviderCostPresentation(showsGenericFallback: false)
            }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "clawrouter",
                aliases: ["claw-router"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        #if canImport(JavaScriptCore)
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
        #else
        // Linux compatibility only. JavaScriptCore platforms use the bundled ClawRouter plugin above.
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ClawRouterAPIFetchStrategy()] }))
        #endif
    }
}

#if !canImport(JavaScriptCore)
struct ClawRouterAPIFetchStrategy: ProviderFetchStrategy {
    let id = "clawrouter.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.clawRouterToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.clawRouterToken(environment: context.env) else {
            throw ClawRouterUsageError.missingCredentials
        }
        try ClawRouterSettingsReader.validateEndpointOverride(environment: context.env)
        let usage = try await ClawRouterUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: ClawRouterSettingsReader.baseURL(environment: context.env))
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
#endif
