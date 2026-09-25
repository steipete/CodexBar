import Foundation

public enum AixyProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: AixySettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(AixySettingsReader.baseURLEnvironmentKey)],
        resolve: AixySettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Aixy API keys.",
            placeholder: "Paste Aixy API key…",
            injection: .environment(key: AixySettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .aixy,
            menuBarMetrics: .automaticOnly,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .aixy,
                displayName: "Aixy",
                sessionLabel: "Budget",
                weeklyLabel: "Secondary budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Reads key-scoped usage and applicable budgets from Aixy.",
                toggleTitle: "Show Aixy usage",
                cliName: "aixy",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Aixy debug log not yet implemented",
                usesDetailBackedWindow: true,
                dashboardURL: "https://dash.aixy-gateway.com",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .aixy),
                iconResourceName: "ProviderIcon-aixy",
                color: ProviderColor(hex: 0x123650),
                confettiPalette: [
                    ProviderColor(hex: 0x123650),
                    ProviderColor(hex: 0xEC744A),
                    ProviderColor(hex: 0xF7F3E8),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Aixy spend is reported by the provider API." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .apiSpend) },
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .resolved(
                        context.snapshot.primary ?? context.snapshot.secondary)
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
                        id: "aixy.js",
                        provider: .aixy,
                        bundledPlugin: "aixy",
                        secretKey: AixySettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
                        validateContext: { context in
                            guard AixySettingsReader.baseURL(environment: context.env) != nil else {
                                throw ProviderFetchClassifiedError(
                                    kind: .apiFailure,
                                    message:
                                    "Set AIXY_BASE_URL to an HTTPS URL, or HTTP on loopback/private networks, " +
                                        "without embedded credentials.")
                            }
                        },
                        resolveValues: { context in
                            guard let key = self.credentials.resolveToken(environment: context.env)?.token
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [AixySettingsReader.baseURLEnvironmentKey:
                                    AixySettingsReader.baseURL(environment: context.env)?.absoluteString ?? ""],
                                secrets: [AixySettingsReader.apiKeyEnvironmentKey: key])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "aixy",
                aliases: [],
                versionDetector: nil))
    }
}
