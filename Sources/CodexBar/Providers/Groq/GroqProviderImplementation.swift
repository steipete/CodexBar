import CodexBarCore
import Foundation

struct GroqProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .groq

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "metrics" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.groqAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.groqToken(environment: context.environment) != nil ||
            !context.settings.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "groq-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Metrics require Groq Enterprise Prometheus access.",
                kind: .secure,
                placeholder: "gsk_...",
                binding: context.stringBinding(\.groqAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
