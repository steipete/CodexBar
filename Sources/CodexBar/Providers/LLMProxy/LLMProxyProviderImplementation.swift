import CodexBarCore
import Foundation

struct LLMProxyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .llmproxy

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.llmProxyAPIKey
        _ = settings.llmProxyBaseURL
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.llmProxyToken(environment: context.environment) != nil &&
            LLMProxySettingsReader.baseURL(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "llmproxy-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Used for /v1/quota-stats.",
                kind: .secure,
                placeholder: "proxy key…",
                binding: context.stringBinding(\.llmProxyAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "llmproxy-base-url",
                title: "Base URL",
                subtitle: "Base URL for the LLM-API-Key-Proxy instance.",
                kind: .plain,
                placeholder: "https://proxy.example.com",
                binding: context.stringBinding(\.llmProxyBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
