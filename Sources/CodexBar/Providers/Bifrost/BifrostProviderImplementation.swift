import CodexBarCore
import Foundation

struct BifrostProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .bifrost

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .bifrost, field: .apiKey]
        _ = settings[providerConfig: .bifrost, field: .endpoint]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.token(for: .bifrost, environment: context.environment) != nil &&
            BifrostSettingsReader.hasBaseURLOverride(environment: context.environment)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "bifrost-api-key",
                title: "Virtual key",
                subtitle: "Bifrost virtual key used to read its own budgets and rate limits.",
                kind: .secure,
                placeholder: "Paste Bifrost virtual key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "bifrost-base-url",
                title: "Base URL",
                subtitle: "Bifrost gateway base URL, e.g. your company's self-hosted Bifrost host.",
                kind: .plain,
                placeholder: "https://bifrost.example.com",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil),
        ]
    }
}
