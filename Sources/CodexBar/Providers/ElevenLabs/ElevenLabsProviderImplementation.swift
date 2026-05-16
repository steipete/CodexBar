import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct ElevenLabsProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .elevenlabs

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.elevenLabsAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ElevenLabsSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                binding: context.stringBinding(\.elevenLabsAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
