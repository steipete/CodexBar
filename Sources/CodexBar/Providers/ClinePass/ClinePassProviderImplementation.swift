import CodexBarCore
import Foundation

struct ClinePassProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .clinepass

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .clinepass, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ClinePassSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .clinepass, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "clinepass-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Paste a ClinePass API key.",
                kind: .secure,
                placeholder: "ClinePass API key...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
