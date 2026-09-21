import Foundation

public enum LLMProxyProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: LLMProxySettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(LLMProxySettingsReader.baseURLEnvironmentKey)],
        resolve: LLMProxySettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple LLM Proxy API keys.",
            placeholder: "Paste proxy API key…",
            injection: .environment(key: LLMProxySettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .llmproxy,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .llmproxy,
                displayName: "LLM Proxy",
                sessionLabel: "Quota",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show LLM Proxy usage",
                cliName: "llmproxy",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "LLM Proxy debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .llmproxy),
                iconResourceName: "ProviderIcon-llmproxy",
                color: ProviderColor(red: 36 / 255, green: 180 / 255, blue: 126 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x00FFFF),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x000000),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LLM Proxy cost history is reported in the quota-stats summary." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "llmproxy.js",
                        provider: .llmproxy,
                        bundledPlugin: "llmproxy",
                        secretKey: LLMProxySettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
                        validateContext: { context in
                            guard LLMProxySettingsReader.baseURL(environment: context.env) != nil else {
                                throw LLMProxyUsageError.invalidEndpointOverride(
                                    LLMProxySettingsReader.baseURLEnvironmentKey)
                            }
                        },
                        resolveValues: { context in
                            guard let key = self.credentials.resolveToken(environment: context.env)?.token,
                                  LLMProxySettingsReader.hasBaseURLOverride(environment: context.env)
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [LLMProxySettingsReader.baseURLEnvironmentKey:
                                    LLMProxySettingsReader.baseURL(environment: context.env)?.absoluteString ?? ""],
                                secrets: [LLMProxySettingsReader.apiKeyEnvironmentKey: key])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "llmproxy",
                aliases: ["llm-api-key-proxy", "llm-proxy"],
                versionDetector: nil))
    }
}
