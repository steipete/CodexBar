import Foundation

public enum AzureOpenAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: AzureOpenAISettingsReader.apiKeyEnvironmentKey,
        apiKeyDebugLabel: AzureOpenAISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [
            .enterpriseHost(AzureOpenAISettingsReader.endpointEnvironmentKey),
            .workspaceID(AzureOpenAISettingsReader.deploymentNameEnvironmentKey),
        ],
        resolve: AzureOpenAISettingsReader.apiKey,
        missingCredentialMessage: { _ in AzureOpenAISettingsError.missingAPIKey.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .azureopenai,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 0, supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .azureopenai,
                displayName: "Azure OpenAI",
                sessionLabel: "Status",
                weeklyLabel: "Deployment",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Azure OpenAI status",
                cliName: "azure-openai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://ai.azure.com",
                statusPageURL: nil,
                statusLinkURL: "https://azure.status.microsoft/en-us/status"),
            branding: ProviderBranding(
                // Provider-specific by design: Azure OpenAI deliberately shares OpenAI's icon rendering style.
                iconStyle: .init(provider: .openai),
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0, green: 120 / 255, blue: 212 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0078D4),
                    ProviderColor(hex: 0x50E6FF),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Azure OpenAI usage history is not exposed by the deployment validation probe." }),
            presentation: ProviderUsagePresentation(menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AzureOpenAIAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "azure-openai",
                aliases: ["azureopenai", "aoai"],
                versionDetector: nil))
    }
}

struct AzureOpenAIAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "azureopenai.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Keep the strategy available so missing partial configuration surfaces
        // as a precise settings error instead of a generic no-strategy failure.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveAPIKey(environment: context.env) else {
            throw AzureOpenAIUsageError.missingAPIKey
        }
        try AzureOpenAISettingsReader.validateEndpointOverrides(environment: context.env)
        guard let endpoint = Self.resolveEndpoint(environment: context.env) else {
            throw AzureOpenAIUsageError.missingEndpoint
        }
        guard let deploymentName = Self.resolveDeploymentName(environment: context.env) else {
            throw AzureOpenAIUsageError.missingDeploymentName
        }

        let usage = try await AzureOpenAIUsageFetcher.fetchUsage(
            apiKey: apiKey,
            endpoint: endpoint,
            deploymentName: deploymentName,
            apiVersion: AzureOpenAISettingsReader.apiVersion(environment: context.env))
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "deployment")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveAPIKey(environment: [String: String]) -> String? {
        ProviderTokenResolver.token(for: .azureopenai, environment: environment)
    }

    private static func resolveEndpoint(environment: [String: String]) -> URL? {
        AzureOpenAISettingsReader.endpoint(environment: environment)
    }

    private static func resolveDeploymentName(environment: [String: String]) -> String? {
        AzureOpenAISettingsReader.deploymentName(environment: environment)
    }
}
