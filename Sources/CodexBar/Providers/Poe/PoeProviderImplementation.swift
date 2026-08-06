import CodexBarCore
import Foundation

struct PoeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .poe

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .poe, field: .apiKey]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "poe-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from poe.com/api/keys.",
                kind: .secure,
                placeholder: nil,
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.poeToken(environment: context.environment) != nil ||
            !context.settings[providerConfig: .poe, field: .apiKey].trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}
