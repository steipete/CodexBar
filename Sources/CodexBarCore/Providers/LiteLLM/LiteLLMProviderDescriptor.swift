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
                    hidesPrimaryResetWithoutDate: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LiteLLMAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "litellm",
                aliases: ["litellm-proxy"],
                versionDetector: nil))
    }
}

struct LiteLLMAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "litellm.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.token(for: .litellm, environment: context.env) != nil &&
            LiteLLMSettingsReader.hasBaseURLOverride(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.token(for: .litellm, environment: context.env) else {
            throw LiteLLMUsageError.missingCredentials
        }
        guard let baseURL = LiteLLMSettingsReader.baseURL(environment: context.env) else {
            // Distinguish "never configured" from "configured but rejected" so the user sees
            // which one applies instead of the provider silently going unavailable.
            throw LiteLLMSettingsReader.hasBaseURLOverride(environment: context.env)
                ? LiteLLMUsageError.invalidEndpointOverride(LiteLLMSettingsReader.baseURLEnvironmentKey)
                : LiteLLMUsageError.missingBaseURL
        }
        let usage = try await LiteLLMUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: baseURL)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
