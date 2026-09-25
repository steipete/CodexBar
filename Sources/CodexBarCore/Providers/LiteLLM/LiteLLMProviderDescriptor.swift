import Foundation

public enum LiteLLMProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: LiteLLMSettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [
            .enterpriseHost(LiteLLMSettingsReader.baseURLEnvironmentKey),
            ProviderCredentialEnvironmentProjection(
                key: LiteLLMSettingsReader.modelUsageEnvironmentKey,
                value: { $0.litellmModelUsageEnabled.map(String.init) }),
        ],
        resolve: LiteLLMSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple LiteLLM API keys.",
            placeholder: "Paste LiteLLM API key…",
            injection: .environment(key: LiteLLMSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .litellm,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .litellm,
                displayName: "LiteLLM",
                sessionLabel: "Personal budget",
                weeklyLabel: "Team budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Reads spend and budget from LiteLLM key, user, and team info endpoints.",
                toggleTitle: "Show LiteLLM usage",
                cliName: "litellm",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "LiteLLM debug log not yet implemented",
                usesDetailBackedWindow: true,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .litellm),
                iconResourceName: "ProviderIcon-litellm",
                color: ProviderColor(red: 76 / 255, green: 137 / 255, blue: 240 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x191938),
                    ProviderColor(hex: 0x8258F2),
                    ProviderColor(hex: 0xC5B9F6),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LiteLLM spend is reported by the provider API." }),
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
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [ScriptFetchStrategy(
                        id: "litellm.js",
                        provider: .litellm,
                        bundledPlugin: "litellm",
                        secretKey: LiteLLMSettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
                        timeout: context.env[LiteLLMSettingsReader.modelUsageEnvironmentKey] == "true"
                            ? 40 : ProviderPluginRuntime.defaultTimeout,
                        validateContext: { context in
                            guard LiteLLMSettingsReader.baseURL(environment: context.env) != nil else {
                                throw LiteLLMUsageError.invalidEndpointOverride(
                                    LiteLLMSettingsReader.baseURLEnvironmentKey)
                            }
                        },
                        resolveValues: { context in
                            guard let key = self.credentials.resolveToken(environment: context.env)?.token,
                                  LiteLLMSettingsReader.hasBaseURLOverride(environment: context.env)
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [
                                    LiteLLMSettingsReader.baseURLEnvironmentKey:
                                        LiteLLMSettingsReader.baseURL(environment: context.env)?.absoluteString ?? "",
                                    LiteLLMSettingsReader.modelUsageEnvironmentKey:
                                        context.env[LiteLLMSettingsReader.modelUsageEnvironmentKey] ?? "false",
                                ],
                                secrets: [LiteLLMSettingsReader.apiKeyEnvironmentKey: key])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "litellm",
                aliases: ["litellm-proxy"],
                versionDetector: nil))
    }
}
