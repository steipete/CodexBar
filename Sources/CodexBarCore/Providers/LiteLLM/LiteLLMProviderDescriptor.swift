import Foundation

public enum LiteLLMProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: LiteLLMSettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(LiteLLMSettingsReader.baseURLEnvironmentKey)],
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
                    let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                        ? .apiSpend
                        : .hidden
                    return ProviderCostPresentation(menuCardStyle: style)
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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "litellm.js",
                        provider: .litellm,
                        bundledPlugin: "litellm",
                        secretKey: LiteLLMSettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
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
                                settings: [LiteLLMSettingsReader.baseURLEnvironmentKey:
                                    LiteLLMSettingsReader.baseURL(environment: context.env)?.absoluteString ?? ""],
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
