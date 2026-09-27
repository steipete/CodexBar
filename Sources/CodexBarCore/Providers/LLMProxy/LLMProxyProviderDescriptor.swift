import Foundation

public enum LLMProxyProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .llmproxy,
        displayName: "LLM Proxy",
        sessionLabel: "Quota",
        weeklyLabel: "Requests",
        debugLogUnavailableMessage: "LLM Proxy debug log not yet implemented",
        dashboardURL: nil,
        color: ProviderColor(hex: 0x24B47E),
        confetti: [0x00FFFF, 0xFFFFFF, 0x000000],
        noDataMessage: "LLM Proxy cost history is reported in the quota-stats summary.",
        environmentKey: LLMProxySettingsReader.apiKeyEnvironmentKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple LLM Proxy API keys.",
            placeholder: "Paste proxy API key…",
            injection: .environment(key: LLMProxySettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        aliases: ["llm-api-key-proxy", "llm-proxy"],
        validateContext: { context in
            guard LLMProxySettingsReader.baseURL(environment: context.env) != nil else {
                throw LLMProxyUsageError.invalidEndpointOverride(
                    LLMProxySettingsReader.baseURLEnvironmentKey)
            }
        },
        apiKeyField: .init(
            id: "llmproxy-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Used for /v1/quota-stats.",
            placeholder: "proxy key…"),
        endpoint: .init(
            environmentKey: LLMProxySettingsReader.baseURLEnvironmentKey,
            requirement: .required(.configured),
            resolve: LLMProxySettingsReader.baseURL,
            field: .init(
                id: "llmproxy-base-url",
                title: "Base URL",
                subtitle: "Base URL for the LLM-API-Key-Proxy instance.",
                placeholder: "https://proxy.example.com")),
        showsAPIDetail: true,
        availability: .environmentKey)
}
