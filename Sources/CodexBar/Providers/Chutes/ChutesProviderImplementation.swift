import CodexBarCore
import Foundation

struct ChutesProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .chutes

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.chutesAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ChutesSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.chutesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "chutes-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Paste a Chutes API key.",
                kind: .secure,
                placeholder: "chutes key...",
                binding: context.stringBinding(\.chutesAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
