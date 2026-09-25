import CodexBarCore
import Foundation

struct OpenRouterProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openrouter

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .openrouter, field: .apiKey]
        _ = settings[providerConfig: .openrouter, field: .endpoint]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        ProviderDescriptorRegistry.descriptor(for: self.id).settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(
                config: context.settings.providerConfig(for: self.id),
                account: nil))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        OpenRouterSettingsReader.apiToken(environment: context.environment) != nil ||
            !context.settings[providerConfig: .openrouter, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "openrouter-api-key",
                title: "API key",
                subtitle: "Required. Enter a regular API key or a Management API key here. "
                    + "Management keys also enable account Activity on the official OpenRouter API.",
                kind: .secure,
                placeholder: "sk-or-v1-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "openrouter-api-url",
                title: "API URL",
                subtitle: "Optional. Defaults to the hosted OpenRouter API.",
                kind: .plain,
                placeholder: "https://openrouter.ai/api/v1",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "openrouter-management-api-key",
                title: "Management API key",
                subtitle: "Optional additional key for account Activity. "
                    + "Only needed to use a separate Management API key "
                    + "from the one in the required API key field above.",
                kind: .secure,
                placeholder: "sk-or-v1-...",
                binding: context.providerConfigSecretBinding(
                    key: OpenRouterSettingsReader.managementAPIKeyEnvironmentKey,
                    logField: "managementAPIKey"),
                actions: [],
                isVisible: nil),
        ]
    }
}
