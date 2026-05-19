import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AzureOpenAIProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .azureopenai,
            metadata: ProviderMetadata(
                id: .azureopenai,
                displayName: "Azure OpenAI",
                sessionLabel: "Status",
                weeklyLabel: "Deployment",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Azure OpenAI usage",
                cliName: "azure-openai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://ai.azure.com",
                statusPageURL: nil,
                statusLinkURL: "https://azure.status.microsoft/en-us/status"),
            branding: ProviderBranding(
                iconStyle: .openai,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0, green: 120 / 255, blue: 212 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Azure OpenAI usage history is not exposed by the deployment validation probe." }),
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
        Self.resolveAPIKey(environment: context.env) != nil &&
            Self.resolveEndpoint(environment: context.env) != nil &&
            Self.resolveDeploymentName(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveAPIKey(environment: context.env) else {
            throw AzureOpenAIUsageError.missingAPIKey
        }
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
        ProviderTokenResolver.azureOpenAIToken(environment: environment)
    }

    private static func resolveEndpoint(environment: [String: String]) -> URL? {
        AzureOpenAISettingsReader.endpoint(environment: environment)
    }

    private static func resolveDeploymentName(environment: [String: String]) -> String? {
        AzureOpenAISettingsReader.deploymentName(environment: environment)
    }
}
