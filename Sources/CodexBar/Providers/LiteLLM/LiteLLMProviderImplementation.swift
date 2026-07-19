import CodexBarCore
import Foundation

struct LiteLLMProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .litellm

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.liteLLMAPIKey
        _ = settings.liteLLMBaseURL
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.liteLLMToken(environment: context.environment) != nil &&
            LiteLLMSettingsReader.baseURL(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "litellm-api-key",
                title: "API key",
                subtitle: "LiteLLM virtual key used to read its own spend and budget.",
                kind: .secure,
                placeholder: "sk-…",
                binding: context.stringBinding(\.liteLLMAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "litellm-base-url",
                title: "Base URL",
                subtitle: "LiteLLM proxy base URL. /v1 suffixes are accepted and stripped for management endpoints.",
                kind: .plain,
                placeholder: "https://litellm.example.com",
                binding: context.stringBinding(\.liteLLMBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
