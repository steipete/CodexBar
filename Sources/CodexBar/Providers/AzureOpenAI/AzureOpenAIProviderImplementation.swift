import CodexBarCore
import Foundation

struct AzureOpenAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .azureopenai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.azureOpenAIAPIKey
        _ = settings.azureOpenAIEndpoint
        _ = settings.azureOpenAIDeploymentName
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        let environment = context.environment
        let hasEnvironmentConfig = AzureOpenAISettingsReader.apiKey(environment: environment) != nil &&
            AzureOpenAISettingsReader.endpoint(environment: environment) != nil &&
            AzureOpenAISettingsReader.deploymentName(environment: environment) != nil
        if hasEnvironmentConfig { return true }

        return !context.settings.azureOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            AzureOpenAISettingsReader.endpointURL(from: context.settings.azureOpenAIEndpoint) != nil &&
            !context.settings.azureOpenAIDeploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "azure-openai-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. AZURE_OPENAI_API_KEY is also supported.",
                kind: .secure,
                placeholder: "Azure OpenAI key",
                binding: context.stringBinding(\.azureOpenAIAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "azure-openai-endpoint",
                title: "Endpoint",
                subtitle: "Azure OpenAI resource endpoint. AZURE_OPENAI_ENDPOINT is also supported.",
                kind: .plain,
                placeholder: "https://resource.openai.azure.com",
                binding: context.stringBinding(\.azureOpenAIEndpoint),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "azure-openai-deployment-name",
                title: "Deployment",
                subtitle: "Azure OpenAI deployment name. AZURE_OPENAI_DEPLOYMENT_NAME is also supported.",
                kind: .plain,
                placeholder: "gpt-4o-mini",
                binding: context.stringBinding(\.azureOpenAIDeploymentName),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
