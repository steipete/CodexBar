import Foundation

public enum OpenRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OpenRouterSettingsReader.envKey,
        apiKeyDebugLabel: OpenRouterSettingsReader.envKey,
        additionalProjections: [.enterpriseHost(OpenRouterSettingsReader.apiURLEnvironmentKey)],
        resolve: OpenRouterSettingsReader.apiToken,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple OpenRouter API keys.",
            placeholder: "sk-or-v1-...",
            injection: .environment(key: OpenRouterSettingsReader.envKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        configValidator: { config in
            guard let raw = config.sanitizedEnterpriseHost,
                  ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil
            else { return [] }
            return [CodexBarConfigIssue(
                severity: .error,
                provider: .openrouter,
                field: "enterpriseHost",
                code: "invalid_enterprise_host",
                message: OpenRouterSettingsError.invalidEndpointOverride(
                    OpenRouterSettingsReader.apiURLEnvironmentKey).errorDescription ?? "Invalid OpenRouter API URL.")]
        },
        missingCredentialMessage: { _ in OpenRouterSettingsError.missingToken.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openrouter,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .openrouter,
                displayName: "OpenRouter",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credit balance from OpenRouter API",
                toggleTitle: "Show OpenRouter usage",
                cliName: "openrouter",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://openrouter.ai/settings/credits",
                statusPageURL: nil,
                statusLinkURL: "https://status.openrouter.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .openrouter),
                iconResourceName: "ProviderIcon-openrouter",
                color: ProviderColor(red: 100 / 255, green: 103 / 255, blue: 242 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x96A5B9),
                    ProviderColor(hex: 0x161616),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 111 / 255, green: 66 / 255, blue: 193 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenRouter cost summary is not yet supported." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsCreditsSection: false,
                    primaryDescriptionPlacement: .reset),
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "openrouter",
                aliases: ["or"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "openrouter.js",
                    provider: .openrouter,
                    bundledPlugin: "openrouter",
                    secretKey: OpenRouterSettingsReader.envKey,
                    sourceLabel: "api",
                    validateContext: { context in
                        try OpenRouterSettingsReader.validateEndpointOverrides(environment: context.env)
                    },
                    resolveValues: { context in
                        guard let token = self.credentials.resolveToken(environment: context.env)?.token else {
                            return nil
                        }
                        var settings = [
                            OpenRouterSettingsReader.apiURLEnvironmentKey:
                                OpenRouterSettingsReader.apiURL(environment: context.env).absoluteString,
                            OpenRouterSettingsReader.clientTitleEnvironmentKey:
                                OpenRouterSettingsReader.clientTitle(environment: context.env),
                        ]
                        if let referer = OpenRouterSettingsReader.httpReferer(environment: context.env) {
                            settings[OpenRouterSettingsReader.httpRefererEnvironmentKey] = referer
                        }
                        return ScriptFetchStrategy.Values(
                            settings: settings,
                            secrets: [OpenRouterSettingsReader.envKey: token])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}

/// Errors related to OpenRouter settings
public enum OpenRouterSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "OpenRouter API token not configured. Set OPENROUTER_API_KEY environment variable or configure in Settings."
        case let .invalidEndpointOverride(key):
            "OpenRouter endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
