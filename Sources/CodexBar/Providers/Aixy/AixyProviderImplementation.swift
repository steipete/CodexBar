import CodexBarCore
import Foundation

struct AixyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .aixy

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .aixy, field: .apiKey]
        _ = settings[providerConfig: .aixy, field: .endpoint]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.token(for: .aixy, environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "aixy-api-key",
                title: "API key",
                subtitle: "Project-scoped Aixy key used to read its own usage and applicable budgets.",
                kind: .secure,
                placeholder: "Paste Aixy API key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "aixy-base-url",
                title: "Base URL",
                subtitle: "Optional Aixy gateway URL for a self-hosted or dedicated installation.",
                kind: .plain,
                placeholder: "https://api.aixy-gateway.com",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil),
        ]
    }
}
