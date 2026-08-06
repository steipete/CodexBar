import CodexBarCore
import Foundation

struct ElevenLabsProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .elevenlabs

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .elevenlabs, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ElevenLabsSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .elevenlabs, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return !context.settings.tokenAccounts(for: .elevenlabs).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "elevenlabs-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from elevenlabs.io/app/settings/api-keys.",
                kind: .secure,
                placeholder: "xi-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
