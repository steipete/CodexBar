import CodexBarCore
import Foundation

struct LLMManProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .llmman

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .llmman, field: .apiKey]
        _ = settings[providerConfig: .llmman, field: .endpoint]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "llmman-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Only needed when llmman serve requires API keys.",
                kind: .secure,
                placeholder: "LLMMAN_API_KEY",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "llmman-base-url",
                title: "Base URL",
                subtitle: "Address of llmman serve. Defaults to http://127.0.0.1:17434.",
                kind: .plain,
                placeholder: LLMManSettingsReader.defaultBaseURL.absoluteString,
                binding: context.providerConfigBinding(.endpoint),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "llmman-open-web-ui",
                        title: "Open llmman",
                        url: LLMManSettingsReader.baseURL(environment: [
                            LLMManSettingsReader.hostEnvironmentKey:
                                context.settings[providerConfig: .llmman, field: .endpoint],
                        ])),
                ],
                isVisible: nil),
        ]
    }
}
