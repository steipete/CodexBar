import Foundation

public enum LLMManProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: LLMManSettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(LLMManSettingsReader.hostEnvironmentKey)],
        resolve: LLMManSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .llmman,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .llmman,
                displayName: "llmman",
                sessionLabel: "Memory",
                weeklyLabel: "Models",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show llmman usage",
                cliName: "llmman",
                defaultEnabled: false,
                widgetSelectable: false,
                usesDetailBackedWindow: true,
                dashboardURL: LLMManSettingsReader.defaultBaseURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .llmman),
                iconResourceName: "ProviderIcon-llmman",
                color: ProviderColor(hex: 0x6CC5B0),
                confettiPalette: [
                    ProviderColor(hex: 0x6CC5B0),
                    ProviderColor(hex: 0x2F7F74),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "llmman cost summary is not supported." }),
            // The memory bar describes loaded weights, not a quota that resets.
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "llmman.js",
                        provider: .llmman,
                        bundledPlugin: "llmman",
                        sourceLabel: "api",
                        validateContext: { context in
                            guard LLMManSettingsReader.baseURL(environment: context.env) != nil else {
                                throw LLMManUsageError.invalidEndpointOverride(LLMManSettingsReader.hostEnvironmentKey)
                            }
                        },
                        resolveValues: { context in
                            .init(
                                settings: [LLMManSettingsReader.hostEnvironmentKey:
                                    LLMManSettingsReader.baseURL(environment: context.env)?.absoluteString ?? ""],
                                secrets: self.credentials.resolveToken(environment: context.env)
                                    .map { [LLMManSettingsReader.apiKeyEnvironmentKey: $0.token] } ?? [:])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(name: "llmman", versionDetector: nil))
    }
}
