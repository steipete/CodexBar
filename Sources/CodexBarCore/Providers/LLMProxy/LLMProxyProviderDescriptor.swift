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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LLMProxyAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "llmproxy",
                aliases: ["llm-api-key-proxy", "llm-proxy"],
                versionDetector: nil))
    }
}

struct LLMProxyAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "llmproxy.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.llmProxyToken(environment: context.env) != nil &&
            LLMProxySettingsReader.hasBaseURLOverride(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.llmProxyToken(environment: context.env) else {
            throw LLMProxyUsageError.missingCredentials
        }
        guard let baseURL = LLMProxySettingsReader.baseURL(environment: context.env) else {
            // Distinguish "never configured" from "configured but rejected" so the user sees
            // which one applies instead of the provider silently going unavailable.
            throw LLMProxySettingsReader.hasBaseURLOverride(environment: context.env)
                ? LLMProxyUsageError.invalidEndpointOverride(LLMProxySettingsReader.baseURLEnvironmentKey)
                : LLMProxyUsageError.missingBaseURL
        }
        let usage = try await LLMProxyUsageFetcher.fetchUsage(apiKey: apiKey, baseURL: baseURL)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
