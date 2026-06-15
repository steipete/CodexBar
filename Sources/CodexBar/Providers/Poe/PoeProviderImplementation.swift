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
        _ = settings.poeAPIKey
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
                binding: context.stringBinding(\.poeAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.poeToken(environment: context.environment) != nil ||
            !context.settings.poeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
