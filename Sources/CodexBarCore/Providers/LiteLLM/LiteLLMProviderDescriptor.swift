import Foundation

public enum LiteLLMProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .litellm,
        displayName: "LiteLLM",
        sessionLabel: "Personal budget",
        weeklyLabel: "Team budget",
        creditsHint: "Reads spend and budget from LiteLLM key, user, and team info endpoints.",
        debugLogUnavailableMessage: "LiteLLM debug log not yet implemented",
        usesDetailBackedWindow: true,
        dashboardURL: nil,
        color: ProviderColor(hex: 0x4C89F0),
        confetti: [0x191938, 0x8258F2, 0xC5B9F6],
        noDataMessage: "LiteLLM spend is reported by the provider API.",
        environmentKey: LiteLLMSettingsReader.apiKeyEnvironmentKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple LiteLLM API keys.",
            placeholder: "Paste LiteLLM API key…",
            injection: .environment(key: LiteLLMSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        presentation: ProviderUsagePresentation(
            costPresenter: { snapshot in
                guard let cost = snapshot.providerCost,
                      cost.limit <= 0 else { return .init(menuCardStyle: .hidden) }
                return .init(
                    showsGenericFallback: false,
                    balances: [.init(
                        label: cost.period ?? "Spend",
                        amount: cost.used,
                        currencyCode: cost.currencyCode)],
                    menuCardStyle: .apiSpend)
            },
            menuBarWindowResolver: { context in
                guard context.metric == .automatic else { return .unhandled }
                return .resolved(
                    ProviderUsagePresentation.exhausted(context.snapshot.primary, context.snapshot.secondary)
                        ?? context.snapshot.secondary
                        ?? context.snapshot.primary)
            },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                showsSecondaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .detailWhenResetDatePresent)),
        aliases: ["litellm-proxy"],
        validateContext: { context in
            guard LiteLLMSettingsReader.baseURL(environment: context.env) != nil else {
                throw LiteLLMUsageError.invalidEndpointOverride(
                    LiteLLMSettingsReader.baseURLEnvironmentKey)
            }
        },
        apiKeyField: .init(
            id: "litellm-api-key",
            title: "API key",
            subtitle: "LiteLLM virtual key used to read its own spend and budget.",
            placeholder: "sk-…"),
        endpoint: .init(
            environmentKey: LiteLLMSettingsReader.baseURLEnvironmentKey,
            requirement: .required(.configured),
            resolve: LiteLLMSettingsReader.baseURL,
            field: .init(
                id: "litellm-base-url",
                title: "Base URL",
                subtitle: "LiteLLM proxy base URL. /v1 suffixes are accepted and stripped for management endpoints.",
                placeholder: "https://litellm.example.com")),
        toggles: [.init(
            id: "litellm-model-usage",
            title: "Show model activity",
            subtitle: "Read the user's last 30 days of tokens and logged requests by model.",
            environmentKey: LiteLLMSettingsReader.modelUsageEnvironmentKey,
            value: { $0.litellmModelUsageEnabled },
            setValue: { $0.litellmModelUsageEnabled = $1 },
            enabledTimeout: 40)],
        showsAPIDetail: true,
        availability: .environmentKey)
}
